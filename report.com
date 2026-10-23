$!------------------------------------------------------------------------------
$! REPORT.COM - System configuration report for OpenVMS
$!
$! A fuller, sectioned companion to SYSINFO.COM, for system managers:
$! identity and boot, processors, memory and paging, global resources,
$! key SYSGEN parameters, cluster membership and members, network
$! identity and every mounted disk.
$!
$! Usage:   @REPORT [option ...]
$!
$!   BRIEF    leave out the SYSGEN parameters, cluster member list and disks
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! Colour is used only on an ANSI terminal; output to a file or batch log is
$! plain text. Works on VAX, Alpha, IA64 and x86-64, needs no privileges,
$! and uses plain DCL only. Anything a system cannot report is left out
$! rather than failing.
$!
$! To add a line to a section, gather the value, then:
$!     $ rp_k = "Label"
$!     $ rp_v = value
$!     $ gosub kv
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ rp_verify = f$verify(0)
$ set noon
$ on control_y then goto cleanup
$! Lexicals a system does not support fail quietly and are skipped.
$ rp_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Options -----------------------------------------------------------------
$ rp_brief = 0
$ rp_plain = 0
$ rp_p = 0
$opt_loop:
$ rp_p = rp_p + 1
$ if rp_p .gt. 8 then goto opt_done
$ rp_opt = f$edit(p'rp_p', "TRIM,UPCASE")
$ if rp_opt .eqs. "" then goto opt_loop
$ rp_len = f$length(rp_opt)                 ! options may be abbreviated
$ if rp_opt .eqs. f$extract(0, rp_len, "HELP") .or. rp_opt .eqs. "?" -
     then goto help
$ if rp_opt .eqs. f$extract(0, rp_len, "BRIEF")
$ then
$   rp_brief = 1
$   goto opt_loop
$ endif
$ if rp_opt .eqs. f$extract(0, rp_len, "PLAIN")
$ then
$   rp_plain = 1
$   goto opt_loop
$ endif
$ set message 'rp_msg'
$ write sys$output "REPORT: unknown option ''rp_opt' (try @REPORT HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ rp_width = 80
$ rp_ansi  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     rp_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     rp_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if rp_w .ge. 64 .and. rp_w .le. 132 then rp_width = rp_w
$   endif
$ endif
$ if rp_plain then rp_ansi = 0
$ rp_bold = ""
$ rp_head = ""
$ rp_key  = ""
$ rp_off  = ""
$ if rp_ansi
$ then
$   rp_esc[0,8] = 27
$   rp_bold = rp_esc + "[1m"
$   rp_head = rp_esc + "[1;31m"             ! bold red section headings
$   rp_key  = rp_esc + "[1;34m"             ! bold blue labels
$   rp_off  = rp_esc + "[0m"
$ endif
$ rp_kw = 22                                ! label width
$ rp_vw = rp_width - 3 - rp_kw              ! room for values
$ rp_rw = rp_width - 2                      ! rule width
$!
$!==============================================================================
$! Header
$!==============================================================================
$ rp_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ rp_title = "System configuration report for " + rp_node
$ rp_now = f$extract(0, 17, f$time())
$ rp_pad = rp_rw - 2 - f$length(rp_title) - f$length(rp_now)
$ if rp_pad .lt. 1 then rp_pad = 1
$ write sys$output ""
$ write sys$output " ", f$fao("!''rp_rw'*=")
$ write sys$output "  ", rp_bold, rp_title, rp_off, -
                   f$fao("!''rp_pad'* "), rp_now
