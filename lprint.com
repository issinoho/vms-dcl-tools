$!------------------------------------------------------------------------------
$! LPRINT.COM - Print files on the printer attached to your terminal
$!
$! Uses the terminal's printer controller mode (ANSI ESC [5i / ESC [4i):
$! everything between the two goes to the printer attached to, or set up
$! in, your terminal or terminal emulator, not to the screen. Handy for a
$! local printer when the system has no print queue for it.
$!
$! Usage:   @LPRINT file [...] [option ...]
$!
$!   file     one or more files; wildcards allowed, e.g. *.COM
$!   FF       send a form feed after each file, to eject the page
$!   HELP     show this text
$!
$! Broadcast messages are held off while printing so they don't end up on
$! paper, and your terminal settings are put back afterwards, even if you
$! press Ctrl/Y. Needs an ANSI terminal (VT100 or later, or an emulator
$! with printer support turned on).
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ lp_verify = f$verify(0)
$ set noon
$ lp_on = 0                                 ! printer controller mode is on
$ on control_y then goto cleanup
$!
$!---- Parameters --------------------------------------------------------------
$ lp_ff = 0
$ lp_nfiles = 0
$ lp_p = 0
$opt_loop:
$ lp_p = lp_p + 1
$ if lp_p .gt. 8 then goto opt_done
$ lp_opt = f$edit(p'lp_p', "TRIM")
$ if lp_opt .eqs. "" then goto opt_loop
$ lp_up = f$edit(lp_opt, "UPCASE")
$ if lp_up .eqs. "HELP" .or. lp_up .eqs. "?" then goto help
$ if lp_up .eqs. "FF"
$ then
$   lp_ff = 1
$   goto opt_loop
$ endif
$ lp_nfiles = lp_nfiles + 1
$ lp_file_'lp_nfiles' = lp_opt
$ goto opt_loop
$opt_done:
$ if lp_nfiles .eq. 0
$ then
$   write sys$output "LPRINT: no file given (try @LPRINT HELP)"
$   goto cleanup
$ endif
$!
$!---- Checks ------------------------------------------------------------------
$ if .not. f$getdvi("SYS$OUTPUT", "TRM")
$ then
$   write sys$output "LPRINT: output is not a terminal"
$   goto cleanup
$ endif
$ if .not. f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$ then
$   write sys$output "LPRINT: this terminal is not set up as ANSI" -
                     + " (try SET TERMINAL/INQUIRE)"
$   goto cleanup
$ endif
$! Make sure every file exists before sending anything to the printer.
$ lp_i = 0
$check_next:
$ lp_i = lp_i + 1
$ if lp_i .gt. lp_nfiles then goto check_done
$ lp_spec = lp_file_'lp_i'
$ lp_stream = lp_i + 10                     ! own search context per file
$ if f$search(lp_spec, lp_stream) .eqs. ""
$ then
$   write sys$output "LPRINT: no file matches ", lp_spec
$   goto cleanup
$ endif
$ goto check_next
$check_done:
$!
$!---- Print -------------------------------------------------------------------
$! Remember the terminal settings, so they can be put back as they were.
$ lp_wrap  = f$getdvi("SYS$OUTPUT", "TT_WRAP")
$ lp_nobrd = f$getdvi("SYS$OUTPUT", "TT_NOBRDCST")
$ set terminal/nowrap/nobroadcast
$ lp_esc[0,8] = 27
$ lp_ffc[0,8] = 12
$ lp_count = 0
$ lp_i = 0
$file_next:
$ lp_i = lp_i + 1
$ if lp_i .gt. lp_nfiles then goto print_done
$ lp_spec = lp_file_'lp_i'
$each_file:
$ lp_f = f$search(lp_spec, 1)
$ if lp_f .eqs. "" then goto file_next
$ if f$parse(lp_f, , , "TYPE") .eqs. ".DIR" then goto each_file
$ lp_on = 1
$ write sys$output lp_esc, "[5i"
$ type/nopage 'lp_f'
$ if lp_ff then write sys$output lp_ffc
$ write sys$output lp_esc, "[4i"
$ lp_on = 0
$ lp_count = lp_count + 1
$ write sys$output "Printed ", f$parse(lp_f, , , "NAME") + -
                   f$parse(lp_f, , , "TYPE")
$ goto each_file
$print_done:
$ if lp_count .eq. 0 then write sys$output "LPRINT: nothing printed"
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ type sys$input
LPRINT - print files on the printer attached to your terminal

Usage:   @LPRINT file [...] [option ...]

  file     one or more files; wildcards allowed, e.g. *.COM
  FF       send a form feed after each file, to eject the page
  HELP     show this text

Needs an ANSI terminal or emulator with printer support turned on.
Example:

  @LPRINT LOGIN.COM FF
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Always leave printer controller mode, or the screen stays blank and
$! everything typed goes to the printer.
$cleanup:
$ if lp_on then write sys$output lp_esc, "[4i"
$ if f$type(lp_wrap) .nes. ""
$ then
$   if lp_wrap then set terminal/wrap
$   if .not. lp_nobrd then set terminal/broadcast
$ endif
$ exit 1 + 0 * f$verify(lp_verify)
