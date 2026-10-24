$!------------------------------------------------------------------------------
$! PSCAN.COM - Find processes by name, user, state, image, age or quota
$!
$! Lists the processes that match all the conditions you give, in a box,
$! and sets global symbols (PS_COUNT, PS_PID, PS_PIDS ...) so a procedure
$! can act on the result. It can also watch, redrawing until you press
$! Ctrl/Y, or wait until the matching processes have all gone.
$!
$! Usage:   @PSCAN [name] [condition ...] [option ...]
$!
$!   name        process name, wildcards allowed; quote mixed case, e.g.
$!               "Beszel*"
$!   condition   item, operator, value: = <> < > <= >=
$!               USER=SMITH  STATE<>HIB  PRI>=6  MODE=BATCH  NODE=*
$!               JOBTYPE=DETACHED  UIC=[1,4]  TERMINAL=TNA*  PID=2040012F
$!               A list after = matches any of it: USER=SMITH,JONES
$!     IMAGE=x   image name contains x, or matches it if x has a wildcard;
$!               IMAGE=IDLE (at DCL) or IMAGE=BUSY (running an image)
$!     OLDER=t   logged in for longer than t: minutes, hh:mm or d-hh:mm
$!     CHECK=q   quota q nearly used up: BYTLM BIOLM DIOLM ENQLM FILLM
$!               TQLM ASTLM PGFLQUOTA PRCLM; PERCENT=n sets how little
$!               must be left (default 10)
$!   SHOW=a,b    also show these $GETJPI items for each process
$!   SORT=k      sort by CPU, IO, FAULTS or AGE, largest first
$!   WATCH[=s]   redraw every s seconds (default 5) until Ctrl/Y
$!   UNTILGONE[=s]  wait until no process matches, checking every s seconds
$!   FIRST       stop at the first match
$!   COUNT       print only the number of matches
$!   QUIET       print nothing; just set the symbols and $STATUS
$!   PLAIN       no colour, line drawing or screen control
$!   HELP        show this text
$!
$! $STATUS is success when something matched and a warning ($SEVERITY 0)
$! when nothing did. The symbols describe the last process listed (the
$! first with FIRST): PS_COUNT, PS_PIDS (comma list), PS_PID, PS_PRCNAM,
$! PS_USER, PS_NODE, PS_MODE, PS_IMAGE ("IDLE" at DCL), PS_STATE, PS_PRI,
$! PS_CPUTIM. NODE=* scans the whole cluster; the default is this node.
$! Seeing other users' processes needs GROUP or WORLD privilege.
$!
$! Based on PROCESS_SCAN.COM by Keith Cayemberg, first written in
$! the mid-1980s. Rewritten.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ ps_verify = f$verify(0)
$ set noon
$ ps_ansi   = 0
$ ps_ctx    = ""
$ ps_status = 1
$ on control_y then goto cleanup
$ ps_ctl = f$environment("CONTROL")        ! Ctrl/Y may be off (SSH logins);
$ set control=y                            ! turn it on so it can stop us
$ ps_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$!
$! Items F$CONTEXT can select on, and the short names accepted for them.
$ ps_ctx_items = ",ACCOUNT,AUTHPRI,CURPRIV,GRP,HW_MODEL,HW_NAME,JOBPRCCNT," + -
                 "JOBTYPE,MASTER_PID,MEM,MODE,NODE_CSID,NODENAME,OWNER," + -
                 "PRCCNT,PRCNAM,PRI,PRIB,STATE,STS,TERMINAL,UIC,USERNAME,"
$ ps_alias = "USER=USERNAME/NAME=PRCNAM/PROC=PRCNAM/PROCESS=PRCNAM/" + -
             "NODE=NODENAME/JOB=JOBTYPE/PRIO=PRI/PRIORITY=PRI/BASE=PRIB/" + -
             "TERM=TERMINAL/GROUP=GRP/MEMBER=MEM/IMAG=IMAGE/IMAGNAME=IMAGE"
$! Quota limits and the item that shows what is left (PRCLM: what is used).
$ ps_quotas = "BYTLM|BYTCNT/BIOLM|BIOCNT/DIOLM|DIOCNT/ENQLM|ENQCNT/" + -
              "FILLM|FILCNT/TQLM|TQCNT/ASTLM|ASTCNT/PGFLQUOTA|PAGFILCNT/" + -
              "PRCLM|PRCCNT"
