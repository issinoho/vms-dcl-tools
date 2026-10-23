$! LPRINT.COM: print a file on the terminal's own printer
$ set term/nowrap/nobroadcast
$ esc[0,8]=27
$ write sys$output esc+"[5i"
$ type/nopage 'p1'
$ write sys$output esc+"[4i"
$ set term/wrap/broadcast