$ write sys$output " ", f$fao("!''rp_rw'*=")
$!
$!==============================================================================
$! System
$!==============================================================================
$ rp_hd = "System"
$ gosub heading
$!
$ rp_item = "ARCH_NAME"
$ gosub get_syi
$ rp_arch = rp_val
$ rp_k = "Operating system"
$ rp_v = "OpenVMS " + f$edit(f$getsyi("VERSION"), "TRIM")
$ if rp_arch .nes. "" then rp_v = rp_v + " on " + rp_arch
$ gosub kv
$!
$ rp_k = "Hardware"
$ rp_v = f$edit(f$getsyi("HW_NAME"), "TRIM,COMPRESS")
$ gosub kv
$!
$ rp_item = "CONSOLE_VERSION"
$ gosub get_syi
$ if rp_val .nes. ""
$ then
$   rp_k = "Firmware"
$   rp_v = f$edit(rp_val, "TRIM,COMPRESS")
$   gosub kv
$ endif
$!
$ rp_k = "SCS node / system ID"
$ rp_v = rp_node
$ rp_item = "SCSSYSTEMID"
$ gosub get_syi
$ if rp_val .nes. "" then rp_v = rp_v + f$fao(" / !UL", rp_val)
$ gosub kv
$!
$ rp_item = "SID"
$ gosub get_syi
$ if rp_val .nes. ""
$ then
$   rp_k = "System type (SID)"
$   rp_v = f$fao("%X!XL", rp_val)
$   gosub kv
$ endif
$!
$! Boot time and uptime
$ rp_item = "BOOTTIME"
$ gosub get_syi
$ if rp_val .nes. ""
$ then
$   rp_boot = rp_val
$   rp_t = f$cvtime(rp_boot, "COMPARISON")
$   gosub civil_days
$   rp_d1 = rp_days
$   rp_s1 = rp_secs
$   rp_t = f$cvtime(, "COMPARISON")
$   gosub civil_days
$   rp_dd = rp_days - rp_d1
$   rp_ss = rp_secs - rp_s1
$   if rp_ss .lt. 0
$   then
$     rp_ss = rp_ss + 86400
$     rp_dd = rp_dd - 1
$   endif
$   rp_hh = rp_ss / 3600
$   rp_mm = (rp_ss - rp_hh * 3600) / 60
$   rp_up = ""
$   if rp_dd .gt. 0 then rp_up = f$fao("!UL day!%S, ", rp_dd)
$   if rp_dd .gt. 0 .or. rp_hh .gt. 0 then -
      rp_up = rp_up + f$fao("!UL hour!%S, ", rp_hh)
$   rp_up = rp_up + f$fao("!UL min!%S", rp_mm)
$   rp_k = "Booted"
$   rp_v = f$extract(0, 17, f$cvtime(rp_boot, "ABSOLUTE")) + -
           " (up " + rp_up + ")"
$   gosub kv
$ endif
$!
$ rp_k = "Time zone"
$ rp_v = f$trnlnm("SYS$TIMEZONE_NAME")
$ rp_tdf = f$trnlnm("SYS$TIMEZONE_DIFFERENTIAL")
$ if f$type(rp_tdf) .eqs. "INTEGER"
$ then
$   rp_tdf = f$integer(rp_tdf)
$   rp_sign = "+"
$   if rp_tdf .lt. 0
$   then
$     rp_sign = "-"
$     rp_tdf = - rp_tdf
$   endif
$   rp_v = rp_v + f$fao(" (UTC!AS!UL:!2ZL)", rp_sign, rp_tdf / 3600, -
                        (rp_tdf - (rp_tdf / 3600) * 3600) / 60)
$ endif
$ rp_v = f$edit(rp_v, "TRIM")
$ if rp_v .nes. "" then gosub kv
$!
$ rp_item = "WINDOW_SYSTEM"
$ gosub get_syi
$ if f$type(rp_val) .eqs. "INTEGER"
$ then
$   rp_k = "Windowing system"
$   rp_v = f$fao("unknown (!UL)", rp_val)
$   if rp_val .eq. 0 then rp_v = "none"
$   if rp_val .eq. 1 then rp_v = "DECwindows Motif"
$   if rp_val .eq. 2 then rp_v = "VAX Workstation Software (UIS)"
$   gosub kv
$ endif
$!
$ rp_k = "Allocation class"
$ rp_v = f$fao("disk !UL, tape !UL", -
               f$getsyi("ALLOCLASS"), f$getsyi("TAPE_ALLOCLASS"))
$ gosub kv
$!
$!==============================================================================
$! Processors
$!==============================================================================
$ rp_hd = "Processors"
$ gosub heading
$ rp_k = "CPUs"
$ rp_v = f$fao("!UL active of !UL available", -
               f$getsyi("ACTIVECPU_CNT"), f$getsyi("AVAILCPU_CNT"))
