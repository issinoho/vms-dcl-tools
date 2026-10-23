$!------------------------------------------------------------------------------
$! SYSINFO.COM - System summary for OpenVMS, in the style of fastfetch
$!
$! Shows the operating system, hardware, uptime, cluster and network
$! identity, CPU and memory use, page and swap files, logged-in users,
$! every mounted disk, your session, and a few system resources, with a
$! small VMS logo beside them.
$!
$! Usage:   @SYSINFO [option ...]
$!
$!   BRIEF    leave out the system resources section
$!   NOLOGO   no logo
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! Colour is used only on an ANSI terminal; output to a file or batch log is
$! plain text. The logo needs a line at least 80 characters wide. Works on
$! VAX, Alpha, IA64 and x86-64, needs no privileges, and uses plain DCL
$! only. Anything a system cannot report is left out rather than failing.
$!
$! To add a line, gather the value in the "Gather" part below, then:
$!     $ si_k = "Label"
$!     $ si_v = value
$!     $ gosub add_line
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ si_verify = f$verify(0)
$ set noon
$ on control_y then goto cleanup
$! Lexicals a system does not support fail quietly and are skipped.
$ si_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Options -----------------------------------------------------------------
$ si_brief  = 0
$ si_plain  = 0
$ si_nologo = 0
$ si_p = 0
$opt_loop:
$ si_p = si_p + 1
$ if si_p .gt. 8 then goto opt_done
$ si_opt = f$edit(p'si_p', "TRIM,UPCASE")
$ if si_opt .eqs. "" then goto opt_loop
$ si_len = f$length(si_opt)                 ! options may be abbreviated
$ if si_opt .eqs. f$extract(0, si_len, "HELP") .or. si_opt .eqs. "?" -
     then goto help
$ if si_opt .eqs. f$extract(0, si_len, "BRIEF")
$ then
$   si_brief = 1
$   goto opt_loop
$ endif
$ if si_opt .eqs. f$extract(0, si_len, "PLAIN")
$ then
$   si_plain = 1
$   goto opt_loop
$ endif
$ if si_opt .eqs. f$extract(0, si_len, "NOLOGO")
$ then
$   si_nologo = 1
$   goto opt_loop
$ endif
$ set message 'si_msg'
$ write sys$output "SYSINFO: unknown option ''si_opt' (try @SYSINFO HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ si_width = 80
$ si_ansi  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     si_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     si_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if si_w .ge. 60 .and. si_w .le. 132 then si_width = si_w
$   endif
$ endif
$ if si_plain then si_ansi = 0
$ si_bold = ""
$ si_key  = ""
$ si_logo = ""
$ si_off  = ""
$ if si_ansi
$ then
$   si_esc[0,8] = 27
$   si_bold = si_esc + "[1m"
$   si_key  = si_esc + "[1;34m"             ! bold blue labels
$   si_logo = si_esc + "[1;31m"             ! bold red logo
$   si_off  = si_esc + "[0m"
$ endif
$ si_logo_on = .not. si_nologo .and. si_width .ge. 80
$ si_lw = 0                                 ! logo column width
$ if si_logo_on then si_lw = 22
$ si_kw = 16                                ! label width
$ si_vw = si_width - si_lw - si_kw - 1      ! room for values
$!
$ si_logo_1 = "__   ____  __ ___"
$ si_logo_2 = "\ \ / /  \/  / __|"
$ si_logo_3 = " \ V /| |\/| \__ \"
$ si_logo_4 = "  \_/ |_|  |_|___/"
$ si_logo_n = 4
$!
$ si_pid = f$getjpi("", "PID")
$ si_tmp = "SYS$SCRATCH:SYSINFO_''si_pid'.TMP"
$ si_n = 0                                  ! lines gathered so far
$!
$!==============================================================================
$! Gather
$!==============================================================================
$!
$!---- Title: user@node --------------------------------------------------------
$ si_user = f$edit(f$getjpi("", "USERNAME"), "TRIM")
$ si_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ si_v = si_bold + si_user + si_off + "@" + si_bold + si_node + si_off
$ gosub add_raw
$ si_tl = f$length(si_user) + 1 + f$length(si_node)
$ si_v = f$fao("!''si_tl'*-")
$ gosub add_raw
$!
$!---- Operating system and hardware -------------------------------------------
$ si_arch = ""
$ si_arch = f$getsyi("ARCH_NAME")
$ si_k = "OS"
$ si_v = "OpenVMS " + f$edit(f$getsyi("VERSION"), "TRIM")
$ if si_arch .nes. "" then si_v = si_v + " (" + si_arch + ")"
$ gosub add_line
$!
$ si_k = "Host"
$ si_v = f$edit(f$getsyi("HW_NAME"), "TRIM,COMPRESS")
$ gosub add_line
$!
$ si_fw = ""
$ si_fw = f$edit(f$getsyi("CONSOLE_VERSION"), "TRIM,COMPRESS")
$ if si_fw .nes. ""
$ then
$   si_k = "Firmware"
$   si_v = si_fw
$   gosub add_line
$ endif
$!
$!---- Uptime and boot time ----------------------------------------------------
$ si_boot = ""
$ si_boot = f$getsyi("BOOTTIME")
$ if si_boot .nes. ""
$ then
$   si_t = f$cvtime(si_boot, "COMPARISON")
$   gosub civil_days
$   si_d1 = si_days
$   si_s1 = si_secs
$   si_t = f$cvtime(, "COMPARISON")
$   gosub civil_days
$   si_dd = si_days - si_d1
$   si_ss = si_secs - si_s1
$   if si_ss .lt. 0
$   then
$     si_ss = si_ss + 86400
$     si_dd = si_dd - 1
$   endif
$   si_hh = si_ss / 3600
$   si_mm = (si_ss - si_hh * 3600) / 60
$   si_v = ""
$   if si_dd .gt. 0 then si_v = f$fao("!UL day!%S, ", si_dd)
$   if si_dd .gt. 0 .or. si_hh .gt. 0 then -
      si_v = si_v + f$fao("!UL hour!%S, ", si_hh)
