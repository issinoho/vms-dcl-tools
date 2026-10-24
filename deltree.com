$!------------------------------------------------------------------------------
$! DELTREE.COM - Delete a directory and everything in it, safely
$!
$! Deletes a directory tree: every file, every version and every
$! subdirectory, then the directory itself. Before deleting it shows the
$! full real path, how many files and directories and how much space, and
$! asks you to type YES. It refuses to touch a whole disk, the directory
$! you are in (or any above it), your login directory (or any above it),
$! the system directories, and any tree that contains an alias directory
$! entry (deleting through one empties the real directory elsewhere).
$!
$! Usage:   @DELTREE directory [option ...]
$!
$!   directory  OLD (a subdirectory of where you are), [.OLD],
$!              DKA200:[USERS.OLD], DISK$TOOLS:[TEMP.X] or OLD.DIR
$!   DRYRUN     list what would be deleted; delete nothing
$!   KEEP       empty the tree but keep the top directory
$!   LOG        show each file as it is deleted
$!   NOCONFIRM  don't ask (for batch jobs; the safety checks still apply)
$!   HELP       show this text
$!
$! Files are given owner and system delete access where they lack it, never
$! world access. Deleting stops as soon as a pass makes no progress, and
$! anything left (an open file, no privilege) is listed with the reason.
$! $STATUS is success only if everything asked for was deleted.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ dt_verify = f$verify(0)
$ set noon
$ dt_status = 1
$ dt_tmp = ""
$ on control_y then goto interrupted
$ dt_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$ dt_err  = %X10000002                      ! error, message already shown
$ dt_warn = %X10000000
$!
$!---- Parameters --------------------------------------------------------------
$ dt_raw     = ""
$ dt_dryrun  = 0
$ dt_keep    = 0
$ dt_log     = 0
$ dt_noconf  = 0
$ dt_p = 0
$opt_loop:
$ dt_p = dt_p + 1
$ if dt_p .gt. 8 then goto opt_done
$ dt_opt = f$edit(p'dt_p', "TRIM")
$ if dt_opt .eqs. "" then goto opt_loop
$ dt_up = f$edit(dt_opt, "UPCASE")
$ if dt_up .eqs. "HELP" .or. dt_up .eqs. "?" then goto help
$ if dt_up .eqs. "DRYRUN"
$ then
$   dt_dryrun = 1
$   goto opt_loop
$ endif
$ if dt_up .eqs. "KEEP"
$ then
$   dt_keep = 1
$   goto opt_loop
$ endif
$ if dt_up .eqs. "LOG"
$ then
$   dt_log = 1
$   goto opt_loop
$ endif
$ if dt_up .eqs. "NOCONFIRM"
$ then
$   dt_noconf = 1
$   goto opt_loop
$ endif
$ if dt_raw .nes. ""
$ then
$   dt_say = "give one directory only (try @DELTREE HELP)"
$   goto refuse
$ endif
$ dt_raw = dt_opt
$ goto opt_loop
$opt_done:
$ if dt_raw .eqs. ""
$ then
$   dt_say = "which directory? (try @DELTREE HELP)"
$   goto refuse
$ endif
$!
$!---- Work out exactly which directory is meant -------------------------------
$! A bare name is a subdirectory of where you are.
$ dt_spec = dt_raw
$ if f$locate("[", dt_spec) .ge. f$length(dt_spec) .and. -
     f$locate("<", dt_spec) .ge. f$length(dt_spec) .and. -
     f$locate(":", dt_spec) .ge. f$length(dt_spec)
$ then
$   dt_nm = f$parse(dt_spec, , , "NAME", "SYNTAX_ONLY")
$   dt_ty = f$edit(f$parse(dt_spec, , , "TYPE", "SYNTAX_ONLY"), "UPCASE")
$   if dt_nm .eqs. "" .or. (dt_ty .nes. "." .and. dt_ty .nes. ".DIR")
$   then
$     dt_say = "''dt_raw' is not a directory name"
$     goto refuse
$   endif
$   dt_spec = "[." + dt_nm + "]"
$ endif
$! [USERS]OLD.DIR form: turn the directory file into a directory.
$ dt_nm = f$parse(dt_spec, , , "NAME", "SYNTAX_ONLY")
$ if dt_nm .nes. ""
$ then
$   dt_ty = f$edit(f$parse(dt_spec, , , "TYPE", "SYNTAX_ONLY"), "UPCASE")
$   if dt_ty .nes. ".DIR" .and. dt_ty .nes. "."
$   then
$     dt_say = "''dt_raw' is a file, not a directory"
$     goto refuse
$   endif
$   dt_d = f$parse(dt_spec, , , "DIRECTORY", "SYNTAX_ONLY")
$   dt_spec = f$parse(dt_spec, , , "DEVICE", "SYNTAX_ONLY") + -
              f$extract(0, f$length(dt_d) - 1, dt_d) + "." + dt_nm + "]"
