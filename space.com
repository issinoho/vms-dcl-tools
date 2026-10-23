$!------------------------------------------------------------------------------
$! SPACE.COM - Disk space report for OpenVMS
$!
$! Lists every disk: for mounted disks the label, size, used and free space,
$! share used and a bar; unmounted disks are listed as such. Totals follow.
$! Shadow sets are shown once (as DSAn:), not once per member, and members
$! of a bound volume set after the first are left out. Disks with device
$! errors get a note under their line.
$!
$! Usage:   @SPACE [percent] [device] [option ...]
$!
$!   percent  only list mounted disks at least this full, e.g. 85
$!   device   a device name or wildcard, e.g. DKA* or DSA1:
$!   PAGE     pause after each screenful
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! With a percent, the procedure exits with a warning status ($SEVERITY 0)
$! when any disk is at or above it, so a batch job can act on it:
$!     $ @SPACE 90
$!     $ IF $SEVERITY .EQ. 0 THEN MAIL/SUBJECT="Disk space" ...
$!
$! Colour is used only on an ANSI terminal; output to a file or batch log is
$! plain text. Works on VAX, Alpha, IA64 and x86-64, needs no privileges,
$! and uses plain DCL only.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ dk_verify = f$verify(0)
$ set noon
$ on control_y then goto interrupted
$ dk_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$ dk_status = 1
$!
$!---- Settings ----------------------------------------------------------------
$ dk_warn = 80                              ! yellow at or above this percent
$ dk_crit = 90                              ! red at or above this percent
$!
$!---- Options -----------------------------------------------------------------
$ dk_plain = 0
$ dk_page  = 0
$ dk_min   = -1                             ! threshold, -1 = list all
$ dk_spec  = "*"
$ dk_p = 0
$opt_loop:
$ dk_p = dk_p + 1
$ if dk_p .gt. 8 then goto opt_done
$ dk_opt = f$edit(p'dk_p', "TRIM,UPCASE") - "%"
$ if dk_opt .eqs. "" then goto opt_loop
$ dk_len = f$length(dk_opt)
$ if f$type(dk_opt) .eqs. "INTEGER"
$ then
$   dk_min = f$integer(dk_opt)
$   if dk_min .ge. 0 .and. dk_min .le. 100 then goto opt_loop
$   set message 'dk_msg'
$   write sys$output "SPACE: percent must be 0 to 100"
$   goto cleanup
$ endif
$ if f$locate("*", dk_opt) .lt. dk_len .or. -
     f$locate(":", dk_opt) .lt. dk_len .or. -
     f$locate("$", dk_opt) .lt. dk_len
$ then
$   dk_spec = dk_opt
$   goto opt_loop
$ endif
$ if dk_opt .eqs. f$extract(0, dk_len, "HELP") .or. dk_opt .eqs. "?" -
     then goto help
$ if dk_opt .eqs. f$extract(0, dk_len, "PAGE")
$ then
$   dk_page = 1
$   goto opt_loop
$ endif
$ if dk_opt .eqs. f$extract(0, dk_len, "PLAIN")
$ then
$   dk_plain = 1
$   goto opt_loop
$ endif
$ set message 'dk_msg'
$ write sys$output "SPACE: unknown option ''dk_opt' (try @SPACE HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ dk_width = 80
$ dk_ansi  = 0
$ dk_rows  = 0                              ! screen height, 0 = don't page
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     dk_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     dk_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if dk_w .ge. 80 .and. dk_w .le. 132 then dk_width = dk_w
$     if dk_page .and. f$mode() .eqs. "INTERACTIVE" then -
        dk_rows = f$getdvi("SYS$OUTPUT", "TT_PAGE")