$ gosub kv
$!
$! Vector processors existed only on some VAX models.
$ if rp_arch .eqs. "VAX"
$ then
$   rp_item = "VP_NUMBER"
$   gosub get_syi
$   rp_vp = rp_val
$   rp_item = "VECTOR_EMULATOR"
$   gosub get_syi
$   if rp_vp .nes. ""
$   then
$     rp_k = "Vector processors"
$     rp_v = f$fao("!UL", rp_vp)
$     if rp_val .eqs. "TRUE" .or. rp_val .eq. 1 then -
        rp_v = rp_v + ", vector emulation active"
$     gosub kv
$   endif
$ endif
$!
$!==============================================================================
$! Memory and paging
$!==============================================================================
$ rp_hd = "Memory and paging"
$ gosub heading
$! MEMSIZE is in CPU pages: 512 bytes on VAX, 8192 elsewhere.
$ rp_pgs = 512
$ rp_item = "PAGE_SIZE"
$ gosub get_syi
$ if f$type(rp_val) .eqs. "INTEGER" then rp_pgs = rp_val
$ if rp_pgs .le. 0 then rp_pgs = 512
$ rp_mem = f$getsyi("MEMSIZE")
$ rp_mb  = rp_mem / (1048576 / rp_pgs)
$ gosub fmt_mb
$ rp_k = "Physical memory"
$ rp_v = rp_size + f$fao(" (!UL pages of !UL bytes)", rp_mem, rp_pgs)
$ gosub kv
$!
$ rp_k   = "Page files"
$ rp_tot = f$getsyi("PAGEFILE_PAGE")
$ rp_fre = f$getsyi("PAGEFILE_FREE")
$ gosub fmt_use
$ gosub kv
$ rp_k   = "Swap files"
$ rp_tot = f$getsyi("SWAPFILE_PAGE")
$ rp_fre = f$getsyi("SWAPFILE_FREE")
$ gosub fmt_use
$ gosub kv
$!
$! AWSA is on when WSINC is non-zero; PFRATL 0 stops it shrinking.
$ rp_item = "WSINC"
$ gosub get_syi
$ if f$type(rp_val) .eqs. "INTEGER"
$ then
$   rp_k = "Working set adjust"
$   rp_v = "disabled (WSINC 0)"
$   if rp_val .gt. 0
$   then
$     rp_v = "enabled"
$     if f$getsyi("PFRATL") .eq. 0 then rp_v = rp_v + ", grows only (PFRATL 0)"
$   endif
$   gosub kv
$ endif
$!
$ rp_k   = "Global pages"
$ rp_tot = f$getsyi("GBLPAGES")
$ rp_fre = f$getsyi("FREE_GBLPAGES")
$ gosub fmt_use
$ rp_item = "CONTIG_GBLPAGES"
$ gosub get_syi
$ if f$type(rp_val) .eqs. "INTEGER" then -
    rp_v = rp_v + f$fao(", largest free run !UL", rp_val)