$ endif
$! The real device and directory, with logical names and roots resolved.
$ dt_s = dt_spec
$ gosub resolve
$ if dt_r_dev .eqs. ""
$ then
$   dt_say = "no such directory: ''dt_raw'"
$   goto refuse
$ endif
$ dt_dev   = dt_r_dev
$ dt_inner = dt_r_inner                     ! e.g. USERS.OLD
$ dt_fdev  = dt_r_fdev
$ if dt_inner .eqs. "000000" .or. dt_inner .eqs. ""
$ then
$   dt_say = "refusing to delete a whole disk (''dt_dev'[000000])"
$   goto refuse
$ endif
$! Split off the last level (an ODS-5 name may contain ^. which is not a
$! separator) to find the parent and the directory file.
$ dt_i = f$length(dt_inner) - 1
$ dt_cut = -1
$split_next:
$ if dt_i .lt. 0 then goto split_done
$ if f$extract(dt_i, 1, dt_inner) .eqs. "."
$ then
$   if dt_i .eq. 0 then goto split_found
$   if f$extract(dt_i - 1, 1, dt_inner) .nes. "^" then goto split_found
$ endif
$ dt_i = dt_i - 1
$ goto split_next
$split_found:
$ dt_cut = dt_i
$split_done:
$ if dt_cut .lt. 0
$ then
$   dt_parent = "[000000]"
$   dt_name   = dt_inner
$ else
$   dt_parent = "[" + f$extract(0, dt_cut, dt_inner) + "]"
$   dt_name   = f$extract(dt_cut + 1, 999, dt_inner)
$ endif
$ dt_top  = dt_dev + "[" + dt_inner + "]"   ! the directory, for messages
$ dt_dirf = dt_dev + dt_parent + dt_name + ".DIR;1"
$ dt_tree = dt_dev + "[" + dt_inner + "...]"
$ if f$search(dt_dirf, 11) .eqs. ""
$ then
$   dt_say = "cannot find the directory file ''dt_dirf'"
$   goto refuse
$ endif
$!
$!---- Safety checks -----------------------------------------------------------
$! Not where you are, nor above it.
$ dt_s = f$environment("DEFAULT")
$ gosub resolve
$ gosub is_under
$ if dt_under
$ then
$   dt_say = "you are in that tree; SET DEFAULT somewhere outside it first"
$   goto refuse
$ endif
$! Not your login directory, nor above it.
$ dt_s = f$trnlnm("SYS$LOGIN")
$ gosub resolve
$ gosub is_under
$ if dt_under
$ then
$   dt_say = "refusing: that tree holds your login directory"
$   goto refuse
$ endif
$! Not the system directories.
$ dt_first = f$element(0, ".", dt_inner)
$ if dt_fdev .eqs. f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM") .and. -
     (f$extract(0, 3, dt_first) .eqs. "SYS" .or. dt_first .eqs. "VMS$COMMON")
$ then
$   dt_say = "refusing to delete system directory ''dt_top'"
$   goto refuse
$ endif
$!
$!---- Look at the tree: size, and alias directory entries ---------------------
$ dt_pid = f$getjpi("", "PID")
$ dt_tmp = "SYS$SCRATCH:DELTREE_''dt_pid'.TMP"
$ dt_nf = 0                                 ! files (each version counts)
$ dt_nd = 0                                 ! subdirectories
$ dt_blk = 0                                ! blocks allocated
$ dt_nalias = 0
$ dt_unver = 0                              ! directories not checkable
$! Tell the user what is happening; a big tree takes a while. On an ANSI
$! terminal the line is updated in place with the count so far.
$ dt_ansi = 0
$ if f$mode() .eqs. "INTERACTIVE" .and. f$getdvi("SYS$OUTPUT", "TRM") then -
    dt_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$ dt_up = ""
