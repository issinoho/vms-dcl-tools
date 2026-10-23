$! LPD_QUEUE.COM
$!
$! Creates (or re-creates) an OpenVMS print queue that prints through
$! TCP/IP Services' LPD client to cups-lpd and CUPS on another machine,
$! and writes its entry in the LPD printcap.  Safe to run again: an
$! existing queue is stopped and re-initialised, keeping its jobs, and an
$! existing printcap entry of the same name is replaced.
$!
$!   $ @LPD_QUEUE [queue] [remote-host] [remote-queue] [DEFAULT]
$!
$!   P1  OpenVMS queue name          default LPD_TS7500I
$!   P2  host running cups-lpd       default 192.168.0.131
$!   P3  CUPS queue on that host     default TS7500i (CUPS ignores case)
$!   P4  DEFAULT to point SYS$PRINT at the queue
$!
$! Needs SYSPRV and OPER; run it from SYSTEM.  The LPD client must be
$! configured and started (TCPIP$CONFIG, Client components, LPR/LPD).
$!
$! On the CUPS side, cups-lpd should run with
$!   -o job-sheets=none -o media=A4 -o media-type=stationery
$! or the printer feeds a blank banner sheet, or tries photo paper.
$!
$ SET NOON
$ say = "WRITE SYS$OUTPUT"
$ tab = F$FAO("!_")
$ old_privs = F$SETPRV("SYSPRV,OPER")
$ IF .NOT. F$PRIVILEGE("SYSPRV,OPER")
$ THEN
$   say "LPD_QUEUE: SYSPRV and OPER are needed"
$   GOTO DONE
$ ENDIF
$!
$ queue = F$EDIT(P1,"TRIM,UPCASE")
$ IF queue .EQS. "" THEN queue = "LPD_TS7500I"
$ rhost = F$EDIT(P2,"TRIM")
$ IF rhost .EQS. "" THEN rhost = "192.168.0.131"
$ rqueue = F$EDIT(P3,"TRIM")
$ IF rqueue .EQS. "" THEN rqueue = "TS7500i"
$ make_default = F$EDIT(P4,"TRIM,UPCASE") .EQS. "DEFAULT"
$ node = F$GETSYI("NODENAME")
$!
$! The LPD client: its root, its symbiont and its printcap.
$!
$ IF F$TRNLNM("TCPIP$LPD_ROOT") .EQS. ""
$ THEN
$   say "LPD_QUEUE: TCPIP$LPD_ROOT is not defined; configure LPR/LPD with"
$   say "           @SYS$MANAGER:TCPIP$CONFIG, or run @SYS$STARTUP:TCPIP$LPD_STARTUP"
$   GOTO DONE
$ ENDIF
$ IF F$SEARCH("SYS$SYSTEM:TCPIP$LPD_SMB.EXE") .EQS. ""
$ THEN
$   say "LPD_QUEUE: SYS$SYSTEM:TCPIP$LPD_SMB.EXE is missing; is LPR/LPD installed?"
$   GOTO DONE
$ ENDIF
$ pcap = F$TRNLNM("TCPIP$PRINTCAP")
$ IF pcap .EQS. "" THEN pcap = "TCPIP$LPD_ROOT:[000000]TCPIP$PRINTCAP.DAT"
$!
$ say "Queue ''queue' on ''node':: to ''rqueue' at ''rhost'"
$!
$! The printcap: copy it to a new version, leaving out any entry for this
$! queue (an entry runs on while its lines end in a backslash), and add
$! the entry at the end.
$!
$ in_file = F$SEARCH(pcap)
$ IF in_file .NES. "" THEN COPY 'in_file' *.BAK
$ OPEN/WRITE out 'pcap'
$ IF in_file .EQS. "" THEN GOTO PCAP_APPEND
$ OPEN/READ in 'in_file'
$ skipping = 0
$PCAP_READ:
$ READ/END_OF_FILE=PCAP_EOF in line
$ last = ""
$ IF F$LENGTH(line) .GT. 0 THEN last = F$EXTRACT(F$LENGTH(line)-1,1,line)
$ IF skipping
$ THEN
$   IF last .NES. "\" THEN skipping = 0
$   GOTO PCAP_READ
$ ENDIF
$ first = F$EXTRACT(0,1,line)
$ IF line .NES. "" .AND. first .NES. "#" .AND. first .NES. " " -
     .AND. first .NES. tab .AND. first .NES. ":"
