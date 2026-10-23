$!------------------------------------------------------------------------------
$! SSHLOGS.COM - Housekeeping for VSI OpenSSH logs and temp files
$!
$! Usage:  @SSHLOGS           clean up now, then schedule the next run
$!         @SSHLOGS SUBMIT    schedule only (use this to start the cycle)
$!         @SSHLOGS DRYRUN    show what would be removed; change nothing
$!------------------------------------------------------------------------------
$ set noon
$ say  = "write sys$output"
$ mode = f$edit(p1, "TRIM,UPCASE")
$ dry  = (mode .eqs. "DRYRUN")
$!
$!---- Settings ----------------------------------------------------------------
$ job_name = "SSHLOGS"
$ run_as   = "SYSTEM"                      ! needs privileges for every rule
$ queue    = "SYS$BATCH"
$ interval = "+0:15"                       ! or e.g. "TOMORROW+02:00"
$ job_log  = "SYS$LOGS:SSHLOGS.LOG"
$ keep     = "YESTERDAY"                   ! delete files older than this
$ sshd_prc = "SSHD*"                       ! process names to count
$!
$!---- Cleanup rules:  ACTION | file spec | extra qualifiers --------------------
$! Add a rule by adding the next rule_n line. Rules run in order.
$ rule_1 = "DELETE|SSH$ROOT:[VAR]*.LOG;*|/BEFORE=''keep'/EXCLUDE=SSH$MIGRATION_*.LOG"
$ rule_2 = "DELETE|SSH$ROOT:[TMP...]*.*;*|/BEFORE=''keep'/EXCLUDE=*.DIR"
$ rule_3 = "PURGE|SSH$ROOT:[VAR...]*.*|"
$ rule_4 = "PURGE|SYS$SYSDEVICE:[000000]SSH$SSHD.DMP|"
$ rule_5 = "PURGE|USER$ROOT:[000000...]SSH$CMDRUN.LOG|"   ! site logical: your user disk
$ rule_6 = "PURGE|SYS$SYSROOT:[SYSMGR]SSH$CMDRUN.LOG|"   ! SYSTEM's login dir
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
$ i = 0
$next_rule:
$ i = i + 1
$ if f$type(rule_'i') .eqs. "" then goto rules_done
$ rule   = rule_'i'
$ action = f$element(0, "|", rule)
$ spec   = f$element(1, "|", rule)
$ quals  = f$element(2, "|", rule)
$ if f$search(spec, i) .eqs. "" then goto next_rule
$ if dry
$ then
$   say "Would ''action' ''spec' ''quals'"
$   if action .eqs. "DELETE" then directory/size/date 'spec' 'quals'
$ else
$   'action'/log 'spec' 'quals'
$ endif
$ goto next_rule
$rules_done:
$!
$! Count SSH server processes. The 9.9-2C release notes say leftover
$! OpenSSH processes can use up process slots; a rising count is the sign.
$ ctx = ""
$ n = 0
$ junk = f$context("PROCESS", ctx, "PRCNAM", sshd_prc, "EQL")
$count_loop:
$ pid = f$pid(ctx)
$ if pid .eqs. "" then goto count_done
$ n = n + 1
$ goto count_loop
$count_done:
$ say "''f$time()' SSHD processes: ''n'"
$!
$! Keep this job's own log at ;1. Otherwise the version number climbs by
$! 96 a day and reaches the 32767 limit in under a year.
$ if .not. dry .and. f$search(job_log) .nes. ""
$ then
$   purge 'job_log'
$   rename 'job_log' 'job_log';1
$ endif
$ exit
$!
$!---- Subroutine: queue the next run unless one is already waiting -------------
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
$ user_q = ""
$ if f$edit(f$getjpi("", "USERNAME"), "TRIM") .nes. run_as then -
    user_q = "/USER=" + run_as
$ submit 'proc' /name='job_name' 'user_q' /queue='queue' -
    /after="''interval'" /log='job_log' /keep /noprint /restart
$ return
