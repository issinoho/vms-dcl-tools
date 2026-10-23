$!------------------------------------------------------------------------------
$! TOOLCHAIN.COM - Show the development toolchain installed on OpenVMS
$!
$! Prints a summary of the system (node, hardware, OpenVMS version, CPUs,
$! memory) followed by the version of each compiler, language and tool it
$! finds, grouped into sections.
$!
$! Usage:   @TOOLCHAIN [option ...]
$!
$!   BRIEF    list only what is installed
$!   PLAIN    no colour or bold, even on a terminal that supports them
$!   HELP     show this text
$!
$! Colour is used only on an ANSI terminal; output to a file or a batch log
$! is always plain text. Works on Alpha, IA64 and x86-64, needs no
$! privileges, and uses plain DCL only (no GNU tools required).
$!
$! A tool counts as installed when its check passes; the check can be a file
$! (SYS$SYSTEM:DECC$COMPILER.EXE), a DCL symbol (SYM:PYTHON) or a logical
$! name (LNM:ANT$HOME). Its version command then runs with input from NLA0:
$! and its output captured, so nothing can hang or spill onto the screen.
$!
$! To add a tool, add a tc_n line to the table below:
$!
$!   "Label | check[,check...] | version command | text to look for | strip"
$!
$! The version shown is the first output line containing "text to look
$! for" (any case), or the first line at all if that field is empty, with
$! the "strip" text removed. A line starting with "=" begins a new section.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ tc_verify = f$verify(0)
$ set noon
$ on control_y then goto cleanup
$!
$!---- Tools to report ---------------------------------------------------------
$! Label | check | version command | text to look for | strip
$ tc_1  = "=Operating system and network"
$ tc_2  = "TCP/IP Services|SYS$STARTUP:TCPIP$STARTUP.COM|" + -
          "tcpip show version|TCP/IP|"
$ tc_3  = "OpenSSL|SSL3$EXE:OPENSSL.EXE|mcr SSL3$EXE:OPENSSL version|SSL|"
$ tc_4  = "OpenSSH|SYM:SSH|ssh ""-V""|OpenSSH|"
$ tc_5  = "Apache|APACHE$COMMON:[000000]APACHE$HTTPD.EXE|" + -
          "mcr APACHE$COMMON:[000000]APACHE$HTTPD ""-v""|Server version|" + -
          "Server version: "
$!
$ tc_6  = "=Compilers and assemblers"
$ tc_7  = "C|SYS$SYSTEM:DECC$COMPILER.EXE|cc/version||"
$ tc_8  = "C++|SYS$SYSTEM:CXX$COMPILER.EXE|cxx/version||"
$ tc_9  = "Fortran|SYS$SYSTEM:F90$MAIN.EXE|fortran/version||"
$ tc_10 = "Pascal|SYS$SYSTEM:PASCAL.EXE|pascal/version||"
$ tc_11 = "COBOL|SYS$SYSTEM:COBOL.EXE|cobol/version||"
$ tc_12 = "BASIC|SYS$SYSTEM:BASIC.EXE|basic/version||"
$ tc_13 = "BLISS|SYS$SYSTEM:BLISS*.EXE|bliss/version||"
$ tc_14 = "LLVM MC|SYS$SYSTEM:LLVM-MC.EXE|" + -
          "mcr SYS$SYSTEM:LLVM-MC ""-version""|LLVM version|"