$!
$!---- Parameters --------------------------------------------------------------
$ ps_nc     = 0                             ! F$CONTEXT conditions
$ ps_image  = ""                            ! IMAGE condition value
$ ps_imgop  = ""                            ! "=" or "<>"
$ ps_pidsel = ""
$ ps_older  = -1                            ! minutes, -1 = not used
$ ps_check  = ""                            ! quota limit item
$ ps_left   = ""                            ! its "left" item
$ ps_pct    = 10
$ ps_show   = ""
$ ps_sort   = ""
$ ps_watch  = 0                             ! seconds between redraws
$ ps_until  = 0
$ ps_first  = 0
$ ps_countonly = 0
$ ps_quiet  = 0
$ ps_plain  = 0
$ ps_cluster = 0
$ ps_desc   = ""                            ! conditions, for the title
$ ps_p = 0
$opt_loop:
$ ps_p = ps_p + 1
$ if ps_p .gt. 8 then goto opt_done
$ ps_raw = f$edit(p'ps_p', "TRIM")
$ if ps_raw .eqs. "" then goto opt_loop
$ ps_opt = f$edit(ps_raw, "UPCASE")
$!
$! Options (a word, perhaps with =value)
$ ps_word = f$element(0, "=", ps_opt)
$ ps_wval = ""
$ if f$locate("=", ps_opt) .lt. f$length(ps_opt) then -
    ps_wval = f$extract(f$locate("=", ps_opt) + 1, 999, ps_opt)
$ if ps_word .eqs. "HELP" .or. ps_word .eqs. "?" then goto help
$ if ps_word .eqs. "FIRST"
$ then
$   ps_first = 1
$   goto opt_loop
$ endif
$ if ps_word .eqs. "COUNT"
$ then
$   ps_countonly = 1
$   goto opt_loop
$ endif
$ if ps_word .eqs. "QUIET"
$ then
$   ps_quiet = 1
$   goto opt_loop
$ endif
$ if ps_word .eqs. "PLAIN"
$ then
$   ps_plain = 1
$   goto opt_loop
$ endif
$ if ps_word .eqs. "WATCH" .or. ps_word .eqs. "UNTILGONE"
$ then
$   ps_secs = 5
$   if ps_wval .nes. "" then ps_secs = ps_wval
$   if f$type(ps_secs) .nes. "INTEGER" then goto bad_secs
$   ps_secs = f$integer(ps_secs)
$   if ps_secs .lt. 1 .or. ps_secs .gt. 3600 then goto bad_secs
$   ps_watch = ps_secs
$   if ps_word .eqs. "UNTILGONE" then ps_until = 1
$   goto opt_loop
$ endif
$ if ps_word .eqs. "SORT"
$ then
$   ps_sl = ",CPU,IO,FAULTS,AGE,"
$   if f$locate("," + ps_wval + ",", ps_sl) .ge. f$length(ps_sl) .or. -
       ps_wval .eqs. "" then goto bad_sort
$   ps_sort = ps_wval
$   goto opt_loop
$ endif
$ if ps_word .eqs. "SHOW"
$ then
$   ps_show = ps_wval
$   goto opt_loop
$ endif
$!
$! Conditions: item, operator, value
$ ps_at = f$length(ps_raw)
$ ps_i = 0
$find_op:
$ ps_c = f$extract(ps_i, 1, ps_raw)
$ if ps_c .eqs. "=" .or. ps_c .eqs. "<" .or. ps_c .eqs. ">"
$ then
$   ps_at = ps_i
$   goto op_found
$ endif
$ ps_i = ps_i + 1
$ if ps_i .lt. f$length(ps_raw) then goto find_op
$! No operator: the process name.
$ ps_nc = ps_nc + 1
$ ps_c_item_'ps_nc' = "PRCNAM"
$ ps_c_op_'ps_nc'   = "EQL"
$ ps_c_val_'ps_nc'  = ps_raw
$ ps_desc = ps_desc + " " + ps_raw
$ goto opt_loop
$op_found:
$ ps_item = f$edit(f$extract(0, ps_at, ps_raw), "UPCASE")
$ ps_op = f$extract(ps_at, 2, ps_raw)
$ if ps_op .nes. "<>" .and. ps_op .nes. "<=" .and. ps_op .nes. ">=" then -
    ps_op = f$extract(ps_at, 1, ps_raw)
$ ps_val = f$extract(ps_at + f$length(ps_op), 999, ps_raw)
$ ps_desc = ps_desc + " " + ps_item + ps_op + ps_val
$! Short names
$ ps_j = 0
$alias_next:
$ ps_a = f$element(ps_j, "/", ps_alias)
$ if ps_a .eqs. "/" then goto alias_done
$ if ps_item .eqs. f$element(0, "=", ps_a) then -
    ps_item = f$element(1, "=", ps_a)