$ gosub kv
$ rp_k   = "Global sections"
$ rp_tot = f$getsyi("GBLSECTIONS")
$ rp_fre = f$getsyi("FREE_GBLSECTS")
$ gosub fmt_use
$ gosub kv
$!
$!==============================================================================
$! SYSGEN parameters (not with BRIEF)
$!==============================================================================
$! One entry per parameter: "NAME|what it is". Add or remove as you like.
$ rp_sg_1 = "MAXPROCESSCNT|process slots"
$ rp_sg_2 = "BALSETCNT|balance set slots"
$ rp_sg_3 = "WSMAX|largest working set"
$ rp_sg_4 = "VIRTUALPAGECNT|largest process virtual size"
$ rp_sg_5 = "NPAGEDYN|nonpaged pool, bytes"
$ rp_sg_6 = "PAGEDYN|paged pool, bytes"
$ rp_sg_7 = "GBLPAGFIL|global pages backed by page file"
$ rp_sg_8 = "LOCKIDTBL|lock ID table entries"
$ rp_sg_9 = "BUGCHECKFATAL|crash on any bugcheck (1 = yes)"
$ if .not. rp_brief
$ then
$   rp_hd = "SYSGEN parameters"
$   gosub heading
$   rp_i = 0
$sg_next:
$   rp_i = rp_i + 1
$   if f$type(rp_sg_'rp_i') .eqs. "" then goto sg_done
$   rp_e = rp_sg_'rp_i'
$   rp_item = f$element(0, "|", rp_e)
$   gosub get_syi
$   if f$type(rp_val) .nes. "INTEGER" then goto sg_next
$   rp_k = rp_item
$   rp_v = f$fao("!12UL  !AS", rp_val, f$element(1, "|", rp_e))
$   gosub kv
$   goto sg_next
$sg_done:
$ endif
$!
$!==============================================================================
$! Cluster
$!==============================================================================
$ rp_hd = "Cluster"
$ gosub heading
$ if .not. f$getsyi("CLUSTER_MEMBER")
$ then
$   rp_k = "Membership"
$   rp_v = rp_node + " is not a cluster member"
$   gosub kv
$   goto cl_done
$ endif
$!
$! Collect every member, and find the founding node by its system ID.
$ rp_fid = -1
$ rp_item = "CLUSTER_FSYSID"
$ gosub get_syi
$ if rp_val .nes. "" then rp_fid = f$integer("%X" + f$edit(rp_val, "TRIM"))
$ rp_found = ""
$ rp_cn = 0
$ rp_ctx = ""
$cl_next:
$ rp_id = f$csid(rp_ctx)
$ if rp_id .eqs. "" then goto cl_list
$ rp_cn = rp_cn + 1
$ rp_cl_name_'rp_cn' = f$edit(f$getsyi("NODENAME", , rp_id), "TRIM")
$ rp_cl_hw_'rp_cn'   = f$edit(f$getsyi("NODE_HWTYPE", , rp_id), "TRIM")
$ rp_cl_ver_'rp_cn'  = f$edit(f$getsyi("NODE_SWVERS", , rp_id), "TRIM")
$ rp_cl_vote_'rp_cn' = 0
$ rp_cl_vote_'rp_cn' = f$getsyi("NODE_VOTES", , rp_id)
$ rp_sid = f$edit(f$getsyi("NODE_SYSTEMID", , rp_id), "TRIM")
$ if rp_sid .nes. "" .and. rp_fid .ge. 0
$ then
$   if f$integer("%X" + rp_sid) .eq. rp_fid then rp_found = rp_cl_name_'rp_cn'
$ endif
$ goto cl_next
$cl_list:
$ rp_k = "Membership"
$ rp_v = f$fao("member of a !UL-node cluster", f$getsyi("CLUSTER_NODES"))
$ gosub kv
$!
$ rp_item = "CLUSTER_FTIME"
$ gosub get_syi
$ if rp_val .nes. ""
$ then
$   rp_k = "Formed"
$   rp_v = f$extract(0, 17, f$cvtime(rp_val, "ABSOLUTE"))
$   if rp_found .nes. ""
$   then
$     rp_v = rp_v + " by " + rp_found
$   else
$     if rp_fid .ge. 0 then rp_v = rp_v + f$fao(" by system ID !UL", rp_fid)
$   endif
$   gosub kv
$ endif
$!
$ rp_k = "Votes"
$ rp_v = f$fao("!UL total, quorum !UL, this node !UL, expected !UL", -
               f$getsyi("CLUSTER_VOTES"), f$getsyi("CLUSTER_QUORUM"), -
               f$getsyi("VOTES"), f$getsyi("EXPECTED_VOTES"))
$ gosub kv
$!
$ rp_k = "MSCP serving"
$ rp_v = f$fao("disk load !UL, serve all !UL, tape load !UL", -
               f$getsyi("MSCP_LOAD"), f$getsyi("MSCP_SERVE_ALL"), -
               f$getsyi("TMSCP_LOAD"))