$!
$ tc_15 = "=Java platform"
$ tc_16 = "Java|SYM:JAVA|java ""-version""|version|"
$ tc_17 = "Scala|SYM:SCALA|scala ""-version""|Scala|"
$ tc_18 = "Groovy|SYM:GROOVY|groovy ""-version""|Groovy|"
$ tc_19 = "Ant|SYM:ANT|ant ""-version""|Ant|"
$!
$ tc_20 = "=Scripting languages"
$ tc_21 = "Python|SYM:PYTHON|python ""--version""|Python|"
$ tc_22 = "Perl|SYM:PERL|perl ""-v""|This is perl|This is "
$ tc_23 = "PHP|SYM:PHP|php ""--version""|PHP|"
$ tc_24 = "Lua|SYM:LUA|lua ""-v""|Lua|"
$!
$ tc_25 = "=Build and source tools"
$ tc_26 = "Git|SYM:GIT|git ""--version""|git version|"
$ tc_27 = "GNU make|SYM:MAKE|make ""--version""|Make|"
$ tc_28 = "GNU grep|SYM:GREP|grep ""--version""|grep|"
$ tc_29 = "GNU sed|SYM:SED|sed ""--version""|sed|"
$ tc_30 = "GNU awk|SYM:GAWK|gawk ""--version""|Awk|"
$ tc_31 = "curl|SYM:CURL|curl ""--version""|curl|"
$ tc_32 = "GNU Wget|SYM:WGET|wget ""--version""|Wget|"
$!
$!---- Options -----------------------------------------------------------------
$ tc_brief = 0
$ tc_plain = 0
$ tc_p = 0
$opt_loop:
$ tc_p = tc_p + 1
$ if tc_p .gt. 8 then goto opt_done
$ tc_opt = f$edit(p'tc_p', "TRIM,UPCASE")
$ if tc_opt .eqs. "" then goto opt_loop
$ tc_len = f$length(tc_opt)                 ! options may be abbreviated
$ if tc_opt .eqs. f$extract(0, tc_len, "HELP") .or. tc_opt .eqs. "?" -
     then goto help
$ if tc_opt .eqs. f$extract(0, tc_len, "BRIEF")
$ then
$   tc_brief = 1
$   goto opt_loop
$ endif
$ if tc_opt .eqs. f$extract(0, tc_len, "PLAIN")
$ then
$   tc_plain = 1
$   goto opt_loop
$ endif
$ write sys$output "TOOLCHAIN: unknown option ''tc_opt' (try @TOOLCHAIN HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$! Colour and a wider line only when SYS$OUTPUT is an ANSI terminal.
$ tc_width = 80
$ tc_ansi  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     tc_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     tc_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if tc_w .ge. 60 .and. tc_w .le. 132 then tc_width = tc_w
$   endif
$ endif
$ if tc_plain then tc_ansi = 0
$ tc_bold  = ""
$ tc_ok    = ""
$ tc_dim   = ""
$ tc_bad   = ""
$ tc_off   = ""
$ if tc_ansi
$ then
$   tc_esc[0,8] = 27
$   tc_bold = tc_esc + "[1m"
$   tc_ok   = tc_esc + "[32m"                ! green
$   tc_dim  = tc_esc + "[2m"                 ! faint
$   tc_bad  = tc_esc + "[31m"                ! red
$   tc_off  = tc_esc + "[0m"
$ endif
$ tc_rule1 = f$fao("!''tc_width'*=")
$ tc_rule2 = f$fao("!''tc_width'*-")
$ tc_valw  = tc_width - 22                  ! room for the version text
$!
$! Scratch files for captured output, unique to this process
$ tc_pid = f$getjpi("", "PID")
$ tc_out = "SYS$SCRATCH:TOOLCHAIN_''tc_pid'.OUT"
$ tc_err = "SYS$SCRATCH:TOOLCHAIN_''tc_pid'.ERR"
$!
$!---- System summary ----------------------------------------------------------
$ tc_pgs = f$getsyi("PAGE_SIZE")
$ tc_mb  = f$getsyi("MEMSIZE") / (1048576 / tc_pgs)
$ tc_gbw  = tc_mb / 1024                     ! whole GB
$ tc_gbf  = (tc_mb - tc_gbw * 1024) * 10 / 1024 ! tenths
$ tc_node = f$getsyi("NODENAME")
$ tc_arch = f$getsyi("ARCH_NAME")
$ tc_hw   = f$edit(f$getsyi("HW_NAME"), "TRIM,COMPRESS")
$ tc_vms  = f$edit(f$getsyi("VERSION"), "TRIM")
$ tc_cpus = f$getsyi("ACTIVECPU_CNT")
$ tc_now  = f$extract(0, 17, f$time())
$ write sys$output tc_rule1
$ write sys$output tc_bold, " OpenVMS development toolchain", tc_off
$ write sys$output tc_rule1
$ write sys$output f$fao(" !12AS!AS (!AS)", "Node", tc_node, tc_arch)
$ write sys$output f$fao(" !12AS!AS", "Hardware", tc_hw)
$ write sys$output f$fao(" !12AS!AS", "OpenVMS", tc_vms)
$ write sys$output f$fao(" !12AS!UL active, !UL.!UL GB memory", -
                         "CPUs", tc_cpus, tc_gbw, tc_gbf)
