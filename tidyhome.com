$!------------------------------------------------------------------------------
$! TIDYHOME.COM - Nightly tidy-up of your login directory (SYS$LOGIN)
$!
$! Usage:  @TIDYHOME           tidy now, then schedule the next run
$!         @TIDYHOME SUBMIT    schedule only (use this to start the cycle)
$!         @TIDYHOME DRYRUN    show what would be removed; change nothing
$!         @TIDYHOME ONCE      tidy now without scheduling another run
$!         P2 (optional)       tidy this directory instead of SYS$LOGIN
$!
$! Runs as whoever submits it and tidies that user's SYS$LOGIN, top level
$! only: subdirectories are never touched. No privileges needed.
$!------------------------------------------------------------------------------
$ set noon
$ set symbol/scope=noglobal               ! a DELETE == "DELETE/CONFIRM" can't interfere
$ say  = "write sys$output"
$ mode = f$edit(p1, "TRIM,UPCASE")
$ dry  = (mode .eqs. "DRYRUN")
$ old_parse = f$getjpi("", "PARSE_STYLE_PERM")
$ set process/parse_style=extended        ! for names such as ^.ZendSem.*
$!
$!---- Settings ----------------------------------------------------------------
$ job_name = "TIDYHOME"
$ queue    = "SYS$BATCH"
$ interval = "TOMORROW+03:30"              ! next run; e.g. "+1-" or "+0:30"
$ job_log  = "SYS$LOGIN:TIDYHOME.LOG"
$ versions = "2"                           ! versions PURGE keeps of each file
$ big      = "5000"                        ! report files this many blocks or more
$ home     = "SYS$LOGIN:"
$ if p2 .nes. "" then home = p2
$!
$!---- Rules:  ACTION | file spec | extra qualifiers ----------------------------
$! Add a rule by adding the next rule_n line. Rules run in order.
$!   PURGE   purge old versions (keeps 'versions')
$!   DELETE  delete matching files; give /BEFORE= so new files are kept
$!           (write times as TODAY-7-00:00: a trailing "-" continues the line)
$!   EMPTY   delete files of 0 blocks; quals is how old they must be
$!   RESET   keep one version and rename it to ;1 once the version number
$!           passes quals (VMS stops making new versions at 32767)
$!   REPORT  list only, never deletes: things to look at yourself
$ rule_1  = "PURGE|''home'*.*|"
$ rule_2  = "RESET|''home'SSH$CMDRUN.LOG|1000"     ! one new version per SSH command
$ rule_3  = "DELETE|''home'*.TMP;*|/BEFORE=TODAY-7-00:00"
$ rule_4  = "DELETE|''home'sess_*.;*|/BEFORE=TODAY-7-00:00"           ! PHP sessions
$ rule_5  = "DELETE|''home'phpt*.;*,php-tests-*.;*|/BEFORE=TODAY-7-00:00"
$ rule_6  = "DELETE|''home'^.ZendSem.*;*|/BEFORE=TODAY-7-00:00"
$ rule_7  = "DELETE|''home'*.JOU;*,*.TJL;*|/BEFORE=TODAY-14-00:00"     ! editor journals
$ rule_8  = "DELETE|''home'*.*_swp;*,*.swp;*|/BEFORE=TODAY-30-00:00"     ! editor swap files
$ rule_9  = "DELETE|''home'*.LOG;*|/BEFORE=TODAY-30-00:00/EXCLUDE=TIDYHOME.LOG"
$ rule_10 = "DELETE|''home'*.LIS;*|/BEFORE=TODAY-30-00:00/EXCLUDE=HISTSH_HISTORY.LIS"
$ rule_11 = "DELETE|''home'*.DMP;*|/BEFORE=TODAY-30-00:00"
$ rule_12 = "EMPTY|''home'*.;*|TODAY-7-00:00"          ! empty temp files with no type
$ rule_13 = "REPORT|''home'*.*;*|/SELECT=SIZE=MINIMUM=''big'"
$ rule_14 = "REPORT|''home'PCSI$SCR*.DIR;*|"       ! leftover PCSI scratch trees
$!
$!---- Main --------------------------------------------------------------------
$! Strip the version so edits to this file are picked up by the next run
$ proc = f$environment("PROCEDURE")
$ proc = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY") -
       + f$parse(proc,,,"NAME")   + f$parse(proc,,,"TYPE")
