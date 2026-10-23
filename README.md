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
| [`toolchain.com`](toolchain.com) | Reports the system and the version of every compiler, language and tool it finds (C, C++, Fortran, Java, Python, Git, GNU tools and more), with colour on ANSI terminals. Plain DCL, no privileges or extra tools needed. | On demand |
| [`sysinfo.com`](sysinfo.com) | A fastfetch-style system summary: OS, hardware, uptime, cluster and network identity, CPU, memory, page and swap files, users, every mounted disk and your session, beside a small VMS logo. Plain DCL, no privileges needed. | On demand |

Both were written for **VSI OpenSSH V9.9-2C** on OpenVMS x86-64, where internet SSH probes
make these files grow quickly.

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

These steps are for `sshlogs.com` and `logrotate.com`; `toolchain.com` and `sysinfo.com` need no setup.

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

## Licence

[MIT](LICENSE)