$ if dt_ansi
$ then
$   dt_esc[0,8] = 27
$   dt_up = dt_esc + "[A" + dt_esc + "[K"   ! back up a line and clear it
$ endif
$ write sys$output ""
$ write sys$output "  Looking through ", dt_top, " ..."
$ dt_canup = dt_ansi                        ! last line is ours to update
$ dt_seen = 0
$ dt_f = dt_dirf
$ gosub check_alias
$scan_next:
$ dt_f = f$search(dt_tree + "*.*;*", 12)
$ if dt_f .eqs. "" then goto scan_done
$ dt_seen = dt_seen + 1
$ if dt_ansi .and. dt_seen - (dt_seen / 500) * 500 .eq. 0
$ then
$   dt_pre = ""
$   if dt_canup then dt_pre = dt_up
$   write sys$output dt_pre, "  Looking through ", dt_top, -
                     f$fao(": !UL items so far ...", dt_seen)
$   dt_canup = 1
$ endif
$ dt_a = 0
$ dt_a = f$file_attributes(dt_f, "ALQ")
$ if f$type(dt_a) .eqs. "INTEGER" then dt_blk = dt_blk + dt_a
$ if f$edit(f$parse(dt_f, , , "TYPE"), "UPCASE") .eqs. ".DIR"
$ then
$   dt_nd = dt_nd + 1
$   gosub check_alias
$ else
$   dt_nf = dt_nf + 1
$ endif
$ goto scan_next
$scan_done:
$ if dt_canup then write sys$output dt_up, "  Looked through ", dt_top, -
                                    f$fao(": !UL items", dt_seen)
$ if dt_nalias .gt. 0
$ then
$   set message 'dt_msg'
$   dt_e = "entries"
$   if dt_nalias .eq. 1 then dt_e = "entry"
$   write sys$output "DELTREE: refusing: the tree contains ", -
                     f$fao("!UL alias directory !AS", dt_nalias, dt_e)
$   write sys$output "         (listed above). Deleting through an alias"
$   write sys$output "         empties the real directory elsewhere. Remove"
$   write sys$output "         each alias entry first with SET FILE/REMOVE."
$   dt_status = dt_err
$   goto cleanup
$ endif
$!
$ dt_mb = dt_blk / 2048
$ gosub fmt_mb
$ dt_what = f$fao("!UL file!%S in !UL subdirector", dt_nf, dt_nd)
$ dt_what = dt_what + f$element(dt_nd .eq. 1, ",", "ies,y") + ", " + dt_size
$ write sys$output ""
$ if dt_keep
$ then
$   write sys$output "  Empty:  ", dt_top, " (the directory itself is kept)"
$ else
$   write sys$output "  Delete: ", dt_top
$ endif
$ write sys$output "  Holds:  ", dt_what
$ if dt_unver .gt. 0 then write sys$output -
    "  Note:   ", dt_unver, " directories could not be checked for aliases"
$ write sys$output ""
$!
$ if dt_dryrun
$ then
$   if dt_nf + dt_nd .gt. 0
$   then
$     set message 'dt_msg'
$     directory/size=allocation/date/notrailing 'dt_tree'*.*;*
$     set message/nofacility/noseverity/noidentification/notext
$   endif
$   write sys$output ""
$   write sys$output "  DRYRUN: nothing was deleted."
$   goto cleanup
$ endif
$!
$!---- Confirm -----------------------------------------------------------------
$ if .not. dt_noconf
$ then
$   if f$mode() .nes. "INTERACTIVE"
$   then
$     dt_say = "not interactive; add NOCONFIRM to delete without asking"
$     goto refuse
$   endif
$   dt_ans = ""
$   read/end_of_file=cancelled/error=cancelled -
        /prompt="  Type YES to delete it all: " sys$command dt_ans