$ me_user = f$edit(f$getjpi("", "USERNAME"), "TRIM")
$ where = f$parse(home,,,"DEVICE") + f$parse(home,,,"DIRECTORY")
$ if where .eqs. "" .or. f$parse(home,,,"NAME") .nes. ""
$ then
$   say "TIDYHOME: ''home' is not a directory"
$   goto finish
$ endif
$!
$! Schedule first, so a failure below doesn't break the cycle
$ if .not. dry .and. mode .nes. "ONCE" then gosub schedule_next
$ if mode .eqs. "SUBMIT" then goto finish
$!
$ if dry then say "Dry run: nothing will be changed"
$ say "''f$time()' tidying ''where' for ''me_user'"
$ gosub measure
$ files_before  = n_files
$ blocks_before = n_blocks
$!
$ i = 0
$next_rule:
$ i = i + 1
$ if f$type(rule_'i') .eqs. "" then goto rules_done
$ rule   = rule_'i'
$ action = f$element(0, "|", rule)
$ spec   = f$element(1, "|", rule)
$ quals  = f$element(2, "|", rule)
$ say ""
$ say "Rule ''i': ''action' ''spec' ''quals'"
$ gosub full_specs
$ if spec .nes. "" then gosub do_'action'
$ goto next_rule
$rules_done:
$!
$ gosub measure
$ say ""
$ say "''f$time()' done: ''files_before' files, ''blocks_before' blocks before; " -
    + "''n_files' files, ''n_blocks' blocks now"
$!
$! Keep this job's own log at ;1, so it doesn't pile up versions.
$ if .not. dry .and. f$search(job_log) .nes. ""
$ then
$   purge 'job_log'
$   rename 'job_log' 'job_log';1
$ endif
$finish:
$ set process/parse_style='old_parse'
$ exit
$!
$!---- Actions -----------------------------------------------------------------
$! Each spec may be a comma list; quiet when nothing matches.
$do_PURGE:
$ if dry
$ then
$   gosub list_old_versions
$ else
$   define/user sys$error nl:
$   purge/log/keep='versions'/noconfirm 'spec' 'quals'
$ endif
$ return
$!
$do_DELETE:
$ gosub existing
$ if spec .eqs. "" then return
$ if dry
$ then
$   define/user sys$output nl:              ! hide "no files" when /BEFORE picks none
$   directory 'spec' 'quals'
$   if $status then directory/size/date/nohead/notrail 'spec' 'quals'
$ else
$   delete/log/noconfirm 'spec' 'quals'
$ endif
$ return
$!
$do_REPORT:
$ gosub existing
$ if spec .eqs. "" then return
$ define/user sys$output nl:
$ directory 'spec' 'quals'
$ if $status then directory/size/date/nohead/notrail 'spec' 'quals'
$ return
$!
$! Give every part of a comma list its full device and directory, carried
$! over from the part before as DCL does, so no part can fall back on the
$! default directory once others are dropped. Parts naming a directory
$! that doesn't exist are dropped.
$full_specs:
$ e = 0
$ full = ""
$ prev = home
$fs_loop:
$ s = f$element(e, ",", spec)
$ e = e + 1
$ if s .eqs. "," then goto fs_done
$ s = f$parse(s, prev)                      ! "" if the directory is missing
$ if s .eqs. "" then goto fs_loop
$ if f$extract(f$length(s) - 1, 1, s) .eqs. ";" then -
    s = s - ";"                             ! keep "no version" for PURGE
