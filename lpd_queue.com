$!------------------------------------------------------------------------------
$! LPD_QUEUE.COM - Create a print queue that prints to CUPS over LPD
$!
$! Creates (or re-creates) an OpenVMS print queue that prints through the
$! TCP/IP Services LPD client to cups-lpd and CUPS on another machine, and
$! writes its entry in the LPD printcap. Safe to run again: an existing
$! queue is stopped and re-initialised, keeping its jobs, and an existing
$! printcap entry of the same name is replaced (the old printcap is kept
$! as a .BAK copy).
$!
$! Usage:   @LPD_QUEUE [queue] [remote-host] [remote-queue] [option ...]
$!
$!   queue         OpenVMS queue name             (default: setting below)
$!   remote-host   host running cups-lpd          (default: setting below)
$!   remote-queue  CUPS queue on that host        (default: setting below)
$!   DEFAULT       also point SYS$PRINT at the queue (until the next boot)
$!   DRYRUN        show the printcap entry and queue settings, change nothing
$!   HELP          show this text
$!
$! Needs SYSPRV and OPER; run it from SYSTEM. The LPD client must be
$! configured (@SYS$MANAGER:TCPIP$CONFIG, Client components, LPR/LPD).
$!
$! On the CUPS side, run cups-lpd with
$!     -o job-sheets=none -o media=A4 -o media-type=stationery
$! or the printer may print a banner page or pick the wrong paper.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ lq_verify = f$verify(0)
$ set noon
$ on control_y then goto done
$ lq_privs = ""
$!
$!---- Settings: defaults for the parameters -----------------------------------
$ lq_def_queue  = "LPD_PRINTER"
$ lq_def_host   = ""                        ! e.g. "printserver" or an address
$ lq_def_rqueue = ""                        ! e.g. "Office_Laser"
$!
$!---- Parameters and options --------------------------------------------------
$ lq_queue   = ""
$ lq_host    = ""
$ lq_rqueue  = ""
$ lq_default = 0
$ lq_dryrun  = 0
$ lq_pos = 0                                ! positional parameters seen
$ lq_p = 0
$opt_loop:
$ lq_p = lq_p + 1
$ if lq_p .gt. 8 then goto opt_done
$ lq_raw = f$edit(p'lq_p', "TRIM")
$ if lq_raw .eqs. "" then goto opt_loop
$ lq_opt = f$edit(lq_raw, "UPCASE")
$ lq_len = f$length(lq_opt)
$ if lq_opt .eqs. f$extract(0, lq_len, "HELP") .or. lq_opt .eqs. "?" -
     then goto help
$ if lq_opt .eqs. "DEFAULT"
$ then
$   lq_default = 1
$   goto opt_loop
$ endif
$ if lq_opt .eqs. "DRYRUN"
$ then
$   lq_dryrun = 1
$   goto opt_loop
$ endif
$ lq_pos = lq_pos + 1
$ if lq_pos .eq. 1 then lq_queue  = lq_opt
$ if lq_pos .eq. 2 then lq_host   = lq_raw
$ if lq_pos .eq. 3 then lq_rqueue = lq_raw   ! CUPS ignores case, keep as given
$ if lq_pos .le. 3 then goto opt_loop
$ write sys$output "LPD_QUEUE: too many parameters (try @LPD_QUEUE HELP)"
$ goto done
$opt_done:
$ if lq_queue  .eqs. "" then lq_queue  = lq_def_queue
$ if lq_host   .eqs. "" then lq_host   = lq_def_host
$ if lq_rqueue .eqs. "" then lq_rqueue = lq_def_rqueue
$ if lq_host .eqs. "" .or. lq_rqueue .eqs. ""
$ then
$   write sys$output "LPD_QUEUE: give the remote host and queue, or set the"
$   write sys$output "           defaults at the top of the procedure"
$   write sys$output "           (try @LPD_QUEUE HELP)"
$   goto done
$ endif
$ lq_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$!
$!---- Checks ------------------------------------------------------------------
$ if .not. lq_dryrun
$ then
$   lq_privs = f$setprv("SYSPRV,OPER")
$   if .not. f$privilege("SYSPRV,OPER")
$   then
$     write sys$output "LPD_QUEUE: SYSPRV and OPER are needed;" -
                       + " run it from SYSTEM"