$ ps_j = ps_j + 1
$ goto alias_next
$alias_done:
$ if ps_item .eqs. "" .or. ps_val .eqs. "" then goto bad_cond
$ if ps_item .eqs. "IMAGE"
$ then
$   if ps_op .nes. "=" .and. ps_op .nes. "<>" then goto bad_cond
$   ps_image = f$edit(ps_val, "UPCASE")
$   ps_imgop = ps_op
$   goto opt_loop
$ endif
$ if ps_item .eqs. "PID"
$ then
$   ps_pidsel = f$edit(ps_val, "UPCASE")
$   goto opt_loop
$ endif
$ if ps_item .eqs. "OLDER"
$ then
$   ps_t = ps_val
$   gosub to_minutes
$   if ps_mins .lt. 0 then goto bad_cond
$   ps_older = ps_mins
$   goto opt_loop
$ endif
$ if ps_item .eqs. "PERCENT"
$ then
$   if f$type(ps_val) .nes. "INTEGER" then goto bad_cond
$   ps_pct = f$integer(ps_val)
$   if ps_pct .lt. 0 .or. ps_pct .gt. 100 then goto bad_cond
$   goto opt_loop
$ endif
$ if ps_item .eqs. "CHECK"
$ then
$   ps_q = f$edit(ps_val, "UPCASE")
$   ps_j = 0
$quota_next:
$   ps_a = f$element(ps_j, "/", ps_quotas)
$   if ps_a .eqs. "/" then goto bad_cond
$   if ps_q .eqs. f$element(0, "|", ps_a) .or. -
       ps_q .eqs. f$element(1, "|", ps_a)
$   then
$     ps_check = f$element(0, "|", ps_a)
$     ps_left  = f$element(1, "|", ps_a)
$     goto opt_loop
$   endif
$   ps_j = ps_j + 1
$   goto quota_next
$ endif
$ if f$locate("," + ps_item + ",", ps_ctx_items) .ge. f$length(ps_ctx_items) -
     then goto bad_cond
$ if ps_item .eqs. "NODENAME" .and. ps_val .eqs. "*" then ps_cluster = 1
$ ps_nc = ps_nc + 1
$ ps_c_item_'ps_nc' = ps_item
$ ps_c_val_'ps_nc'  = ps_val
$ ps_c_op_'ps_nc'   = "EQL"
$ if ps_op .eqs. "<>" then ps_c_op_'ps_nc' = "NEQ"
$ if ps_op .eqs. "<"  then ps_c_op_'ps_nc' = "LSS"
$ if ps_op .eqs. ">"  then ps_c_op_'ps_nc' = "GTR"
$ if ps_op .eqs. "<=" then ps_c_op_'ps_nc' = "LEQ"
$ if ps_op .eqs. ">=" then ps_c_op_'ps_nc' = "GEQ"
$ goto opt_loop
$!
$bad_cond:
$ set message 'ps_msg'
$ write sys$output "PSCAN: cannot use condition ''ps_raw' (try @PSCAN HELP)"
$ ps_status = %X10000000
$ goto cleanup
$bad_secs:
$ set message 'ps_msg'
$ write sys$output "PSCAN: seconds must be 1 to 3600"
$ ps_status = %X10000000
$ goto cleanup
$bad_sort:
$ set message 'ps_msg'
$ write sys$output "PSCAN: SORT can be CPU, IO, FAULTS or AGE"
$ ps_status = %X10000000
$ goto cleanup
$opt_done:
$ ps_desc = f$edit(ps_desc, "TRIM")
$ if ps_check .nes. "" then ps_desc = f$edit(ps_desc + -
    f$fao(" (!AS under !UL% left)", ps_check, ps_pct), "TRIM")
$!
$!---- Output style ------------------------------------------------------------
$ ps_width = 80
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     ps_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     ps_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if ps_w .ge. 80 .and. ps_w .le. 160 then ps_width = ps_w
$   endif
$ endif
$ if ps_plain .or. ps_quiet .or. ps_countonly then ps_ansi = 0
$! A live screen needs ANSI; otherwise WATCH draws once, and UNTILGONE
$! waits without drawing.
$ ps_live = ps_watch .gt. 0 .and. ps_ansi .and. .not. ps_quiet
$ if ps_watch .gt. 0 .and. .not. ps_ansi .and. .not. ps_until then ps_watch = 0
$ ps_draw = .not. ps_quiet .and. .not. ps_countonly
$ if ps_until .and. .not. ps_live then ps_draw = 0
$ ps_bold = ""
$ ps_key  = ""
$ ps_grn  = ""
$ ps_yel  = ""
$ ps_red  = ""
$ ps_dim  = ""
$ ps_off  = ""
$ ps_gon  = ""
$ ps_goff = ""
$ ps_c_tl = "+"
$ ps_c_tr = "+"
$ ps_c_bl = "+"
$ ps_c_br = "+"
$ ps_c_ml = "+"
$ ps_c_mr = "+"
$ ps_c_h  = "-"
$ ps_c_v  = "|"
$ if ps_ansi
$ then
$   ps_esc[0,8] = 27
$   ps_bold = ps_esc + "[1m"
$   ps_key  = ps_esc + "[1;34m"             ! bold blue headings
$   ps_grn  = ps_esc + "[32m"
$   ps_yel  = ps_esc + "[33m"
$   ps_red  = ps_esc + "[1;31m"
$   ps_dim  = ps_esc + "[2m"
$   ps_off  = ps_esc + "[0m"
$   ps_gon  = ps_esc + "(0"
$   ps_goff = ps_esc + "(B"
$   ps_c_tl = "l"
$   ps_c_tr = "k"
$   ps_c_bl = "m"
$   ps_c_br = "j"
$   ps_c_ml = "t"
$   ps_c_mr = "u"
$   ps_c_h  = "q"
$   ps_c_v  = "x"
$ endif
$ ps_cw = ps_width - 6                      ! room inside the box
$ ps_hn = ps_cw + 2
$ ps_hline = f$fao("!''ps_hn'*''ps_c_h'")
$! Columns: PID 8, process 15, user 12, state 6, CPU 11, then the image.
$! A wide screen adds node 8, mode 11, priority 3, I/O 9 and age 10.
$ ps_wide = ps_cw .ge. 114
$ ps_iw = ps_cw - 57
$ if ps_wide then ps_iw = ps_cw - 103
$ if ps_iw .gt. 30 then ps_iw = 30
$ ps_rowvl = 57 + ps_iw                     ! visible length of a row
$ if ps_wide then ps_rowvl = 103 + ps_iw
$ if ps_wide
$ then
$   ps_colplain = f$fao("!8AS !15AS !12AS !8AS !11AS !6AS !3AS !11AS " + -
                  "!9AS !10AS !AS", "PID", "Process", "User", "Node", -
                  "Mode", "State", "Pri", "        CPU", "      I/O", -
                  "Logged in", "Image")
