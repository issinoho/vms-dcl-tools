$!------------------------------------------------------------------------------
$! UPTIME.COM - Uptime of every cluster member
$!
$! Lists each node in the cluster with its hardware, OpenVMS version, votes,
$! boot time and uptime, after when the cluster was formed and its quorum.
$! On a standalone system it shows just that system. Nodes up for less than
$! a day are highlighted, so a recent reboot stands out.
$!
$! Usage:   @UPTIME [option ...]
$!
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! Colour is used only on an ANSI terminal; output to a file or batch log is
$! plain text. Works on VAX, Alpha, IA64 and x86-64, needs no privileges,
$! and uses plain DCL only.
$!
$! Based on the UPTIME procedure by RDJ (1994). Rewritten.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ ut_verify = f$verify(0)
$ set noon
$ on control_y then goto interrupted
$ ut_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Options -----------------------------------------------------------------
$ ut_plain = 0
$ ut_p = 0
$opt_loop:
$ ut_p = ut_p + 1
$ if ut_p .gt. 8 then goto opt_done
$ ut_opt = f$edit(p'ut_p', "TRIM,UPCASE")
$ if ut_opt .eqs. "" then goto opt_loop
$ ut_len = f$length(ut_opt)
$ if ut_opt .eqs. f$extract(0, ut_len, "HELP") .or. ut_opt .eqs. "?" -
     then goto help
$ if ut_opt .eqs. f$extract(0, ut_len, "PLAIN")
$ then
$   ut_plain = 1
$   goto opt_loop
$ endif
$ set message 'ut_msg'
$ write sys$output "UPTIME: unknown option ''ut_opt' (try @UPTIME HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ ut_width = 80
$ ut_ansi  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     ut_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     ut_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if ut_w .ge. 80 .and. ut_w .le. 132 then ut_width = ut_w
$   endif
$ endif
$ if ut_plain then ut_ansi = 0
$ ut_bold = ""
$ ut_key  = ""
$ ut_yel  = ""
$ ut_off  = ""
$ if ut_ansi
$ then
$   ut_esc[0,8] = 27
$   ut_bold = ut_esc + "[1m"
$   ut_key  = ut_esc + "[1;34m"             ! bold blue labels and headings
$   ut_yel  = ut_esc + "[1;33m"             ! up less than a day
$   ut_off  = ut_esc + "[0m"
$ endif
$!
$!---- Box ---------------------------------------------------------------------
$! DEC Special Graphics line drawing on an ANSI terminal, as the original
$! had; plain +-| elsewhere, so files and batch logs stay readable.
$ ut_gon  = ""
$ ut_goff = ""
$ ut_c_tl = "+"
$ ut_c_tr = "+"
$ ut_c_bl = "+"
$ ut_c_br = "+"
$ ut_c_ml = "+"
$ ut_c_mr = "+"
$ ut_c_h  = "-"
$ ut_c_v  = "|"
$ if ut_ansi
$ then
$   ut_gon  = ut_esc + "(0"
$   ut_goff = ut_esc + "(B"
$   ut_c_tl = "l"
$   ut_c_tr = "k"
$   ut_c_bl = "m"
$   ut_c_br = "j"
$   ut_c_ml = "t"
$   ut_c_mr = "u"
$   ut_c_h  = "q"
$   ut_c_v  = "x"
$ endif
$ ut_cw = ut_width - 6                      ! room inside the box
$ ut_hn = ut_cw + 2
$ ut_hline = f$fao("!''ut_hn'*''ut_c_h'")
$!
$ ut_local  = f$edit(f$getsyi("NODENAME"), "TRIM")
$ ut_member = f$getsyi("CLUSTER_MEMBER")
$! Columns: node 9, hardware (whatever is left), version 9, votes 5 (in a
$! cluster only), booted 16, uptime 15.
$ ut_hw_w = ut_cw - 9 - 9 - 16 - 15 - 4
$ if ut_member then ut_hw_w = ut_hw_w - 6
$ if ut_hw_w .gt. 40 then ut_hw_w = 40
$!
$!---- Title -------------------------------------------------------------------
$ ut_title = "Uptime for cluster members"
$ if .not. ut_member then ut_title = "Uptime for " + ut_local
$ ut_now = f$extract(0, 17, f$time())
$ ut_pad = ut_cw - f$length(ut_title) - f$length(ut_now)
$ if ut_pad .lt. 1 then ut_pad = 1
$ write sys$output ""
$ ut_l = ut_c_tl
$ ut_r = ut_c_tr
$ gosub box_rule
$ ut_txt = ut_bold + ut_title + ut_off + f$fao("!''ut_pad'* ") + ut_now
$ ut_vl  = f$length(ut_title) + ut_pad + f$length(ut_now)
$ gosub box_line
$ ut_l = ut_c_ml
$ ut_r = ut_c_mr
$ gosub box_rule
$!
$!---- Cluster summary ---------------------------------------------------------
$ if ut_member
$ then
$   ut_ft = ""
$   ut_ft = f$getsyi("CLUSTER_FTIME")
$   if ut_ft .nes. ""
$   then
$     ut_k = "Formed"
$     ut_val = f$extract(0, 17, f$cvtime(ut_ft, "ABSOLUTE"))
$     gosub box_kv
$   endif
$   ut_k = "Members"
$   ut_val = f$fao("!UL", f$getsyi("CLUSTER_NODES"))
$   gosub box_kv
$   ut_k = "Votes"
$   ut_val = f$fao("!UL, quorum !UL", f$getsyi("CLUSTER_VOTES"), -
                   f$getsyi("CLUSTER_QUORUM"))