$   endif
$ endif
$ if dk_rows .lt. 10 then dk_rows = 0
$ if dk_plain then dk_ansi = 0
$ dk_bold = ""
$ dk_key  = ""
$ dk_grn  = ""
$ dk_yel  = ""
$ dk_red  = ""
$ dk_off  = ""
$ if dk_ansi
$ then
$   dk_esc[0,8] = 27
$   dk_bold = dk_esc + "[1m"
$   dk_key  = dk_esc + "[1;34m"             ! bold blue column headings
$   dk_grn  = dk_esc + "[32m"
$   dk_yel  = dk_esc + "[33m"
$   dk_red  = dk_esc + "[1;31m"
$   dk_off  = dk_esc + "[0m"
$ endif
$!
$!---- Box ---------------------------------------------------------------------
$! DEC Special Graphics line drawing on an ANSI terminal; plain +-| elsewhere,
$! so files and batch logs stay readable.
$ dk_gon  = ""
$ dk_goff = ""
$ dk_c_tl = "+"
$ dk_c_tr = "+"
$ dk_c_bl = "+"
$ dk_c_br = "+"
$ dk_c_ml = "+"
$ dk_c_mr = "+"
$ dk_c_h  = "-"
$ dk_c_v  = "|"
$ if dk_ansi
$ then
$   dk_gon  = dk_esc + "(0"
$   dk_goff = dk_esc + "(B"
$   dk_c_tl = "l"
$   dk_c_tr = "k"
$   dk_c_bl = "m"
$   dk_c_br = "j"
$   dk_c_ml = "t"
$   dk_c_mr = "u"
$   dk_c_h  = "q"
$   dk_c_v  = "x"
$ endif
$ dk_cw = dk_width - 6                      ! room inside the box
$ dk_hn = dk_cw + 2
$ dk_hline = f$fao("!''dk_hn'*''dk_c_h'")
$!
$! Columns: device 16, label 12, size, used, free 8 each, use 4, then a bar
$! "  [....]" in whatever is left (none if under 5 characters).
$ dk_bw = dk_cw - 16 - 12 - 8 - 8 - 8 - 5 - 4 - 4
$ if dk_bw .gt. 40 then dk_bw = 40
$ dk_colplain = f$fao("!16AS !12AS !8AS !8AS !8AS !4AS", -
               "Device", "Label", "    Size", "    Used", "    Free", " Use")
$ dk_lines = 0                              ! lines on this screen
$!
$!---- Header ------------------------------------------------------------------
$ dk_node  = f$edit(f$getsyi("NODENAME"), "TRIM")
$ dk_title = "Disk space on " + dk_node
$ if dk_min .ge. 0 then -
    dk_title = dk_title + f$fao(", disks !UL% full or more", dk_min)
$ dk_now = f$extract(0, 17, f$time())
$ dk_pad = dk_cw - f$length(dk_title) - f$length(dk_now)
$ if dk_pad .lt. 1 then dk_pad = 1
$ write sys$output ""
$ dk_lines = 1
$ dk_l = dk_c_tl
$ dk_r = dk_c_tr
$ gosub rule
$ dk_out = dk_bold + dk_title + dk_off + f$fao("!''dk_pad'* ") + dk_now
$ dk_vl  = f$length(dk_title) + dk_pad + f$length(dk_now)
$ gosub say
$ dk_l = dk_c_ml
$ dk_r = dk_c_mr
$ gosub rule
$ gosub colhead
$!
$!==============================================================================
$! One line per disk
$!==============================================================================
$ dk_sysdev = f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM")
$ dk_mnt   = 0                              ! mounted disks looked at
$ dk_unmnt = 0                              ! unmounted disks listed
$ dk_n     = 0                              ! mounted disks listed
$ dk_over  = 0                              ! disks at or above the threshold
$ dk_tot   = 0                              ! totals of listed disks, in MB
$ dk_tfree = 0
$ dk_sysin = 0                              ! system disk listed
$disk_next:
$ dk_dev = ""
$ dk_dev = f$device(dk_spec, "DISK")
$ if dk_dev .eqs. "" then goto disk_done
$ if f$getdvi(dk_dev, "SHDW_MEMBER") then goto disk_next
$ dk_rvn = 0
$ dk_rvn = f$getdvi(dk_dev, "VOLNUMBER")
$ if dk_rvn .gt. 1 then goto disk_next      ! later bound volume set member
$ dk_name = f$getdvi(dk_dev, "DEVNAM") - "_"
$ if f$getdvi(dk_dev, "FULLDEVNAM") .eqs. dk_sysdev
$ then
$   dk_name = dk_name + " *"
$   dk_sysin = 1
$ endif
$!
$! Not mounted, or mounted foreign: no file structure to measure.
$ dk_why = ""
$ if .not. f$getdvi(dk_dev, "MNT") then dk_why = "(not mounted)"
$ if dk_why .eqs. "" .and. f$getdvi(dk_dev, "FOR") then -
    dk_why = "(mounted foreign)"
