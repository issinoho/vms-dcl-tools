$!------------------------------------------------------------------------------
$! DEV.COM - List the devices on an OpenVMS system
$!
$! Lists devices grouped by class, one table per class, with each device's
$! status, error count and operation count. Disks also show their label,
$! size and how full they are; other devices show their type and, when a
$! process owns them, its user name and image.
$!
$! Usage:   @DEV [class ...] [device] [option ...]
$!
$!   class    one or more of DISK TAPE SCOM CARD TERM LP WORKSTATION
$!            REALTIME DECVOICE BUS MAILBOX REMCSL_STORAGE MISC
$!            (default: all classes)
$!   device   a device name or wildcard, e.g. DKA* or $1$DGA100:
$!   ALL      also list mailboxes, idle terminals and TCP/IP socket devices
$!   ERRORS   only devices that have errors or are offline
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! By default mailboxes, terminals with no owner and TCP/IP socket devices
$! (BGn:) are left out, as there are usually hundreds of them; naming a class
$! (e.g. @DEV MAILBOX) or giving ALL lists them. Colour is used only on an
$! ANSI terminal. Works on VAX, Alpha, IA64 and x86-64 with plain DCL.
$! Without WORLD privilege, owners in other groups show as a PID only.
$!
$! To list another class, add a line to the class table below.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ dv_verify = f$verify(0)
$ set noon
$ on control_y then goto cleanup
$! Lexicals a system does not support fail quietly and are skipped.
$ dv_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Device classes: "F$DEVICE keyword|section title" ------------------------
$ dv_c_1  = "DISK|Disks"
$ dv_c_2  = "TAPE|Tapes"
$ dv_c_3  = "SCOM|Communications and network"
$ dv_c_4  = "CARD|Card readers"
$ dv_c_5  = "TERM|Terminals"
$ dv_c_6  = "LP|Printers"
$ dv_c_7  = "WORKSTATION|Workstations"
$ dv_c_8  = "REALTIME|Real-time"
$ dv_c_9  = "DECVOICE|DECvoice"
$ dv_c_10 = "BUS|Buses"
$ dv_c_11 = "MAILBOX|Mailboxes"
$ dv_c_12 = "REMCSL_STORAGE|Remote console storage"
$ dv_c_13 = "MISC|Miscellaneous"
$!
$!---- Options -----------------------------------------------------------------
$ dv_all    = 0
$ dv_errors = 0
$ dv_plain  = 0
$ dv_want   = ""                            ! classes asked for, ",A,B,"
$ dv_spec   = "*"
$ dv_p = 0
$opt_loop:
$ dv_p = dv_p + 1
$ if dv_p .gt. 8 then goto opt_done
$ dv_opt = f$edit(p'dv_p', "TRIM,UPCASE")
$ if dv_opt .eqs. "" then goto opt_loop
$ dv_len = f$length(dv_opt)
$! A device name or wildcard
$ if f$locate("*", dv_opt) .lt. dv_len .or. -
     f$locate("%", dv_opt) .lt. dv_len .or. -
     f$locate(":", dv_opt) .lt. dv_len .or. -
     f$locate("$", dv_opt) .lt. dv_len
$ then
$   dv_spec = dv_opt
$   goto opt_loop
$ endif
$! A class name (exact)
$ dv_i = 0
$opt_class:
$ dv_i = dv_i + 1
$ if f$type(dv_c_'dv_i') .eqs. "" then goto opt_word
$ if dv_opt .nes. f$element(0, "|", dv_c_'dv_i') then goto opt_class
$ if dv_want .eqs. "" then dv_want = ","
$ dv_want = dv_want + dv_opt + ","
$ goto opt_loop
$! An option word (may be abbreviated)
$opt_word:
$ if dv_opt .eqs. f$extract(0, dv_len, "HELP") .or. dv_opt .eqs. "?" -
     then goto help
