$!------------------------------------------------------------------------------
$! QUEMON.COM - Live queue monitor for OpenVMS
$!
$! A boxed screen that redraws itself every few seconds, showing queues and
$! their jobs: each queue's type, state (stopped, stalled, paused ... in
$! colour), node, device and job counts, then each job's entry, name, user
$! and what it is doing (executing for how long, printing which block,
$! pending and why, held until when, retained with which error).
$!
$! Usage:   @QUEMON [queue] [seconds] [option ...]
$!
$!   queue    a queue name or wildcard (default: all queues)
$!   seconds  time between refreshes, 2 to 255 (default 5)
$!   ALL      also show idle, empty queues (normally hidden when a
$!            wildcard is used; a queue named exactly is always shown)
$!   ONCE     draw the screen once and exit
$!   PLAIN    no colour, line drawing or screen control
$!   HELP     show this text
$!
$! While it runs: Q (or Ctrl/Z) quits, S starts a stopped queue (needs
$! OPER or management access to the queue), Return refreshes at once.
$! Output that is not an ANSI terminal (a file, a batch log) is drawn once,
$! in plain text. Plain DCL; no privileges needed to watch, though jobs
$! you have no access to show as "no access".
$!
$! Based on MONITOR_QUE.COM by Neil Sakac (1990-1992). Rewritten.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ qm_verify = f$verify(0)
$ set noon
$ qm_ansi = 0
$ on control_y then goto cleanup
$ qm_ctl = f$environment("CONTROL")        ! Ctrl/Y may be off (SSH logins);
$ set control=y                            ! turn it on so it can stop us
$ qm_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$!---- Settings ----------------------------------------------------------------
$ qm_maxjobs = 12                           ! jobs listed per queue at most
$!
$!---- Options -----------------------------------------------------------------
$ qm_spec  = "*"
$ qm_named = 0                              ! a queue was given without wildcard
$ qm_secs  = 5
$ qm_all   = 0
$ qm_once  = 0
$ qm_plain = 0
$ qm_p = 0
$opt_loop:
$ qm_p = qm_p + 1
$ if qm_p .gt. 8 then goto opt_done
$ qm_opt = f$edit(p'qm_p', "TRIM,UPCASE")
$ if qm_opt .eqs. "" then goto opt_loop
$ qm_len = f$length(qm_opt)
$ if f$type(qm_opt) .eqs. "INTEGER"
$ then
$   qm_secs = f$integer(qm_opt)
$   if qm_secs .ge. 2 .and. qm_secs .le. 255 then goto opt_loop
$   set message 'qm_msg'
$   write sys$output "QUEMON: seconds must be 2 to 255"
$   goto cleanup
$ endif
$ if qm_opt .eqs. "HELP" .or. qm_opt .eqs. "?" then goto help
$ if qm_opt .eqs. "ALL"
$ then
$   qm_all = 1
$   goto opt_loop
$ endif
$ if qm_opt .eqs. "ONCE"
$ then
$   qm_once = 1
$   goto opt_loop
$ endif
$ if qm_opt .eqs. "PLAIN"
$ then
$   qm_plain = 1
$   goto opt_loop
$ endif
$! Anything else is the queue name or wildcard.
$ qm_spec = qm_opt
$ qm_named = f$locate("*", qm_spec) .ge. qm_len .and. -
             f$locate("%", qm_spec) .ge. qm_len
