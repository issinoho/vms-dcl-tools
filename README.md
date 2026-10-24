# DCL tools for OpenVMS

![OpenVMS](https://img.shields.io/badge/OpenVMS-x86--64-blue)
[![License](https://img.shields.io/github/license/issinoho/vms-dcl-tools)](LICENSE)

A collection of DCL command procedures for running and inspecting OpenVMS systems. Each one is a
single file with its settings at the top, so you can copy it to your system and adjust it.

## Procedures

| File | What it does | Runs |
|---|---|---|
| [`sshlogs.com`](sshlogs.com) | Cleans up VSI OpenSSH per-connection logs, temp files, process dumps and `SSH$CMDRUN.LOG` files. Counts SSH server processes so leftover ones get noticed. | Every 15 minutes |
| [`logrotate.com`](logrotate.com) | Rotates the accounting file, security audit journal and operator log, keeping dated archives for 90 days. | 1st of each month |
| [`toolchain.com`](toolchain.com) | In a box, reports the system and the version of every compiler, language and tool it finds (C, C++, Fortran, Java, Python, Git, GNU tools and more), with colour on ANSI terminals. Plain DCL, no privileges or extra tools needed. | On demand |
| [`sysinfo.com`](sysinfo.com) | A fastfetch-style system summary: OS, hardware, uptime, cluster and network identity, CPU, memory, page and swap files, users, every mounted disk and your session, beside a small VMS logo. Plain DCL, no privileges needed. | On demand |
| [`report.com`](report.com) | A boxed, sectioned configuration report for system managers: identity and boot, processors, memory and paging, global pages and sections, key SYSGEN parameters, cluster membership and members, network identity and a disk table. Plain DCL, no privileges needed. | On demand |
| [`dev.com`](dev.com) | Lists devices by class in a box with status, errors and operation counts; disks show label, size and use, other devices their type and owner. Filter by class, device name or wildcard, or show only devices with errors. Plain DCL, no privileges needed. | On demand |
| [`space.com`](space.com) | Disk space report in a box: every disk with label, size, used and free space, a coloured bar and totals; unmounted disks and device errors noted. Give a percentage to list only fuller disks and get a warning status for batch jobs. Plain DCL, no privileges needed. | On demand |
| [`uptime.com`](uptime.com) | Uptime of every cluster member (or the standalone system) in a box: hardware, version, votes, boot time and uptime, plus when the cluster formed and its quorum. Recent reboots are highlighted. Plain DCL, no privileges needed. | On demand |
| [`bootmap.com`](bootmap.com) | Explains in plain language, in a box, how the system boots and starts up: the boot sequence and each startup phase, where SYLOGICALS.COM fits and the names it defines, which procedure mounts each disk, the networking components, base OS, layered products and site software, the queues and the jobs and processes started at boot, and how long the last boot took. Reads the startup procedures without running them. | On demand |
| [`devmon.com`](devmon.com) | Live disk monitor in a box, redrawn every minute: use bars, error counts, shadow set members with copy/merge progress, and cluster mount counts. | On demand |
| [`quemon.com`](quemon.com) | Live queue monitor in a box: queue states in colour and each job's state (executing for how long, printing which block, pending and why, retained with which error). Start a stopped queue from the screen. | On demand |
| [`pscan.com`](pscan.com) | Finds processes by name, user, state, image, age or nearly-exhausted quota, in a box. Sets `PS_COUNT`, `PS_PIDS` and other symbols and a success/warning status for scripts; can watch live or wait until processes have gone. | On demand or in scripts |
| [`deltree.com`](deltree.com) | Deletes a directory tree safely: shows the real path, file count and size and asks for YES; refuses whole disks, the tree you are in, your login tree, system directories and trees with alias entries. `DRYRUN`, `KEEP`, `LOG`, `NOCONFIRM`. | On demand |
| [`lpd_queue.com`](lpd_queue.com) | Creates or re-creates a print queue that prints through the TCP/IP Services LPD client to a CUPS printer, and writes its printcap entry. Safe to re-run; `DRYRUN` shows what it would do. Needs SYSPRV and OPER. | When setting up a printer |
| [`lprint.com`](lprint.com) | Prints files on the printer attached to your terminal or emulator, using ANSI printer controller mode; restores the terminal even after Ctrl/Y. | On demand |

## toolchain.com

```
$ @TOOLCHAIN            full report
$ @TOOLCHAIN BRIEF      only what is installed
$ @TOOLCHAIN PLAIN      no colour
$ PIPE @TOOLCHAIN > TOOLCHAIN.TXT
```

Each tool is one `tc_n` line in a table at the top: a label, how to tell it is
installed (a file, `SYM:symbol` or `LNM:logical`), the command that prints its
version, and the text that marks the version line. Add a line to report another
tool. Output to a file or batch log is always plain text.

## sysinfo.com

```
$ @SYSINFO              full summary with logo
$ @SYSINFO BRIEF        without the system resources section
$ @SYSINFO NOLOGO       no logo
$ @SYSINFO PLAIN        no colour
```

Values a system cannot report are left out rather than failing. The logo
needs a line at least 80 characters wide; output to a file or batch log is
plain text.

## report.com

```
$ @REPORT               full report
$ @REPORT BRIEF         without SYSGEN parameters, cluster members and disks
$ @REPORT PLAIN         no colour
$ PIPE @REPORT > REPORT.TXT
```

The SYSGEN parameters shown are a `NAME|description` table in the procedure;
add or remove lines to suit. Values a system cannot report are left out.

## dev.com

```
$ @DEV                  all classes, hiding mailboxes, idle terminals and sockets
$ @DEV DISK TAPE        only these classes
$ @DEV DKA*             devices matching a name or wildcard
$ @DEV ERRORS           only devices with errors or offline
$ @DEV ALL              everything, including mailboxes and idle terminals
```

Classes are a table at the top of the procedure; add a line to list another.

Based on DEV.COM by Steve Watts.

## space.com

```
$ @SPACE                all disks
$ @SPACE 85             only disks 85% full or more
$ @SPACE DKA*           disks matching a name or wildcard
$ @SPACE PAGE           pause after each screenful
```

With a percentage, `$SEVERITY` is 0 (warning) when any disk is at or above it,
so a batch job can act on it:

```
$ @SPACE 90
$ IF $SEVERITY .EQ. 0 THEN MAIL/SUBJECT="Disk space" ...
```

## uptime.com

```
$ @UPTIME               boxed table, line-drawing characters on ANSI terminals
$ @UPTIME PLAIN         plain +-| box, no colour
```

Nodes up for less than a day are highlighted. Output to a file or batch log
uses the plain box.

Based on the UPTIME procedure by RDJ.

## bootmap.com

```
$ @BOOTMAP              full report
$ @BOOTMAP BRIEF        without the startup chain tree and the logical name list
$ @BOOTMAP FULL         also follow the procedures that product startups call
$ @BOOTMAP PAGE         pause after each screenful
$ PIPE @BOOTMAP > BOOTMAP.TXT
```

It starts from the startup databases that `STARTUP.COM` reads (`VMS$PHASES.DAT`,
`VMS$VMS.DAT`, `VMS$LAYERED.DAT`), finds the site procedures the OS calls
(`SYCONFIG`, `SYLOGICALS`, `SYPAGSWPFILES`, `SYSECURITY`, `SYSTARTUP_VMS`) and follows
every `@` call from them, including procedures named in symbol lists such as
`st_n = "label|SYS$STARTUP:FOO$STARTUP.COM|OPTIONAL"`. Along the way it notes disk
mounts, system logical names, queue commands, `SUBMIT`s, detached `RUN`s and page
files, with the `IF` condition around each. Site procedures are followed all the way
down; a product's startup is only summarised (`FULL` follows it too).

The sections are: in brief, boot sequence, startup chain, SYLOGICALS.COM, disks,
networking, layered products and site software, queues, batch jobs and processes,
other settings, last boot, and after startup. The last-boot section needs
`STARTUP_P2` to include `D`, so that each boot writes
`SYS$SPECIFIC:[SYSEXE]STARTUP.LOG`; the report says how to turn this on if it is off.

Nothing is run, so it is safe on a live system, but reading every startup
procedure takes half a minute or so. It turns on READALL and WORLD if you hold
them; without them some procedures may be listed as unreadable. Procedure
descriptions and categories are `ds_n` and `ct_n` tables at the top: add a line to
describe another product.

## lpd_queue.com

```
$ @LPD_QUEUE LPD_OFFICE printserver Office_Laser            create the queue
$ @LPD_QUEUE LPD_OFFICE printserver Office_Laser DEFAULT    and make it SYS$PRINT
$ @LPD_QUEUE LPD_OFFICE printserver Office_Laser DRYRUN     show, change nothing
```

Set your usual queue, host and CUPS queue at the top of the procedure to run it
with no parameters. On the CUPS side, start `cups-lpd` with
`-o job-sheets=none` so no banner page is printed.

## lprint.com

```
$ @LPRINT LOGIN.COM             print one file on the terminal's printer
$ @LPRINT *.COM FF              several files, form feed after each
```

Inspired by an old DECUS library procedure.

## devmon.com

```
$ @DEVMON               redraw every 60 seconds until Ctrl/Y
$ @DEVMON 10            every 10 seconds
$ @DEVMON ONCE          draw once and exit
```

Based on MONITOR_DEVICES.COM by A.G.M. van Ruitenbeek and J.P. van den Ende.

## quemon.com

```
$ @QUEMON               queues with jobs or problems, every 5 seconds
$ @QUEMON SYS$BATCH 10  one queue, every 10 seconds
$ @QUEMON ALL ONCE      every queue, drawn once
```

While it runs, `Q` quits, `S` starts a stopped queue and Return refreshes.

Based on MONITOR_QUE.COM by Neil Sakac.

## pscan.com

```
$ @PSCAN USER=SYSTEM SORT=CPU          SYSTEM's processes, busiest first
$ @PSCAN IMAGE=SSHD OLDER=12:00        SSH servers logged in over 12 hours
$ @PSCAN STATE=RWAST,RWMBX,MUTEX       processes waiting for resources
$ @PSCAN CHECK=BYTLM PERCENT=10        nearly out of buffered I/O bytes
$ @PSCAN STATE<>HIB WATCH=3            live view until Ctrl/Y
$ @PSCAN IMAGE=BACKUP UNTILGONE=60 QUIET   wait for a backup to finish
```

In a procedure:

```
$ @PSCAN IMAGE=MYSQLD QUIET
$ IF PS_COUNT .EQ. 0 THEN @SYS$STARTUP:MYSQL_STARTUP
```

Based on PROCESS_SCAN.COM by Keith Cayemberg.

## deltree.com

```
$ @DELTREE OLD DRYRUN               what would go from [.OLD]; deletes nothing
$ @DELTREE DKA200:[USERS.OLD]       shows path, count and size; type YES
$ @DELTREE [.BUILD] KEEP            empty the tree, keep BUILD.DIR
$ @DELTREE [.SCRATCH] NOCONFIRM     in a batch job
```

Anything that cannot be deleted (an open file, no privilege) is listed with
the reason, and `$STATUS` is an error.

## How sshlogs.com and logrotate.com work

Both procedures resubmit themselves to a batch queue and share the same conventions:

- **Parameters:** none = do the work and schedule the next run, `SUBMIT` = schedule only
  (use this to start the cycle), `DRYRUN` = show what would happen and change nothing.
- **Settings and rules at the top.** Add a cleanup with a new `rule_n` line in
  `sshlogs.com`, or a log to rotate with a new `log_n` line in `logrotate.com`.
- **Safe rescheduling.** The next run is queued *before* the work starts, with
  `/RESTART`, so a failure or crash doesn't break the cycle. A check across all batch
  queues stops a second copy being queued.
- **Edits take effect.** The procedure resubmits itself without a version number, so the
  next run picks up the latest version of the file.

## Installing

These steps are for `sshlogs.com` and `logrotate.com`; the on-demand procedures need no setup.
Put them in a directory on `DCL$PATH` to run them by name (e.g. `SPACE`), or define a
symbol such as `SPACE :== @dev:[dir]SPACE`. DCL matches built-in commands on their first
four letters before it searches `DCL$PATH`, so avoid names that start like an existing command.

1. Copy the file to a directory on your system, e.g. `SYS$COMMON:[SYSMGR]`.
2. Check the settings at the top:
   - `run_as`: the account the job runs under (default `SYSTEM`). It needs the
     privileges to delete the files involved; `logrotate.com` needs OPER and SECURITY.
   - `queue`: default `SYS$BATCH`.
   - In `sshlogs.com`, `USER$ROOT` in `rule_5` is a site logical for the user disk. Change
     it to match your system.
   - In `logrotate.com`, check the audit journal location with `SHOW AUDIT/JOURNAL`.
3. Test with `@SSHLOGS DRYRUN` / `@LOGROTATE DRYRUN`.
4. Start the cycle with `@SSHLOGS SUBMIT` / `@LOGROTATE SUBMIT`. Running `SUBMIT` again
   should report that the job is already queued.

## Acknowledgements

Some of these tools build on DCL written by others, often decades ago. We appreciate
the effort and inspiration that went into that work, and are glad to carry it into a
new era of OpenVMS:

- **Keith Cayemberg**, whose `PROCESS_SCAN.COM`, first written in the mid-1980s,
  is the basis of [`pscan.com`](pscan.com).
- **Neil Sakac**, whose `MONITOR_QUE.COM` (1990–1992) is the basis of
  [`quemon.com`](quemon.com).
- **RDJ**, who wrote the `UPTIME` procedure (1994) that is the basis of
  [`uptime.com`](uptime.com).
- **A.G.M. van Ruitenbeek** and **J.P. van den Ende** (PinkRoccade Industry, the
  Netherlands, 2003–2004), whose `MONITOR_DEVICES.COM` is the basis of
  [`devmon.com`](devmon.com).
- **Steve Watts**, whose `DEV.COM` (2005) is the basis of [`dev.com`](dev.com).
- The author of the DECUS library procedure that inspired [`lprint.com`](lprint.com),
  and the DECUS community that shared so much DCL with every VMS site.

## Licence

[MIT](LICENSE)