$   si_v = si_v + f$fao("!UL min!%S", si_mm)
$   si_k = "Uptime"
$   gosub add_line
$   si_k = "Booted"
$   si_v = f$extract(0, 17, f$cvtime(si_boot, "ABSOLUTE"))
$   gosub add_line
$ endif
$!
$!---- Cluster -----------------------------------------------------------------
$ si_k = "Cluster"
$ si_v = "No (standalone)"
$ if f$getsyi("CLUSTER_MEMBER")
$ then
$   si_v = f$fao("Yes, !UL node!%S, !UL vote!%S, quorum !UL", -
                 f$getsyi("CLUSTER_NODES"), f$getsyi("CLUSTER_VOTES"), -
                 f$getsyi("CLUSTER_QUORUM"))
$ endif
$ gosub add_line
$!
$!---- Network identity --------------------------------------------------------
$ si_host = f$trnlnm("TCPIP$INET_HOST")
$ if si_host .eqs. "" then si_host = f$trnlnm("UCX$INET_HOST")
$ si_dom = f$trnlnm("TCPIP$INET_DOMAIN")
$ if si_dom .eqs. "" then si_dom = f$trnlnm("UCX$INET_DOMAIN")
$ if si_host .nes. ""
$ then
$   si_k = "TCP/IP"
$   si_v = f$edit(si_host, "LOWERCASE")
$   if si_dom .nes. "" then si_v = si_v + "." + f$edit(si_dom, "LOWERCASE")
$   gosub add_line
$ endif
$!
$ si_dnv = ""
$ si_dnv = f$getsyi("DECNET_VERSION")
$ si_phase = 0
$ if si_dnv .nes. "" then si_phase = f$integer(f$extract(2, 2, si_dnv))
$ if si_phase .ge. 4
$ then
$   si_area = f$getsyi("NODE_AREA")
$   si_num  = f$getsyi("NODE_NUMBER")
$   si_k = "DECnet"
$   si_v = "Phase IV"
$   if si_phase .ge. 5
$   then
$     si_v = "DECnet-Plus"
$     si_full = ""
$     si_full = f$getsyi("DECNET_FULLNAME")
$     if si_full .nes. "" then si_v = si_v + " " + si_full
$   endif
$   if si_area .gt. 0 .or. si_num .gt. 0 then -
      si_v = si_v + f$fao(", address !UL.!UL (!UL)", -
                          si_area, si_num, si_area * 1024 + si_num)