$ else
$   ps_colplain = f$fao("!8AS !15AS !12AS !6AS !11AS !AS", "PID", -
                  "Process", "User", "State", "        CPU", "Image")
$ endif
$ ps_wait = f$fao("!2ZL:!2ZL:!2ZL", ps_watch / 3600, -
                  (ps_watch - (ps_watch / 3600) * 3600) / 60, -
                  ps_watch - (ps_watch / 60) * 60)
$ ps_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ ps_seen = 0                               ! UNTILGONE: matches seen
$ if ps_live then write sys$output ps_esc, "[2J", ps_esc, "[?25l"
$!
$!==============================================================================
$! Scan
$!==============================================================================
$scan:
$ ps_t = f$cvtime(, "COMPARISON")
$ gosub civil_days
$ ps_dnow = ps_days
$ ps_snow = ps_sod
$ ps_n = 0
$ ps_pids = ""
$ ps_ctx = ""
$ ps_k = 0
$ctx_next:
$ ps_k = ps_k + 1
$ if ps_k .gt. ps_nc then goto ctx_done
$ ps_x = f$context("PROCESS", ps_ctx, ps_c_item_'ps_k', ps_c_val_'ps_k', -
                   ps_c_op_'ps_k')
$ if .not. $status
$ then
$   set message 'ps_msg'
$   write sys$output "PSCAN: F$CONTEXT refused ", ps_c_item_'ps_k', " ", -
                     ps_c_op_'ps_k', " ", ps_c_val_'ps_k'
$   ps_status = %X10000000
$   goto cleanup
$ endif
$ goto ctx_next
$ctx_done:
$!
$proc_next:
$ ps_pid = f$pid(ps_ctx)
$ if ps_pid .eqs. "" then goto proc_done
$ if ps_pidsel .nes. "" .and. ps_pid .nes. ps_pidsel then goto proc_next
$ ps_chk = ""
$ ps_chk = f$getjpi(ps_pid, "PID")          ! gone already, or no access
$ if ps_chk .eqs. "" then goto proc_next
$ ps_img = f$edit(f$getjpi(ps_pid, "IMAGNAME"), "UPCASE")
$!
$! IMAGE condition
$ if ps_image .nes. ""
$ then
$   ps_hit = 0
$   if ps_image .eqs. "IDLE" then ps_hit = ps_img .eqs. ""
$   if ps_image .eqs. "BUSY" then ps_hit = ps_img .nes. ""
$   if ps_image .nes. "IDLE" .and. ps_image .nes. "BUSY"
$   then
$     ps_j = 0
$img_next:
$     ps_a = f$element(ps_j, ",", ps_image)
$     if ps_a .eqs. "," .or. ps_hit then goto img_done
$     if f$locate("*", ps_a) .lt. f$length(ps_a) .or. -
         f$locate("%", ps_a) .lt. f$length(ps_a)