$ if dv_opt .eqs. f$extract(0, dv_len, "ALL")
$ then
$   dv_all = 1
$   goto opt_loop
$ endif
$ if dv_opt .eqs. f$extract(0, dv_len, "ERRORS")
$ then
$   dv_errors = 1
$   goto opt_loop
$ endif
$ if dv_opt .eqs. f$extract(0, dv_len, "PLAIN")
$ then
$   dv_plain = 1
$   goto opt_loop
$ endif
$ set message 'dv_msg'
$ write sys$output "DEV: unknown class or option ''dv_opt' (try @DEV HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ dv_width = 80
$ dv_ansi  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     dv_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     dv_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if dv_w .ge. 80 .and. dv_w .le. 132 then dv_width = dv_w
$   endif
$ endif
$ if dv_plain then dv_ansi = 0
$ dv_bold = ""
$ dv_head = ""
$ dv_key  = ""
$ dv_red  = ""
$ dv_yel  = ""
$ dv_off  = ""
$ if dv_ansi
$ then
$   dv_esc[0,8] = 27
$   dv_bold = dv_esc + "[1m"
$   dv_head = dv_esc + "[1;31m"             ! bold red section headings
$   dv_key  = dv_esc + "[1;34m"             ! bold blue column headings
$   dv_red  = dv_esc + "[31m"               ! offline
$   dv_yel  = dv_esc + "[33m"               ! errors
$   dv_off  = dv_esc + "[0m"
$ endif
$ dv_rw = dv_width - 2                      ! rule width
$! Owner column gets whatever is left of the line.
$ dv_ow = dv_width - 2 - 18 - 9 - 20 - 5 - 8 - 6
$!
$ dv_shown  = 0
$ dv_hidden = 0
$ dv_bad    = 0
$!
$!---- Header ------------------------------------------------------------------
$ dv_node  = f$edit(f$getsyi("NODENAME"), "TRIM")
$ dv_title = "Devices on " + dv_node
$ if dv_spec .nes. "*" then dv_title = dv_title + " matching " + dv_spec
$ if dv_errors then dv_title = dv_title + " with errors"
$ dv_now = f$extract(0, 17, f$time())
$ dv_pad = dv_rw - 2 - f$length(dv_title) - f$length(dv_now)
$ if dv_pad .lt. 1 then dv_pad = 1
$ write sys$output ""
$ write sys$output " ", f$fao("!''dv_rw'*=")
$ write sys$output "  ", dv_bold, dv_title, dv_off, -
                   f$fao("!''dv_pad'* "), dv_now
$ write sys$output " ", f$fao("!''dv_rw'*=")
$!
$!==============================================================================
$! One section per class
$!==============================================================================
$ dv_ci = 0
$class_next:
$ dv_ci = dv_ci + 1
$ if f$type(dv_c_'dv_ci') .eqs. "" then goto class_done
$ dv_e     = dv_c_'dv_ci'
$ dv_cls   = f$element(0, "|", dv_e)
$ dv_named = 0                              ! class asked for by name
$ if dv_want .nes. ""
$ then
$   if f$locate("," + dv_cls + ",", dv_want) .ge. f$length(dv_want) -
       then goto class_next
$   dv_named = 1
$ endif
$ dv_n = 0                                  ! rows gathered for this class
$!
$dev_next:
$ dv_dev = ""
$ dv_dev = f$device(dv_spec, dv_cls)
$ if dv_dev .eqs. "" then goto dev_done
$ dv_name = dv_dev - "_"
$ dv_pid = f$edit(f$getdvi(dv_dev, "PID"), "TRIM")
$ if dv_pid .eqs. "00000000" then dv_pid = ""
$!
$! Leave out the usual crowd unless asked for.
$ if .not. dv_all
$ then
$   dv_skip = 0
$   if dv_cls .eqs. "MAILBOX" .and. .not. dv_named then dv_skip = 1
$   if dv_cls .eqs. "TERM" .and. .not. dv_named .and. dv_pid .eqs. "" -
       then dv_skip = 1
$   if (f$locate("$BG", dv_name) .lt. f$length(dv_name) .or. -
        f$extract(0, 2, dv_name) .eqs. "BG") .and. -
       f$getdvi(dv_dev, "UNIT") .ne. 0 then dv_skip = 1