$ goto opt_loop
$opt_done:
$ qm_junk = f$getqui("CANCEL_OPERATION")
$ if qm_named
$ then
$   if f$getqui("DISPLAY_QUEUE", "QUEUE_NAME", qm_spec) .eqs. ""
$   then
$     set message 'qm_msg'
$     write sys$output "QUEMON: no queue called ", qm_spec
$     goto cleanup
$   endif
$ endif
$!
$!---- Output style ------------------------------------------------------------
$ qm_width = 80
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     qm_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     qm_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if qm_w .ge. 80 .and. qm_w .le. 132 then qm_width = qm_w
$   endif
$ endif
$ if qm_plain then qm_ansi = 0
$ if .not. qm_ansi then qm_once = 1         ! no live screen without ANSI
$ if f$mode() .nes. "INTERACTIVE" then qm_once = 1
$ qm_bold = ""
$ qm_key  = ""
$ qm_grn  = ""
$ qm_yel  = ""
$ qm_red  = ""
$ qm_dim  = ""
$ qm_off  = ""
$ qm_gon  = ""
$ qm_goff = ""
$ qm_c_tl = "+"
$ qm_c_tr = "+"
$ qm_c_bl = "+"
$ qm_c_br = "+"
$ qm_c_ml = "+"
$ qm_c_mr = "+"
$ qm_c_h  = "-"
$ qm_c_v  = "|"
$ if qm_ansi
$ then
$   qm_esc[0,8] = 27
$   qm_bold = qm_esc + "[1m"
$   qm_key  = qm_esc + "[1;34m"             ! bold blue headings
$   qm_grn  = qm_esc + "[32m"
$   qm_yel  = qm_esc + "[33m"
$   qm_red  = qm_esc + "[1;31m"
$   qm_dim  = qm_esc + "[2m"
$   qm_off  = qm_esc + "[0m"
$   qm_gon  = qm_esc + "(0"
$   qm_goff = qm_esc + "(B"
$   qm_c_tl = "l"
$   qm_c_tr = "k"
$   qm_c_bl = "m"
$   qm_c_br = "j"
$   qm_c_ml = "t"
$   qm_c_mr = "u"
$   qm_c_h  = "q"
$   qm_c_v  = "x"
$ endif
$ qm_cw = qm_width - 6                      ! room inside the box
$ qm_hn = qm_cw + 2
$ qm_hline = f$fao("!''qm_hn'*''qm_c_h'")
$! Job columns: indent 2, entry 6, name 22, user 12, then the state.
$ qm_sw = qm_cw - 2 - 6 - 22 - 12 - 3
$ qm_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ qm_note = ""                              ! result of the last S command
$ if qm_ansi
$ then
$   write sys$output qm_esc, "[2J"          ! clear the screen once
$ endif
$!
$!==============================================================================
$! Draw the screen
$!==============================================================================
$draw:
$ if qm_ansi then write sys$output qm_esc, "[H", qm_esc, "[?25l"
$ qm_title = "Queue monitor on " + qm_node
$ if qm_spec .nes. "*" then qm_title = qm_title + ": " + qm_spec
$ qm_now = f$extract(0, 20, f$time())
$ qm_pad = qm_cw - f$length(qm_title) - f$length(qm_now)
$ if qm_pad .lt. 1 then qm_pad = 1
$ qm_l = qm_c_tl
$ qm_r = qm_c_tr
$ gosub box_rule
$ qm_txt = qm_bold + qm_title + qm_off + f$fao("!''qm_pad'* ") + qm_now
$ qm_vl  = f$length(qm_title) + qm_pad + f$length(qm_now)
$ gosub box_line
$!
$ qm_t = f$cvtime(, "COMPARISON")           ! now, for job run times
$ gosub civil_days
$ qm_dnow = qm_days
$ qm_snow = qm_secs_of_day
$ qm_nq = 0                                 ! queues shown
$ qm_nh = 0                                 ! queues hidden (idle, empty)
$ qm_nbad = 0                               ! queues stopped, stalled ...
$ qm_nexe = 0                               ! jobs executing
$ qm_npen = 0                               ! jobs pending
$ qm_nhold = 0                              ! jobs holding or retained
$ qm_junk = f$getqui("CANCEL_OPERATION")
$queue_next:
$ qm_q = f$getqui("DISPLAY_QUEUE", "QUEUE_NAME", qm_spec, "WILDCARD")
$ if qm_q .eqs. "" then goto queue_done
$ gosub queue_info
$ qm_jobs = qm_exe + qm_pen + qm_hold + qm_ret + qm_tim
$ if .not. qm_all .and. .not. qm_named .and. qm_jobs .eq. 0 .and. -
     qm_sc .nes. qm_red .and. qm_sc .nes. qm_yel
