$!------------------------------------------------------------------------------
$! DEVMON.COM - Live disk monitor for OpenVMS
$!
$! A boxed screen that redraws itself until you press Ctrl/Y, showing every
$! mounted disk with its label, size, share used, a bar, and error count.
$! Shadow sets list each member and its state (copying or merging with
$! percent done, or not available). In a cluster it also shows on how many
$! nodes each disk is mounted, highlighting disks not mounted everywhere,
$! and lists disks mounted on other nodes but not this one.
$!
$! Usage:   @DEVMON [seconds] [option ...]
$!
$!   seconds  time between refreshes, 5 to 86400 (default 60)
$!   ONCE     draw the screen once and exit
$!   PLAIN    no colour, line drawing or screen control
$!   HELP     show this text
$!
$! Output that is not an ANSI terminal (a file, a batch log) is drawn once,
$! in plain text. Works on Alpha, IA64 and x86-64, needs no privileges,
$! and uses plain DCL only.
$!
$! Based on MONITOR_DEVICES.COM by A.G.M. van Ruitenbeek and
$! J.P. van den Ende, PinkRoccade Industry, the Netherlands (2003-2004),
$! whose notice asks that their credits be kept. Rewritten.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ dm_verify = f$verify(0)
$ set noon
$ dm_ansi = 0
$ on control_y then goto cleanup
$ dm_ctl = f$environment("CONTROL")        ! Ctrl/Y may be off (SSH logins);
$ set control=y                            ! turn it on so it can stop us
$ dm_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Settings ----------------------------------------------------------------
$ dm_warn = 80                              ! yellow at or above this percent
$ dm_crit = 90                              ! red at or above this percent
$!
$!---- Options -----------------------------------------------------------------
$ dm_secs  = 60
$ dm_once  = 0
$ dm_plain = 0
$ dm_p = 0
$opt_loop:
$ dm_p = dm_p + 1
$ if dm_p .gt. 8 then goto opt_done
$ dm_opt = f$edit(p'dm_p', "TRIM,UPCASE")
$ if dm_opt .eqs. "" then goto opt_loop
$ dm_len = f$length(dm_opt)
$ if f$type(dm_opt) .eqs. "INTEGER"
$ then
$   dm_secs = f$integer(dm_opt)
$   if dm_secs .ge. 5 .and. dm_secs .le. 86400 then goto opt_loop
$   set message 'dm_msg'
$   write sys$output "DEVMON: seconds must be 5 to 86400"
$   goto cleanup
$ endif
$ if dm_opt .eqs. f$extract(0, dm_len, "HELP") .or. dm_opt .eqs. "?" -
     then goto help
