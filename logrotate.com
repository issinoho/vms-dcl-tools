$!------------------------------------------------------------------------------
$! LOGROTATE.COM - Monthly rotation of system logs that SSH probes grow
$!
$! For each log: start a new version, rename the closed one to
$! NAME_yyyymmdd.TYPE (the date it was closed), and delete archives older
$! than keep_days.
$!
$! Usage:  @LOGROTATE           rotate now, then schedule next month's run
$!         @LOGROTATE SUBMIT    schedule only (use this to start the cycle)
$!         @LOGROTATE DRYRUN    show what would happen; change nothing
$!
$! Needs OPER (accounting, operator log) and SECURITY (audit journal).
$!------------------------------------------------------------------------------
$ set noon
$ say  = "write sys$output"
$ mode = f$edit(p1, "TRIM,UPCASE")
$ dry  = (mode .eqs. "DRYRUN")
$!
$!---- Settings ----------------------------------------------------------------
$ job_name  = "LOGROTATE"
$ run_as    = "SYSTEM"                     ! needs privileges for every rule
$ queue     = "SYS$BATCH"
$ run_time  = "00:05"                      ! time of day on the 1st
$ job_log   = "SYS$LOGS:LOGROTATE.LOG"
$ keep_days = 90                           ! delete archives older than this
$!
$!---- Logs to rotate:  label | current file | command that starts a new one ----
$! Add a log by adding the next log_n line. Check the audit journal location
$! with SHOW AUDIT/JOURNAL if you have moved it.
$ log_1 = "Accounting|SYS$MANAGER:ACCOUNTNG.DAT|SET ACCOUNTING/NEW_FILE"
$ log_2 = "Audit journal|SYS$MANAGER:SECURITY.AUDIT$JOURNAL|SET AUDIT/SERVER=NEW_LOG"
$ log_3 = "Operator log|SYS$MANAGER:OPERATOR.LOG|REPLY/LOG"
$!
$!---- Main --------------------------------------------------------------------
$! Strip the version so edits to this file are picked up by the next run
$ proc = f$environment("PROCEDURE")
$ proc = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY") -
       + f$parse(proc,,,"NAME")   + f$parse(proc,,,"TYPE")
$!
$! Schedule first, so a failure below doesn't break the cycle
$ if .not. dry then gosub schedule_next
$ if mode .eqs. "SUBMIT" then exit
$!
$ junk = f$setprv("OPER,SECURITY")
$ if .not. f$privilege("OPER,SECURITY") then -
    say "WARNING: OPER and SECURITY not both held - rotations may fail"
$!
$ today  = f$cvtime(, "COMPARISON", "DATE")              ! yyyy-mm-dd
$ stamp  = f$element(0, "-", today) + f$element(1, "-", today) -
         + f$element(2, "-", today)
$ cutoff = f$cvtime("-''keep_days'-", "ABSOLUTE", "DATE")
$!
$ i = 0
$next_log:
$ i = i + 1
$ if f$type(log_'i') .eqs. "" then goto logs_done
$ entry = log_'i'
$ label = f$element(0, "|", entry)
$ spec  = f$element(1, "|", entry)
$ cmd   = f$element(2, "|", entry)
$ say ""
$ say "''label': ''spec'"
$!
$ old = f$search(spec, 1)                  ! highest version = the open file
$ if old .eqs. ""
$ then
$   say "  Not found - skipped"
$   goto next_log
$ endif
$ where   = f$parse(old,,,"DEVICE") + f$parse(old,,,"DIRECTORY")
$ name    = f$parse(old,,,"NAME")
$ type    = f$parse(old,,,"TYPE")
$ archive = where + name + "_" + stamp + type
$ blocks  = f$file_attributes(old, "EOF")
$!
$ if dry
$ then
$   say "  Would run:     ''cmd'"
$   say "  Would rename:  ''old' (''blocks' blocks)"
$   say "            to:  ''archive'"
$   say "  Would delete archives created before ''cutoff':"
$   directory/size/date 'where''name'_*'type';* /before='cutoff'
$   goto next_log
$ endif
$!
$ 'cmd'
$ status = $status
$ if .not. status
$ then
$   say "  ''cmd' failed (status ''status') - skipped"
$   goto next_log
$ endif
$!
$! Only rename if a new version really was created
$ new = f$search(spec, 2)
$ if new .eqs. old
$ then
$   say "  No new version created - old file left in place"
$   goto next_log
$ endif
$ rename/log 'old' 'archive'
$ delete/log 'where''name'_*'type';* /before='cutoff'
$ goto next_log
$logs_done:
$!
$! Keep the last three of this job's own logs (12 runs a year, so no version worry)
$ if .not. dry .and. f$search(job_log) .nes. ""
$ then
$   purge/keep=3 'job_log'
$ endif
$ exit
$!
$!---- Subroutine: queue next month's run unless one is already waiting --------
$schedule_next:
$ me = 0
$ if f$mode() .eqs. "BATCH" then -
    me = f$getqui("DISPLAY_ENTRY", "ENTRY_NUMBER", , "THIS_JOB")
$ found = 0
$ junk = f$getqui("CANCEL_OPERATION")
$! Scan every batch queue: a job sent to a generic queue such as SYS$BATCH
$! actually sits in an execution queue such as NODE_BATCH.
$sn_queue:
$ q = f$getqui("DISPLAY_QUEUE", "QUEUE_NAME", "*", "WILDCARD,BATCH")
$ if q .eqs. "" then goto sn_check
$sn_loop:
$ q_entry = ""
$ q_entry = f$getqui("DISPLAY_JOB", "ENTRY_NUMBER", , "ALL_JOBS")
$ if q_entry .eqs. "" then goto sn_queue
$ if q_entry .eq. me then goto sn_loop
$ q_name = f$getqui("DISPLAY_JOB", "JOB_NAME", , "FREEZE_CONTEXT,ALL_JOBS")
$ if q_name .eqs. job_name then found = q_entry
$ if found .eq. 0 then goto sn_loop
$sn_check:
$ junk = f$getqui("CANCEL_OPERATION")
$ if found .ne. 0
$ then
$   say "''job_name' already queued as entry ''found' - not resubmitting"
$   return
$ endif
$!
$sn_submit:
$! Work out the 1st of next month: 1st of this month + 32 days lands in it
$ mon   = f$cvtime(, "ABSOLUTE", "MONTH")
$ yr    = f$cvtime(, "ABSOLUTE", "YEAR")
$ nxt   = f$cvtime("1-''mon'-''yr'+32-", "ABSOLUTE")
$ after = "1-" + f$cvtime(nxt, "ABSOLUTE", "MONTH") + "-" -
        + f$cvtime(nxt, "ABSOLUTE", "YEAR") + ":" + run_time
$ user_q = ""
$ if f$edit(f$getjpi("", "USERNAME"), "TRIM") .nes. run_as then -
    user_q = "/USER=" + run_as
$ submit 'proc' /name='job_name' 'user_q' /queue='queue' -
    /after="''after'" /log='job_log' /keep /noprint /restart
$ return