$ then
$   qm_nh = qm_nh + 1
$   goto queue_next
$ endif
$ qm_nq = qm_nq + 1
$ qm_nexe  = qm_nexe + qm_exe
$ qm_npen  = qm_npen + qm_pen
$ qm_nhold = qm_nhold + qm_hold + qm_ret + qm_tim
$ if qm_sc .eqs. qm_red .or. qm_sc .eqs. qm_yel then qm_nbad = qm_nbad + 1
$!
$! Queue heading: name, type and state; then its details.
$ qm_l = qm_c_ml
$ qm_r = qm_c_mr
$ gosub box_rule
$ qm_txt = qm_bold + qm_q + qm_off + "  " + qm_type + "  " + -
           qm_sc + qm_state + qm_off
$ qm_vl  = f$length(qm_q) + 2 + f$length(qm_type) + 2 + f$length(qm_state)
$ if qm_vl .gt. qm_cw
$ then
$   qm_txt = qm_bold + f$extract(0, qm_cw, qm_q) + qm_off
$   qm_vl  = f$length(qm_q)
$   if qm_vl .gt. qm_cw then qm_vl = qm_cw
$ endif
$ gosub box_line
$ if qm_detail .nes. ""
$ then
$   qm_detail = f$extract(0, qm_cw, qm_detail)
$   qm_txt = qm_dim + qm_detail + qm_off
$   qm_vl  = f$length(qm_detail)
$   gosub box_line
$ endif
$!
$! Jobs in this queue.
$ if qm_jobs .eq. 0 then goto queue_next
$ qm_txt = f$fao("  !6AS !22AS !12AS !AS", " Entry", "Job", "User", "State")
$ qm_vl  = f$length(qm_txt)
$ qm_txt = qm_key + qm_txt + qm_off
$ gosub box_line
$ qm_k = 0
$job_next:
$ qm_e = f$getqui("DISPLAY_JOB", "ENTRY_NUMBER", , "ALL_JOBS")
$ if qm_e .eqs. "" then goto queue_next
$ qm_k = qm_k + 1
$ if qm_k .gt. qm_maxjobs then goto job_next   ! counted, not listed
$ gosub job_info
$ qm_txt = f$fao("  !6UL !22AS !12AS ", f$integer(qm_e), qm_jn, qm_ju)
$ qm_vl  = f$length(qm_txt) + f$length(qm_js)
$ qm_txt = qm_txt + qm_jc + qm_js + qm_off
$ gosub box_line
$ if qm_k .eq. qm_maxjobs .and. qm_jobs .gt. qm_maxjobs
$ then
$   qm_txt = f$fao("  ... and !UL more", qm_jobs - qm_maxjobs)
$   qm_vl  = f$length(qm_txt)
$   gosub box_line
$ endif
$ goto job_next
$!
$queue_done:
$ if qm_nq .eq. 0
$ then
$   qm_l = qm_c_ml
$   qm_r = qm_c_mr
$   gosub box_rule
$   qm_txt = "No queues with jobs or problems"
$   if qm_nh .eq. 0 then qm_txt = "No queues match " + qm_spec
$   qm_vl  = f$length(qm_txt)
$   gosub box_line
$ endif
$!
$!---- Summary -----------------------------------------------------------------
$ qm_l = qm_c_ml
$ qm_r = qm_c_mr
$ gosub box_rule
$ qm_txt = f$fao("!UL queue!%S", qm_nq)
$ if qm_nh .gt. 0 then qm_txt = qm_txt + f$fao(" (!UL idle hidden)", qm_nh)
$ qm_txt = qm_txt + f$fao(", !UL executing, !UL pending, !UL held", -
                          qm_nexe, qm_npen, qm_nhold)
$ if qm_nbad .gt. 0 then qm_txt = qm_txt + f$fao(", !UL need!%S attention", -
                                               qm_nbad)