$   if f$edit(dt_ans, "TRIM,UPCASE") .nes. "YES" then goto cancelled
$ endif
$!
$!---- Delete ------------------------------------------------------------------
$! Owner and system get delete access where they lack it (never world);
$! that needs ownership or privilege, and fails quietly otherwise.
$ set security/protection=(system:rwed,owner:rwed) 'dt_tree'*.*;*
$ set security/protection=(system:rwed,owner:rwed) 'dt_dirf'
$! Each pass deletes the files and the directories that have become empty;
$! stop when nothing is left, or a pass deletes nothing more.
$ dt_left = dt_nf + dt_nd
$ dt_pass = 0
$pass_next:
$ if dt_left .eq. 0 then goto passes_done
$ dt_pass = dt_pass + 1
$ if dt_log then set message 'dt_msg'
$ if dt_log
$ then
$   delete/log 'dt_tree'*.*;*
$ else
$   delete/nolog 'dt_tree'*.*;*
$ endif
$ set message/nofacility/noseverity/noidentification/notext
$ dt_was = dt_left
$ gosub count_left
$ if dt_left .lt. dt_was then goto pass_next
$passes_done:
$!
$ if dt_left .eq. 0 .and. .not. dt_keep
$ then
$   if dt_log then set message 'dt_msg'
$   delete/nolog 'dt_dirf'
$   set message/nofacility/noseverity/noidentification/notext
$ endif
$!
$!---- Report ------------------------------------------------------------------
$ dt_topgone = f$search(dt_dirf, 13) .eqs. ""
$ if dt_left .eq. 0 .and. (dt_keep .or. dt_topgone)
$ then
$   if dt_keep
$   then
$     write sys$output "  Emptied ", dt_top, ": ", dt_what
$   else
$     write sys$output "  Deleted ", dt_top, ": ", dt_what
$   endif
$   goto cleanup
$ endif
$ dt_status = dt_err
$ if dt_left .eq. 0
$ then
$   write sys$output "  The contents are gone, but ", dt_dirf, -
                     " could not be deleted:"
$   set message 'dt_msg'
$   delete/nolog 'dt_dirf'
$   goto cleanup
$ endif
$ write sys$output f$fao("  !UL item!%S could not be deleted.", dt_left), -
                   " The first few, with the reason:"
$ set message 'dt_msg'
$ dt_k = 0
$left_next:
$ dt_f = f$search(dt_tree + "*.*;*", 14)
$ if dt_f .eqs. "" then goto cleanup
$ if f$edit(f$parse(dt_f, , , "TYPE"), "UPCASE") .eqs. ".DIR" then -
    goto left_next
$ dt_k = dt_k + 1
$ if dt_k .gt. 10 then goto left_next       ! finish the search quietly
$ delete/nolog 'dt_f'                       ! fails again, saying why
$ goto left_next
$!
$!---- Refusals and cancelling -------------------------------------------------
$refuse:
$ set message 'dt_msg'
$ write sys$output "DELTREE: ", dt_say
$ dt_status = dt_err
$ goto cleanup
$cancelled:
$ write sys$output "  Cancelled; nothing was deleted."
$ dt_status = dt_warn
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'dt_msg'
$ type sys$input
DELTREE - delete a directory and everything in it, safely

Usage:   @DELTREE directory [option ...]

  directory  OLD, [.OLD], DKA200:[USERS.OLD], DISK$TOOLS:[TEMP.X] or OLD.DIR
  DRYRUN     list what would be deleted; delete nothing
  KEEP       empty the tree but keep the top directory
  LOG        show each file as it is deleted
  NOCONFIRM  don't ask (for batch jobs; the safety checks still apply)
  HELP       show this text