$     then
$       if f$match_wild(ps_img, ps_a) then ps_hit = 1
$     else
$       if f$locate(ps_a, ps_img) .lt. f$length(ps_img) then ps_hit = 1
$     endif
$     ps_j = ps_j + 1
$     goto img_next
$img_done:
$   endif
$   if ps_imgop .eqs. "<>" then ps_hit = .not. ps_hit
$   if .not. ps_hit then goto proc_next
$ endif
$!
$! Age, for OLDER, SORT=AGE and the wide screen
$ ps_age = -1
$ ps_lt = ""
$ ps_lt = f$getjpi(ps_pid, "LOGINTIM")
$ if ps_lt .nes. ""
$ then
$   ps_t = f$cvtime(ps_lt, "COMPARISON")
$   if f$integer(f$extract(0, 4, ps_t)) .ge. 1990
$   then
$     gosub civil_days
$     ps_age = (ps_dnow - ps_days) * 1440 + (ps_snow - ps_sod) / 60
$   endif
$ endif
$ if ps_older .ge. 0 .and. ps_age .le. ps_older then goto proc_next
$!
$! CHECK condition
$ ps_det = ""
$ if ps_check .nes. ""
$ then
$   ps_lim = ""
$   ps_lim = f$getjpi(ps_pid, ps_check)
$   ps_rem = ""
$   ps_rem = f$getjpi(ps_pid, ps_left)
$   if f$type(ps_lim) .nes. "INTEGER" .or. f$type(ps_rem) .nes. "INTEGER" -
       then goto proc_next
$   if ps_lim .le. 0 then goto proc_next
$   if ps_check .eqs. "PRCLM" then ps_rem = ps_lim - ps_rem   ! used -> left
$   if ps_lim .lt. 20000000
$   then
$     if ps_rem * 100 .gt. ps_lim * ps_pct then goto proc_next
$     ps_lp = ps_rem * 100 / ps_lim
$   else
$     if ps_rem .gt. ps_lim / 100 * ps_pct then goto proc_next
$     ps_lp = ps_rem / (ps_lim / 100)
$   endif
$   ps_det = f$fao("!AS: !UL of !UL left (!UL%)", ps_check, ps_rem, ps_lim, -
                   ps_lp)
$ endif
$!
$! It matches: gather what is shown.
$ ps_n = ps_n + 1
$ ps_nm   = f$getjpi(ps_pid, "PRCNAM")
$ ps_user = f$edit(f$getjpi(ps_pid, "USERNAME"), "TRIM")
$ ps_st   = f$edit(f$getjpi(ps_pid, "STATE"), "TRIM")
$ ps_pri  = f$getjpi(ps_pid, "PRI")
$ ps_mode = f$edit(f$getjpi(ps_pid, "MODE"), "TRIM")
$ ps_nd   = f$edit(f$getjpi(ps_pid, "NODENAME"), "TRIM")
$ ps_tk   = f$getjpi(ps_pid, "CPUTIM")
$ ps_io   = f$getjpi(ps_pid, "DIRIO") + f$getjpi(ps_pid, "BUFIO")
$ ps_flt  = f$getjpi(ps_pid, "PAGEFLTS")
$ ps_imn  = "(DCL)"
$ if ps_img .nes. "" then ps_imn = f$parse(ps_img, , , "NAME", "SYNTAX_ONLY")
$ gosub fmt_cpu
$ if f$length(ps_pids) .lt. 900 then ps_pids = ps_pids + ps_pid + ","
$! The symbols describe this process (the last listed, or the first).
$ ps_l_pid  = ps_pid
$ ps_l_nm   = ps_nm
$ ps_l_user = ps_user
$ ps_l_nd   = ps_nd
$ ps_l_mode = ps_mode
$ ps_l_img  = ps_img
$ if ps_l_img .eqs. "" then ps_l_img = "IDLE"
$ ps_l_st   = ps_st
$ ps_l_pri  = ps_pri
$ ps_l_cpu  = ps_cpu
$!
$ if ps_draw
$ then
$   ps_sc = ""
$   if f$extract(0, 2, ps_st) .eqs. "RW" .or. ps_st .eqs. "MUTEX" then -
      ps_sc = ps_red                        ! waiting for a resource
$   if f$locate("SUSP", ps_st) .lt. f$length(ps_st) then ps_sc = ps_yel
$   if ps_st .eqs. "CUR" .or. ps_st .eqs. "COM" then ps_sc = ps_grn
$   if ps_wide
$   then
$     ps_agt = ""
$     if ps_age .ge. 0 then gosub fmt_age
$     ps_row = f$fao("!8AS !15AS !12AS !8AS !11AS ", ps_pid, ps_nm, -
                     ps_user, ps_nd, ps_mode) + ps_sc + -
               f$fao("!6AS", ps_st) + ps_off + -
               f$fao(" !3UL !11AS !9UL !10AS !''ps_iw'AS", ps_pri, ps_cpu, -
                     ps_io, ps_agt, ps_imn)
$   else
$     ps_row = f$fao("!8AS !15AS !12AS ", ps_pid, ps_nm, ps_user) + -
               ps_sc + f$fao("!6AS", ps_st) + ps_off + -
               f$fao(" !11AS !''ps_iw'AS", ps_cpu, ps_imn)