$ qm_txt = f$extract(0, qm_cw, qm_txt)
$ qm_vl  = f$length(qm_txt)
$ gosub box_line
$ if qm_note .nes. ""
$ then
$   qm_txt = f$extract(0, qm_cw, qm_note)
$   qm_vl  = f$length(qm_txt)
$   gosub box_line
$ endif
$ qm_l = qm_c_bl
$ qm_r = qm_c_br
$ gosub box_rule
$ if qm_once
$ then
$   if qm_ansi then write sys$output qm_esc, "[J"
$   goto cleanup
$ endif
$!
$! Wait for a key, or refresh when the time runs out.
$ if qm_ansi then write sys$output qm_esc, "[J", qm_esc, "[?25h"
$ qm_ans = ""
$ read/time_out='qm_secs'/error=draw/end_of_file=cleanup -
      /prompt=" Q quit, S start a queue, Return refresh: " sys$command qm_ans
$ qm_ans = f$edit(qm_ans, "TRIM,UPCASE")
$ if qm_ans .eqs. "Q" .or. qm_ans .eqs. "E" then goto cleanup
$ if qm_ans .eqs. "S" then gosub start_queue
$ goto draw
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'qm_msg'
$ type sys$input
QUEMON - live queue monitor for OpenVMS

Usage:   @QUEMON [queue] [seconds] [option ...]

  queue    a queue name or wildcard (default: all queues)
  seconds  time between refreshes, 2 to 255 (default 5)
  ALL      also show idle, empty queues
  ONCE     draw the screen once and exit
  PLAIN    no colour, line drawing or screen control
  HELP     show this text

While it runs: Q or Ctrl/Z quits, S starts a stopped queue, Return
refreshes at once. Examples:

  @QUEMON                  every queue with jobs or problems
  @QUEMON SYS$BATCH 10     one queue, every 10 seconds
  PIPE @QUEMON > Q.TXT     plain text, once
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Put the terminal back: normal characters and the cursor on.
$cleanup:
$ if qm_ansi then write sys$output qm_esc, "(B", qm_esc, "[0m", qm_esc, "[?25h"
$ qm_junk = f$getqui("CANCEL_OPERATION")
$ if f$type(qm_msg) .nes. "" then set message 'qm_msg'
$ if f$type(qm_ctl) .nes. "" then -
    if f$locate("Y", qm_ctl) .eq. f$length(qm_ctl) then set nocontrol=y
$ exit 1 + 0 * f$verify(qm_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! QUEUE_INFO: for the current queue qm_q, set qm_type, qm_state and its
$! colour qm_sc, qm_detail, and the job counts.
$queue_info:
$ qm_f = "WILDCARD,FREEZE_CONTEXT"
$ qm_type = "Queue"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_BATCH", -
        qm_spec, qm_f) then qm_type = "Batch"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_PRINTER", -
        qm_spec, qm_f) then qm_type = "Printer"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_TERMINAL", -
        qm_spec, qm_f) then qm_type = "Terminal"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_SERVER", -
        qm_spec, qm_f) then qm_type = "Server"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_GENERIC",  qm_spec, qm_f) then -
    qm_type = "Generic " + f$edit(qm_type, "LOWERCASE")
$!
$! State, most serious first. Red: not running; yellow: needs a look.
$ qm_sc = qm_grn
$ qm_state = "running"
$ qm_i = 0
$st_next:
$ qm_i = qm_i + 1
$ qm_e = f$element(qm_i - 1, "/", -
  "STOPPED|stopped|R/STOP_PENDING|stop pending|Y/STOPPING|stopping|Y/" + -
  "UNAVAILABLE|unavailable|R/STALLED|stalled|Y/PAUSED|paused|Y/" + -
  "PAUSING|pausing|Y/RESETTING|resetting|Y/STARTING|starting|Y/" + -
  "RESUMING|resuming|Y/ALIGNING|aligning|Y/BUSY|busy|G/IDLE|idle|G")
$ if qm_e .eqs. "/" then goto st_done
$ if .not. f$getqui("DISPLAY_QUEUE", "QUEUE_" + f$element(0, "|", qm_e), -
                    qm_spec, qm_f) then goto st_next