It shows the full path, file count and size, and asks you to type YES.
It will not delete a whole disk, the directory you are in or above it,
your login directory or above it, system directories, or a tree that
contains an alias directory entry.
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$interrupted:
$ write sys$output ""
$ write sys$output "DELTREE: interrupted; part of the tree may already be gone"
$ dt_status = dt_err
$cleanup:
$ if f$trnlnm("DT_IN") .nes. "" then close dt_in
$ if dt_tmp .nes. ""
$ then
$   if f$search(dt_tmp) .nes. "" then delete/nolog 'dt_tmp';*
$ endif
$ if f$type(dt_msg) .nes. "" then set message 'dt_msg'
$ exit dt_status + 0 * f$verify(dt_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! RESOLVE: from dt_s, set dt_r_dev (real device, "" if no such
$! directory), dt_r_fdev (its full device name) and dt_r_inner (the
$! directory path without brackets, rooted directories joined up).
$resolve:
$ dt_r_dev = ""
$ dt_r_inner = ""
$ dt_r_fdev = ""
$ dt_x = f$parse(dt_s, , , , "NO_CONCEAL")  ! "" if the directory is missing
$ if dt_x .eqs. "" then return
$ dt_r_dev = f$parse(dt_s, , , "DEVICE", "NO_CONCEAL")
$ dt_d = f$parse(dt_s, , , "DIRECTORY", "NO_CONCEAL")
$ dt_d = f$edit(dt_d, "UPCASE")
$! <> to [], then join rooted parts: [ROOT.][SUB] -> [ROOT.SUB]
$rs_angle:
$ dt_j = f$locate("<", dt_d)
$ if dt_j .lt. f$length(dt_d)
$ then
$   dt_d[dt_j,1] := "["
$   goto rs_angle
$ endif
$ dt_j = f$locate(">", dt_d)
$ if dt_j .lt. f$length(dt_d)
$ then
$   dt_d[dt_j,1] := "]"
$   goto rs_angle
$ endif
$ dt_d = dt_d - ".][000000]"
$rs_join:
$ if f$locate("][", dt_d) .lt. f$length(dt_d)
$ then
$   dt_d = dt_d - "]["
$   goto rs_join
$ endif
$ if f$extract(f$length(dt_d) - 1, 1, dt_d) .nes. "]" then dt_d = dt_d + "]"
$ dt_r_inner = f$extract(1, f$length(dt_d) - 2, dt_d)
$ if f$extract(f$length(dt_r_inner) - 1, 1, dt_r_inner) .eqs. "." then -
    dt_r_inner = f$extract(0, f$length(dt_r_inner) - 1, dt_r_inner)
$ dt_r_fdev = f$getdvi(dt_r_dev, "FULLDEVNAM")
$ return
$!
$! IS_UNDER: dt_under = 1 if the directory just resolved (dt_r_*) is the
$! target or inside it.
$is_under:
$ dt_under = 0
$ if dt_r_dev .eqs. "" .or. dt_r_fdev .nes. dt_fdev then return
$ if dt_r_inner .eqs. dt_inner then dt_under = 1
$ if f$extract(0, f$length(dt_inner) + 1, dt_r_inner) .eqs. dt_inner + "." -
     then dt_under = 1
$ return
$!
$! CHECK_ALIAS: is directory file dt_f a real entry, or an alias for a
$! directory that lives elsewhere? A directory's header has a back link
$! to its real parent; compare it with the directory it was found in.
$check_alias:
$ dt_did = ""
$ dt_did = f$file_attributes(dt_f, "DID")
$ dt_bl = ""
$ if f$search(dt_tmp) .nes. "" then delete/nolog 'dt_tmp';*
$ define/user sys$error nla0:
$ dump/header/block=count:0/output='dt_tmp' 'dt_f'
$ open/read/error=ca_check dt_in 'dt_tmp'
$ca_read:
$ read/end_of_file=ca_close/error=ca_close dt_in dt_rec
$ if f$locate("Back link file identification", dt_rec) .ge. -
     f$length(dt_rec) then goto ca_read
$ dt_bl = f$edit(f$element(1, ":", dt_rec), "COLLAPSE")
$ca_close:
$ close dt_in
$ca_check:
$ dt_did = f$edit(dt_did, "COLLAPSE")
$ if dt_did .eqs. "" .or. dt_bl .eqs. ""
$ then
$   dt_unver = dt_unver + 1
$   return
$ endif
$ if dt_bl .nes. dt_did
$ then
$   dt_nalias = dt_nalias + 1
$   write sys$output "  Alias entry: ", dt_f
$   dt_canup = 0                            ! don't overwrite this line
$ endif
$ return
$!
$! COUNT_LEFT: dt_left = how many files and directories remain in the tree.
$count_left:
$ dt_left = 0
$cl_next:
$ dt_f = f$search(dt_tree + "*.*;*", 15)
$ if dt_f .eqs. "" then return
$ dt_left = dt_left + 1
$ goto cl_next
$!
$! FMT_MB: dt_size = dt_mb megabytes as "512 MB" or "3.4 GB".
$fmt_mb:
$ if dt_mb .lt. 1024
$ then
$   dt_size = f$fao("!UL MB", dt_mb)
$   if dt_mb .eq. 0 then dt_size = f$fao("!UL blocks", dt_blk)
$ else
$   dt_size = f$fao("!UL.!UL GB", dt_mb / 1024, -
                    (dt_mb - (dt_mb / 1024) * 1024) * 10 / 1024)
$ endif
$ return