$   gosub add_line
$ endif
$!
$!---- CPU and memory ----------------------------------------------------------
$ si_k = "CPU"
$ si_v = f$fao("!UL active of !UL available", -
               f$getsyi("ACTIVECPU_CNT"), f$getsyi("AVAILCPU_CNT"))
$ gosub add_line
$!
$! Total from MEMSIZE (pages); used share from SHOW MEMORY/PHYSICAL.
$ si_pgs = f$getsyi("PAGE_SIZE")
$ if si_pgs .le. 0 then si_pgs = 512
$ si_mb  = f$getsyi("MEMSIZE") / (1048576 / si_pgs)
$ gosub fmt_mb
$ si_k = "Memory"
$ si_v = si_size
$ si_cmd   = "show memory/physical"
$ si_match = "Main Memory"
$ gosub capture
$ if si_line .nes. ""
$ then
$   si_rest = f$edit(f$element(1, ")", si_line), "TRIM,COMPRESS")
$   si_tok = f$element(0, " ", si_rest)
$   gosub tok_value
$   si_tot = si_val
$   si_tok = f$element(1, " ", si_rest)
$   gosub tok_value
$   si_fre = si_val
$   if si_tot .ge. 100 .and. si_fre .ge. 0
$   then
$     si_v = si_v + f$fao(", !UL% used", (si_tot - si_fre) / (si_tot / 100))
$   endif
$ endif
$ gosub add_line
$!
$!---- Page and swap files -----------------------------------------------------
$ si_k   = "Page file"
$ si_tot = f$getsyi("PAGEFILE_PAGE")
$ si_fre = f$getsyi("PAGEFILE_FREE")
$ gosub fmt_use
$ gosub add_line
$ si_k   = "Swap file"
$ si_tot = f$getsyi("SWAPFILE_PAGE")
$ si_fre = f$getsyi("SWAPFILE_FREE")
$ gosub fmt_use
$ gosub add_line
$!
$!---- Users -------------------------------------------------------------------
$ si_cmd   = "show users"
$ si_match = "Total number of users"
$ gosub capture
$ if si_line .nes. ""
$ then
$   si_nu = f$edit(f$element(0, ",", f$element(1, "=", si_line)), "TRIM")
$   si_np = f$edit(f$element(2, "=", si_line), "TRIM")
$   if f$type(si_nu) .eqs. "INTEGER" .and. f$type(si_np) .eqs. "INTEGER"
$   then
$     si_k = "Users"
$     si_v = f$fao("!UL user!%S, !UL interactive process!%S", -
                   f$integer(si_nu), f$integer(si_np))
$     gosub add_line
$   endif
$ endif
$!
$!---- Disks -------------------------------------------------------------------
$! Every mounted disk, skipping foreign mounts and shadow set members.
$ si_sysdev = f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM")
$disk_next:
$ si_dev = f$device("*", "DISK")
$ if si_dev .eqs. "" then goto disk_done
$ if .not. f$getdvi(si_dev, "MNT") then goto disk_next
$ if f$getdvi(si_dev, "FOR") then goto disk_next
$ if f$getdvi(si_dev, "SHDW_MEMBER") then goto disk_next
$ si_lab = f$edit(f$getdvi(si_dev, "VOLNAM"), "TRIM")
$ si_max = f$getdvi(si_dev, "MAXBLOCK")
$ si_fb  = f$getdvi(si_dev, "FREEBLOCKS")
$ si_k = "Disk"
$ if f$getdvi(si_dev, "FULLDEVNAM") .eqs. si_sysdev then si_k = "Disk (system)"
$ si_v = si_lab
$ if si_max .gt. 0
$ then
$   si_mb = si_max / 2048
$   gosub fmt_mb
$   si_v = si_v + " " + si_size + f$fao(", !UL% used", -
                  (si_max - si_fb) / (si_max / 100 + 1))