$ if dk_why .nes. ""
$ then
$   if dk_min .ge. 0 then goto disk_next
$   dk_unmnt = dk_unmnt + 1
$   dk_out = f$fao("!16AS !AS", dk_name, dk_why)
$   dk_vl  = f$length(dk_out)
$   gosub say
$   gosub errors
$   goto disk_next
$ endif
$!
$ dk_max = f$getdvi(dk_dev, "MAXBLOCK")
$ if dk_max .le. 0 then goto disk_next
$ dk_fb  = f$getdvi(dk_dev, "FREEBLOCKS")
$ dk_mnt = dk_mnt + 1
$! Percent without overflowing 32-bit DCL arithmetic on big disks.
$ dk_pc  = 0
$ if dk_max .ge. 100 then dk_pc = (dk_max - dk_fb) / (dk_max / 100)
$ if dk_pc .gt. 100 then dk_pc = 100
$ if dk_min .ge. 0
$ then
$   if dk_pc .lt. dk_min then goto disk_next
$   dk_over = dk_over + 1
$ endif
$ dk_n = dk_n + 1
$!
$ dk_lab = f$edit(f$getdvi(dk_dev, "VOLNAM"), "TRIM")
$ dk_mb = dk_max / 2048
$ dk_tot = dk_tot + dk_mb
$ gosub fmt_mb
$ dk_sz = dk_size
$ dk_fmb = dk_fb / 2048
$ dk_tfree = dk_tfree + dk_fmb
$ dk_mb = dk_mb - dk_fmb
$ gosub fmt_mb
$ dk_us = dk_size
$ dk_mb = dk_fmb
$ gosub fmt_mb
$ gosub bar
$ dk_out = f$fao("!16AS !12AS !8AS !8AS !8AS ", -
           dk_name, dk_lab, dk_sz, dk_us, dk_size)
$ dk_vl  = f$length(dk_out) + dk_lvl
$ dk_out = dk_out + dk_line
$ gosub say
$ gosub errors
$ goto disk_next
$!
$disk_done:
$!
$!---- Totals and summary ------------------------------------------------------
$ if dk_n .gt. 1
$ then
$   dk_pc = 0
$   if dk_tot .ge. 100 then dk_pc = (dk_tot - dk_tfree) / (dk_tot / 100)
$   dk_mb = dk_tot
$   gosub fmt_mb
$   dk_sz = dk_size
$   dk_mb = dk_tot - dk_tfree
$   gosub fmt_mb
$   dk_us = dk_size
$   dk_mb = dk_tfree
$   gosub fmt_mb
$   gosub bar
$   dk_l = dk_c_ml
$   dk_r = dk_c_mr
$   gosub rule
$   dk_out = f$fao("!16AS !12AS !8AS !8AS !8AS ", -
             "Total", "", dk_sz, dk_us, dk_size)
$   dk_vl  = f$length(dk_out) + dk_lvl
$   dk_out = dk_bold + dk_out + dk_off + dk_line
$   gosub say
$ endif
$ dk_l = dk_c_ml
$ dk_r = dk_c_mr
$ gosub rule
$ if dk_min .ge. 0
$ then
$   dk_v = f$fao("!UL of !UL mounted disk!%S !UL% full or more", -
                 dk_over, dk_mnt, dk_min)
$   if dk_over .gt. 0 then dk_status = %X10000000    ! warning
$ else
$   dk_v = f$fao("!UL disk!%S mounted", dk_n)
$   if dk_unmnt .gt. 0 then dk_v = dk_v + f$fao(", !UL not", dk_unmnt)
$ endif
$ if dk_sysin then dk_v = dk_v + " (* = system disk)"
$ dk_out = f$extract(0, dk_cw, dk_v)
$ dk_vl  = f$length(dk_out)
$ gosub say
$ dk_l = dk_c_bl
$ dk_r = dk_c_br
$ gosub rule
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'dk_msg'
$ type sys$input
SPACE - disk space report for OpenVMS

Usage:   @SPACE [percent] [device] [option ...]

  percent  only list mounted disks at least this full, e.g. 85
  device   a device name or wildcard, e.g. DKA* or DSA1:
  PAGE     pause after each screenful
  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

With a percent, $SEVERITY is 0 (warning) when any disk is at or above it,
so a batch job can test it. Output to a file is plain text:

  PIPE @SPACE > SPACE.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Ctrl/Y: put the terminal back in its normal character set first.