$   if dv_skip
$   then
$     dv_hidden = dv_hidden + 1
$     goto dev_next
$   endif
$ endif
$!
$ dv_errs = f$getdvi(dv_dev, "ERRCNT")
$ dv_ops  = f$getdvi(dv_dev, "OPCNT")
$ gosub status
$ if dv_errors .and. dv_errs .eq. 0 .and. .not. dv_offline then goto dev_next
$ if dv_errs .gt. 0 .or. dv_offline then dv_bad = dv_bad + 1
$!
$! Coloured columns are padded first so the colour codes don't upset widths.
$ dv_st = f$fao("!9AS", dv_status)
$ if dv_offline then dv_st = dv_red + dv_st + dv_off
$ dv_er = f$fao("!5UL", dv_errs)
$ if dv_errs .gt. 0 then dv_er = dv_yel + dv_er + dv_off
$!
$ if dv_cls .eqs. "DISK"
$ then
$   gosub disk_cols
$   dv_row = f$fao("!18AS ", dv_name) + dv_st + " " + -
             f$fao("!12AS !9AS !5AS ", dv_lab, dv_sz, dv_used) + -
             dv_er + f$fao(" !10UL", dv_ops)
$ else
$   dv_type = ""
$   dv_item = "DEVICE_TYPE_NAME"
$   gosub get_dvi
$   dv_type = f$edit(dv_val, "TRIM,COMPRESS")
$   if dv_type .eqs. ""
$   then
$     dv_item = "MEDIA_NAME"
$     gosub get_dvi
$     dv_type = f$edit(dv_val, "TRIM")
$   endif
$   gosub owner
$   dv_row = f$fao("!18AS ", dv_name) + dv_st + " " + -
             f$fao("!20AS ", dv_type) + dv_er + f$fao(" !8UL ", dv_ops) + -
             f$fao("!''dv_ow'AS", dv_own)
$ endif
$ dv_n = dv_n + 1
$ dv_row_'dv_n' = dv_row
$ goto dev_next
$!
$dev_done:
$ if dv_n .eq. 0 then goto class_next
$ dv_shown = dv_shown + dv_n
$ dv_hd = f$element(1, "|", dv_e) + f$fao(" (!UL)", dv_n)
$ gosub heading
$ if dv_cls .eqs. "DISK"
$ then
$   write sys$output "  ", dv_key, -
      f$fao("!18AS !9AS !12AS !9AS !5AS !5AS !10AS", "Device", "Status", -
            "Label", "Size", "Used", " Errs", "       Ops"), dv_off
$ else
$   write sys$output "  ", dv_key, -
      f$fao("!18AS !9AS !20AS !5AS !8AS !AS", "Device", "Status", -
            "Type", " Errs", "     Ops", "Owner"), dv_off
$ endif
$ dv_i = 0
$row_next:
$ dv_i = dv_i + 1
$ if dv_i .gt. dv_n then goto class_next
$ write sys$output "  ", dv_row_'dv_i'
$ goto row_next
$!
$class_done:
$!
$!---- Summary -----------------------------------------------------------------
$ write sys$output ""
$ write sys$output " ", f$fao("!''dv_rw'*=")
$ if dv_shown .eq. 0
$ then
$   dv_v = "No devices found"
$   if dv_errors then dv_v = "No devices with errors or offline"
$ else
$   dv_v = f$fao("!UL device!%S listed", dv_shown)
$   if dv_bad .gt. 0 then -
      dv_v = dv_v + f$fao(", !UL with errors or offline", dv_bad)
$ endif
$ if dv_hidden .gt. 0 then -
    dv_v = dv_v + f$fao(", !UL hidden (use ALL to list them)", dv_hidden)
$ write sys$output "  ", dv_v
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'dv_msg'
$ type sys$input
DEV - list the devices on an OpenVMS system

Usage:   @DEV [class ...] [device] [option ...]

  class    one or more of DISK TAPE SCOM CARD TERM LP WORKSTATION
           REALTIME DECVOICE BUS MAILBOX REMCSL_STORAGE MISC
           (default: all classes)
  device   a device name or wildcard, e.g. DKA* or $1$DGA100:
  ALL      also list mailboxes, idle terminals and TCP/IP socket devices
  ERRORS   only devices that have errors or are offline
  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