$ endif
$ si_dn = f$getdvi(si_dev, "DEVNAM") - "_"
$ si_v = si_v + " (" + si_dn + ")"
$ gosub add_line
$ goto disk_next
$disk_done:
$!
$!---- Your session ------------------------------------------------------------
$ si_term = f$edit(f$getjpi("", "TERMINAL"), "TRIM")
$ si_k = "Session"
$ si_v = si_user + " " + f$getjpi("", "UIC") + ", " + -
         f$edit(f$mode(), "LOWERCASE")
$ if si_term .nes. "" then si_v = si_v + " on " + si_term
$ gosub add_line
$!
$ si_k = "Local time"
$ si_v = f$extract(0, 17, f$time())
$ si_tz = f$trnlnm("SYS$TIMEZONE_NAME")
$ if si_tz .nes. "" then si_v = si_v + " " + si_tz
$ gosub add_line
$!
$!---- System resources --------------------------------------------------------
$ if .not. si_brief
$ then
$   si_v = ""
$   gosub add_raw
$   si_v = si_bold + "Resources" + si_off
$   gosub add_raw
$   si_k = "Global pages"
$   si_v = f$fao("!UL free", f$getsyi("FREE_GBLPAGES"))
$   gosub add_line
$   si_k = "Global sections"
$   si_v = f$fao("!UL free", f$getsyi("FREE_GBLSECTS"))
$   gosub add_line
$   si_k = "GBLPAGFIL"
$   si_v = f$fao("!UL", f$getsyi("GBLPAGFIL"))
$   gosub add_line
$   si_k = "VIRTUALPAGECNT"
$   si_v = f$fao("!UL", f$getsyi("VIRTUALPAGECNT"))
$   gosub add_line
$   si_k = "BUGCHECKFATAL"
$   si_v = "No"
$   if f$getsyi("BUGCHECKFATAL") then si_v = "Yes"
$   gosub add_line
$ endif
$!
$!---- Colour swatch, as fastfetch does ----------------------------------------
$ if si_ansi
$ then
$   si_v = ""
$   gosub add_raw
$   si_c = 0
$   si_v = ""
$swatch:
$   si_v = si_v + si_esc + "[4''si_c'm   "
$   si_c = si_c + 1
$   if si_c .le. 7 then goto swatch
$   si_v = si_v + si_off
$   gosub add_raw
$ endif
$!
$!==============================================================================
$! Print: logo on the left, gathered lines on the right
$!==============================================================================
$ set message 'si_msg'
$ si_rows = si_n
$ if si_logo_on .and. si_logo_n .gt. si_rows then si_rows = si_logo_n
$ write sys$output ""
$ si_i = 0
$print_next:
$ si_i = si_i + 1
$ if si_i .gt. si_rows then goto print_done
$ si_left = ""
$ if si_logo_on
$ then
$   si_lt = ""
$   if si_i .le. si_logo_n then si_lt = si_logo_'si_i'
$   si_left = si_logo + f$fao("!''si_lw'AS", si_lt) + si_off
$ endif
$ si_right = ""
$ if si_i .le. si_n then si_right = si_line_'si_i'
$ write sys$output "  ", si_left, si_right
$ goto print_next
$print_done:
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'si_msg'
$ type sys$input
SYSINFO - system summary for OpenVMS, in the style of fastfetch

Usage:   @SYSINFO [option ...]

  BRIEF    leave out the system resources section
  NOLOGO   no logo
  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

Output to a file or batch log is always plain text, for example:

  PIPE @SYSINFO > SYSINFO.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$cleanup:
$ if f$trnlnm("SI_IN") .nes. "" then close si_in
$ if f$type(si_tmp) .nes. ""
$ then
$   if f$search(si_tmp) .nes. "" then delete/nolog 'si_tmp';*
$ endif
$ if f$type(si_msg) .nes. "" then set message 'si_msg'
$ exit 1 + 0 * f$verify(si_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! ADD_LINE: add "label  value" (si_k, si_v), fitting value to the width.
$add_line:
$ if f$length(si_v) .gt. si_vw then -
    si_v = f$extract(0, si_vw - 3, si_v) + "..."
$ si_n = si_n + 1
$ si_line_'si_n' = si_key + f$fao("!''si_kw'AS", si_k) + si_off + si_v
$ return
$!
$! ADD_RAW: add si_v as it is (titles, rules, blank lines).
$add_raw:
$ si_n = si_n + 1
$ si_line_'si_n' = si_v
$ return
$!
$! FMT_MB: si_size = si_mb megabytes as "512 MB" or "33.9 GB".
$fmt_mb:
$ if si_mb .lt. 1024
$ then
$   si_size = f$fao("!UL MB", si_mb)
$ else
$   si_size = f$fao("!UL.!UL GB", si_mb / 1024, -
                    (si_mb - (si_mb / 1024) * 1024) * 10 / 1024)
$ endif
$ return
$!
$! FMT_USE: si_v = share used from si_tot and si_fre (any units).
$fmt_use:
$ if si_tot .le. 0
$ then
$   si_v = "none"
$ else
$   si_v = f$fao("!UL% used", (si_tot - si_fre) / (si_tot / 100 + 1))
$ endif
$ return
$!
$! TOK_VALUE: si_val = a SHOW MEMORY number in common units, or -1.
$! Accepts a plain count (pages) or a size such as 7.00GB, 512.5MB.
$tok_value:
$ si_val = -1
$ if f$type(si_tok) .eqs. "INTEGER"
$ then
$   si_val = f$integer(si_tok)
$   return
$ endif
$ si_unit = f$edit(f$extract(f$length(si_tok) - 2, 2, si_tok), "UPCASE")
$ si_numb = si_tok - si_unit
$ si_whole = f$element(0, ".", si_numb)
$ si_frac  = f$extract(0, 2, f$element(1, ".", si_numb) + "00")
$ if si_frac .eqs. ".0" then si_frac = "00"
$ if f$type(si_whole) .nes. "INTEGER" .or. f$type(si_frac) .nes. "INTEGER" -
     then return
$ si_cent = f$integer(si_whole) * 100 + f$integer(si_frac)  ! hundredths
$ if si_unit .eqs. "KB" then si_val = si_cent / 1024
$ if si_unit .eqs. "MB" then si_val = si_cent
$ if si_unit .eqs. "GB" then si_val = si_cent * 1024
$ if si_unit .eqs. "TB" then si_val = si_cent * 1024 * 1024
$ return
$!
$! CAPTURE: run si_cmd and set si_line to the first output line that
$! contains si_match (any case), or "" if none.
$capture:
$ si_line = ""
$ if f$search(si_tmp) .nes. "" then delete/nolog 'si_tmp';*
$ pipe 'si_cmd' < NLA0: > 'si_tmp' 2> NLA0:
$ open/read/error=cap_done si_in 'si_tmp'
$cap_next:
$ read/end_of_file=cap_close/error=cap_close si_in si_rec
$ if f$locate(f$edit(si_match, "UPCASE"), f$edit(si_rec, "UPCASE")) -
     .ge. f$length(si_rec) then goto cap_next
$ si_line = f$edit(si_rec, "TRIM,COMPRESS")
$cap_close:
$ close si_in
$cap_done:
$ return
$!
$! CIVIL_DAYS: from si_t ("yyyy-mm-dd hh:mm:ss..."), si_days = days since a
$! fixed epoch and si_secs = seconds into that day.
$civil_days:
$ si_y = f$integer(f$extract(0, 4, si_t))
$ si_m = f$integer(f$extract(5, 2, si_t))
$ si_d = f$integer(f$extract(8, 2, si_t))
$ si_secs = f$integer(f$extract(11, 2, si_t)) * 3600 + -
            f$integer(f$extract(14, 2, si_t)) * 60 + -
            f$integer(f$extract(17, 2, si_t))
$ if si_m .le. 2 then si_y = si_y - 1
$ si_era = si_y / 400
$ si_yoe = si_y - si_era * 400
$ si_mp  = si_m - 3
$ if si_m .le. 2 then si_mp = si_m + 9
$ si_doy = (153 * si_mp + 2) / 5 + si_d - 1
$ si_doe = si_yoe * 365 + si_yoe / 4 - si_yoe / 100 + si_doy
$ si_days = si_era * 146097 + si_doe
$ return