$ write sys$output f$fao(" !12AS!AS", "Report date", tc_now)
$!
$!---- Report each tool --------------------------------------------------------
$ tc_n_ok   = 0
$ tc_n_miss = 0
$ tc_n_bad  = 0
$ tc_i = 0
$next_tool:
$ tc_i = tc_i + 1
$ if f$type(tc_'tc_i') .eqs. "" then goto tools_done
$ tc_entry = tc_'tc_i'
$!
$! Section heading
$ if f$extract(0, 1, tc_entry) .eqs. "="
$ then
$   write sys$output ""
$   write sys$output tc_bold, " ", f$extract(1, 999, tc_entry), tc_off
$   write sys$output tc_rule2
$   goto next_tool
$ endif
$!
$ tc_label = f$element(0, "|", tc_entry)
$ tc_check = f$element(1, "|", tc_entry)
$ tc_cmd   = f$element(2, "|", tc_entry)
$ tc_match = f$element(3, "|", tc_entry)
$ tc_strip = f$element(4, "|", tc_entry)
$ if tc_match .eqs. "|" then tc_match = ""
$ if tc_strip .eqs. "|" then tc_strip = ""
$!
$ gosub check_installed
$ if .not. tc_found
$ then
$   tc_n_miss = tc_n_miss + 1
$   if tc_brief then goto next_tool
$   tc_mark  = "-"
$   tc_style = tc_dim
$   tc_value = "not installed"
$   gosub show_row
$   goto next_tool
$ endif
$!
$! Run the version command, capturing both output streams
$ if f$search(tc_out) .nes. "" then delete/nolog 'tc_out';*
$ if f$search(tc_err) .nes. "" then delete/nolog 'tc_err';*
$ pipe 'tc_cmd' < NLA0: > 'tc_out' 2> 'tc_err'
$ tc_status = $status
$!
$! Find the version line: output first, then error stream (Java uses it)
$ tc_file = tc_out
$ gosub find_line
$ if tc_line .eqs. ""
$ then
$   tc_file = tc_err
$   gosub find_line
$ endif
$!
$ if .not. tc_status .and. tc_line .eqs. ""
$ then
$!   The command failed: show its first message instead of a version
$   tc_match = ""
$   tc_file  = tc_err
$   gosub find_line
$   if tc_line .eqs. ""
$   then
$     tc_file = tc_out
$     gosub find_line
$   endif
$   if tc_line .eqs. "" then tc_line = f$message(tc_status)
$   tc_n_bad = tc_n_bad + 1
$   tc_mark  = "!"
$   tc_style = tc_bad
$   tc_value = tc_line
$   gosub show_row
$   goto next_tool
$ endif
$!
$! No line matched: fall back to the first line of output
$ if tc_line .eqs. ""
$ then
$   tc_match = ""
$   tc_file  = tc_out
$   gosub find_line
$   if tc_line .eqs. ""
$   then
$     tc_file = tc_err
$     gosub find_line
$   endif
$ endif
$ if tc_line .eqs. "" then tc_line = "installed (no version reported)"
$ if tc_strip .nes. "" then tc_line = tc_line - tc_strip
$ tc_n_ok    = tc_n_ok + 1
$ tc_mark    = "+"
$ tc_style   = tc_ok
$ tc_value   = tc_line
$ gosub show_row
$ goto next_tool
$tools_done:
$!
$!---- Summary -----------------------------------------------------------------
$ write sys$output ""
$ write sys$output tc_rule1
$ write sys$output f$fao(" !UL installed, !UL not installed, !UL failed", -
                         tc_n_ok, tc_n_miss, tc_n_bad)