$ gosub kv
$!
$ rp_k = "Conversational boot"
$ rp_v = "not allowed"
$ if f$getsyi("NISCS_CONV_BOOT") then rp_v = "allowed"
$ gosub kv
$!
$ if .not. rp_brief .and. rp_cn .gt. 0
$ then
$   write sys$output ""
$   write sys$output "  ", rp_key, -
      f$fao("!8AS  !10AS  !12AS  !5AS", "Node", "Type", "Version", "Votes"), -
      rp_off
$   rp_i = 0
$cl_row:
$   rp_i = rp_i + 1
$   if rp_i .gt. rp_cn then goto cl_done
$   write sys$output "  ", f$fao("!8AS  !10AS  !12AS  !5UL", -
      rp_cl_name_'rp_i', rp_cl_hw_'rp_i', rp_cl_ver_'rp_i', rp_cl_vote_'rp_i')
$   goto cl_row
$ endif
$cl_done:
$!
$!==============================================================================
$! Network
$!==============================================================================
$ rp_hd = "Network"
$ gosub heading
$ rp_net = 0
$ rp_host = f$trnlnm("TCPIP$INET_HOST")
$ if rp_host .eqs. "" then rp_host = f$trnlnm("UCX$INET_HOST")
$ rp_dom = f$trnlnm("TCPIP$INET_DOMAIN")
$ if rp_dom .eqs. "" then rp_dom = f$trnlnm("UCX$INET_DOMAIN")
$ if rp_host .nes. ""
$ then
$   rp_k = "TCP/IP host"
$   rp_v = f$edit(rp_host, "LOWERCASE")
$   if rp_dom .nes. "" then rp_v = rp_v + "." + f$edit(rp_dom, "LOWERCASE")
$   gosub kv
$   rp_net = 1
$ endif
$!
$ rp_item = "DECNET_VERSION"
$ gosub get_syi
$ rp_phase = 0
$ if rp_val .nes. "" then rp_phase = f$integer(f$extract(2, 2, rp_val))
$ if rp_phase .ge. 4
$ then
$   rp_area = f$getsyi("NODE_AREA")
$   rp_num  = f$getsyi("NODE_NUMBER")
$   rp_k = "DECnet"
$   rp_v = "Phase IV"
$   if rp_phase .ge. 5
$   then
$     rp_v = "DECnet-Plus"
$     rp_item = "DECNET_FULLNAME"
$     gosub get_syi
$     if rp_val .nes. "" then rp_v = rp_v + " " + rp_val
$   endif
$   if rp_area .gt. 0 .or. rp_num .gt. 0 then -
      rp_v = rp_v + f$fao(", address !UL.!UL (!UL)", -
                          rp_area, rp_num, rp_area * 1024 + rp_num)
$   gosub kv
$   rp_net = 1
$ endif
$ if .not. rp_net
$ then
$   rp_k = "Network"
$   rp_v = "no TCP/IP or DECnet identity found"
$   gosub kv
$ endif
$!
$!==============================================================================
$! Disks (not with BRIEF)
$!==============================================================================
$! Every mounted disk, skipping foreign mounts and shadow set members.
$ if rp_brief then goto disk_done
$ rp_hd = "Disks"
$ gosub heading
$ write sys$output "  ", rp_key, -
    f$fao("!20AS !12AS !9AS !9AS !5AS", -
          "Device", "Label", "Size", "Free", "Used"), rp_off
$ rp_sysdev = f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM")
$disk_next:
$ rp_dev = f$device("*", "DISK")
$ if rp_dev .eqs. "" then goto disk_end
$ if .not. f$getdvi(rp_dev, "MNT") then goto disk_next
$ if f$getdvi(rp_dev, "FOR") then goto disk_next
$ if f$getdvi(rp_dev, "SHDW_MEMBER") then goto disk_next
$ rp_dn  = f$getdvi(rp_dev, "DEVNAM") - "_"
$ if f$getdvi(rp_dev, "FULLDEVNAM") .eqs. rp_sysdev then rp_dn = rp_dn + " *"
$ rp_lab = f$edit(f$getdvi(rp_dev, "VOLNAM"), "TRIM")
$ rp_max = f$getdvi(rp_dev, "MAXBLOCK")
$ rp_fb  = f$getdvi(rp_dev, "FREEBLOCKS")
$ rp_mb = rp_max / 2048
$ gosub fmt_mb
$ rp_sz = rp_size
$ rp_mb = rp_fb / 2048
$ gosub fmt_mb
$ rp_pc = 0
$ if rp_max .gt. 0 then rp_pc = (rp_max - rp_fb) / (rp_max / 100 + 1)
$ write sys$output "  ", f$fao("!20AS !12AS !9AS !9AS !3UL%", -
    rp_dn, rp_lab, rp_sz, rp_size, rp_pc)