$ if dm_opt .eqs. f$extract(0, dm_len, "ONCE")
$ then
$   dm_once = 1
$   goto opt_loop
$ endif
$ if dm_opt .eqs. f$extract(0, dm_len, "PLAIN")
$ then
$   dm_plain = 1
$   goto opt_loop
$ endif
$ set message 'dm_msg'
$ write sys$output "DEVMON: unknown option ''dm_opt' (try @DEVMON HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ dm_width = 80
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     dm_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     dm_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if dm_w .ge. 80 .and. dm_w .le. 132 then dm_width = dm_w
$   endif
$ endif
$ if dm_plain then dm_ansi = 0
$ if .not. dm_ansi then dm_once = 1         ! no live screen without ANSI
$ dm_bold = ""
$ dm_key  = ""
$ dm_grn  = ""
$ dm_yel  = ""
$ dm_red  = ""
$ dm_rev  = ""
$ dm_off  = ""
$ dm_gon  = ""
$ dm_goff = ""
$ dm_c_tl = "+"
$ dm_c_tr = "+"
$ dm_c_bl = "+"
$ dm_c_br = "+"
$ dm_c_ml = "+"
$ dm_c_mr = "+"
$ dm_c_h  = "-"
$ dm_c_v  = "|"
$ dm_tree = "`-"                            ! before each shadow set member
$ if dm_ansi
$ then
$   dm_esc[0,8] = 27
$   dm_bold = dm_esc + "[1m"
$   dm_key  = dm_esc + "[1;34m"             ! bold blue column headings
$   dm_grn  = dm_esc + "[32m"
$   dm_yel  = dm_esc + "[33m"
$   dm_red  = dm_esc + "[1;31m"
$   dm_rev  = dm_esc + "[7m"                ! not mounted on every node
$   dm_off  = dm_esc + "[0m"
$   dm_gon  = dm_esc + "(0"
$   dm_goff = dm_esc + "(B"
$   dm_c_tl = "l"
$   dm_c_tr = "k"
$   dm_c_bl = "m"
$   dm_c_br = "j"
$   dm_c_ml = "t"
$   dm_c_mr = "u"
$   dm_c_h  = "q"
$   dm_c_v  = "x"
$   dm_tree = dm_gon + "mq" + dm_goff
$ endif
$ dm_cw = dm_width - 6                      ! room inside the box
$ dm_hn = dm_cw + 2
$ dm_hline = f$fao("!''dm_hn'*''dm_c_h'")
$!
$ dm_member = f$getsyi("CLUSTER_MEMBER")
$! Columns: device 15, label 12, size 8, use 4, errors 5, mounts 3 (in a
$! cluster only), then a bar "  [....]" in whatever is left.
$ dm_bw = dm_cw - 15 - 12 - 8 - 4 - 5 - 4 - 4
$ if dm_member then dm_bw = dm_bw - 4
$ if dm_bw .gt. 40 then dm_bw = 40
$ dm_colplain = f$fao("!15AS !12AS !8AS !4AS !5AS", "Device", "Label", -
                      "    Size", " Use", " Errs")
$ if dm_member then dm_colplain = dm_colplain + " Mnt"
$! Scale over the bar: 25, 50 and 75 percent.
$ dm_scale = ""
$ if dm_bw .ge. 12
$ then
$   dm_scale = f$fao("!''dm_bw'* ")
$   dm_q = 25
$scale_next:
$   dm_at = dm_q * dm_bw / 100 - 2
$   dm_scale['dm_at',2] := 'dm_q'
$   dm_q = dm_q + 25
$   if dm_q .le. 75 then goto scale_next
$   dm_colplain = dm_colplain + "   " + dm_scale
$ endif
$!
$ dm_wait = f$fao("!2ZL:!2ZL:!2ZL", dm_secs / 3600, -
                  (dm_secs - (dm_secs / 3600) * 3600) / 60, -
                  dm_secs - (dm_secs / 60) * 60)
$ dm_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ dm_sysdev = f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM")
$ if dm_ansi
$ then
$   write sys$output dm_esc, "[2J"          ! clear the screen once
$   write sys$output dm_esc, "[?25l"        ! and hide the cursor
$ endif
$!
$!==============================================================================
$! Draw the screen
$!==============================================================================
$draw:
$ if dm_ansi then write sys$output dm_esc, "[H"   ! back to the top
$ dm_title = "Disk monitor on " + dm_node
$ dm_now = f$extract(0, 20, f$time())
$ dm_pad = dm_cw - f$length(dm_title) - f$length(dm_now)
$ if dm_pad .lt. 1 then dm_pad = 1
$ dm_l = dm_c_tl
$ dm_r = dm_c_tr
$ gosub box_rule
$ dm_txt = dm_bold + dm_title + dm_off + f$fao("!''dm_pad'* ") + dm_now
$ dm_vl  = f$length(dm_title) + dm_pad + f$length(dm_now)
$ gosub box_line
$ dm_l = dm_c_ml
$ dm_r = dm_c_mr
$ gosub box_rule
$ dm_txt = dm_key + dm_colplain + dm_off
$ dm_vl  = f$length(dm_colplain)
$ gosub box_line
$!
$ dm_nodes = 0
$ if dm_member then dm_nodes = f$getsyi("CLUSTER_NODES")
$ dm_n     = 0                              ! disks shown
$ dm_full  = 0                              ! at or above dm_crit
$ dm_errd  = 0                              ! with device errors
$ dm_degr  = 0                              ! shadow sets not fully whole
$ dm_rem   = 0                              ! mounted elsewhere only
$disk_next:
$ dm_dev = ""
$ dm_dev = f$device("*", "DISK")
$ if dm_dev .eqs. "" then goto disk_done
$ if f$getdvi(dm_dev, "SHDW_MEMBER") then goto disk_next  ! under its set
$ dm_name = f$getdvi(dm_dev, "DEVNAM") - "_"
$ if f$locate("DNFS", dm_name) .lt. f$length(dm_name) then -
    goto disk_next                          ! NFS client disk