$interrupted:
$ if f$type(dk_goff) .nes. ""
$ then
$   if dk_goff .nes. "" then write sys$output dk_goff, dk_off
$ endif
$cleanup:
$ if f$type(dk_msg) .nes. "" then set message 'dk_msg'
$ exit dk_status + 0 * f$verify(dk_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! SAY: write dk_out inside the box (dk_vl = its visible length). With PAGE,
$! close the box when the screen is full, pause, and reopen it.
$say:
$ if dk_rows .gt. 0 .and. dk_lines .ge. dk_rows - 2
$ then
$   write sys$output " ", dk_gon, dk_c_bl, dk_hline, dk_c_br, dk_goff
$   read/prompt="  -- Press RETURN for more, Ctrl/Z to stop -- " -
         /end_of_file=cleanup/error=cleanup sys$command dk_nada
$   write sys$output " ", dk_gon, dk_c_tl, dk_hline, dk_c_tr, dk_goff
$   dk_save_out = dk_out
$   dk_save_vl  = dk_vl
$   gosub colhead
$   dk_out = dk_save_out
$   dk_vl  = dk_save_vl
$   dk_lines = 2
$ endif
$ gosub box_write
$ dk_lines = dk_lines + 1
$ return
$!
$! BOX_WRITE: dk_out between the box sides, padded to the box width.
$box_write:
$ dk_fill = dk_cw - dk_vl
$ dk_sp = ""
$ if dk_fill .gt. 0 then dk_sp = f$fao("!''dk_fill'* ")
$ write sys$output " ", dk_gon, dk_c_v, dk_goff, " ", dk_out, dk_sp, " ", -
                   dk_gon, dk_c_v, dk_goff
$ return
$!
$! RULE: a line across the box, ending in dk_l and dk_r.
$rule:
$ write sys$output " ", dk_gon, dk_l, dk_hline, dk_r, dk_goff
$ dk_lines = dk_lines + 1
$ return
$!
$! COLHEAD: the column headings line.
$colhead:
$ dk_out = dk_key + dk_colplain + dk_off
$ dk_vl  = f$length(dk_colplain)
$ gosub box_write
$ dk_lines = dk_lines + 1
$ return
$!
$! ERRORS: a note under the disk's line if it has device errors.
$errors:
$ dk_err = f$getdvi(dk_dev, "ERRCNT")
$ if dk_err .le. 0 then return
$ dk_out = f$fao("!16* ^ !UL device error!%S", dk_err)
$ dk_vl  = f$length(dk_out)
$ dk_out = dk_yel + dk_out + dk_off
$ gosub say
$ return
$!
$! BAR: dk_line = "use%  [#####.....]" for dk_pc, coloured by level;
$! dk_lvl = its visible length.
$bar:
$ dk_col = dk_grn
$ if dk_pc .ge. dk_warn then dk_col = dk_yel
$ if dk_pc .ge. dk_crit then dk_col = dk_red
$ dk_line = dk_col + f$fao("!3UL%", dk_pc) + dk_off
$ dk_lvl = 4
$ if dk_bw .lt. 5 then return
$ dk_fill = (dk_pc * dk_bw + 50) / 100
$ if dk_fill .gt. dk_bw then dk_fill = dk_bw
$ dk_rest = dk_bw - dk_fill
$ dk_b = ""
$ if dk_fill .gt. 0 then dk_b = f$fao("!''dk_fill'*#")
$ dk_e = ""
$ if dk_rest .gt. 0 then dk_e = f$fao("!''dk_rest'*.")
$ dk_line = dk_line + "  [" + dk_col + dk_b + dk_off + dk_e + "]"
$ dk_lvl = dk_lvl + dk_bw + 4
$ return
$!
$! FMT_MB: dk_size = dk_mb megabytes as "512 MB", "33.9 GB" or "1.2 TB".
$fmt_mb:
$ if dk_mb .lt. 1024
$ then
$   dk_size = f$fao("!UL MB", dk_mb)
$   return
$ endif
$ dk_gb = dk_mb / 1024
$ if dk_gb .lt. 1024
$ then
$   dk_size = f$fao("!UL.!UL GB", dk_gb, (dk_mb - dk_gb * 1024) * 10 / 1024)
$   return
$ endif
$ dk_tb = dk_gb / 1024
$ dk_size = f$fao("!UL.!UL TB", dk_tb, (dk_gb - dk_tb * 1024) * 10 / 1024)
$ return