$ write sys$output " ", tc_ok, "+", tc_off, " installed   ", -
                        tc_dim, "-", tc_off, " not installed   ", -
                        tc_bad, "!", tc_off, " version command failed"
$ write sys$output tc_rule1
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ type sys$input
TOOLCHAIN - show the development toolchain installed on this system

Usage:   @TOOLCHAIN [option ...]

  BRIEF    list only what is installed
  PLAIN    no colour or bold, even on a terminal that supports them
  HELP     show this text

Output to a file or batch log is always plain text, for example:

  PIPE @TOOLCHAIN > TOOLCHAIN.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$cleanup:
$ if f$trnlnm("TC_IN") .nes. "" then close tc_in
$ if f$type(tc_out) .nes. ""
$ then
$   if f$search(tc_out) .nes. "" then delete/nolog 'tc_out';*
$   if f$search(tc_err) .nes. "" then delete/nolog 'tc_err';*
$ endif
$ exit 1 + 0 * f$verify(tc_verify)
$!
$!==============================================================================
$! Subroutines
$!==============================================================================
$!
$! CHECK_INSTALLED: tc_found = 1 if any check in tc_check passes.
$! Each check is a file spec, SYM:symbol or LNM:logical-name.
$check_installed:
$ tc_found = 0
$ tc_j = 0
$ci_next:
$ tc_alt = f$edit(f$element(tc_j, ",", tc_check), "TRIM")
$ if tc_found .or. tc_alt .eqs. "" .or. tc_alt .eqs. "," then return
$ tc_j = tc_j + 1
$ tc_kind = f$extract(0, 4, f$edit(tc_alt, "UPCASE"))
$ if tc_kind .eqs. "SYM:"
$ then
$   tc_name = f$extract(4, 999, tc_alt)
$   if f$type('tc_name') .nes. "" then tc_found = 1
$ else
$   if tc_kind .eqs. "LNM:"
$   then
$     if f$trnlnm(f$extract(4, 999, tc_alt)) .nes. "" then tc_found = 1
$   else
$     if f$search(tc_alt) .nes. "" then tc_found = 1
$   endif
$ endif
$ goto ci_next
$!
$! FIND_LINE: tc_line = first non-blank line of tc_file containing tc_match
$! (any case); any line if tc_match is empty; "" if none or no file.
$! (OPEN reports a missing file; F$SEARCH is avoided here because it keeps
$! its place between calls and would miss a file searched for twice.)
$find_line:
$ tc_line = ""
$ open/read/error=fl_done tc_in 'tc_file'
$fl_next:
$ read/end_of_file=fl_close/error=fl_close tc_in tc_rec
$ tc_rec = f$edit(tc_rec, "TRIM,COMPRESS")
$ if tc_rec .eqs. "" then goto fl_next
$ if tc_match .nes. ""
$ then
$   if f$locate(f$edit(tc_match, "UPCASE"), f$edit(tc_rec, "UPCASE")) -
       .ge. f$length(tc_rec) then goto fl_next
$ endif
$ tc_line = tc_rec
$fl_close:
$ close tc_in
$fl_done:
$ return
$!
$! SHOW_ROW: print one tool line, fitting the version text to the width.
$show_row:
$ if f$length(tc_value) .gt. tc_valw then -
    tc_value = f$extract(0, tc_valw - 3, tc_value) + "..."
$ write sys$output "  ", tc_style, tc_mark, tc_off, " ", -
                   f$fao("!18AS", tc_label), tc_style, tc_value, tc_off
$ return