Examples:

  @DEV                  everything except the usual crowd
  @DEV DISK TAPE        disks and tapes only
  @DEV ERRORS           quick health check
  @DEV TERM             every terminal, including idle ones
  PIPE @DEV > DEV.TXT   plain text to a file
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$cleanup:
$ if f$type(dv_msg) .nes. "" then set message 'dv_msg'
$ exit 1 + 0 * f$verify(dv_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! HEADING: print a section heading for dv_hd.
$heading:
$ dv_hl = dv_rw - 6 - f$length(dv_hd)
$ if dv_hl .lt. 1 then dv_hl = 1
$ write sys$output ""
$ write sys$output "  ", dv_head, "-- ", dv_hd, " ", -
                   f$fao("!''dv_hl'*-"), dv_off
$ return
$!
$! STATUS: dv_status and dv_offline for dv_dev.
$! Bit 4 of STS is UCB$V_ONLINE.
$status:
$ dv_offline = 0
$ dv_status = "Online"
$ if (f$getdvi(dv_dev, "STS") .and. 16) .eq. 0
$ then
$   dv_status = "Offline"
$   dv_offline = 1
$   return
$ endif
$ if f$getdvi(dv_dev, "MNT")
$ then
$   dv_status = "Mounted"
$   if f$getdvi(dv_dev, "FOR") then dv_status = "Foreign"
$ endif
$ if dv_cls .eqs. "DISK"
$ then
$   if f$getdvi(dv_dev, "SHDW_MEMBER") then dv_status = "Shadow"
$ endif
$ if dv_status .eqs. "Online"
$ then
$   if f$getdvi(dv_dev, "ALL") then dv_status = "Allocated"
$ endif
$ if dv_status .eqs. "Online" .and. dv_pid .nes. "" then dv_status = "In use"
$ if .not. f$getdvi(dv_dev, "AVL") then dv_status = "Unavail"
$ return
$!
$! DISK_COLS: dv_lab, dv_sz and dv_used for a disk.
$disk_cols:
$ dv_lab  = ""
$ dv_used = ""
$ dv_sz   = ""
$ if dv_status .eqs. "Shadow"
$ then
$   dv_item = "SHDW_MASTER_NAME"
$   gosub get_dvi
$   dv_lab = "in " + (dv_val - "_" - ":")
$ endif
$ dv_max = 0
$ if .not. dv_offline then dv_max = f$getdvi(dv_dev, "MAXBLOCK")
$ if dv_max .gt. 0
$ then
$   dv_mb = dv_max / 2048
$   gosub fmt_mb
$   dv_sz = dv_size
$ endif
$ if dv_status .eqs. "Mounted"
$ then
$   dv_lab = f$edit(f$getdvi(dv_dev, "VOLNAM"), "TRIM")
$   dv_fb  = f$getdvi(dv_dev, "FREEBLOCKS")
$   if dv_max .gt. 0 then -
      dv_used = f$fao("!3UL%", (dv_max - dv_fb) / (dv_max / 100 + 1))
$ endif
$ return
$!
$! OWNER: dv_own = "USER IMAGE" for the process that owns dv_dev, or its PID
$! if that process can't be looked at; "" if no owner.
$owner:
$ dv_own = ""
$ if dv_pid .eqs. "" then return
$ dv_user = ""
$ dv_user = f$edit(f$getjpi(dv_pid, "USERNAME"), "TRIM")
$ if dv_user .eqs. ""
$ then
$   dv_own = dv_pid
$   return
$ endif
$ dv_img = ""
$ dv_img = f$getjpi(dv_pid, "IMAGNAME")
$ dv_own = dv_user
$ if dv_img .nes. "" then -
    dv_own = dv_own + " " + f$parse(dv_img, , , "NAME", "SYNTAX_ONLY")
$ return
$!
$! GET_DVI: dv_val = F$GETDVI(dv_dev, dv_item), or "" if not supported.
$get_dvi:
$ dv_val = ""
$ dv_val = f$getdvi(dv_dev, dv_item)
$ return
$!
$! FMT_MB: dv_size = dv_mb megabytes as "512 MB" or "33.9 GB".
$fmt_mb:
$ if dv_mb .lt. 1024
$ then
$   dv_size = f$fao("!UL MB", dv_mb)
$ else
$   dv_size = f$fao("!UL.!UL GB", dv_mb / 1024, -
                    (dv_mb - (dv_mb / 1024) * 1024) * 10 / 1024)
$ endif
$ return