$   gosub box_kv
$ else
$   ut_k = "Cluster"
$   ut_val = "not a cluster member"
$   gosub box_kv
$ endif
$ gosub box_rule
$!
$!---- One row per node --------------------------------------------------------
$ if ut_member
$ then
$   ut_plain_txt = f$fao("!9AS !''ut_hw_w'AS !9AS !5AS !16AS !15AS", "Node", -
                   "Hardware", "Version", "Votes", "Booted", "Uptime")
$ else
$   ut_plain_txt = f$fao("!9AS !''ut_hw_w'AS !9AS !16AS !15AS", "Node", -
                   "Hardware", "Version", "Booted", "Uptime")
$ endif
$ ut_txt = ut_key + ut_plain_txt + ut_off
$ ut_vl  = f$length(ut_plain_txt)
$ gosub box_line
$!
$ ut_t = f$cvtime(, "COMPARISON")           ! now, for the uptimes
$ gosub civil_days
$ ut_dnow = ut_days
$ ut_snow = ut_secs
$ ut_n = 0
$ ut_long  = -1
$ ut_short = -1
$ ut_ctx = ""
$node_next:
$ if ut_member
$ then
$   ut_id = f$csid(ut_ctx)
$   if ut_id .eqs. "" then goto node_done
$ else
$   if ut_n .gt. 0 then goto node_done
$   ut_id = ""
$ endif
$ ut_n = ut_n + 1
$ ut_boot = ""
$ if ut_id .eqs. ""
$ then
$   ut_node = ut_local
$   ut_boot = f$getsyi("BOOTTIME")
$ else
$   ut_node = f$edit(f$getsyi("NODENAME", , ut_id), "TRIM")
$   ut_boot = f$getsyi("BOOTTIME", , ut_id)
$ endif
$ ut_hw = ""
$ ut_hw = f$edit(f$getsyi("HW_NAME", ut_node), "TRIM,COMPRESS")
$ if ut_hw .eqs. "" then -
    ut_hw = f$edit(f$getsyi("NODE_HWTYPE", ut_node), "TRIM")
$ ut_ver = ""
$ ut_ver = f$edit(f$getsyi("NODE_SWVERS", ut_node), "TRIM")
$ ut_votes = ""
$ ut_votes = f$getsyi("NODE_VOTES", ut_node)
$ if f$type(ut_votes) .eqs. "INTEGER" then ut_votes = f$fao("!5UL", ut_votes)
$!
$ ut_bt  = ""
$ ut_upt = ""
$ ut_new = 0                                ! up less than a day
$ if ut_boot .nes. ""
$ then
$   ut_t = f$cvtime(ut_boot, "COMPARISON")
$   ut_bt = f$extract(0, 16, ut_t)          ! yyyy-mm-dd hh:mm
$   gosub civil_days
$   ut_dd = ut_dnow - ut_days
$   ut_ss = ut_snow - ut_secs
$   if ut_ss .lt. 0
$   then
$     ut_ss = ut_ss + 86400
$     ut_dd = ut_dd - 1
$   endif
$   ut_hh = ut_ss / 3600
$   ut_mm = (ut_ss - ut_hh * 3600) / 60
$   if ut_dd .gt. 0
$   then
$     ut_upt = f$fao("!UL day!%S, !UL:!2ZL", ut_dd, ut_hh, ut_mm)
$   else
$     ut_upt = f$fao("!UL:!2ZL", ut_hh, ut_mm)
$     ut_new = 1
$   endif
$   ut_mins = ut_dd * 1440 + ut_hh * 60 + ut_mm
$   if ut_mins .gt. ut_long
$   then
$     ut_long = ut_mins
$     ut_long_node = ut_node
$   endif
$   if ut_short .lt. 0 .or. ut_mins .lt. ut_short
$   then
$     ut_short = ut_mins
$     ut_short_node = ut_node
$   endif
$ endif
$!
$ ut_name = ut_node
$ if ut_node .eqs. ut_local then ut_name = ut_node + " *"
$ if ut_member
$ then
$   ut_txt = f$fao("!9AS !''ut_hw_w'AS !9AS !5AS !16AS ", -
                   ut_name, ut_hw, ut_ver, ut_votes, ut_bt)