$ qm_state = f$element(1, "|", qm_e)
$ qm_sc = qm_grn
$ if f$element(2, "|", qm_e) .eqs. "Y" then qm_sc = qm_yel
$ if f$element(2, "|", qm_e) .eqs. "R" then qm_sc = qm_red
$st_done:
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_CLOSED", qm_spec, qm_f) then -
    qm_state = qm_state + ", closed"
$! Generic queues are never "started" in the same way; idle is normal.
$ if f$locate("Generic", qm_type) .eq. 0 .and. qm_sc .eqs. qm_red then -
    qm_sc = qm_yel
$!
$ qm_exe  = f$getqui("DISPLAY_QUEUE", "EXECUTING_JOB_COUNT", qm_spec, qm_f)
$ qm_pen  = f$getqui("DISPLAY_QUEUE", "PENDING_JOB_COUNT", qm_spec, qm_f)
$ qm_hold = f$getqui("DISPLAY_QUEUE", "HOLDING_JOB_COUNT", qm_spec, qm_f)
$ qm_ret  = f$getqui("DISPLAY_QUEUE", "RETAINED_JOB_COUNT", qm_spec, qm_f)
$ qm_tim  = f$getqui("DISPLAY_QUEUE", "TIMED_RELEASE_JOB_COUNT", qm_spec, qm_f)
$ if f$type(qm_exe)  .nes. "INTEGER" then qm_exe  = 0
$ if f$type(qm_pen)  .nes. "INTEGER" then qm_pen  = 0
$ if f$type(qm_hold) .nes. "INTEGER" then qm_hold = 0
$ if f$type(qm_ret)  .nes. "INTEGER" then qm_ret  = 0
$ if f$type(qm_tim)  .nes. "INTEGER" then qm_tim  = 0
$!
$! Details: where it runs and anything unusual about it.
$ qm_detail = ""
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "SCSNODE_NAME", -
        qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" then qm_detail = "on " + qm_v + "::"
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "DEVICE_NAME", qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" .and. qm_type .nes. "Batch" then -
    qm_detail = qm_detail + " " + qm_v
$ if qm_type .eqs. "Batch"
$ then
$   qm_v = f$getqui("DISPLAY_QUEUE", "JOB_LIMIT", qm_spec, qm_f)
$   if f$type(qm_v) .eqs. "INTEGER" then qm_detail = qm_detail + -
      f$fao(", job limit !UL", qm_v)
$   qm_v = f$getqui("DISPLAY_QUEUE", "BASE_PRIORITY", qm_spec, qm_f)
$   if f$type(qm_v) .eqs. "INTEGER" then qm_detail = qm_detail + -
      f$fao(", priority !UL", qm_v)
$ endif
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "GENERIC_TARGET", -
        qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" then qm_detail = qm_detail + ", feeds " + qm_v
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "PROCESSOR", qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" .and. qm_v .nes. "PRTSMB" then -
    qm_detail = qm_detail + ", processor " + qm_v
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "FORM_NAME", qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" .and. qm_v .nes. "DEFAULT" then -
    qm_detail = qm_detail + ", form " + qm_v
$ qm_v = f$edit(f$getqui("DISPLAY_QUEUE", "QUEUE_DESCRIPTION", -
        qm_spec, qm_f), "TRIM")