$ THEN
$   names = F$EDIT(F$ELEMENT(0,":",line),"TRIM,UPCASE") - "\"
$   names = "|" + names + "|"
$   IF F$LOCATE("|''queue'|",names) .LT. F$LENGTH(names)
$   THEN
$     say "Replacing the printcap entry for ''queue'"
$     IF last .EQS. "\" THEN skipping = 1
$     GOTO PCAP_READ
$   ENDIF
$ ENDIF
$ WRITE out line
$ GOTO PCAP_READ
$PCAP_EOF:
$ CLOSE in
$PCAP_APPEND:
$ WRITE out queue, "|", F$EDIT(queue,"LOWERCASE"), ":\"
$ WRITE out tab, ":lf=/TCPIP$LPD_ROOT/000000/", queue, ".LOG:\"
$ WRITE out tab, ":rm=", rhost, ":\"
$ WRITE out tab, ":rp=", rqueue, ":\"
$ WRITE out tab, ":sd=/TCPIP$LPD_ROOT/", queue, ":\"
$ WRITE out tab, ":sh:"
$ CLOSE out
$ say "Printcap: ''F$SEARCH(pcap)'"
$!
$! The spool directory the printcap names.
$!
$ IF F$SEARCH("TCPIP$LPD_ROOT:[000000]''queue'.DIR") .EQS. ""
$ THEN
$   CREATE/DIRECTORY/OWNER=PARENT TCPIP$LPD_ROOT:['queue']
$ ENDIF
$!
$! The queue: stopped first if it is there, so INITIALIZE can change it
$! without losing its jobs.  No flag, burst or trailer pages and no form
$! feed added, so a job prints as it was sent.
$!
$ dummy = F$GETQUI("CANCEL_OPERATION")
$ IF F$GETQUI("DISPLAY_QUEUE","QUEUE_NAME",queue) .NES. ""
$ THEN
$   say "Stopping the existing queue ''queue'"
$   STOP/QUEUE/RESET 'queue'
$ ENDIF
$ INITIALIZE/QUEUE/START 'queue' -
    /ON='node':: -
    /PROCESSOR=TCPIP$LPD_SMB -
    /DEFAULT=(NOBURST,NOFLAG,NOTRAILER,NOFEED) -
    /RETAIN=ERROR -
    /NOENABLE_GENERIC
$ IF .NOT. $STATUS
$ THEN
$   say "LPD_QUEUE: the queue was not initialised"
$   GOTO DONE
$ ENDIF
$!
$ IF make_default
$ THEN
$   DEFINE/SYSTEM/EXECUTIVE_MODE SYS$PRINT 'queue'
$   say "SYS$PRINT is ''queue' until the next boot; for good, add to"
$   say "SYS$MANAGER:SYLOGICALS.COM:  $ DEFINE/SYSTEM/EXECUTIVE_MODE SYS$PRINT ''queue'"
$ ENDIF
$!
$ SHOW QUEUE/FULL 'queue'
$ say ""
$ say "To test:   $ PRINT/QUEUE=''queue' SYS$LOGIN:LOGIN.COM"
$ say "Errors go to TCPIP$LPD_ROOT:[000000]''queue'.LOG"
$ say "To start the queue at boot, add to SYS$MANAGER:SYSTARTUP_VMS.COM,"
$ say "after TCP/IP Services starts:   $ START/QUEUE ''queue'"
$!
$DONE:
$ IF F$TRNLNM("IN","LNM$PROCESS") .NES. "" THEN CLOSE in
$ IF F$TRNLNM("OUT","LNM$PROCESS") .NES. "" THEN CLOSE out
$ old_privs = F$SETPRV(old_privs)
$ EXIT