$     goto done
$   endif
$ endif
$ if f$trnlnm("TCPIP$LPD_ROOT") .eqs. ""
$ then
$   write sys$output "LPD_QUEUE: TCPIP$LPD_ROOT is not defined. Configure"
$   write sys$output "           LPR/LPD with @SYS$MANAGER:TCPIP$CONFIG, or"
$   write sys$output "           start it with"
$   write sys$output "           @SYS$STARTUP:TCPIP$LPD_STARTUP"
$   goto done
$ endif
$ if f$search("SYS$SYSTEM:TCPIP$LPD_SMB.EXE") .eqs. ""
$ then
$   write sys$output "LPD_QUEUE: SYS$SYSTEM:TCPIP$LPD_SMB.EXE is missing;" -
                     + " is LPR/LPD installed?"
$   goto done
$ endif
$ lq_pcap = f$trnlnm("TCPIP$PRINTCAP")
$ if lq_pcap .eqs. "" then lq_pcap = "TCPIP$LPD_ROOT:[000000]TCPIP$PRINTCAP.DAT"
$ lq_tab = f$fao("!_")
$!
$! The printcap entry this queue gets.
$ lq_e_1 = lq_queue + "|" + f$edit(lq_queue, "LOWERCASE") + ":\"
$ lq_e_2 = lq_tab + ":lf=/TCPIP$LPD_ROOT/000000/" + lq_queue + ".LOG:\"
$ lq_e_3 = lq_tab + ":rm=" + lq_host + ":\"
$ lq_e_4 = lq_tab + ":rp=" + lq_rqueue + ":\"
$ lq_e_5 = lq_tab + ":sd=/TCPIP$LPD_ROOT/" + lq_queue + ":\"
$ lq_e_6 = lq_tab + ":sh:"
$!
$ write sys$output "Queue ''lq_queue' on ''lq_node':: prints to ''lq_rqueue'" -
                   + " at ''lq_host'"
$ if lq_dryrun
$ then
$   write sys$output ""
$   write sys$output "DRYRUN: nothing will be changed. Printcap entry for ", -
                     lq_pcap, ":"
$   lq_i = 0
$dry_entry:
$   lq_i = lq_i + 1
$   if lq_i .gt. 6 then goto dry_done
$   write sys$output "    ", lq_e_'lq_i'
$   goto dry_entry
$dry_done:
$   write sys$output "Queue: INITIALIZE/QUEUE/START ''lq_queue'" -
                     + " /ON=''lq_node':: /PROCESSOR=TCPIP$LPD_SMB"
$   write sys$output "       /DEFAULT=(NOBURST,NOFLAG,NOTRAILER,NOFEED)" -
                     + " /RETAIN=ERROR /NOENABLE_GENERIC"
$   if lq_default then write sys$output "SYS$PRINT would point at ''lq_queue'"
$   goto done
$ endif
$!
$!---- Printcap ----------------------------------------------------------------
$! Write a new version without any entry for this queue (an entry runs on
$! while its lines end in a backslash), then add the entry at the end.
$ lq_in = f$search(lq_pcap)
$ if lq_in .nes. "" then copy/nolog 'lq_in' *.BAK
$ open/write/error=pcap_fail lq_out 'lq_pcap'
$ if lq_in .eqs. "" then goto pcap_append
$ open/read/error=pcap_fail lq_rd 'lq_in'
$ lq_skip = 0
$pcap_read:
$ read/end_of_file=pcap_eof lq_rd lq_line
$ lq_last = ""
$ if f$length(lq_line) .gt. 0 then -
    lq_last = f$extract(f$length(lq_line) - 1, 1, lq_line)
$ if lq_skip
$ then
$   if lq_last .nes. "\" then lq_skip = 0
$   goto pcap_read
$ endif
$ lq_first = f$extract(0, 1, lq_line)
$ if lq_line .nes. "" .and. lq_first .nes. "#" .and. lq_first .nes. " " -
     .and. lq_first .nes. lq_tab .and. lq_first .nes. ":"