$   endif
$   ps_row_'ps_n' = ps_row
$!  Extra line: the SHOW items and the quota found.
$   if ps_show .nes. ""
$   then
$     ps_j = 0
$show_next:
$     ps_a = f$element(ps_j, ",", ps_show)
$     if ps_a .eqs. "," then goto show_done
$     ps_v = ""
$     ps_v = f$getjpi(ps_pid, ps_a)
$     if f$type(ps_v) .eqs. "INTEGER" then ps_v = f$fao("!UL", ps_v)
$     ps_det = f$edit(ps_det + "  " + ps_a + "=" + f$edit(ps_v, "TRIM"), -
                     "TRIM")
$     ps_j = ps_j + 1
$     goto show_next
$show_done:
$   endif
$   ps_det_'ps_n' = ps_det
$!  Sort key
$   ps_key_'ps_n' = 0
$   if ps_sort .eqs. "CPU"    then ps_key_'ps_n' = ps_tk
$   if ps_sort .eqs. "IO"     then ps_key_'ps_n' = ps_io
$   if ps_sort .eqs. "FAULTS" then ps_key_'ps_n' = ps_flt
$   if ps_sort .eqs. "AGE"    then ps_key_'ps_n' = ps_age
$ endif
$ if ps_first then goto proc_done
$ goto proc_next
$!
$proc_done:
$ if f$type(ps_ctx) .eqs. "PROCESS_CONTEXT" then -
    ps_x = f$context("PROCESS", ps_ctx, "CANCEL")
$ if ps_n .gt. 0 then ps_seen = 1
$ if ps_sort .nes. "" .and. ps_draw then gosub sort_rows
$!
$!---- Symbols and status ------------------------------------------------------
$ PS_COUNT == ps_n
$ PS_PIDS  == ""
$ if ps_pids .nes. "" then -
    PS_PIDS == f$extract(0, f$length(ps_pids) - 1, ps_pids)   ! no last comma
$ if ps_n .gt. 0
$ then
$   PS_PID    == ps_l_pid
$   PS_PRCNAM == ps_l_nm
$   PS_USER   == ps_l_user
$   PS_NODE   == ps_l_nd
$   PS_MODE   == ps_l_mode
$   PS_IMAGE  == ps_l_img
$   PS_STATE  == ps_l_st
$   PS_PRI    == ps_l_pri
$   PS_CPUTIM == ps_l_cpu
$   ps_status = 1
$ else
$   PS_PID == ""
$   PS_PRCNAM == ""
$   PS_USER == ""
$   PS_NODE == ""
$   PS_MODE == ""
$   PS_IMAGE == ""
$   PS_STATE == ""
$   PS_PRI == ""
$   PS_CPUTIM == ""
$   ps_status = %X10000000                  ! warning: nothing matched
$ endif
$!
$ if ps_countonly
$ then
$   write sys$output ps_n
$   goto finished
$ endif
$ if ps_draw then gosub draw
$!
$! Watching or waiting?
$ if ps_until
$ then
$   if .not. ps_seen
$   then
$     if .not. ps_quiet then write sys$output -
        "PSCAN: no process matches, so there is nothing to wait for"
$     goto finished
$   endif
$   if ps_n .eq. 0
$   then
$     if .not. ps_quiet then write sys$output -
        "PSCAN: all matching processes have gone, at ", -
        f$extract(12, 8, f$time())
$     ps_status = 1
$     goto finished
$   endif
$   wait 'ps_wait'
$   goto scan
$ endif
$ if ps_watch .gt. 0
$ then
$   wait 'ps_wait'
$   goto scan
$ endif
$finished:
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'ps_msg'
$ type sys$input
PSCAN - find processes by name, user, state, image, age or quota

Usage:   @PSCAN [name] [condition ...] [option ...]

  name        process name, wildcards allowed; quote mixed case
  condition   item operator value, with = <> < > <= >=, for example
              USER=SMITH  STATE<>HIB  PRI>=6  MODE=BATCH  NODE=*
              JOBTYPE=DETACHED  TERMINAL=TNA*  PID=2040012F
              IMAGE=SSHD  IMAGE=IDLE  OLDER=2:00  CHECK=BYTLM PERCENT=5
  SHOW=a,b    also show these $GETJPI items
  SORT=k      sort by CPU, IO, FAULTS or AGE
  WATCH[=s]   redraw every s seconds until Ctrl/Y
  UNTILGONE[=s]  wait until no process matches
  FIRST  COUNT  QUIET  PLAIN  HELP

Examples:

  @PSCAN USER=SYSTEM SORT=CPU          SYSTEM's processes, busiest first
  @PSCAN IMAGE=SSHD OLDER=12:00        SSH servers up over 12 hours
  @PSCAN STATE=RWAST,RWMBX,MUTEX       processes waiting for resources
  @PSCAN CHECK=BYTLM PERCENT=10        nearly out of buffered I/O bytes
  @PSCAN IMAGE=MYSQLD QUIET            then IF PS_COUNT .EQ. 0 ...
  @PSCAN BACKUP* UNTILGONE=30          wait for BACKUP processes to end
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$cleanup:
$ if f$type(ps_ctx) .eqs. "PROCESS_CONTEXT" then -
    ps_x = f$context("PROCESS", ps_ctx, "CANCEL")