$ if qm_v .nes. "" then qm_detail = qm_detail + ", """ + qm_v + """"
$ if f$extract(0, 2, qm_detail) .eqs. ", " then -
    qm_detail = f$extract(2, 999, qm_detail)
$ qm_detail = f$edit(qm_detail, "TRIM")
$ return
$!
$! JOB_INFO: for the current job, set qm_jn (name), qm_ju (user), qm_js
$! (state) and its colour qm_jc.
$job_info:
$ qm_f = "FREEZE_CONTEXT,ALL_JOBS"
$ qm_jc = ""
$ if f$getqui("DISPLAY_JOB", "JOB_INACCESSIBLE", , qm_f)
$ then
$   qm_jn = "(no access)"
$   qm_ju = ""
$   qm_js = "no access to this job"
$   qm_jc = qm_dim
$   return
$ endif
$ qm_jn = f$getqui("DISPLAY_JOB", "JOB_NAME", , qm_f)
$ qm_v  = f$edit(f$getqui("DISPLAY_JOB", "NOTE", , qm_f), "TRIM")
$ if qm_v .nes. "" then qm_jn = qm_jn + " (" + qm_v + ")"
$ qm_ju = f$getqui("DISPLAY_JOB", "USERNAME", , qm_f)
$ qm_blk = f$getqui("DISPLAY_JOB", "COMPLETED_BLOCKS", , qm_f)
$ if f$type(qm_blk) .nes. "INTEGER" then qm_blk = 0
$ qm_js = "?"
$!
$ if f$getqui("DISPLAY_JOB", "JOB_EXECUTING", , qm_f)
$ then
$   qm_jc = qm_grn
$   if qm_type .eqs. "Batch"
$   then
$     qm_js = "executing"
$     gosub run_time
$     if qm_run .nes. "" then qm_js = qm_js + " " + qm_run
$   else
$     qm_js = "printing"
$     if qm_blk .gt. 0 then qm_js = qm_js + f$fao(", block !UL", qm_blk)
$   endif
$   return
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_STARTING", , qm_f) then qm_js = "starting"
$ if f$getqui("DISPLAY_JOB", "JOB_ABORTING", , qm_f)
$ then
$   qm_js = "aborting"
$   qm_jc = qm_red
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_SUSPENDED", , qm_f)
$ then
$   qm_js = "suspended"
$   qm_jc = qm_yel
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_REFUSED", , qm_f)
$ then
$   qm_js = "refused by the symbiont"
$   qm_jc = qm_red
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_HOLDING", , qm_f) then qm_js = "holding"
$ if f$getqui("DISPLAY_JOB", "JOB_TIMED_RELEASE", , qm_f)
$ then
$   qm_v = f$getqui("DISPLAY_JOB", "AFTER_TIME", , qm_f)
$   qm_js = "held until " + f$extract(0, 17, qm_v)
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_PENDING", , qm_f)
$ then
$   qm_js = "pending"
$   if qm_blk .gt. 0 then qm_js = qm_js + f$fao(" at block !UL", qm_blk)
$   gosub pend_reason
$ endif
$ if f$getqui("DISPLAY_JOB", "JOB_RETAINED", , qm_f)
$ then
$   qm_js = "retained"
$   qm_v = f$getqui("DISPLAY_JOB", "CONDITION_VECTOR", , qm_f)
$   qm_v = f$element(0, ",", qm_v)
$   if f$type(qm_v) .eqs. "INTEGER"
$   then
$     if (f$integer(qm_v) .and. 1) .eq. 0
$     then
$       qm_jc = qm_red
$       qm_js = qm_js + ": " + f$edit(f$element(1, ",", -
                f$message(f$integer(qm_v))), "TRIM")
$     else
$       qm_js = qm_js + ", completed"
$     endif
$   endif
$ endif
$ return
$!
$! PEND_REASON: add why a pending job is waiting to qm_js.
$pend_reason:
$ qm_i = 0
$pr_next:
$ qm_i = qm_i + 1
$ qm_pr = f$element(qm_i - 1, "/", -
  "PEND_QUEUE_STATE|queue not running/PEND_QUEUE_BUSY|queue busy/" + -
  "PEND_CHAR_MISMATCH|characteristics/PEND_STOCK_MISMATCH|form stock/" + -
  "PEND_LOWERCASE_MISMATCH|lowercase/PEND_NO_ACCESS|no device access/" + -
  "PEND_JOB_SIZE_MAX|too big/PEND_JOB_SIZE_MIN|too small")
$ if qm_pr .eqs. "/" then return
$ if f$getqui("DISPLAY_JOB", f$element(0, "|", qm_pr), , qm_f)
$ then
$   qm_js = qm_js + " (" + f$element(1, "|", qm_pr) + ")"
$   return
$ endif
$ goto pr_next
$!
$! RUN_TIME: qm_run = how long the executing batch job's process has been
$! running ("12:03" or "2 days, 3:04"), or "" if it can't be looked at.
$run_time:
$ qm_run = ""
$ qm_pid = f$getqui("DISPLAY_JOB", "JOB_PID", , qm_f)
$ if qm_pid .eqs. "" then return
$ qm_lt = ""
$ qm_lt = f$getjpi(qm_pid, "LOGINTIM")
$ if qm_lt .eqs. "" then return
$ qm_t = f$cvtime(qm_lt, "COMPARISON")
$ gosub civil_days
$ qm_dd = qm_dnow - qm_days
$ qm_ss = qm_snow - qm_secs_of_day
$ if qm_ss .lt. 0
$ then
$   qm_ss = qm_ss + 86400
$   qm_dd = qm_dd - 1
$ endif
$ qm_hh = qm_ss / 3600
$ qm_mm = (qm_ss - qm_hh * 3600) / 60
$ qm_s2 = qm_ss - qm_hh * 3600 - qm_mm * 60
$ if qm_dd .gt. 0
$ then
$   qm_run = f$fao("!UL day!%S, !UL:!2ZL", qm_dd, qm_hh, qm_mm)
$ else
$   qm_run = f$fao("!UL:!2ZL:!2ZL", qm_hh, qm_mm, qm_s2)
$ endif
$ return
$!
$! START_QUEUE: ask for a queue name and start it.
$start_queue:
$ read/end_of_file=sq_done/error=sq_done -
      /prompt=" Queue to start: " sys$command qm_sq
$ qm_sq = f$edit(qm_sq, "TRIM,UPCASE")
$ if qm_sq .eqs. "" then goto sq_done
$ set message 'qm_msg'
$ define/user sys$output nla0:
$ define/user sys$error  nla0:
$ start/queue 'qm_sq'
$ qm_st = $status
$ set message/nofacility/noseverity/noidentification/notext
$ if qm_st
$ then
$   qm_note = "Started " + qm_sq + " at " + f$extract(12, 8, f$time())
$ else
$   qm_note = "Could not start " + qm_sq + ": " + -
              f$edit(f$element(1, ",", f$message(qm_st)), "TRIM")
$ endif
$sq_done:
$ return
$!
$! BOX_RULE: a line across the box, ending in qm_l and qm_r.
$box_rule:
$ write sys$output " ", qm_gon, qm_l, qm_hline, qm_r, qm_goff
$ return
$!
$! BOX_LINE: qm_txt inside the box, padded by its visible length qm_vl.
$box_line:
$ qm_fill = qm_cw - qm_vl
$ qm_sp = ""
$ if qm_fill .gt. 0 then qm_sp = f$fao("!''qm_fill'* ")
$ write sys$output " ", qm_gon, qm_c_v, qm_goff, " ", qm_txt, qm_sp, " ", -
                   qm_gon, qm_c_v, qm_goff
$ return
$!
$! CIVIL_DAYS: from qm_t ("yyyy-mm-dd hh:mm:ss..."), qm_days = days since a
$! fixed epoch and qm_secs_of_day = seconds into that day.
$civil_days:
$ qm_y = f$integer(f$extract(0, 4, qm_t))
$ qm_m = f$integer(f$extract(5, 2, qm_t))
$ qm_d = f$integer(f$extract(8, 2, qm_t))
$ qm_secs_of_day = f$integer(f$extract(11, 2, qm_t)) * 3600 + -
                   f$integer(f$extract(14, 2, qm_t)) * 60 + -
                   f$integer(f$extract(17, 2, qm_t))
$ if qm_m .le. 2 then qm_y = qm_y - 1
$ qm_era = qm_y / 400
$ qm_yoe = qm_y - qm_era * 400
$ qm_mp  = qm_m - 3
$ if qm_m .le. 2 then qm_mp = qm_m + 9
$ qm_doy = (153 * qm_mp + 2) / 5 + qm_d - 1
$ qm_doe = qm_yoe * 365 + qm_yoe / 4 - qm_yoe / 100 + qm_doy
$ qm_days = qm_era * 146097 + qm_doe
$ return