$ goto disk_next
$disk_end:
$ write sys$output "  (* = system disk)"
$disk_done:
$!
$ write sys$output " ", f$fao("!''rp_rw'*=")
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'rp_msg'
$ type sys$input
REPORT - system configuration report for OpenVMS

Usage:   @REPORT [option ...]

  BRIEF    leave out the SYSGEN parameters, cluster member list and disks
  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

Output to a file or batch log is always plain text, for example:

  PIPE @REPORT > REPORT.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$cleanup:
$ if f$type(rp_msg) .nes. "" then set message 'rp_msg'
$ exit 1 + 0 * f$verify(rp_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! HEADING: print a section heading for rp_hd.
$heading:
$ rp_hl = rp_rw - 6 - f$length(rp_hd)
$ if rp_hl .lt. 1 then rp_hl = 1
$ write sys$output ""
$ write sys$output "  ", rp_head, "-- ", rp_hd, " ", -
                   f$fao("!''rp_hl'*-"), rp_off
$ return
$!
$! KV: print "label  value" (rp_k, rp_v), fitting value to the width.
$kv:
$ if f$length(rp_v) .gt. rp_vw then -
    rp_v = f$extract(0, rp_vw - 3, rp_v) + "..."
$ write sys$output "  ", rp_key, f$fao("!''rp_kw'AS", rp_k), rp_off, " ", rp_v
$ return
$!
$! GET_SYI: rp_val = F$GETSYI(rp_item), or "" if this system lacks it.
$get_syi:
$ rp_val = ""
$ rp_val = f$getsyi(rp_item)
$ return
$!
$! FMT_MB: rp_size = rp_mb megabytes as "512 MB" or "33.9 GB".
$fmt_mb:
$ if rp_mb .lt. 1024
$ then
$   rp_size = f$fao("!UL MB", rp_mb)
$ else
$   rp_size = f$fao("!UL.!UL GB", rp_mb / 1024, -
                    (rp_mb - (rp_mb / 1024) * 1024) * 10 / 1024)
$ endif
$ return
$!
$! FMT_USE: rp_v = "N of M free, P% used" from rp_tot and rp_fre.
$fmt_use:
$ if rp_tot .le. 0
$ then
$   rp_v = "none"
$ else
$   rp_v = f$fao("!UL of !UL free, !UL% used", rp_fre, rp_tot, -
                 (rp_tot - rp_fre) / (rp_tot / 100 + 1))
$ endif
$ return
$!
$! CIVIL_DAYS: from rp_t ("yyyy-mm-dd hh:mm:ss..."), rp_days = days since a
$! fixed epoch and rp_secs = seconds into that day.
$civil_days:
$ rp_y = f$integer(f$extract(0, 4, rp_t))
$ rp_m = f$integer(f$extract(5, 2, rp_t))
$ rp_d = f$integer(f$extract(8, 2, rp_t))
$ rp_secs = f$integer(f$extract(11, 2, rp_t)) * 3600 + -
            f$integer(f$extract(14, 2, rp_t)) * 60 + -
            f$integer(f$extract(17, 2, rp_t))
$ if rp_m .le. 2 then rp_y = rp_y - 1
$ rp_era = rp_y / 400
$ rp_yoe = rp_y - rp_era * 400
$ rp_mp  = rp_m - 3
$ if rp_m .le. 2 then rp_mp = rp_m + 9
$ rp_doy = (153 * rp_mp + 2) / 5 + rp_d - 1
$ rp_doe = rp_yoe * 365 + rp_yoe / 4 - rp_yoe / 100 + rp_doy
$ rp_days = rp_era * 146097 + rp_doe
$ return