$ else
$   ut_txt = f$fao("!9AS !''ut_hw_w'AS !9AS !16AS ", -
                   ut_name, ut_hw, ut_ver, ut_bt)
$ endif
$ ut_upt = f$fao("!15AS", ut_upt)
$ ut_vl  = f$length(ut_txt) + 15
$ if ut_new then ut_upt = ut_yel + ut_upt + ut_off
$ ut_txt = ut_txt + ut_upt
$ gosub box_line
$ goto node_next
$node_done:
$!
$!---- Summary -----------------------------------------------------------------
$ ut_l = ut_c_ml
$ ut_r = ut_c_mr
$ gosub box_rule
$ ut_txt = f$fao("!UL node!%S", ut_n)
$ if ut_n .gt. 1 .and. ut_long .ge. 0
$ then
$   ut_txt = ut_txt + ", longest up " + ut_long_node + -
             ", latest boot " + ut_short_node
$ endif
$ ut_txt = ut_txt + " (* = this node)"
$ ut_txt = f$extract(0, ut_cw, ut_txt)
$ ut_vl  = f$length(ut_txt)
$ gosub box_line
$ ut_l = ut_c_bl
$ ut_r = ut_c_br
$ gosub box_rule
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'ut_msg'
$ type sys$input
UPTIME - uptime of every cluster member

Usage:   @UPTIME [option ...]

  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

On a standalone system it shows just that system. Output to a file is
plain text:

  PIPE @UPTIME > UPTIME.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Ctrl/Y: put the terminal back in its normal character set first.
$interrupted:
$ if f$type(ut_goff) .nes. ""
$ then
$   if ut_goff .nes. "" then write sys$output ut_goff, ut_off
$ endif
$cleanup:
$ if f$type(ut_msg) .nes. "" then set message 'ut_msg'
$ exit 1 + 0 * f$verify(ut_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! BOX_RULE: a line across the box, ending in ut_l and ut_r.
$box_rule:
$ write sys$output " ", ut_gon, ut_l, ut_hline, ut_r, ut_goff
$ return
$!
$! BOX_LINE: ut_txt inside the box, padded by its visible length ut_vl.
$box_line:
$ ut_fill = ut_cw - ut_vl
$ ut_sp = ""
$ if ut_fill .gt. 0 then ut_sp = f$fao("!''ut_fill'* ")
$ write sys$output " ", ut_gon, ut_c_v, ut_goff, " ", ut_txt, ut_sp, " ", -
                   ut_gon, ut_c_v, ut_goff
$ return
$!
$! BOX_KV: "label  value" (ut_k, ut_val) inside the box.
$box_kv:
$ ut_val = f$extract(0, ut_cw - 10, ut_val)
$ ut_txt = ut_key + f$fao("!10AS", ut_k) + ut_off + ut_val
$ ut_vl  = 10 + f$length(ut_val)
$ gosub box_line
$ return
$!
$! CIVIL_DAYS: from ut_t ("yyyy-mm-dd hh:mm:ss..."), ut_days = days since a
$! fixed epoch and ut_secs = seconds into that day.
$civil_days:
$ ut_y = f$integer(f$extract(0, 4, ut_t))
$ ut_m = f$integer(f$extract(5, 2, ut_t))
$ ut_d = f$integer(f$extract(8, 2, ut_t))
$ ut_secs = f$integer(f$extract(11, 2, ut_t)) * 3600 + -
            f$integer(f$extract(14, 2, ut_t)) * 60 + -
            f$integer(f$extract(17, 2, ut_t))
$ if ut_m .le. 2 then ut_y = ut_y - 1
$ ut_era = ut_y / 400
$ ut_yoe = ut_y - ut_era * 400
$ ut_mp  = ut_m - 3
$ if ut_m .le. 2 then ut_mp = ut_m + 9
$ ut_doy = (153 * ut_mp + 2) / 5 + ut_d - 1
$ ut_doe = ut_yoe * 365 + ut_yoe / 4 - ut_yoe / 100 + ut_doy
$ ut_days = ut_era * 146097 + ut_doe
$ return