$!
$! Cluster mount count (blank if this system can't tell).
$ dm_mc = ""
$ if dm_member then dm_mc = f$getdvi(dm_dev, "MOUNTCNT_CLUSTER")
$!
$ if .not. f$getdvi(dm_dev, "MNT")
$ then
$   if f$type(dm_mc) .nes. "INTEGER" then goto disk_next
$   if dm_mc .le. 0 then goto disk_next
$   dm_rem = dm_rem + 1                     ! mounted on other nodes only
$   dm_txt = f$fao("!15AS mounted on !UL other node!%S", dm_name, dm_mc)
$   dm_vl  = f$length(dm_txt)
$   gosub box_line
$   goto disk_next
$ endif
$ if f$getdvi(dm_dev, "FOR") then goto disk_next
$!
$ dm_max = f$getdvi(dm_dev, "MAXBLOCK")
$ if dm_max .le. 0 then goto disk_next
$ dm_fb  = f$getdvi(dm_dev, "FREEBLOCKS")
$ dm_n = dm_n + 1
$ dm_pc = 0
$ if dm_max .ge. 100 then dm_pc = (dm_max - dm_fb) / (dm_max / 100)
$ if dm_pc .gt. 100 then dm_pc = 100
$ if dm_pc .ge. dm_crit then dm_full = dm_full + 1
$ if f$getdvi(dm_dev, "FULLDEVNAM") .eqs. dm_sysdev then dm_name = dm_name + "*"
$ dm_lab = f$edit(f$getdvi(dm_dev, "VOLNAM"), "TRIM")
$ dm_mb = dm_max / 2048
$ gosub fmt_mb
$ dm_err = f$getdvi(dm_dev, "ERRCNT")
$ if dm_err .gt. 0 then dm_errd = dm_errd + 1
$!
$ dm_txt = f$fao("!15AS !12AS !8AS ", dm_name, dm_lab, dm_size)
$ dm_vl  = f$length(dm_txt)
$ gosub use_col
$ dm_e = f$fao("!5UL", dm_err)
$ dm_vl = dm_vl + 6
$ if dm_err .gt. 0 then dm_e = dm_yel + dm_e + dm_off
$ dm_txt = dm_txt + " " + dm_e
$ if dm_member
$ then
$   dm_m = "   "
$   if f$type(dm_mc) .eqs. "INTEGER" then dm_m = f$fao("!3UL", dm_mc)
$   if f$type(dm_mc) .eqs. "INTEGER" .and. dm_mc .lt. dm_nodes then -
      dm_m = dm_rev + dm_m + dm_off
$   dm_txt = dm_txt + " " + dm_m
$   dm_vl = dm_vl + 4
$ endif
$ gosub bar
$ gosub box_line
$!
$! Shadow set members, in the set's order.
$ if f$getdvi(dm_dev, "SHDW_MASTER") then gosub members
$ goto disk_next
$!
$disk_done:
$ if dm_n .eq. 0 .and. dm_rem .eq. 0
$ then
$   dm_txt = "No mounted disks"
$   dm_vl  = f$length(dm_txt)
$   gosub box_line
$ endif
$!
$!---- Summary -----------------------------------------------------------------
$ dm_l = dm_c_ml
$ dm_r = dm_c_mr
$ gosub box_rule
$ dm_txt = f$fao("!UL disk!%S", dm_n)
$ if dm_full .gt. 0 then dm_txt = dm_txt + f$fao(", !UL !UL% full or more", -
                                               dm_full, dm_crit)
$ if dm_errd .gt. 0 then dm_txt = dm_txt + f$fao(", !UL with errors", dm_errd)
$ if dm_degr .gt. 0 then -
    dm_txt = dm_txt + f$fao(", !UL shadow set!%S not whole", dm_degr)
$ if dm_txt .eqs. f$fao("!UL disk!%S", dm_n) then -
    dm_txt = dm_txt + ", all well"
$ dm_txt = dm_txt + " (* = system disk)"
$ dm_txt = f$extract(0, dm_cw, dm_txt)
$ dm_vl  = f$length(dm_txt)
$ gosub box_line
$ if .not. dm_once
$ then
$   dm_txt = "Refreshes every " + dm_wait + "; press Ctrl/Y to stop"
$   dm_vl  = f$length(dm_txt)
$   gosub box_line
$ endif
$ dm_l = dm_c_bl
$ dm_r = dm_c_br
$ gosub box_rule
$ if dm_ansi then write sys$output dm_esc, "[J"   ! clear anything below
$ if dm_once then goto cleanup
$ wait 'dm_wait'
$ goto draw
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'dm_msg'
$ type sys$input
DEVMON - live disk monitor for OpenVMS

Usage:   @DEVMON [seconds] [option ...]

  seconds  time between refreshes, 5 to 86400 (default 60)
  ONCE     draw the screen once and exit
  PLAIN    no colour, line drawing or screen control
  HELP     show this text

Press Ctrl/Y to stop. Output to a file or batch log is drawn once, in
plain text:

  PIPE @DEVMON > DEVMON.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Put the terminal back: normal characters, cursor on, below the box.
$cleanup:
$ if dm_ansi then write sys$output dm_esc, "(B", dm_esc, "[0m", -
                                   dm_esc, "[?25h"
$ if f$type(dm_msg) .nes. "" then set message 'dm_msg'
$ if f$type(dm_ctl) .nes. "" then -
    if f$locate("Y", dm_ctl) .eq. f$length(dm_ctl) then set nocontrol=y
$ exit 1 + 0 * f$verify(dm_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! MEMBERS: one line per member of the shadow set dm_dev, following the
$! chain of SHDW_NEXT_MBR_NAME.
$members:
$ dm_set_ok = 1
$ dm_mbr = ""
$ dm_mbr = f$getdvi(dm_dev, "SHDW_NEXT_MBR_NAME")
$ dm_k = 0
$mbr_next:
$ if dm_mbr .eqs. "" .or. dm_k .ge. 16 then goto mbr_done
$ dm_k = dm_k + 1
$ dm_mn = dm_mbr - "_"
$ dm_st = "member"
$ dm_sc = ""                                ! colour for the state
$ if .not. f$getdvi(dm_mbr, "AVL") .or. .not. f$getdvi(dm_mbr, "MNT")
$ then
$   dm_st = "not available"
$   dm_sc = dm_red
$ endif
$ if f$getdvi(dm_mbr, "SHDW_CATCHUP_COPYING")
$ then
$   dm_st = "copying"
$   dm_pd = ""
$   dm_pd = f$getdvi(dm_mbr, "SHDW_MBR_COPY_DONE")
$   if f$type(dm_pd) .eqs. "INTEGER" then dm_st = dm_st + f$fao(" !UL%", dm_pd)
$   dm_sc = dm_yel
$ endif
$ if f$getdvi(dm_mbr, "SHDW_MERGE_COPYING")
$ then
$   dm_st = "merging"
$   dm_pd = ""
$   dm_pd = f$getdvi(dm_mbr, "SHDW_MBR_MERGE_DONE")
$   if f$type(dm_pd) .eqs. "INTEGER" then dm_st = dm_st + f$fao(" !UL%", dm_pd)
$   dm_sc = dm_yel
$ endif
$ if dm_sc .nes. "" .or. dm_st .nes. "member" then dm_set_ok = 0
$ dm_me = f$getdvi(dm_mbr, "ERRCNT")
$ if dm_me .gt. 0 then dm_st = dm_st + f$fao(", !UL error!%S", dm_me)
$ dm_txt = " " + dm_tree + " " + f$fao("!16AS ", dm_mn) + dm_sc + dm_st + dm_off
$ dm_vl  = 4 + 17 + f$length(dm_st)
$ gosub box_line
$ dm_next = ""
$ dm_next = f$getdvi(dm_mbr, "SHDW_NEXT_MBR_NAME")
$ dm_mbr = dm_next
$ goto mbr_next
$mbr_done:
$ if dm_k .eq. 0 then dm_set_ok = 0         ! a set with no members found
$ if .not. dm_set_ok then dm_degr = dm_degr + 1
$ return
$!
$! USE_COL: append " 62%" to dm_txt, coloured by level (dm_vl updated).
$use_col:
$ dm_col = dm_grn
$ if dm_pc .ge. dm_warn then dm_col = dm_yel
$ if dm_pc .ge. dm_crit then dm_col = dm_red
$ dm_txt = dm_txt + dm_col + f$fao("!3UL%", dm_pc) + dm_off
$ dm_vl  = dm_vl + 4
$ return
$!
$! BAR: append "  [#####.....]" for dm_pc to dm_txt (dm_vl updated).
$bar:
$ if dm_bw .lt. 5 then return
$ dm_fill = (dm_pc * dm_bw + 50) / 100
$ if dm_fill .gt. dm_bw then dm_fill = dm_bw
$ dm_rest = dm_bw - dm_fill
$ dm_b = ""
$ if dm_fill .gt. 0 then dm_b = f$fao("!''dm_fill'*#")
$ dm_d = ""
$ if dm_rest .gt. 0 then dm_d = f$fao("!''dm_rest'*.")
$ dm_txt = dm_txt + "  [" + dm_col + dm_b + dm_off + dm_d + "]"
$ dm_vl  = dm_vl + dm_bw + 4
$ return
$!
$! BOX_RULE: a line across the box, ending in dm_l and dm_r.
$box_rule:
$ write sys$output " ", dm_gon, dm_l, dm_hline, dm_r, dm_goff
$ return
$!
$! BOX_LINE: dm_txt inside the box, padded by its visible length dm_vl.
$box_line:
$ dm_fill = dm_cw - dm_vl
$ dm_sp = ""
$ if dm_fill .gt. 0 then dm_sp = f$fao("!''dm_fill'* ")
$ write sys$output " ", dm_gon, dm_c_v, dm_goff, " ", dm_txt, dm_sp, " ", -
                   dm_gon, dm_c_v, dm_goff
$ return
$!
$! FMT_MB: dm_size = dm_mb megabytes as "512 MB", "33.9 GB" or "1.2 TB".
$fmt_mb:
$ if dm_mb .lt. 1024
$ then
$   dm_size = f$fao("!UL MB", dm_mb)
$   return
$ endif
$ dm_gb = dm_mb / 1024
$ if dm_gb .lt. 1024
$ then
$   dm_size = f$fao("!UL.!UL GB", dm_gb, (dm_mb - dm_gb * 1024) * 10 / 1024)
$   return
$ endif
$ dm_tb = dm_gb / 1024
$ dm_size = f$fao("!UL.!UL TB", dm_tb, (dm_gb - dm_tb * 1024) * 10 / 1024)
$ return