$ then
$   lq_names = f$edit(f$element(0, ":", lq_line), "TRIM,UPCASE") - "\"
$   lq_names = "|" + lq_names + "|"
$   if f$locate("|''lq_queue'|", lq_names) .lt. f$length(lq_names)
$   then
$     write sys$output "Replacing the printcap entry for ''lq_queue'"
$     if lq_last .eqs. "\" then lq_skip = 1
$     goto pcap_read
$   endif
$ endif
$ write lq_out lq_line
$ goto pcap_read
$pcap_eof:
$ close lq_rd
$pcap_append:
$ lq_i = 0
$pcap_entry:
$ lq_i = lq_i + 1
$ if lq_i .gt. 6 then goto pcap_closed
$ write lq_out lq_e_'lq_i'
$ goto pcap_entry
$pcap_closed:
$ close lq_out
$ write sys$output "Printcap: ", f$search(lq_pcap)
$ if lq_in .nes. "" then write sys$output "Previous:  ", -
    f$parse("*.BAK", lq_in, , , "SYNTAX_ONLY") - ";"
$ goto spool
$pcap_fail:
$ write sys$output "LPD_QUEUE: cannot write ", lq_pcap
$ goto done
$!
$!---- Spool directory named in the printcap -----------------------------------
$spool:
$ if f$search("TCPIP$LPD_ROOT:[000000]''lq_queue'.DIR") .eqs. "" then -
    create/directory/owner=parent TCPIP$LPD_ROOT:['lq_queue']
$!
$!---- Queue -------------------------------------------------------------------
$! Stopped first if it exists, so INITIALIZE can change it without losing
$! its jobs. No flag, burst or trailer pages and no added form feed, so a
$! job prints exactly as sent.
$ lq_junk = f$getqui("CANCEL_OPERATION")
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_NAME", lq_queue) .nes. ""
$ then
$   write sys$output "Stopping the existing queue ''lq_queue'"
$   stop/queue/reset 'lq_queue'
$ endif
$ initialize/queue/start 'lq_queue' -
    /on='lq_node':: -
    /processor=TCPIP$LPD_SMB -
    /default=(noburst,noflag,notrailer,nofeed) -
    /retain=error -
    /noenable_generic
$ if .not. $status
$ then
$   write sys$output "LPD_QUEUE: the queue was not initialised"
$   goto done
$ endif
$!
$ if lq_default
$ then
$   define/system/executive_mode SYS$PRINT 'lq_queue'
$   write sys$output "SYS$PRINT is ''lq_queue' until the next boot. To keep it,"
$   write sys$output "add to SYS$MANAGER:SYLOGICALS.COM:"
$   write sys$output "    $ DEFINE/SYSTEM/EXECUTIVE_MODE SYS$PRINT ''lq_queue'"
$ endif
$!
$ show queue/full 'lq_queue'
$ write sys$output ""
$ write sys$output "Test it:   $ PRINT/QUEUE=''lq_queue' SYS$LOGIN:LOGIN.COM"
$ write sys$output "Errors go to TCPIP$LPD_ROOT:[000000]''lq_queue'.LOG"
$ write sys$output "To start it at boot, add to SYS$MANAGER:SYSTARTUP_VMS.COM"
$ write sys$output "after TCP/IP Services has started:"
$ write sys$output "    $ START/QUEUE ''lq_queue'"
$ goto done
$!
$!---- Help --------------------------------------------------------------------
$help:
$ type sys$input
LPD_QUEUE - create a print queue that prints to CUPS over LPD

Usage:   @LPD_QUEUE [queue] [remote-host] [remote-queue] [option ...]

  queue         OpenVMS queue name
  remote-host   host running cups-lpd
  remote-queue  CUPS queue on that host
  DEFAULT       also point SYS$PRINT at the queue (until the next boot)
  DRYRUN        show what would be done, change nothing
  HELP          show this text

Defaults for the three names can be set at the top of the procedure.
Needs SYSPRV and OPER. Example:

  @LPD_QUEUE LPD_OFFICE printserver Office_Laser DEFAULT
$ goto done
$!
$!---- Clean up and exit -------------------------------------------------------
$done:
$ if f$trnlnm("LQ_RD", "LNM$PROCESS") .nes. "" then close lq_rd
$ if f$trnlnm("LQ_OUT", "LNM$PROCESS") .nes. "" then close lq_out
$ if lq_privs .nes. "" then lq_privs = f$setprv(lq_privs)
$ exit 1 + 0 * f$verify(lq_verify)