$ full = full + "," + s
$ prev = f$parse(s,,,"DEVICE") + f$parse(s,,,"DIRECTORY")
$ goto fs_loop
$fs_done:
$ spec = full - ","
$ return
$!
$! Drop the parts of a comma list that match no file at all
$existing:
$ e = 0
$ keep = ""
$ex_loop:
$ s = f$element(e, ",", spec)
$ e = e + 1
$ if s .eqs. "," then goto ex_done
$ if f$search(s, i*10+e) .nes. "" then keep = keep + "," + s  ! own stream each, so a repeat starts afresh
$ goto ex_loop
$ex_done:
$ spec = keep - ","
$ return
$!
$do_RESET:
$ f = f$search(spec)                        ! the newest version
$ if f .eqs. "" then return
$ v = f$integer(f$parse(f,,,"VERSION") - ";")
$ if v .le. f$integer(quals) then return
$ base = f - f$parse(f,,,"VERSION")
$ if dry
$ then
$   say "  ''f' would become ''base';1"
$ else
$   purge/log/noconfirm 'base'
$   rename/log 'f' 'base';1
$ endif
$ return
$!
$do_EMPTY:
$ cutoff = f$cvtime(quals)
$ e = 0
$empty_spec:
$ s = f$element(e, ",", spec)
$ e = e + 1
$ if s .eqs. "," then return
$empty_loop:
$ f = f$search(s, 1)
$ if f .eqs. "" then goto empty_spec
$ if f$parse(f,,,"TYPE") .nes. "." then goto empty_loop     ! *.; still lists .DIR
$ eof = -1                                 ! stays -1 if the file can't be read
$ eof = f$file_attributes(f, "EOF")
$ if eof .ne. 0 then goto empty_loop
$ if f$cvtime(f$file_attributes(f, "CDT")) .ges. cutoff then goto empty_loop
$ if dry
$ then
$   say "  ", f
$ else
$   delete/log/noconfirm 'f'
$ endif
$ goto empty_loop
$!
$!---- Dry run of PURGE: list each version past the newest 'versions' ----------
$list_old_versions:
$ e = 0
$lov_spec:
$ s = f$element(e, ",", spec)
$ e = e + 1
$ if s .eqs. "," then return
$ s = f$parse(";*", s)                      ! every version, newest first
$ last = ""
$lov_loop:
$ f = f$search(s, 2)
$ if f .eqs. "" then goto lov_spec
$ base = f - f$parse(f,,,"VERSION")
$ if base .nes. last then k = 0
$ last = base
$ k = k + 1
$ if k .gt. 'versions' then say "  ", f
$ goto lov_loop
$!
$!---- Count files and blocks at the top of SYS$LOGIN ---------------------------
$measure:
$ n_files  = 0
$ n_blocks = 0
$m_loop:
$ f = f$search(home + "*.*;*", 3)
$ if f .eqs. "" then return
$ n_files = n_files + 1
$ b = 0
$ b = f$file_attributes(f, "ALQ")
$ n_blocks = n_blocks + b
$ goto m_loop
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
$ q_user = f$getqui("DISPLAY_JOB", "USERNAME", , "FREEZE_CONTEXT,ALL_JOBS")
$ if q_name .eqs. job_name .and. f$edit(q_user, "TRIM") .eqs. me_user then -
    found = q_entry
$ if found .eq. 0 then goto sn_loop
$sn_check:
$ junk = f$getqui("CANCEL_OPERATION")
$ if found .ne. 0
$ then
$   say "''job_name' already queued as entry ''found' - not resubmitting"
$   return
$ endif
$!
$ params = ""
$ if p2 .nes. "" then params = "/PARAMETERS=("""",""''p2'"")"
$ submit 'proc' /name='job_name' /queue='queue' 'params' -
    /after="''interval'" /log='job_log' /keep /noprint /restart
$ return