$ if ps_ansi then write sys$output ps_esc, "(B", ps_esc, "[0m", ps_esc, "[?25h"
$ if f$type(ps_msg) .nes. "" then set message 'ps_msg'
$ if f$type(ps_ctl) .nes. "" then -
    if f$locate("Y", ps_ctl) .eq. f$length(ps_ctl) then set nocontrol=y
$ exit ps_status + 0 * f$verify(ps_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! DRAW: the box with the rows gathered in this scan.
$draw:
$ if ps_live then write sys$output ps_esc, "[H"
$ ps_title = "Processes on " + ps_node
$ if ps_cluster then ps_title = "Processes in the cluster"
$ ps_now = f$extract(0, 20, f$time())
$ ps_pad = ps_cw - f$length(ps_title) - f$length(ps_now)
$ if ps_pad .lt. 1 then ps_pad = 1
$ ps_l = ps_c_tl
$ ps_r = ps_c_tr
$ gosub box_rule
$ ps_txt = ps_bold + ps_title + ps_off + f$fao("!''ps_pad'* ") + ps_now
$ ps_vl  = f$length(ps_title) + ps_pad + f$length(ps_now)
$ gosub box_line
$ if ps_desc .nes. ""
$ then
$   ps_v = f$extract(0, ps_cw, "Matching: " + ps_desc)
$   ps_txt = ps_dim + ps_v + ps_off
$   ps_vl  = f$length(ps_v)
$   gosub box_line
$ endif
$ ps_l = ps_c_ml
$ ps_r = ps_c_mr
$ gosub box_rule
$ ps_v = f$extract(0, ps_cw, ps_colplain)
$ ps_txt = ps_key + ps_v + ps_off
$ ps_vl  = f$length(ps_v)
$ gosub box_line
$ ps_i = 0
$draw_row:
$ ps_i = ps_i + 1
$ if ps_i .gt. ps_n then goto draw_rows_done
$ ps_txt = ps_row_'ps_i'
$ ps_vl  = ps_rowvl
$ gosub box_line
$ if ps_det_'ps_i' .nes. ""
$ then
$   ps_v = f$extract(0, ps_cw - 9, ps_det_'ps_i')
$   ps_txt = "         " + ps_dim + ps_v + ps_off
$   ps_vl  = 9 + f$length(ps_v)
$   gosub box_line
$ endif
$ goto draw_row
$draw_rows_done:
$ if ps_n .eq. 0
$ then
$   ps_txt = "No process matches"
$   ps_vl  = f$length(ps_txt)
$   gosub box_line
$ endif
$ ps_l = ps_c_ml
$ ps_r = ps_c_mr
$ gosub box_rule
$ ps_txt = f$fao("!UL process!%S", ps_n)
$ if ps_n .eq. 1 then ps_txt = "1 process"
$ if ps_first .and. ps_n .gt. 0 then ps_txt = ps_txt + " (stopped at the first)"
$ if ps_watch .gt. 0 .and. ps_live
$ then
$   if ps_until
$   then
$     ps_txt = ps_txt + f$fao("; waiting for none, checking every !UL s", -
                              ps_watch)
$   else
$     ps_txt = ps_txt + f$fao("; every !UL s, Ctrl/Y to stop", ps_watch)
$   endif
$ endif
$ ps_txt = f$extract(0, ps_cw, ps_txt)
$ ps_vl  = f$length(ps_txt)
$ gosub box_line
$ ps_l = ps_c_bl
$ ps_r = ps_c_br
$ gosub box_rule
$ if ps_live then write sys$output ps_esc, "[J"
$ return
$!
$! SORT_ROWS: order the rows by ps_key_n, largest first (insertion sort).
$sort_rows:
$ ps_i = 1
$sort_outer:
$ ps_i = ps_i + 1
$ if ps_i .gt. ps_n then return
$ ps_kr = ps_key_'ps_i'
$ ps_rr = ps_row_'ps_i'
$ ps_dr = ps_det_'ps_i'
$ ps_j = ps_i - 1
$sort_inner:
$ if ps_j .lt. 1 then goto sort_place
$ if ps_key_'ps_j' .ge. ps_kr then goto sort_place
$ ps_m = ps_j + 1
$ ps_key_'ps_m' = ps_key_'ps_j'
$ ps_row_'ps_m' = ps_row_'ps_j'
$ ps_det_'ps_m' = ps_det_'ps_j'
$ ps_j = ps_j - 1
$ goto sort_inner
$sort_place:
$ ps_m = ps_j + 1
$ ps_key_'ps_m' = ps_kr
$ ps_row_'ps_m' = ps_rr
$ ps_det_'ps_m' = ps_dr
$ goto sort_outer
$!
$! FMT_CPU: ps_cpu = CPU time ps_tk (10 ms ticks) as "1:02.34", "3:04:05"
$! or "2 03:04:05".
$fmt_cpu:
$ ps_s  = ps_tk / 100
$ ps_cc = ps_tk - ps_s * 100
$ ps_h  = ps_s / 3600
$ ps_mi = (ps_s - ps_h * 3600) / 60
$ ps_se = ps_s - ps_h * 3600 - ps_mi * 60
$ if ps_h .eq. 0
$ then
$   ps_cpu = f$fao("!UL:!2ZL.!2ZL", ps_mi, ps_se, ps_cc)
$ else
$   if ps_h .lt. 24
$   then
$     ps_cpu = f$fao("!UL:!2ZL:!2ZL", ps_h, ps_mi, ps_se)
$   else
$     ps_cpu = f$fao("!UL !2ZL:!2ZL:!2ZL", ps_h / 24, ps_h - (ps_h / 24) * 24, -
                     ps_mi, ps_se)
$   endif
$ endif
$ ps_pad = 11 - f$length(ps_cpu)             ! right-align in 11
$ if ps_pad .gt. 0 then ps_cpu = f$fao("!''ps_pad'* ") + ps_cpu
$ return
$!
$! FMT_AGE: ps_agt = minutes ps_age as "3d 04:05" or "4:05".
$fmt_age:
$ ps_d  = ps_age / 1440
$ ps_h  = (ps_age - ps_d * 1440) / 60
$ ps_mi = ps_age - ps_d * 1440 - ps_h * 60
$ if ps_d .gt. 0
$ then
$   ps_agt = f$fao("!ULd !2ZL:!2ZL", ps_d, ps_h, ps_mi)
$ else
$   ps_agt = f$fao("!UL:!2ZL", ps_h, ps_mi)
$ endif
$ return
$!
$! TO_MINUTES: ps_mins = ps_t ("90", "1:30" or "2-01:30") in minutes, or -1.
$to_minutes:
$ ps_mins = -1
$ ps_dd = 0
$ if f$locate("-", ps_t) .lt. f$length(ps_t)
$ then
$   ps_dd = f$element(0, "-", ps_t)
$   ps_t  = f$element(1, "-", ps_t)
$   if f$type(ps_dd) .nes. "INTEGER" then return
$ endif
$ if f$locate(":", ps_t) .lt. f$length(ps_t)
$ then
$   ps_hh = f$element(0, ":", ps_t)
$   ps_mm = f$element(1, ":", ps_t)
$   if f$type(ps_hh) .nes. "INTEGER" .or. f$type(ps_mm) .nes. "INTEGER" -
       then return
$   ps_mins = f$integer(ps_dd) * 1440 + f$integer(ps_hh) * 60 + -
              f$integer(ps_mm)
$ else
$   if f$type(ps_t) .nes. "INTEGER" then return
$   ps_mins = f$integer(ps_dd) * 1440 + f$integer(ps_t)
$ endif
$ return
$!
$! BOX_RULE: a line across the box, ending in ps_l and ps_r.
$box_rule:
$ write sys$output " ", ps_gon, ps_l, ps_hline, ps_r, ps_goff
$ return
$!
$! BOX_LINE: ps_txt inside the box, padded by its visible length ps_vl.
$box_line:
$ ps_fill = ps_cw - ps_vl
$ ps_sp = ""
$ if ps_fill .gt. 0 then ps_sp = f$fao("!''ps_fill'* ")
$ write sys$output " ", ps_gon, ps_c_v, ps_goff, " ", ps_txt, ps_sp, " ", -
                   ps_gon, ps_c_v, ps_goff
$ return
$!
$! CIVIL_DAYS: from ps_t ("yyyy-mm-dd hh:mm:ss..."), ps_days = days since a
$! fixed epoch and ps_sod = seconds into that day.
$civil_days:
$ ps_y = f$integer(f$extract(0, 4, ps_t))
$ ps_m = f$integer(f$extract(5, 2, ps_t))
$ ps_dy = f$integer(f$extract(8, 2, ps_t))
$ ps_sod = f$integer(f$extract(11, 2, ps_t)) * 3600 + -
           f$integer(f$extract(14, 2, ps_t)) * 60 + -
           f$integer(f$extract(17, 2, ps_t))
$ if ps_m .le. 2 then ps_y = ps_y - 1
$ ps_era = ps_y / 400
$ ps_yoe = ps_y - ps_era * 400
$ ps_mp  = ps_m - 3
$ if ps_m .le. 2 then ps_mp = ps_m + 9
$ ps_doy = (153 * ps_mp + 2) / 5 + ps_dy - 1
$ ps_doe = ps_yoe * 365 + ps_yoe / 4 - ps_yoe / 100 + ps_doy
$ ps_days = ps_era * 146097 + ps_doe
$ return
