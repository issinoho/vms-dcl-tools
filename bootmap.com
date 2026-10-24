$!------------------------------------------------------------------------------
$! BOOTMAP.COM - How this OpenVMS system boots and starts up
$!
$! Reads the startup databases and every startup procedure they lead to, and
$! describes the whole chain in plain language: the boot sequence and its
$! phases, where SYLOGICALS.COM fits and what it defines, how the disks are
$! mounted, the networking components, the base OS, the layered products and
$! site software, the queues and the jobs and processes started at boot, and
$! how long the last boot took and what it complained about.
$!
$! Nothing is run: the procedures are read, not executed. Commands inside an
$! IF are shown with their condition, because which branch runs is only
$! known at boot time.
$!
$! Usage:   @BOOTMAP [option ...]
$!
$!   BRIEF    leave out the startup chain tree and the logical name list
$!   FULL     also follow the procedures that product startups call
$!            (slower: several minutes on a system with many products)
$!   PAGE     pause after each screenful
$!   PLAIN    no colour or line drawing, even on a terminal that has them
$!   HELP     show this text
$!
$! Some startup procedures can only be read with privilege; BOOTMAP turns on
$! READALL and WORLD if you have them and says which files it could not read.
$! Colour and line drawing are used only on an ANSI terminal; output to a
$! file or batch log is plain text. Uses plain DCL only.
$!
$! To describe another product, add its file name to a ds_n line and its
$! category to a ct_n line below.
$!
$! Copyright (c) 2026 Iain Smith. MIT licence:
$! https://github.com/issinoho/vms-dcl-tools/blob/main/LICENSE
$!------------------------------------------------------------------------------
$ bm_verify = f$verify(0)
$ set noon
$ on control_y then goto interrupted
$ bm_msg = f$environment("MESSAGE")
$ set message/nofacility/noseverity/noidentification/notext
$ bm_prv = f$setprv("READALL,WORLD")
$!
$!---- Settings ----------------------------------------------------------------
$ bm_maxdep = 8                             ! deepest call level followed
$!
$! Categories: "Category|pattern,pattern,..." matched against procedure
$! names, first match wins. Unmatched site procedures are "Site", the rest
$! "Product".
$ ct_1  = "Hook|SYCONFIG,SYLOGICALS,SYPAGSWPFILES,SYSECURITY,SYSTARTUP_V"
$ ct_2  = "Base OS|VMS$,SYS$,IPC$,DECDTM,LICENSE"
$ ct_3  = "Disks|MOUNT"
$ ct_4  = "Networking|TCPIP$,NET$STARTUP,STARTNET,DECNET,LAT$,SSH$,LDAP,"  + -
          "KERBEROS,NFS,SAMBA,CIFS,MULTINET,TCPWARE,NTP,SMTP,POSTFIX,SNMP"
$ ct_5  = "Security|SSL,AUDIT,ACME,SECURITY"
$ ct_6  = "Desktop|DECW$,MOTIF"
$ ct_7  = "Development|DECC$,CXX$,FORT$,PASCAL$,COBOL,BASIC$,BLISS,DECSET," + -
          "MMS$,LSE$,SCA$,DTM$,CMS$,PCA$,FMSTARTUP,PYTHON,JAVA,PERL,RUBY," + -
          "GIT$,GNUPLOT,CURL"
$ ct_8  = "Databases|MARIADB,MYSQL,SQLITE,RDB$,ORACLE,POSTGRES,REDIS"
$ ct_9  = "Web|LIGHTTPD,APACHE,CSWS,WASD,HTTPD,NGINX,TOMCAT,PHP"
$ ct_10 = "Monitoring|BESZEL,T4$,TDC,ZABBIX,NAGIOS"
$!
$! Descriptions: "pattern|text" matched against procedure names.
$ ds_1  = "INITIAL-050_VMS|core system logical names and services"
$ ds_2  = "INITIAL-050_LIB|shared run-time libraries"
$ ds_3  = "INITIAL-050_CONFIGURE|device configuration, run by others"
$ ds_4  = "CONFIG-050_CSP|cluster server process"
$ ds_5  = "SHADOW_SERVER|volume shadowing server"
$ ds_6  = "DEVICE_STARTUP|configures devices, runs the site's early files"
$ ds_7  = "IPC$STARTUP|intra-cluster communication"
$ ds_8  = "CONFIG-050_VMS|base system configuration"
$ ds_9  = "ERRFMT|error log formatter"
$ ds_10 = "CACHE_SERVER|file system cache server"
$ ds_11 = "OPCOM|operator messages (OPCOM)"
$ ds_12 = "AUDIT_SERVER|security audit server"
$ ds_13 = "JOBCTL|job controller and queue manager"
$ ds_14 = "050_LMF|licences (LMF)"
$ ds_15 = "SECURITY_SERVER|intrusion and proxy security server"
$ ds_16 = "ACME_SERVER|authentication server (ACME)"
$ ds_17 = "BASEENVIRON-050_VMS|base environment and network services"
$ ds_18 = "SMISERVER|SYSMAN server"
$ ds_19 = "BASEENVIRON-050_LIB|more shared libraries"
$ ds_20 = "DECDTM$|transaction manager (DECdtm)"
$ ds_21 = "LICENSE_CHECK|licence check"
$ ds_22 = "INDICT_SERVER|fault indictment server"
$ ds_23 = "LPBEGIN-050_STARTUP|runs the site's SYSTARTUP_VMS"
$ ds_24 = "SMHANDLER|system management event handler"
$ ds_25 = "END-050_COORDINATED|end of startup"
$ ds_26 = "SYCONFIG|site device configuration"
$ ds_27 = "SYLOGICALS|site logical names"
$ ds_28 = "SYPAGSWPFILES|site page and swap files"
$ ds_29 = "SYSECURITY|site security settings"
$ ds_30 = "SYSTARTUP_V|site startup"
$ ds_31 = "INDICTMENT_POLICY|fault indictment policy"
$ ds_32 = "MSCPMOUNT|mounts disks"
$ ds_33 = "CLU_DISK_MOUNT|mounts a disk"
$ ds_34 = "TCPIP$STARTUP|TCP/IP Services"
$ ds_35 = "NET$STARTUP|DECnet-Plus"
$ ds_36 = "STARTNET|DECnet Phase IV"
$ ds_37 = "LAT$STARTUP|LAT terminal protocol"
$ ds_38 = "SSH$STARTUP|OpenSSH server"
$ ds_39 = "SSL111$|OpenSSL 1.1.1"
$ ds_40 = "SSL3$|OpenSSL 3"
$ ds_41 = "SSL31$|OpenSSL 3.1"
$ ds_42 = "SSL$|OpenSSL"
$ ds_43 = "LDAP$|LDAP client"
$ ds_44 = "DECW$STARTUP|DECwindows desktop"
$ ds_45 = "DECC$|C compiler"
$ ds_46 = "CXX$|C++ compiler"
$ ds_47 = "FORT$|Fortran compiler"
$ ds_48 = "PASCAL$|Pascal compiler"
$ ds_49 = "COBOL$|COBOL compiler"
$ ds_50 = "BASIC$|BASIC compiler"
$ ds_51 = "FMSTARTUP|FMS forms"
$ ds_52 = "DECSET$|DECset"
$ ds_53 = "MMS$|MMS build tool"
$ ds_54 = "LSE$|language-sensitive editor"
$ ds_55 = "SCA$|source code analyzer"
$ ds_56 = "DTM$|test manager"
$ ds_57 = "CMS$|code management system"
$ ds_58 = "PYTHON_WHEELS|Python wheels"
$ ds_59 = "PYTHON$|Python"
$ ds_60 = "JAVA$|Java"
$ ds_61 = "PERL$|Perl"
$ ds_62 = "GIT$|Git"
$ ds_63 = "MARIADB|MariaDB"
$ ds_64 = "MYSQL|MySQL"
$ ds_65 = "LIGHTTPD|lighttpd web server"
$ ds_66 = "CSWS|Apache web server"
$ ds_67 = "APACHE$|Apache web server"
$ ds_68 = "WASD|WASD web server"
$ ds_69 = "BESZEL|Beszel monitoring agent"
$ ds_70 = "POWER_MONITOR|power monitor"
$!
$! Network software to check for while the report runs:
$! "label|process name|pattern of its startup procedure".
$ np_1 = "TCP/IP Services|TCPIP$INETACP|TCPIP$"
$ np_2 = "DECnet Phase IV|NETACP|STARTNET"
$ np_3 = "DECnet-Plus|NET$ACP|NET$STARTUP"
$ np_4 = "LAT|LATACP|LAT$"
$!
$!---- Options -----------------------------------------------------------------
$ bm_brief = 0
$ bm_full  = 0
$ bm_page  = 0
$ bm_plain = 0
$ bm_p = 0
$opt_loop:
$ bm_p = bm_p + 1
$ if bm_p .gt. 8 then goto opt_done
$ bm_opt = f$edit(p'bm_p', "TRIM,UPCASE")
$ if bm_opt .eqs. "" then goto opt_loop
$ bm_len = f$length(bm_opt)
$ if bm_opt .eqs. f$extract(0, bm_len, "HELP") .or. bm_opt .eqs. "?" -
     then goto help
$ if bm_opt .eqs. f$extract(0, bm_len, "BRIEF")
$ then
$   bm_brief = 1
$   goto opt_loop
$ endif
$ if bm_opt .eqs. f$extract(0, bm_len, "FULL")
$ then
$   bm_full = 1
$   goto opt_loop
$ endif
$ if bm_opt .eqs. f$extract(0, bm_len, "PAGE") .and. bm_len .ge. 2
$ then
$   bm_page = 1
$   goto opt_loop
$ endif
$ if bm_opt .eqs. f$extract(0, bm_len, "PLAIN") .and. bm_len .ge. 2
$ then
$   bm_plain = 1
$   goto opt_loop
$ endif
$ set message 'bm_msg'
$ write sys$output "BOOTMAP: unknown option ''bm_opt' (try @BOOTMAP HELP)"
$ goto cleanup
$opt_done:
$!
$!---- Output style ------------------------------------------------------------
$ bm_width = 80
$ bm_ansi  = 0
$ bm_rows  = 0
$ if f$getdvi("SYS$OUTPUT", "EXISTS")
$ then
$   if f$getdvi("SYS$OUTPUT", "TRM")
$   then
$     bm_ansi = f$getdvi("SYS$OUTPUT", "TT_ANSICRT")
$     bm_w = f$getdvi("SYS$OUTPUT", "DEVBUFSIZ")
$     if bm_w .ge. 80 .and. bm_w .le. 132 then bm_width = bm_w
$     if bm_page .and. f$mode() .eqs. "INTERACTIVE" then -
        bm_rows = f$getdvi("SYS$OUTPUT", "TT_PAGE")
$   endif
$ endif
$ if bm_rows .lt. 10 then bm_rows = 0
$ if bm_plain then bm_ansi = 0
$ bm_bold = ""
$ bm_head = ""
$ bm_key  = ""
$ bm_dim  = ""
$ bm_grn  = ""
$ bm_yel  = ""
$ bm_red  = ""
$ bm_off  = ""
$ if bm_ansi
$ then
$   bm_esc[0,8] = 27
$   bm_bold = bm_esc + "[1m"
$   bm_head = bm_esc + "[1;31m"             ! bold red section headings
$   bm_key  = bm_esc + "[1;34m"             ! bold blue labels
$   bm_dim  = bm_esc + "[36m"               ! cyan for secondary detail
$   bm_grn  = bm_esc + "[32m"
$   bm_yel  = bm_esc + "[33m"
$   bm_red  = bm_esc + "[1;31m"
$   bm_off  = bm_esc + "[0m"
$ endif
$!
$!---- Box ---------------------------------------------------------------------
$! DEC Special Graphics line drawing on an ANSI terminal; plain +-| elsewhere,
$! so files and batch logs stay readable.
$ bm_gon  = ""
$ bm_goff = ""
$ bm_c_tl = "+"
$ bm_c_tr = "+"
$ bm_c_bl = "+"
$ bm_c_br = "+"
$ bm_c_ml = "+"
$ bm_c_mr = "+"
$ bm_c_h  = "-"
$ bm_c_v  = "|"
$ bm_t_mid  = "|-"                          ! tree: an entry with more below
$ bm_t_last = "`-"                          ! tree: the last entry
$ bm_t_bar  = "| "                          ! tree: a level still open
$ if bm_ansi
$ then
$   bm_gon  = bm_esc + "(0"
$   bm_goff = bm_esc + "(B"
$   bm_c_tl = "l"
$   bm_c_tr = "k"
$   bm_c_bl = "m"
$   bm_c_br = "j"
$   bm_c_ml = "t"
$   bm_c_mr = "u"
$   bm_c_h  = "q"
$   bm_c_v  = "x"
$   bm_t_mid  = "tq"
$   bm_t_last = "mq"
$   bm_t_bar  = "x "
$ endif
$ bm_cw = bm_width - 6                      ! room inside the box
$ bm_hn = bm_cw + 2
$ bm_hline = f$fao("!''bm_hn'*''bm_c_h'")
$ bm_kw = 18                                ! label width in key/value lines
$ bm_lines = 0
$!
$! Tell an interactive user something is happening: reading takes a while.
$ bm_tell = 0
$ if f$mode() .eqs. "INTERACTIVE" .and. f$getdvi("SYS$OUTPUT", "TRM") then -
    bm_tell = 1
$ if bm_tell then write sys$output "Reading the startup procedures..."
$!
$!==============================================================================
$! Gather: phases and startup databases
$!==============================================================================
$ bm_node = f$edit(f$getsyi("NODENAME"), "TRIM")
$ bm_nph = 0
$ open/read/share=write/error=no_phases bm_in STARTUP$PHASES
$ph_next:
$ read/end_of_file=ph_done/error=ph_done bm_in bm_rec
$ bm_rec = f$edit(bm_rec, "TRIM,UPCASE")
$ if bm_rec .eqs. "" then goto ph_next
$ bm_nph = bm_nph + 1
$ bm_ph'bm_nph' = bm_rec
$ goto ph_next
$ph_done:
$ close bm_in
$no_phases:
$ if bm_nph .eq. 0
$ then
$   bm_ph1 = "INITIAL"
$   bm_ph2 = "DEVICES"
$   bm_ph3 = "CONFIGURE"
$   bm_ph4 = "BASEENVIRON"
$   bm_ph5 = "LPBEGIN"
$   bm_ph6 = "LPMAIN"
$   bm_ph7 = "LPBETA"
$   bm_ph8 = "END"
$   bm_nph = 8
$ endif
$!
$! Each startup database record: phase (12), mode (1), file (79), then the
$! parameters up to a CR, the enable flag (E/D) and the node list. This is
$! the layout STARTUP.COM itself reads.
$ bm_cr[0,7] = 13
$ bm_ndb = 0                                ! databases
$ bm_nr  = 0                                ! records
$db_next:
$ bm_dbl = f$trnlnm("STARTUP$STARTUP_LIST", "LNM$SYSTEM_TABLE", bm_ndb)
$ if bm_dbl .eqs. "" then goto db_done
$ bm_ndb = bm_ndb + 1
$ bm_dbn'bm_ndb' = bm_dbl
$ bm_dbf'bm_ndb' = f$trnlnm(bm_dbl, "LNM$SYSTEM_TABLE")
$ bm_dbc'bm_ndb' = 0
$ open/read/share=write/error=db_next bm_in 'bm_dbl'
$db_read:
$ read/end_of_file=db_eof/error=db_eof bm_in bm_rec
$ bm_nr = bm_nr + 1
$ bm_dbc'bm_ndb' = bm_dbc'bm_ndb' + 1
$ bm_rpe = f$locate(bm_cr, bm_rec)
$ bm_r'bm_nr'_pha = f$edit(f$extract(0, 12, bm_rec), "COLLAPSE,UPCASE")
$ bm_r'bm_nr'_mod = f$extract(12, 1, bm_rec)
$ bm_r'bm_nr'_fil = f$edit(f$extract(13, 79, bm_rec), "COLLAPSE,UPCASE")
$ bm_r'bm_nr'_flg = f$extract(bm_rpe + 1, 1, bm_rec)
$ bm_r'bm_nr'_nod = "," + f$edit(f$extract(bm_rpe + 2, 200, bm_rec), "COLLAPSE,UPCASE")
$ bm_r'bm_nr'_db  = bm_ndb
$ goto db_read
$db_eof:
$ close bm_in
$ goto db_next
$db_done:
$ if bm_ndb .eq. 0
$ then
$   bm_ndb = 1
$   bm_dbn1 = "STARTUP$STARTUP_VMS"
$   bm_dbf1 = "(not found)"
$   bm_dbc1 = 0
$ endif
$!
$!==============================================================================
$! Gather: walk the chain phase by phase
$!==============================================================================
$! Every procedure found becomes an entry (bm_e<n>_...) in run order, with
$! its depth in the call tree. What the procedures do is collected as they
$! are read: system logicals (bm_l), disk mounts (bm_m), queue commands
$! (bm_q), batch jobs (bm_s), detached processes (bm_d), page and swap
$! files (bm_g), network commands (bm_w) and other settings (bm_x).
$ bm_ne = 0
$ bm_nl = 0
$ bm_nm = 0
$ bm_nq = 0
$ bm_ns = 0
$ bm_nd = 0
$ bm_ng = 0
$ bm_nw = 0
$ bm_nx = 0
$ bm_seq = 0                                ! order of collected actions
$! Commands worth a closer look in a product's startup, by first 3 letters.
$ bm_verbs = "|IF |IF(|ELS|END|THE|DEF|ASS|MOU|SUB|RUN|INS|STA|INI|ENA|MCR|"
$ bm_pk = 0
$walk_phase:
$ bm_pk = bm_pk + 1
$ if bm_pk .gt. bm_nph then goto walk_done
$ bm_phase = bm_ph'bm_pk'
$ bm_ri = 0
$walk_rec:
$ bm_ri = bm_ri + 1
$ if bm_ri .gt. bm_nr then goto walk_phase
$ if bm_r'bm_ri'_pha .nes. bm_phase then goto walk_rec
$ bm_a_fil = ""
$ bm_a_nam = bm_r'bm_ri'_fil
$ bm_a_st  = ""
$ bm_a_how = bm_r'bm_ri'_mod
$ bm_a_dep = 0
$ bm_a_lab = ""
$ bm_a_cnd = ""
$ bm_a_par = 0
$ bm_a_pha = bm_phase
$ bm_a_db  = bm_r'bm_ri'_db
$ bm_a_mod = "OS"
$ if bm_a_db .gt. 1 then bm_a_mod = "PROD"
$! Enabled on this node? Same test as STARTUP.COM.
$ bm_nod = bm_r'bm_ri'_nod
$ bm_on = 0
$ if bm_r'bm_ri'_flg .eqs. "E" .and. (bm_nod .eqs. ",*" .or. -
     f$locate("," + bm_node + ",", bm_nod + ",") .lt. f$length(bm_nod)) -
     then bm_on = 1
$ if bm_r'bm_ri'_flg .eqs. "D" .and. bm_nod .nes. ",*" .and. -
     f$locate("," + bm_node + ",", bm_nod + ",") .ge. f$length(bm_nod) -
     then bm_on = 1
$ if .not. bm_on then bm_a_st = "disabled on this node"
$ bm_find = "SYS$STARTUP:" + bm_a_nam
$ gosub find
$ if bm_found .eqs. "" .and. bm_a_st .eqs. "" then bm_a_st = "missing"
$ bm_a_fil = bm_found
$ gosub add_entry
$ if bm_a_st .nes. "" then goto walk_rec
$ if f$parse(bm_a_fil,,, "TYPE") .nes. ".COM" then goto walk_rec
$ bm_root = bm_ne
$ gosub scan
$ goto walk_rec
$walk_done:
$!
$!==============================================================================
$! Gather: live state (processes, disks, startup log)
$!==============================================================================
$! Process names, to tell what is running now. Needs WORLD to see them all.
$ bm_world = f$privilege("WORLD")
$ bm_procs = "|"
$ bm_ctx = ""
$pr_next:
$ bm_pid = f$pid(bm_ctx)
$ if bm_pid .eqs. "" then goto pr_done
$ bm_pn = f$edit(f$getjpi(bm_pid, "PRCNAM"), "TRIM,UPCASE")
$ if f$length(bm_procs) .lt. 7000 then bm_procs = bm_procs + bm_pn + "|"
$ goto pr_next
$pr_done:
$!
$ bm_sysdev = f$getdvi("SYS$SYSDEVICE", "FULLDEVNAM")
$ bm_syslab = f$edit(f$getdvi("SYS$SYSDEVICE", "VOLNAM"), "TRIM")
$ bm_sysnam = f$getdvi("SYS$SYSDEVICE", "DEVNAM") - "_"
$ bm_root_dir = f$element(0, ".", f$element(1, "[", f$trnlnm("SYS$SPECIFIC")) - "]")
$ bm_boot = f$getsyi("BOOTTIME")
$!
$! The startup log, if STARTUP_P2 has D and the log is from this boot.
$ bm_p1 = f$edit(f$getsyi("STARTUP_P1"), "TRIM,UPCASE")
$ bm_p2 = f$edit(f$getsyi("STARTUP_P2"), "TRIM,UPCASE")
$ bm_log = f$search("SYS$SPECIFIC:[SYSEXE]STARTUP.LOG;0")
$ bm_logok = 0
$ bm_dur = -1
$ bm_nlw = 0                                ! warnings and errors in the log
$ if bm_log .nes. ""
$ then
$   bm_t = f$cvtime(bm_boot, "COMPARISON")
$   gosub civil
$   bm_bsec = bm_days * 86400 + bm_secs
$   bm_t = f$cvtime(f$file_attributes(bm_log, "CDT"), "COMPARISON")
$   gosub civil
$   bm_csec = bm_days * 86400 + bm_secs
$   bm_t = f$cvtime(f$file_attributes(bm_log, "RDT"), "COMPARISON")
$   gosub civil
$   bm_rsec = bm_days * 86400 + bm_secs
$   if bm_csec - bm_bsec .ge. -5 .and. bm_csec - bm_bsec .le. 900 then -
      bm_logok = 1
$   if bm_logok then bm_dur = bm_rsec - bm_bsec
$   if bm_logok
$   then
$     open/read/share=write/error=log_done bm_in 'bm_log'
$log_next:
$     read/end_of_file=log_eof/error=log_eof bm_in bm_rec
$     if f$extract(0, 1, bm_rec) .nes. "%" then goto log_next
$     if f$locate("-W-", bm_rec) .ge. f$length(bm_rec) .and. -
         f$locate("-E-", bm_rec) .ge. f$length(bm_rec) .and. -
         f$locate("-F-", bm_rec) .ge. f$length(bm_rec) then goto log_next
$     bm_nlw = bm_nlw + 1
$     if bm_nlw .le. 10 then bm_lw'bm_nlw' = f$edit(bm_rec, "COMPRESS,TRIM")
$     goto log_next
$log_eof:
$     close bm_in
$log_done:
$   endif
$ endif
$!
$! Counts for the summaries.
$ bm_i = 0
$ bm_ncnt_net = 0
$ bm_ncnt_prod = 0
$ bm_ncnt_site = 0
$ bm_ncnt_miss = 0
$ bm_ncnt_read = 0
$ bm_syl = 0                                ! the SYLOGICALS entry
$ bm_sst = 0                                ! the SYSTARTUP_VMS entry
$cnt_next:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto cnt_done
$ bm_c = bm_e'bm_i'_cat
$ if bm_e'bm_i'_st .eqs. "missing" then bm_ncnt_miss = bm_ncnt_miss + 1
$ if bm_e'bm_i'_st .eqs. "cannot read" then bm_ncnt_read = bm_ncnt_read + 1
$ if bm_e'bm_i'_nam .eqs. "SYLOGICALS" .and. bm_syl .eq. 0 then bm_syl = bm_i
$ if bm_e'bm_i'_nam .eqs. "SYSTARTUP_VMS" .and. bm_sst .eq. 0 then -
    bm_sst = bm_i
$ if bm_e'bm_i'_st .nes. "" then goto cnt_next
$ if bm_c .eqs. "Networking" then bm_ncnt_net = bm_ncnt_net + 1
$ if bm_c .eqs. "Site" then bm_ncnt_site = bm_ncnt_site + 1
$ if bm_c .nes. "Networking" .and. bm_c .nes. "Base OS" .and. -
     bm_c .nes. "Hook" .and. bm_c .nes. "Disks" .and. bm_c .nes. "Site" -
     then bm_ncnt_prod = bm_ncnt_prod + 1
$ goto cnt_next
$cnt_done:
$ bm_nsysl = bm_nl                          ! system logicals, site files
$!
$!==============================================================================
$! Report: title
$!==============================================================================
$ if bm_tell .and. bm_ansi then write sys$output bm_esc, "[A", bm_esc, "[2K", bm_esc, "[A"
$ bm_title = "Boot and startup of " + bm_node
$ bm_now = f$extract(0, 17, f$time())
$ bm_pad = bm_cw - f$length(bm_title) - f$length(bm_now)
$ if bm_pad .lt. 1 then bm_pad = 1
$ write sys$output ""
$ bm_lines = 1
$ bm_l = bm_c_tl
$ bm_r = bm_c_tr
$ gosub rule
$ bm_out = bm_bold + bm_title + bm_off + f$fao("!''bm_pad'* ") + bm_now
$ bm_vl  = f$length(bm_title) + bm_pad + f$length(bm_now)
$ gosub say
$!
$!==============================================================================
$! In brief
$!==============================================================================
$ bm_hd = "In brief"
$ gosub heading
$ bm_arch = f$getsyi("ARCH_NAME")
$ if bm_arch .eqs. "x86_64" then bm_arch = "x86-64"
$ bm_hw = f$edit(f$getsyi("HW_NAME"), "COMPRESS,TRIM")
$ bm_wt = bm_node + " runs OpenVMS " + f$edit(f$getsyi("VERSION"), "TRIM") + -
          " on " + bm_hw + " (" + bm_arch + "). It last booted at " + -
          f$extract(0, 17, bm_boot) + " from the system disk " + bm_sysnam + -
          " (volume " + bm_syslab + ")"
$ if bm_dur .ge. 0
$ then
$   gosub fmt_dur
$   bm_wt = bm_wt + ", and startup took " + bm_dtxt
$ endif
$ bm_wt = bm_wt + "."
$ bm_osn = 0
$ bm_i = 0
$br_os:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto br_os_done
$ if bm_e'bm_i'_dep .eq. 0 .and. bm_e'bm_i'_db .eq. 1 then bm_osn = bm_osn + 1
$ goto br_os
$br_os_done:
$ bm_wt = bm_wt + f$fao(" The base OS starts in !UL phases (!UL procedure!%S from the startup database).", -
          bm_nph, bm_osn)
$ bm_cl = ""
$ if bm_syl .gt. 0 then bm_cl = bm_cl + f$fao("!UL system logical name!%S", bm_nsysl) + "|"
$ if bm_nm .gt. 0 then bm_cl = bm_cl + f$fao("!UL disk mount!%S", bm_nm) + "|"
$ if bm_ncnt_net .gt. 0 then bm_cl = bm_cl + f$fao("!UL networking component!%S", bm_ncnt_net) + "|"
$ if bm_ncnt_prod .gt. 0 then bm_cl = bm_cl + f$fao("!UL product startup!%S", bm_ncnt_prod) + "|"
$ if bm_nq .gt. 0 then bm_cl = bm_cl + f$fao("!UL queue command!%S", bm_nq) + "|"
$ if bm_ns .gt. 0 then bm_cl = bm_cl + f$fao("!UL batch job!%S", bm_ns) + "|"
$ if bm_nd .gt. 0 then bm_cl = bm_cl + f$fao("!UL detached process!1%C!%Ees!%F", bm_nd, bm_nd) + "|"
$ if bm_cl .nes. ""
$ then
$   gosub join_and
$   bm_wt = bm_wt + " The site's startup files then add " + bm_joined + "."
$ endif
$ if bm_ncnt_miss .gt. 0 then -
    bm_wt = bm_wt + f$fao(" !UL procedure!%S called at startup !1%Cis!%Eare!%F missing.", -
                          bm_ncnt_miss, bm_ncnt_miss)
$ if bm_ncnt_read .gt. 0 then -
    bm_wt = bm_wt + f$fao(" !UL procedure!%S could not be read; run BOOTMAP from a privileged account to see !1%Cit!%Ethem!%F.", -
                          bm_ncnt_read, bm_ncnt_read)
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap
$!
$!==============================================================================
$! Boot sequence
$!==============================================================================
$ bm_hd = "Boot sequence"
$ gosub heading
$ bm_wt = "The boot loader reads SYSBOOT from " + bm_sysnam + ", system root " + -
          bm_root_dir + ". SYSBOOT loads the SYSGEN parameters and the executive."
$ bm_wf = " 1. "
$ bm_wi = 4
$ gosub wrap
$ bm_mode = "a normal startup"
$ if bm_p1 .eqs. "MIN" then bm_mode = "a minimum startup (STARTUP_P1 is MIN)"
$ if bm_p1 .nes. "" .and. bm_p1 .nes. "MIN" then -
    bm_mode = "startup with STARTUP_P1 """ + bm_p1 + """"
$ bm_wt = "SYSINIT mounts the system disk and creates the STARTUP process, " + -
          "which runs SYS$SYSTEM:STARTUP.COM: " + bm_mode
$ bm_cl = ""
$ if f$locate("D", bm_p2) .lt. f$length(bm_p2) then -
    bm_cl = bm_cl + "logged to SYS$SPECIFIC:[SYSEXE]STARTUP.LOG|"
$ if f$locate("V", bm_p2) .lt. f$length(bm_p2) .or. bm_p2 .eqs. "YES" .or. -
     f$extract(0, 1, bm_p2) .eqs. "Y" then bm_cl = bm_cl + "with every command shown|"
$ if f$locate("P", bm_p2) .lt. f$length(bm_p2) then -
    bm_cl = bm_cl + "with STARTUP.COM's commands shown|"
$ if f$locate("C", bm_p2) .lt. f$length(bm_p2) then -
    bm_cl = bm_cl + "with each procedure named as it starts|"
$ if bm_cl .nes. ""
$ then
$   gosub join_and
$   bm_wt = bm_wt + ", " + bm_joined + " (STARTUP_P2 is """ + bm_p2 + """)"
$ endif
$ bm_wt = bm_wt + "."
$ bm_wf = " 2. "
$ gosub wrap
$ bm_wt = f$fao("STARTUP.COM works through the !UL phases in VMS$PHASES.DAT, ", bm_nph) + -
          "running the procedures registered for each phase in the startup " + -
          "database"
$ bm_k = 0
$bs_db:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_ndb then goto bs_db_done
$ bm_v = bm_dbf'bm_k'
$ bm_v = f$parse(bm_v,,, "NAME") + f$parse(bm_v,,, "TYPE")
$ bm_sep = ", "
$ if bm_k .eq. 1 then bm_sep = "s: "
$ bm_wt = bm_wt + bm_sep + bm_v + f$fao(" (!UL entr!1%Cy!%Eies!%F)", -
          bm_dbc'bm_k', bm_dbc'bm_k')
$ goto bs_db
$bs_db_done:
$ bm_wt = bm_wt + ". The site's own files are called from these phases:"
$ bm_wf = " 3. "
$ gosub wrap
$!
$! One line per phase: its OS work, the site files it calls, and products.
$ bm_pk = 0
$bs_phase:
$ bm_pk = bm_pk + 1
$ if bm_pk .gt. bm_nph then goto bs_phase_done
$ bm_phase = bm_ph'bm_pk'
$ bm_os = ""
$ bm_hk = ""
$ bm_lp = ""
$ bm_i = 0
$bs_ent:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto bs_ent_done
$ if bm_e'bm_i'_pha .nes. bm_phase then goto bs_ent
$ if bm_e'bm_i'_dep .eq. 0 .and. bm_e'bm_i'_db .eq. 1
$ then
$   bm_v = bm_e'bm_i'_dsc
$   if bm_v .eqs. "" then bm_v = bm_e'bm_i'_nam
$   if bm_e'bm_i'_how .eqs. "C" then goto bs_ent    ! only run when called
$   if f$locate("the site's", bm_v) .lt. f$length(bm_v) then goto bs_ent
$   if f$locate(bm_v + ";", bm_os) .ge. f$length(bm_os) then -
      bm_os = bm_os + bm_v + "; "
$ endif
$ if bm_e'bm_i'_dep .eq. 0 .and. bm_e'bm_i'_db .gt. 1 then -
    bm_lp = bm_lp + bm_e'bm_i'_nam + ", "
$ bm_up = bm_e'bm_i'_par
$ if bm_e'bm_i'_dep .eq. 1 .and. bm_up .gt. 0
$ then
$   if bm_e'bm_up'_db .eq. 1 .and. bm_e'bm_i'_mod .eqs. "SITE" then -
      bm_hk = bm_hk + bm_e'bm_i'_nam + ", "
$   if bm_e'bm_up'_db .eq. 1 .and. bm_e'bm_i'_mod .nes. "SITE" then -
      bm_lp = bm_lp + bm_e'bm_i'_nam + ", "
$ endif
$ goto bs_ent
$bs_ent_done:
$ bm_wt = ""
$ if bm_os .nes. "" then bm_wt = f$extract(0, f$length(bm_os) - 2, bm_os) + "."
$ if bm_hk .nes. "" then bm_wt = bm_wt + " Site: " + -
    f$extract(0, f$length(bm_hk) - 2, bm_hk) + "."
$ if bm_lp .nes. "" then bm_wt = bm_wt + " Products: " + -
    f$extract(0, f$length(bm_lp) - 2, bm_lp) + "."
$ if bm_wt .eqs. "" then bm_wt = "nothing registered."
$ bm_wt = f$edit(bm_wt, "TRIM")
$ bm_wf = f$fao("    !12AS", bm_phase)
$ bm_wi = 16
$ gosub wrap_key
$ goto bs_phase
$bs_phase_done:
$ bm_v = f$trnlnm("SYS$SYLOGIN")
$ bm_wt = "When the last phase ends the system is up. Each login then runs "
$ if bm_v .nes. ""
$ then
$   bm_wt = bm_wt + "the system login procedure " + bm_v + " (SYS$SYLOGIN)."
$ else
$   bm_wt = bm_wt + "the user's LOGIN.COM; SYS$SYLOGIN is not defined."
$ endif
$ bm_wf = " 4. "
$ bm_wi = 4
$ gosub wrap
$!
$!==============================================================================
$! Startup chain (tree)
$!==============================================================================
$ if bm_brief then goto tree_done
$ bm_hd = "Startup chain"
$ gosub heading
$ bm_wt = "Every procedure in the order it runs, indented under the one that " + -
          "calls it. Conditions in brackets decide at boot time whether it runs."
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap_dim
$ bm_nc = 36                                ! tree and name column
$ if bm_cw .ge. 100 then bm_nc = 40
$ bm_i = 0
$ bm_lastph = ""
$tr_next:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto tree_done
$ bm_d = bm_e'bm_i'_dep
$ if bm_e'bm_i'_pha .nes. bm_lastph
$ then
$   bm_lastph = bm_e'bm_i'_pha
$   bm_out = bm_key + bm_lastph + bm_off
$   bm_vl  = f$length(bm_lastph)
$   gosub say
$ endif
$! Is this the last entry at its level (within its phase at the top)?
$ bm_last = 1
$ bm_j = bm_i
$tr_look:
$ bm_j = bm_j + 1
$ if bm_j .gt. bm_ne then goto tr_looked
$ if bm_e'bm_j'_dep .lt. bm_d then goto tr_looked
$ if bm_e'bm_j'_dep .gt. bm_d then goto tr_look
$ if bm_d .gt. 0 .or. bm_e'bm_j'_pha .eqs. bm_e'bm_i'_pha then bm_last = 0
$tr_looked:
$ bm_open'bm_d' = .not. bm_last
$ bm_pre = " "
$ bm_k = 0
$tr_pre:
$ if bm_k .ge. bm_d then goto tr_pre_done
$ if bm_open'bm_k'
$ then
$   bm_pre = bm_pre + bm_t_bar + " "
$ else
$   bm_pre = bm_pre + "   "
$ endif
$ bm_k = bm_k + 1
$ goto tr_pre
$tr_pre_done:
$ if bm_last
$ then
$   bm_pre = bm_pre + bm_t_last
$ else
$   bm_pre = bm_pre + bm_t_mid
$ endif
$ bm_nm_txt = " " + bm_e'bm_i'_nam
$ bm_pv = f$length(bm_pre) + f$length(bm_nm_txt)
$ if bm_pv .gt. bm_nc - 1 then bm_nm_txt = f$extract(0, bm_nc - 1 - f$length(bm_pre), bm_nm_txt)
$ bm_pv = f$length(bm_pre) + f$length(bm_nm_txt)
$ bm_fill = bm_nc - bm_pv
$ bm_sp = ""
$ if bm_fill .gt. 0 then bm_sp = f$fao("!''bm_fill'* ")
$! Detail: label or description, what it does, condition, problems.
$ bm_dt = bm_e'bm_i'_dsc
$ if bm_dt .eqs. "" then bm_dt = bm_e'bm_i'_lab
$ bm_e = bm_i
$ gosub summary
$ if bm_sum .nes. ""
$ then
$   if bm_dt .nes. "" then bm_dt = bm_dt + ": "
$   bm_dt = bm_dt + bm_sum
$ endif
$ if bm_e'bm_i'_how .eqs. "C" then bm_dt = bm_dt + " (run when called)"
$ if bm_e'bm_i'_how .eqs. "S" then bm_dt = bm_dt + " (spawned)"
$ if bm_e'bm_i'_how .eqs. "B" then bm_dt = bm_dt + " (batch job)"
$ bm_cn = bm_e'bm_i'_cnd
$ if bm_cn .nes. "" then bm_dt = bm_dt + " [if " + bm_cn + "]"
$ bm_dt = f$edit(bm_dt, "TRIM")
$ bm_st = bm_e'bm_i'_st
$ bm_sc = bm_yel
$ if bm_st .eqs. "missing" then bm_sc = bm_red
$ bm_dw = bm_cw - bm_nc
$ if bm_st .nes. ""
$ then
$   bm_dw = bm_dw - f$length(bm_st) - 3
$   if bm_dw .lt. 0 then bm_dw = 0
$ endif
$ if f$length(bm_dt) .gt. bm_dw
$ then
$   bm_dt = f$extract(0, bm_dw - 3, bm_dt) + "..."
$   if bm_dw .lt. 4 then bm_dt = ""
$ endif
$ bm_nmc = ""
$ if bm_d .eq. 0 .and. bm_e'bm_i'_db .gt. 1 then bm_nmc = bm_bold
$ if bm_e'bm_i'_cat .eqs. "Hook" then bm_nmc = bm_bold
$ bm_out = bm_gon + bm_pre + bm_goff + bm_nmc + bm_nm_txt + bm_off + bm_sp + -
           bm_dim + bm_dt + bm_off
$ bm_vl  = bm_pv + f$length(bm_sp) + f$length(bm_dt)
$ if bm_st .nes. ""
$ then
$   bm_out = bm_out + " " + bm_sc + "(" + bm_st + ")" + bm_off
$   bm_vl  = bm_vl + 3 + f$length(bm_st)
$ endif
$ gosub say
$ goto tr_next
$tree_done:
$!
$!==============================================================================
$! SYLOGICALS.COM
$!==============================================================================
$ bm_hd = "SYLOGICALS.COM: site logical names"
$ gosub heading
$ if bm_syl .eq. 0
$ then
$   bm_wt = "Nothing in the startup calls SYS$MANAGER:SYLOGICALS.COM, so no " + -
            "site logical names are defined early in the boot."
$   if f$search("SYS$MANAGER:SYLOGICALS.COM") .nes. "" then bm_wt = -
      "SYS$MANAGER:SYLOGICALS.COM exists, but nothing in the startup calls it."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$   goto syl_done
$ endif
$ bm_par = bm_e'bm_syl'_par
$ bm_sib1 = ""
$ bm_sib2 = ""
$ bm_i = 0
$syl_sib:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto syl_sib_done
$ if bm_i .eq. bm_syl .or. bm_e'bm_i'_par .ne. bm_par .or. bm_par .eq. 0 then goto syl_sib
$ if bm_i .lt. bm_syl then bm_sib1 = bm_sib1 + bm_e'bm_i'_nam + "|"
$ if bm_i .gt. bm_syl then bm_sib2 = bm_sib2 + bm_e'bm_i'_nam + "|"
$ goto syl_sib
$syl_sib_done:
$ bm_wt = "SYLOGICALS.COM runs in the " + bm_e'bm_syl'_pha + " phase"
$ if bm_par .gt. 0 then bm_wt = bm_wt + ", called by " + bm_e'bm_par'_nam
$ if bm_sib1 .nes. ""
$ then
$   bm_cl = bm_sib1
$   gosub join_and
$   bm_wt = bm_wt + " after " + bm_joined
$ endif
$ if bm_sib2 .nes. ""
$ then
$   bm_cl = bm_sib2
$   gosub join_and
$   if bm_sib1 .nes. "" then bm_wt = bm_wt + " and"
$   bm_wt = bm_wt + " before " + bm_joined
$ endif
$ bm_wt = bm_wt + "."
$! What starts after it? Networking, queues and products, normally.
$ bm_early = ""
$ bm_i = 0
$syl_after:
$ bm_i = bm_i + 1
$ if bm_i .ge. bm_syl then goto syl_after_done
$ bm_c = bm_e'bm_i'_cat
$ if bm_e'bm_i'_st .nes. "" then goto syl_after
$ if bm_c .eqs. "Networking" .or. bm_c .eqs. "Databases" .or. -
     bm_c .eqs. "Web" .or. bm_c .eqs. "Product" then -
    bm_early = bm_early + bm_e'bm_i'_nam + "|"
$ goto syl_after
$syl_after_done:
$ if bm_early .eqs. ""
$ then
$   bm_wt = bm_wt + " This is early: the network, the queues and the layered " + -
            "products all start later, so every name it defines is in place " + -
            "for them. That is why it should only define names and mount disks."
$ else
$   bm_cl = bm_early
$   gosub join_and
$   bm_wt = bm_wt + " These start before it and cannot use its names: " + bm_joined + "."
$ endif
$! Its own logicals and those of the procedures it calls.
$ bm_ld = 0
$ bm_lmnt = 0
$ bm_ch = ""
$ bm_i = bm_syl
$syl_kids:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto syl_kids_done
$ if bm_e'bm_i'_dep .le. bm_e'bm_syl'_dep then goto syl_kids_done
$ if bm_e'bm_i'_dep .eq. bm_e'bm_syl'_dep + 1 then bm_ch = bm_ch + bm_e'bm_i'_nam + "|"
$ goto syl_kids
$syl_kids_done:
$ bm_lend = bm_i                            ! first entry after its subtree
$ bm_k = 0
$syl_cnt:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nl then goto syl_cnt2
$ if bm_l'bm_k'_e .ge. bm_syl .and. bm_l'bm_k'_e .lt. bm_lend then bm_ld = bm_ld + 1
$ goto syl_cnt
$syl_cnt2:
$ bm_k = 0
$syl_mnt:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nm then goto syl_mnt_done
$ if bm_m'bm_k'_e .ge. bm_syl .and. bm_m'bm_k'_e .lt. bm_lend then bm_lmnt = bm_lmnt + 1
$ goto syl_mnt
$syl_mnt_done:
$ bm_wt = bm_wt + f$fao(" It defines !UL system logical name!%S", bm_ld)
$ if bm_ch .nes. ""
$ then
$   bm_cl = bm_ch
$   gosub join_and
$   bm_wt = bm_wt + " and calls " + bm_joined
$ endif
$ if bm_lmnt .gt. 0 then bm_wt = bm_wt + f$fao(", mounting !UL disk!%S (see Disks)", bm_lmnt)
$ bm_wt = bm_wt + "."
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap
$ if bm_brief .or. bm_ld .eq. 0 then goto syl_others
$ bm_out = ""
$ bm_vl  = 0
$ gosub say
$ bm_kw = 24
$ bm_k = 0
$syl_list:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nl then goto syl_others
$ if bm_l'bm_k'_e .lt. bm_syl .or. bm_l'bm_k'_e .ge. bm_lend then goto syl_list
$ bm_kn = bm_l'bm_k'_nam
$ bm_v  = bm_l'bm_k'_val
$ bm_note = ""
$ if bm_l'bm_k'_cnd .nes. "" then bm_note = "[if " + bm_l'bm_k'_cnd + "]"
$ if f$locate("'", bm_kn) .ge. f$length(bm_kn) .and. -
     f$trnlnm(bm_kn, "LNM$SYSTEM_TABLE") .eqs. "" .and. -
     f$trnlnm(bm_kn, "LNM$SYSCLUSTER_TABLE") .eqs. "" then -
    bm_note = f$edit(bm_note + " not defined now", "TRIM")
$ gosub kv_note
$ goto syl_list
$syl_others:
$ bm_kw = 18
$! Other procedures defining system logicals: site files by name, products
$! as a count.
$ bm_cl = ""
$ bm_pn2 = 0
$ bm_pd2 = 0
$ bm_i = 0
$syl_oth:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto syl_oth_done
$ if bm_i .ge. bm_syl .and. bm_i .lt. bm_lend then goto syl_oth
$ if bm_e'bm_i'_def .eq. 0 then goto syl_oth
$ if bm_e'bm_i'_mod .eqs. "SITE"
$ then
$   bm_cl = bm_cl + bm_e'bm_i'_nam + f$fao(" (!UL)", bm_e'bm_i'_def) + "|"
$ else
$   bm_pn2 = bm_pn2 + 1
$   bm_pd2 = bm_pd2 + bm_e'bm_i'_def
$ endif
$ goto syl_oth
$syl_oth_done:
$ if bm_pn2 .gt. 0 then bm_cl = bm_cl + -
    f$fao("!UL product startup!%S (!UL name!%S between them)", bm_pn2, bm_pd2) + "|"
$ if bm_cl .nes. ""
$ then
$   gosub join_and
$   bm_wt = "System logical names are also defined by " + bm_joined + "."
$   bm_out = ""
$   bm_vl  = 0
$   gosub say
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap_dim
$ endif
$syl_done:
$!
$!==============================================================================
$! Disks
$!==============================================================================
$ bm_hd = "Disks"
$ gosub heading
$ bm_wt = "The system disk " + bm_sysnam + " (" + bm_syslab + ") is mounted by " + -
          "SYSINIT during the boot, before any startup procedure runs."
$ if bm_nm .eq. 0 then bm_wt = bm_wt + " No startup procedure mounts any other disk."
$ if bm_nm .gt. 0 then bm_wt = bm_wt + f$fao(" The startup files mount !UL more:", bm_nm)
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap
$ if bm_nm .eq. 0 then goto dk_more
$ bm_hdr = f$fao("  !16AS !10AS !14AS !AS", "Device", "Label", "Logical", "Now")
$ bm_out = bm_key + bm_hdr + bm_off
$ bm_vl  = f$length(bm_hdr)
$ gosub say
$ bm_k = 0
$dk_list:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nm then goto dk_more
$ bm_dv = bm_m'bm_k'_dev
$ bm_e  = bm_m'bm_k'_e
$ bm_by = "by " + bm_e'bm_e'_nam
$ bm_up = bm_e'bm_e'_par
$ if bm_up .gt. 0 then bm_by = bm_by + ", called from " + bm_e'bm_up'_nam
$ bm_by = bm_by + " (" + bm_e'bm_e'_pha + " phase)"
$ if bm_m'bm_k'_cnd .nes. "" then bm_by = bm_by + " [if " + bm_m'bm_k'_cnd + "]"
$ bm_now_s = "no such device"
$ bm_now_c = bm_red
$ if f$getdvi(bm_dv, "EXISTS")
$ then
$   bm_now_s = "not mounted"
$   bm_now_c = bm_yel
$   if f$getdvi(bm_dv, "MNT")
$   then
$     bm_now_c = bm_grn
$     bm_mx = f$getdvi(bm_dv, "MAXBLOCK")
$     bm_fb = f$getdvi(bm_dv, "FREEBLOCKS")
$     bm_pc = 0
$     if bm_mx .ge. 100 then bm_pc = (bm_mx - bm_fb) / (bm_mx / 100)
$     bm_now_s = f$fao("mounted, !UL% used", bm_pc)
$   endif
$ endif
$ bm_row = f$fao("  !16AS !10AS !14AS ", bm_dv, bm_m'bm_k'_lab, bm_m'bm_k'_lnm)
$ bm_out = bm_row + bm_now_c + bm_now_s + bm_off
$ bm_vl  = f$length(bm_row) + f$length(bm_now_s)
$ gosub say
$ bm_wt = bm_by
$ bm_wf = "      "
$ bm_wi = 6
$ gosub wrap_dim
$ goto dk_list
$dk_more:
$! Disks mounted now that no startup file mounts.
$ bm_cl = ""
$ bm_dsp = "*"
$dk_scan:
$ bm_dv = f$device(bm_dsp, "DISK")
$ if bm_dv .eqs. "" then goto dk_scanned
$ if .not. f$getdvi(bm_dv, "MNT") then goto dk_scan
$ if f$getdvi(bm_dv, "SHDW_MEMBER") then goto dk_scan
$ if f$getdvi(bm_dv, "FULLDEVNAM") .eqs. bm_sysdev then goto dk_scan
$ bm_fd = f$getdvi(bm_dv, "FULLDEVNAM")
$ bm_k = 0
$dk_match:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nm then goto dk_nomatch
$ if .not. f$getdvi(bm_m'bm_k'_dev, "EXISTS") then goto dk_match
$ if f$getdvi(bm_m'bm_k'_dev, "FULLDEVNAM") .eqs. bm_fd then goto dk_scan
$ goto dk_match
$dk_nomatch:
$ bm_cl = bm_cl + (f$getdvi(bm_dv, "DEVNAM") - "_") + " (" + -
          f$edit(f$getdvi(bm_dv, "VOLNAM"), "TRIM") + ")|"
$ goto dk_scan
$dk_scanned:
$ if bm_cl .nes. ""
$ then
$   gosub join_and
$   bm_wt = "Mounted now, but not by a startup file (by hand or by another " + -
            "procedure): " + bm_joined + "."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ endif
$! Page and swap files.
$ if bm_ng .eq. 0
$ then
$   bm_wt = "No startup file installs a page or swap file; the system uses " + -
            "the primary page file the OS installs at boot."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ else
$   bm_k = 0
$dk_pg:
$   bm_k = bm_k + 1
$   if bm_k .gt. bm_ng then goto dk_pg_done
$   bm_e = bm_g'bm_k'_e
$   bm_wt = bm_g'bm_k'_txt + ", installed by " + bm_e'bm_e'_nam + " (" + -
            bm_e'bm_e'_pha + ")"
$   if bm_g'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_g'bm_k'_cnd + "]"
$   bm_wf = "  - "
$   bm_wi = 4
$   gosub wrap
$   goto dk_pg
$dk_pg_done:
$ endif
$!
$!==============================================================================
$! Networking
$!==============================================================================
$ bm_hd = "Networking"
$ gosub heading
$ bm_cat = "Networking"
$ gosub cat_rows
$ if bm_rows_out .eq. 0 .and. bm_nw .eq. 0
$ then
$   bm_wt = "No network software is started by the startup procedures."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ endif
$ bm_k = 0
$nw_cmd:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nw then goto nw_live
$ bm_e = bm_w'bm_k'_e
$ bm_wt = bm_w'bm_k'_txt + " - in " + bm_e'bm_e'_nam
$ if bm_w'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_w'bm_k'_cnd + "]"
$ bm_wf = "  "
$ bm_wi = 4
$ gosub wrap
$ goto nw_cmd
$nw_live:
$! Running now?
$ bm_run = ""
$ bm_stop = ""
$ bm_k = 0
$nw_np:
$ bm_k = bm_k + 1
$ if f$type(np_'bm_k') .eqs. "" then goto nw_np_done
$ bm_lb = f$element(0, "|", np_'bm_k')
$ bm_pn = f$element(1, "|", np_'bm_k')
$ bm_pt = f$element(2, "|", np_'bm_k')
$ bm_is = f$locate("|" + bm_pn + "|", bm_procs) .lt. f$length(bm_procs)
$ bm_rel = bm_is
$ bm_i = 0
$nw_np_ent:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne .or. bm_rel then goto nw_np_chk
$ if f$locate(bm_pt, bm_e'bm_i'_nam) .lt. f$length(bm_e'bm_i'_nam) then bm_rel = 1
$ goto nw_np_ent
$nw_np_chk:
$ if .not. bm_rel then goto nw_np
$ if bm_is then bm_run = bm_run + bm_lb + "|"
$ if .not. bm_is then bm_stop = bm_stop + bm_lb + "|"
$ goto nw_np
$nw_np_done:
$ if bm_run .nes. "" .or. bm_stop .nes. ""
$ then
$   bm_wt = ""
$   if bm_run .nes. ""
$   then
$     bm_cl = bm_run
$     gosub join_and
$     bm_wt = "Running now: " + bm_joined + "."
$   endif
$   if bm_stop .nes. ""
$   then
$     bm_cl = bm_stop
$     gosub join_and
$     bm_wt = bm_wt + " Not running now: " + bm_joined + "."
$     if .not. bm_world then bm_wt = bm_wt + " (Without WORLD privilege only your own processes can be seen.)"
$   endif
$   bm_out = ""
$   bm_vl  = 0
$   gosub say
$   bm_wt = f$edit(bm_wt, "TRIM")
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ endif
$!
$!==============================================================================
$! Layered products and site software
$!==============================================================================
$ bm_hd = "Layered products and site software"
$ gosub heading
$ bm_any = 0
$ bm_ck = 0
$lp_cat:
$ bm_ck = bm_ck + 1
$ bm_cat = f$element(bm_ck - 1, "|", -
  "Security|Desktop|Development|Databases|Web|Monitoring|Product|Site")
$ if bm_cat .eqs. "|" then goto lp_cat_done
$ bm_cl = ""
$ bm_cn = 0
$ bm_i = 0
$lp_ent:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto lp_ent_done
$ if bm_e'bm_i'_cat .nes. bm_cat .or. bm_e'bm_i'_st .nes. "" then goto lp_ent
$ bm_e = bm_i
$ gosub short_name
$ bm_cl = bm_cl + bm_short + "|"
$ bm_cn = bm_cn + 1
$ goto lp_ent
$lp_ent_done:
$ if bm_cn .eq. 0 then goto lp_cat
$ bm_any = 1
$ bm_cl = f$extract(0, f$length(bm_cl) - 1, bm_cl)
$ bm_wt = ""
$ bm_j = 0
$lp_join:
$ bm_v = f$element(bm_j, "|", bm_cl)
$ if bm_v .eqs. "|" then goto lp_joined
$ if bm_j .gt. 0 then bm_wt = bm_wt + ", "
$ bm_wt = bm_wt + bm_v
$ bm_j = bm_j + 1
$ goto lp_join
$lp_joined:
$ bm_v = bm_cat
$ if bm_v .eqs. "Product" then bm_v = "Other"
$ bm_wf = f$fao("!AS (!UL)", bm_v, bm_cn)
$ bm_wf = f$fao("  !17AS", bm_wf)
$ bm_wi = 19
$ gosub wrap_key
$ goto lp_cat
$lp_cat_done:
$ if .not. bm_any
$ then
$   bm_wt = "No layered products or site software are started at boot."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ endif
$! Where they are started from.
$ bm_cl = ""
$ bm_i = 0
$lp_from:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto lp_from_done
$ bm_c = bm_e'bm_i'_cat
$ if bm_c .eqs. "Base OS" .or. bm_c .eqs. "Hook" .or. bm_c .eqs. "Disks" -
     .or. bm_c .eqs. "Networking" .or. bm_e'bm_i'_st .nes. "" then goto lp_from
$ bm_v = "the layered product database"
$ bm_up = bm_e'bm_i'_par
$ if bm_up .gt. 0 then bm_v = bm_e'bm_up'_nam + " (" + bm_e'bm_up'_pha + " phase)"
$ if f$locate(bm_v + "|", bm_cl) .ge. f$length(bm_cl) then bm_cl = bm_cl + bm_v + "|"
$ goto lp_from
$lp_from_done:
$ if bm_cl .nes. ""
$ then
$   gosub join_and
$   bm_wt = "Started by " + bm_joined + ", in the order shown in the startup chain."
$   bm_out = ""
$   bm_vl  = 0
$   gosub say
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap_dim
$ endif
$! Not installed, missing, disabled, unreadable.
$ bm_sk = 0
$lp_st:
$ bm_sk = bm_sk + 1
$ bm_stx = f$element(bm_sk - 1, "/", "optional, not installed|Optional and not installed|Y/" + -
           "missing|Missing|R/disabled on this node|Disabled on this node|Y/" + -
           "cannot read|Could not be read|Y")
$ if bm_stx .eqs. "/" then goto lp_st_done
$ bm_cl = ""
$ bm_i = 0
$lp_st_ent:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto lp_st_list
$ if bm_e'bm_i'_st .nes. f$element(0, "|", bm_stx) then goto lp_st_ent
$ bm_cl = bm_cl + bm_e'bm_i'_nam + "|"
$ goto lp_st_ent
$lp_st_list:
$ if bm_cl .eqs. "" then goto lp_st
$ gosub join_and
$ bm_wt = f$element(1, "|", bm_stx) + ": " + bm_joined + "."
$ bm_wc = bm_yel
$ if f$element(2, "|", bm_stx) .eqs. "R" then bm_wc = bm_red
$ bm_out = ""
$ bm_vl  = 0
$ gosub say
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap_col
$ goto lp_st
$lp_st_done:
$!
$!==============================================================================
$! Queues, batch jobs and processes
$!==============================================================================
$ bm_hd = "Queues, batch jobs and processes"
$ gosub heading
$ bm_jc = ""
$ bm_i = 0
$qu_jc:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne then goto qu_jc_done
$ if f$locate("JOBCTL", bm_e'bm_i'_nam) .lt. f$length(bm_e'bm_i'_nam) then -
    bm_jc = bm_e'bm_i'_pha
$ goto qu_jc
$qu_jc_done:
$ bm_qm = f$locate("|QUEUE_MANAGER|", bm_procs) .lt. f$length(bm_procs)
$ bm_wt = "The job controller starts"
$ if bm_jc .nes. "" then bm_wt = bm_wt + " in the " + bm_jc + " phase"
$ bm_v = f$trnlnm("QMAN$MASTER")
$ if bm_v .eqs. "" then bm_v = "SYS$COMMON:[SYSEXE]"
$ bm_wt = bm_wt + " and starts the queue manager, which reads the queue " + -
          "database in " + bm_v + ". The queues are started by the site:"
$ if bm_nq .eq. 0 then bm_wt = bm_wt - ":" + " - but no startup procedure starts a queue."
$ bm_wf = ""
$ bm_wi = 0
$ gosub wrap
$ bm_k = 0
$qu_cmd:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nq then goto qu_order
$ bm_e = bm_q'bm_k'_e
$ bm_wt = bm_q'bm_k'_txt + " - in " + bm_e'bm_e'_nam + " (" + bm_e'bm_e'_pha + ")"
$ if bm_q'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_q'bm_k'_cnd + "]"
$ bm_wf = "  - "
$ bm_wi = 4
$ gosub wrap
$ goto qu_cmd
$qu_order:
$! Jobs submitted before the queues start wait until they do.
$ bm_qs1 = 0
$ bm_k = 0
$qu_first:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nq then goto qu_first_done
$ if bm_q'bm_k'_start .and. bm_qs1 .eq. 0 then bm_qs1 = bm_q'bm_k'_seq
$ goto qu_first
$qu_first_done:
$ bm_early = 0
$ bm_k = 0
$qu_early:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_ns then goto qu_early_done
$ if bm_qs1 .gt. 0 .and. bm_s'bm_k'_seq .lt. bm_qs1 then bm_early = bm_early + 1
$ goto qu_early
$qu_early_done:
$ if bm_early .gt. 0
$ then
$   bm_wt = f$fao("!UL batch job!%S !1%Cis!%Eare!%F submitted before the queues " + -
                  "start, so !1%Cit waits!%Ethey wait!%F until they are running.", -
                  bm_early, bm_early, bm_early)
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap_dim
$ endif
$! Queues now.
$ bm_out = ""
$ bm_vl  = 0
$ gosub say
$ bm_hdr = f$fao("  !24AS !16AS !AS", "Queue now", "Type", "State")
$ bm_out = bm_key + bm_hdr + bm_off
$ bm_vl  = f$length(bm_hdr)
$ gosub say
$ bm_nqn = 0
$ bm_junk = f$getqui("CANCEL_OPERATION")
$qu_now:
$ bm_q = f$getqui("DISPLAY_QUEUE", "QUEUE_NAME", "*", "WILDCARD")
$ if bm_q .eqs. "" then goto qu_now_done
$ bm_nqn = bm_nqn + 1
$ bm_qf = "WILDCARD,FREEZE_CONTEXT"
$ bm_qt = "Queue"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_BATCH", "*", bm_qf) then bm_qt = "Batch"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_PRINTER", "*", bm_qf) then bm_qt = "Printer"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_TERMINAL", "*", bm_qf) then bm_qt = "Terminal"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_SERVER", "*", bm_qf) then bm_qt = "Server"
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_GENERIC", "*", bm_qf) then -
    bm_qt = "Generic " + f$edit(bm_qt, "LOWERCASE")
$ bm_qs = "running"
$ bm_qc = bm_grn
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_STOPPED", "*", bm_qf)
$ then
$   bm_qs = "stopped"
$   bm_qc = bm_red
$   if f$locate("Generic", bm_qt) .eq. 0 then bm_qc = bm_yel
$ endif
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_STALLED", "*", bm_qf)
$ then
$   bm_qs = "stalled"
$   bm_qc = bm_yel
$ endif
$ if f$getqui("DISPLAY_QUEUE", "QUEUE_PAUSED", "*", bm_qf)
$ then
$   bm_qs = "paused"
$   bm_qc = bm_yel
$ endif
$ bm_row = f$fao("  !24AS !16AS ", bm_q, bm_qt)
$ bm_out = bm_row + bm_qc + bm_qs + bm_off
$ bm_vl  = f$length(bm_row) + f$length(bm_qs)
$ gosub say
$ goto qu_now
$qu_now_done:
$ if bm_nqn .eq. 0
$ then
$   bm_v = "(none)"
$   if .not. bm_qm then bm_v = "(the queue manager is not running, or cannot be seen)"
$   bm_out = "  " + bm_v
$   bm_vl  = f$length(bm_out)
$   gosub say
$ endif
$! Batch jobs and detached processes started at boot.
$ if bm_ns .gt. 0
$ then
$   bm_out = ""
$   bm_vl  = 0
$   gosub say
$   bm_wt = "Batch jobs submitted at boot:"
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$   bm_k = 0
$qu_sub:
$   bm_k = bm_k + 1
$   if bm_k .gt. bm_ns then goto qu_sub_done
$   bm_e = bm_s'bm_k'_e
$   bm_wt = bm_s'bm_k'_txt + " - by " + bm_e'bm_e'_nam
$   if bm_s'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_s'bm_k'_cnd + "]"
$   bm_wf = "  - "
$   bm_wi = 4
$   gosub wrap
$   goto qu_sub
$qu_sub_done:
$ endif
$ if bm_nd .gt. 0
$ then
$   bm_out = ""
$   bm_vl  = 0
$   gosub say
$   bm_wt = "Detached processes started at boot:"
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$   bm_k = 0
$qu_det:
$   bm_k = bm_k + 1
$   if bm_k .gt. bm_nd then goto qu_det_done
$   bm_e = bm_d'bm_k'_e
$   bm_wt = bm_d'bm_k'_txt + " - by " + bm_e'bm_e'_nam
$   if bm_d'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_d'bm_k'_cnd + "]"
$   bm_pn = f$edit(bm_d'bm_k'_pn, "UPCASE")
$   if bm_pn .nes. "" .and. f$locate("'", bm_pn) .ge. f$length(bm_pn)
$   then
$     if f$locate("|" + bm_pn + "|", bm_procs) .lt. f$length(bm_procs)
$     then
$       bm_wt = bm_wt + "; running now"
$     else
$       bm_wt = bm_wt + "; not running now"
$     endif
$   endif
$   bm_wf = "  - "
$   bm_wi = 4
$   gosub wrap
$   goto qu_det
$qu_det_done:
$ endif
$!
$!==============================================================================
$! Other site settings
$!==============================================================================
$ if bm_nx .eq. 0 then goto ot_done
$ bm_hd = "Other settings made at startup"
$ gosub heading
$ bm_k = 0
$ot_next:
$ bm_k = bm_k + 1
$ if bm_k .gt. bm_nx then goto ot_done
$ bm_e = bm_x'bm_k'_e
$ bm_wt = bm_x'bm_k'_txt + " - in " + bm_e'bm_e'_nam
$ if bm_x'bm_k'_cnd .nes. "" then bm_wt = bm_wt + " [if " + bm_x'bm_k'_cnd + "]"
$ bm_wf = "  - "
$ bm_wi = 4
$ gosub wrap
$ goto ot_next
$ot_done:
$!
$!==============================================================================
$! Last boot
$!==============================================================================
$ bm_hd = "Last boot"
$ gosub heading
$ if bm_logok
$ then
$   gosub fmt_dur
$   bm_wt = "SYS$SPECIFIC:[SYSEXE]STARTUP.LOG records the console output of " + -
            "this boot. Startup began at " + f$extract(0, 20, bm_boot) + -
            " and the log was last written at " + -
            f$extract(0, 20, f$file_attributes(bm_log, "RDT")) + ", " + bm_dtxt + -
            " later."
$   if bm_nlw .eq. 0 then bm_wt = bm_wt + " It holds no warnings or errors."
$   if bm_nlw .gt. 0 then bm_wt = bm_wt + -
      f$fao(" It holds !UL warning or error message!%S:", bm_nlw)
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$   bm_k = 0
$lb_next:
$   bm_k = bm_k + 1
$   if bm_k .gt. bm_nlw .or. bm_k .gt. 10 then goto lb_done
$   bm_wt = bm_lw'bm_k'
$   bm_wf = "  "
$   bm_wi = 4
$   bm_wc = bm_yel
$   gosub wrap_col
$   goto lb_next
$lb_done:
$   if bm_nlw .gt. 10
$   then
$     bm_out = f$fao("  ... and !UL more", bm_nlw - 10)
$     bm_vl  = f$length(bm_out)
$     gosub say
$   endif
$ else
$   bm_wt = "No startup log from this boot"
$   if bm_log .nes. "" then bm_wt = bm_wt + " (the one in SYS$SPECIFIC:[SYSEXE] is from " + -
      f$extract(0, 17, f$file_attributes(bm_log, "CDT")) + ")"
$   bm_wt = bm_wt + ". To keep one, add D to STARTUP_P2 (SYSGEN> SET " + -
            "STARTUP_P2 ""D"" then WRITE CURRENT); the next boot then writes " + -
            "its console output to SYS$SPECIFIC:[SYSEXE]STARTUP.LOG."
$   bm_wf = ""
$   bm_wi = 0
$   gosub wrap
$ endif
$!
$!==============================================================================
$! After startup
$!==============================================================================
$ bm_hd = "After startup"
$ gosub heading
$ bm_v = f$trnlnm("SYS$SYLOGIN")
$ if bm_v .eqs. "" then bm_v = "(not defined)"
$ bm_kn = "Every login"
$ bm_note = ""
$ gosub kv_note
$ bm_kn = "Shutdown"
$ bm_v = "SYS$MANAGER:SYSHUTDWN.COM"
$ if f$search("SYS$MANAGER:SYSHUTDWN.COM") .eqs. "" then bm_v = "(no SYSHUTDWN.COM)"
$ gosub kv_note
$ bm_kn = "Next boot"
$ bm_v = "STARTUP_P1 """ + bm_p1 + """, STARTUP_P2 """ + bm_p2 + """"
$ gosub kv_note
$!
$!---- Footer ------------------------------------------------------------------
$ bm_l = bm_c_ml
$ bm_r = bm_c_mr
$ gosub rule
$ bm_v = f$fao("!UL procedure!%S in the chain", bm_ne)
$ if bm_full then bm_v = bm_v + " (FULL)"
$ if bm_ncnt_miss .gt. 0 then bm_v = bm_v + f$fao(", !UL missing", bm_ncnt_miss)
$ if bm_ncnt_read .gt. 0 then bm_v = bm_v + f$fao(", !UL unreadable", bm_ncnt_read)
$ bm_out = bm_dim + bm_v + bm_off
$ bm_vl  = f$length(bm_v)
$ gosub say
$ bm_l = bm_c_bl
$ bm_r = bm_c_br
$ gosub rule
$ write sys$output ""
$ goto cleanup
$!
$!---- Help --------------------------------------------------------------------
$help:
$ set message 'bm_msg'
$ type sys$input
BOOTMAP - how this OpenVMS system boots and starts up

Usage:   @BOOTMAP [option ...]

  BRIEF    leave out the startup chain tree and the logical name list
  FULL     also follow the procedures that product startups call
  PAGE     pause after each screenful
  PLAIN    no colour or line drawing, even on a terminal that has them
  HELP     show this text

Reads the startup databases and the procedures they lead to (SYLOGICALS,
SYSTARTUP_VMS and everything they call) without running them, and
describes the boot: phases, disks, networking, products, queues, and the
last boot's log. Output to a file is plain text:

  PIPE @BOOTMAP > BOOTMAP.TXT
$ goto cleanup
$!
$!---- Clean up and exit -------------------------------------------------------
$! Ctrl/Y: put the terminal back in its normal character set first.
$interrupted:
$ if f$type(bm_goff) .nes. ""
$ then
$   if bm_goff .nes. "" then write sys$output bm_goff, bm_off
$ endif
$cleanup:
$ bm_k = 0
$cl_close:
$ bm_k = bm_k + 1
$ if f$trnlnm("BM_CH''bm_k'") .nes. "" then close bm_ch'bm_k'
$ if bm_k .lt. 10 then goto cl_close
$ if f$trnlnm("BM_IN") .nes. "" then close bm_in
$ if f$type(bm_prv) .nes. "" then bm_prv = f$setprv(bm_prv)
$ if f$type(bm_msg) .nes. "" then set message 'bm_msg'
$ exit 1 + 0 * f$verify(bm_verify)
$!
$!==============================================================================
$! Subroutines: reading the procedures
$!==============================================================================
$!
$! FIND: bm_found = the file bm_find names (default type .COM), or "".
$! F$SEARCH without wildcards returns a file only every other time it is
$! asked for the same one, so its stream is reset first.
$find:
$ bm_found = ""
$ bm_junk = f$search("SYS$SYSTEM:BOOTMAP$$NONE.NONE", 7)
$ bm_fp = f$parse(bm_find, ".COM")
$ if bm_fp .eqs. "" then return
$ bm_found = f$search(bm_fp, 7)
$ if bm_found .nes. "" then bm_found = f$element(0, ";", bm_found)
$ return
$!
$! ADD_ENTRY: a new entry bm_ne from bm_a_nam, _fil, _dep, _how, _lab,
$! _pha, _st, _cnd, _mod, _par and _db.
$add_entry:
$ bm_ne = bm_ne + 1
$ bm_cn = bm_a_nam
$ if bm_a_fil .nes. "" then bm_cn = f$parse(bm_a_fil,,, "NAME")
$ if bm_cn .eqs. "" then bm_cn = bm_a_nam
$ bm_cmode = bm_a_mod
$ gosub classify
$ bm_e'bm_ne'_nam = bm_cn
$ bm_e'bm_ne'_fil = bm_a_fil
$ bm_e'bm_ne'_dep = bm_a_dep
$ bm_e'bm_ne'_how = bm_a_how
$ bm_e'bm_ne'_lab = bm_a_lab
$ bm_e'bm_ne'_pha = bm_a_pha
$ bm_e'bm_ne'_st  = bm_a_st
$ bm_e'bm_ne'_cnd = bm_a_cnd
$ bm_e'bm_ne'_mod = bm_a_mod
$ bm_e'bm_ne'_par = bm_a_par
$ bm_e'bm_ne'_db  = bm_a_db
$ bm_e'bm_ne'_cat = bm_ccat
$ bm_e'bm_ne'_dsc = bm_cdesc
$ bm_e'bm_ne'_def = 0
$ bm_e'bm_ne'_mnt = 0
$ bm_e'bm_ne'_ins = 0
$ bm_e'bm_ne'_det = 0
$ bm_e'bm_ne'_sub = 0
$ bm_e'bm_ne'_que = 0
$ bm_e'bm_ne'_pgf = 0
$ bm_e'bm_ne'_cal = 0
$ return
$!
$! CLASSIFY: bm_ccat and bm_cdesc for the procedure name bm_cn.
$classify:
$ bm_ccat = ""
$ bm_ck = 0
$cf_cat:
$ bm_ck = bm_ck + 1
$ if f$type(ct_'bm_ck') .eqs. "" then goto cf_default
$ bm_cv = ct_'bm_ck'
$ bm_cl2 = f$element(1, "|", bm_cv)
$ bm_cj = 0
$cf_pat:
$ bm_cp = f$element(bm_cj, ",", bm_cl2)
$ if bm_cp .eqs. "," .or. bm_cp .eqs. "" then goto cf_cat
$ bm_cj = bm_cj + 1
$ if f$locate(bm_cp, bm_cn) .ge. f$length(bm_cn) then goto cf_pat
$ bm_ccat = f$element(0, "|", bm_cv)
$ goto cf_desc
$cf_default:
$ bm_ccat = "Product"
$ if bm_cmode .eqs. "SITE" then bm_ccat = "Site"
$cf_desc:
$ bm_cdesc = ""
$ bm_ck = 0
$cf_ds:
$ bm_ck = bm_ck + 1
$ if f$type(ds_'bm_ck') .eqs. "" then return
$ bm_cp = f$element(0, "|", ds_'bm_ck')
$ if f$locate(bm_cp, bm_cn) .ge. f$length(bm_cn) then goto cf_ds
$ bm_cdesc = f$element(1, "|", ds_'bm_ck')
$ return
$!
$! SCAN: read the procedure of entry bm_root and everything it leads to.
$! The procedures being read form a stack (bm_sd deep), each open on its
$! own channel BM_CH<level>, so a call is followed where it is made and
$! reading resumes after it.
$scan:
$ bm_sd = 1
$ bm_st_e_1 = bm_root
$ bm_st_m_1 = bm_e'bm_root'_mod
$ gosub scan_open
$sc_read:
$ if bm_sd .lt. 1 then return
$ gosub read_cmd
$ if bm_eof
$ then
$   close bm_ch'bm_sd'
$   bm_sd = bm_sd - 1
$   goto sc_read
$ endif
$ bm_push = 0
$ gosub parse_cmd
$ if bm_push .gt. 0
$ then
$   bm_sd = bm_sd + 1
$   bm_st_e_'bm_sd' = bm_push
$   bm_st_m_'bm_sd' = bm_pmod
$   gosub scan_open
$ endif
$ goto sc_read
$!
$! SCAN_OPEN: open the procedure for level bm_sd.
$scan_open:
$ bm_oe = bm_st_e_'bm_sd'
$ bm_ifn_'bm_sd' = 0
$ bm_tab_'bm_sd' = 0
$ bm_of = bm_e'bm_oe'_fil
$ open/read/share=write/error=so_fail bm_ch'bm_sd' 'bm_of'
$ return
$so_fail:
$ bm_e'bm_oe'_st = "cannot read"
$ bm_sd = bm_sd - 1
$ return
$!
$! READ_CMD: the next command from level bm_sd, continuation lines joined
$! and comments removed: bm_o as written, bm_u in capitals. bm_data is 1
$! for a data line (no $), bm_eof at the end of the file.
$read_cmd:
$ bm_o = ""
$ bm_eof = 0
$ bm_data = 0
$rc_next:
$ read/end_of_file=rc_eof/error=rc_eof bm_ch'bm_sd' bm_rec
$ bm_rec = f$edit(bm_rec, "UNCOMMENT,COMPRESS,TRIM")
$ if bm_o .eqs. "" .and. (bm_rec .eqs. "$" .or. bm_rec .eqs. "")  -
     then goto rc_next                       ! comment or blank line
$ if bm_o .eqs. "" .and. f$extract(0, 1, bm_rec) .nes. "$"
$ then
$   if bm_rec .eqs. "" then goto rc_next
$   bm_data = 1
$   bm_o = bm_rec
$   goto rc_done
$ endif
$ bm_rl = f$length(bm_rec)
$ if bm_rl .gt. 0 .and. f$extract(bm_rl - 1, 1, bm_rec) .eqs. "-"
$ then
$   bm_o = bm_o + f$extract(0, bm_rl - 1, bm_rec) + " "
$   goto rc_next
$ endif
$ bm_o = bm_o + bm_rec
$ goto rc_done
$rc_eof:
$ if bm_o .eqs. "" then bm_eof = 1
$rc_done:
$ bm_o = f$edit(bm_o, "COMPRESS,TRIM")
$ bm_u = f$edit(bm_o, "UPCASE")
$ return
$!
$! PARSE_CMD: note what the command in bm_o/bm_u does.
$parse_cmd:
$ bm_md = bm_st_m_'bm_sd'
$ bm_ce = bm_st_e_'bm_sd'
$ bm_c1 = ""                                ! condition of a one-line IF
$ if bm_data
$ then
$   if bm_md .nes. "OS" then gosub act_page
$   return
$ endif
$! Base OS procedures: only their calls into SYS$MANAGER (the site hooks).
$ if bm_md .eqs. "OS" .and. -
     f$locate("@SYS$MANAGER:", bm_u) .ge. f$length(bm_u) then return
$ if f$extract(0, 1, bm_u) .eqs. "$"
$ then
$   bm_o = f$edit(f$extract(1, 9999, bm_o), "TRIM")
$   bm_u = f$edit(f$extract(1, 9999, bm_u), "TRIM")
$ endif
$ if bm_u .eqs. "" then return
$! Products are only counted, so skip quickly what cannot matter to that.
$ if bm_md .eqs. "PROD"
$ then
$   bm_len = f$length(bm_u)
$   if f$locate("|" + f$extract(0, 3, bm_u) + "|", bm_verbs) .ge. -
       f$length(bm_verbs) .and. -
       f$locate("@", bm_u) .ge. bm_len .and. -
       f$locate("MOUNT", bm_u) .ge. bm_len .and. -
       f$locate("FILE", bm_u) .ge. bm_len then return
$ endif
$! Join "VERB /QUAL" into "VERB/QUAL" so qualifiers stay with their word.
$pc_join:
$ bm_pp = f$locate(" /", bm_u)
$ if bm_pp .lt. f$length(bm_u)
$ then
$   bm_u = f$extract(0, bm_pp, bm_u) + f$extract(bm_pp + 1, 9999, bm_u)
$   bm_o = f$extract(0, bm_pp, bm_o) + f$extract(bm_pp + 1, 9999, bm_o)
$   goto pc_join
$ endif
$! A label first?
$ bm_t1 = f$element(0, " ", bm_u)
$ bm_tl = f$length(bm_t1)
$ if bm_tl .gt. 1 .and. f$extract(bm_tl - 1, 1, bm_t1) .eqs. ":" .and. -
     f$locate("[", bm_t1) .ge. bm_tl .and. f$locate("""", bm_t1) .ge. bm_tl
$ then
$   gosub cut_word
$   if bm_u .eqs. "" then return
$ endif
$! IF / THEN / ELSE / ENDIF
$ bm_t1 = f$element(0, " ", bm_u)
$ if bm_t1 .eqs. "ENDIF"
$ then
$   if bm_ifn_'bm_sd' .gt. 0 then bm_ifn_'bm_sd' = bm_ifn_'bm_sd' - 1
$   return
$ endif
$ if bm_t1 .eqs. "THEN"
$ then
$   gosub cut_word
$   if bm_u .eqs. "" then return
$ endif
$ if bm_t1 .eqs. "ELSE"
$ then
$   bm_n = bm_ifn_'bm_sd'
$   if bm_n .gt. 0
$   then
$     if bm_if_'bm_sd'_'bm_n' .nes. "" then -
        bm_if_'bm_sd'_'bm_n' = "not (" + bm_if_'bm_sd'_'bm_n' + ")"
$   endif
$   gosub cut_word
$   if bm_u .eqs. "" then return
$ endif
$ bm_t1 = f$element(0, " ", bm_u)
$ bm_t2 = f$element(1, " ", bm_u)
$ if bm_t2 .eqs. "=" .or. bm_t2 .eqs. "==" .or. bm_t2 .eqs. ":=" then -
    bm_t1 = ""                              ! a symbol named IF
$ if bm_t1 .eqs. "IF" .or. f$extract(0, 3, bm_u) .eqs. "IF("
$ then
$   bm_pt = f$locate(" THEN", bm_u)
$   if bm_pt .ge. f$length(bm_u)
$   then
$     bm_cond = f$extract(2, 9999, bm_o)
$     gosub tidy_cond
$     gosub push_if
$     return
$   endif
$   bm_cond = f$extract(2, bm_pt - 2, bm_o)
$   gosub tidy_cond
$   bm_u = f$edit(f$extract(bm_pt + 5, 9999, bm_u), "TRIM")
$   bm_o = f$edit(f$extract(bm_pt + 5, 9999, bm_o), "TRIM")
$   if bm_u .eqs. ""
$   then
$     gosub push_if
$     return
$   endif
$   bm_c1 = bm_cond
$   if f$extract(0, 1, bm_u) .eqs. "$"
$   then
$     bm_u = f$edit(f$extract(1, 9999, bm_u), "TRIM")
$     bm_o = f$edit(f$extract(1, 9999, bm_o), "TRIM")
$   endif
$ endif
$! The condition that applies: the one-line IF's, else the innermost block's.
$ bm_cond = bm_c1
$ bm_n = bm_ifn_'bm_sd'
$pc_cond:
$ if bm_cond .nes. "" .or. bm_n .le. 0 then goto pc_cond_done
$ bm_cond = bm_if_'bm_sd'_'bm_n'
$ bm_n = bm_n - 1
$ goto pc_cond
$pc_cond_done:
$ bm_guard = 0                              ! only runs if the file exists
$ if bm_cond .eqs. "?FS"
$ then
$   bm_guard = 1
$   bm_cond = ""
$ endif
$ bm_t1 = f$element(0, " ", bm_u)
$ bm_vb = f$element(0, "/", bm_t1)
$ bm_vq = f$extract(f$length(bm_vb), 999, bm_t1)
$ bm_vl2 = f$length(bm_vb)
$ bm_rest_u = f$edit(f$extract(f$length(bm_t1), 9999, bm_u), "TRIM")
$ bm_rest_o = f$edit(f$extract(f$length(bm_t1), 9999, bm_o), "TRIM")
$!
$! @procedure
$ if f$extract(0, 1, bm_vb) .eqs. "@"
$ then
$   bm_spec = f$extract(1, 999, bm_t1)
$   bm_params = bm_rest_u
$   if bm_spec .eqs. ""
$   then
$     bm_spec = f$element(0, " ", bm_rest_u)
$     bm_params = f$edit(f$extract(f$length(bm_spec), 9999, bm_rest_u), "TRIM")
$   endif
$   bm_how = "@"
$   bm_tlab = ""
$   bm_topt = 0
$   if bm_md .nes. "OS" .or. f$locate("SYS$MANAGER:", bm_spec) .eq. 0 then -
      gosub do_call
$   return
$ endif
$ if bm_md .eqs. "OS" then return
$! A symbol holding a procedure name: name = "label|procedure|OPTIONAL"
$ bm_t2 = f$element(1, " ", bm_u)
$ if bm_t2 .eqs. "=" .or. bm_t2 .eqs. "==" .or. bm_t2 .eqs. ":=" .or. -
     bm_t2 .eqs. ":==" .or. f$locate("=""", bm_t1) .lt. f$length(bm_t1)
$ then
$   if f$locate("""", bm_u) .lt. f$length(bm_u) then gosub table_entry
$   return
$ endif
$! Page and swap files, wherever they are installed from.
$ gosub act_page
$ if bm_got then return
$! MOUNT, as a command or as a word after a symbol (MSCPMOUNT's style).
$ gosub act_mount
$ if bm_got then return
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "DEFINE") .or. -
     bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "ASSIGN")
$ then
$   gosub act_define
$   return
$ endif
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "START")
$ then
$   gosub act_start
$   return
$ endif
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "INITIALIZE") .and. -
     f$locate("/QUE", bm_vq) .lt. f$length(bm_vq)
$ then
$   bm_qn = f$element(0, "/", f$element(0, " ", bm_rest_o))
$   bm_qt = "print"
$   if f$locate("/BAT", bm_u) .lt. f$length(bm_u) then bm_qt = "batch"
$   if f$locate("/GEN", bm_u) .lt. f$length(bm_u) then bm_qt = "generic"
$   bm_txt = "Creates " + bm_qt + " queue " + bm_qn
$   bm_qstart = 0
$   if f$locate("/STAR", bm_u) .lt. f$length(bm_u)
$   then
$     bm_txt = bm_txt + " and starts it"
$     bm_qstart = 1
$   endif
$   gosub add_queue
$   return
$ endif
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "ENABLE") .and. -
     f$extract(0, 4, bm_rest_u) .eqs. "AUTO"
$ then
$   bm_txt = "Enables autostart queues"
$   if f$locate("/QUE", bm_rest_u) .ge. f$length(bm_rest_u) then -
      bm_txt = "Enables autostart"
$   bm_qstart = 1
$   gosub add_queue
$   return
$ endif
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "SUBMIT")
$ then
$   gosub act_submit
$   return
$ endif
$ if bm_vb .eqs. "RUN" .or. bm_vb .eqs. "RU"
$ then
$   gosub act_run
$   return
$ endif
$ if bm_vb .eqs. "MCR" .and. f$element(0, " ", bm_rest_u) .eqs. "INSTALL"
$ then
$   bm_vb = "INSTALL"
$   bm_vl2 = 7
$   bm_rest_u = f$edit(f$extract(7, 9999, bm_rest_u), "TRIM")
$ endif
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "INSTALL")
$ then
$   bm_t2 = f$extract(0, 3, bm_rest_u)
$   if bm_t2 .eqs. "ADD" .or. bm_t2 .eqs. "CRE" .or. bm_t2 .eqs. "REP" .or. -
       f$locate("/OPE", bm_rest_u) .lt. f$length(bm_rest_u) .or. -
       f$locate("/SHA", bm_rest_u) .lt. f$length(bm_rest_u) .or. -
       f$locate("/HEA", bm_rest_u) .lt. f$length(bm_rest_u) .or. -
       f$locate("/PRIV", bm_rest_u) .lt. f$length(bm_rest_u) then -
      bm_e'bm_ce'_ins = bm_e'bm_ce'_ins + 1
$   return
$ endif
$ if bm_md .eqs. "PROD" .and. .not. bm_full then return
$ if bm_vb .eqs. "SET" then gosub act_set
$ if bm_vl2 .ge. 3 .and. bm_vb .eqs. f$extract(0, bm_vl2, "LICENSE")
$ then
$   bm_t2 = f$element(0, "/", f$element(0, " ", bm_rest_u))
$   if f$extract(0, 3, bm_t2) .eqs. "LOA" .or. f$extract(0, 3, bm_t2) .eqs. "REG"
$   then
$     bm_txt = "Loads or registers licences (LICENSE " + bm_t2 + ")"
$     gosub add_other
$   endif
$ endif
$ return
$!
$! CUT_WORD: drop the first word of bm_o/bm_u.
$cut_word:
$ bm_cw1 = f$length(f$element(0, " ", bm_u))
$ bm_u = f$edit(f$extract(bm_cw1, 9999, bm_u), "TRIM")
$ bm_o = f$edit(f$extract(bm_cw1, 9999, bm_o), "TRIM")
$ return
$!
$! PUSH_IF: an IF block opens with condition bm_cond.
$push_if:
$ bm_ifn_'bm_sd' = bm_ifn_'bm_sd' + 1
$ bm_n = bm_ifn_'bm_sd'
$ bm_if_'bm_sd'_'bm_n' = bm_cond
$ return
$!
$! TIDY_COND: shorten bm_cond; tests for a file's existence are dropped,
$! because the report already says whether each file exists.
$tidy_cond:
$ bm_cond = f$edit(bm_cond, "COMPRESS,TRIM")
$ bm_cu = f$edit(bm_cond, "UPCASE")
$ if f$locate("$STATUS", bm_cu) .lt. f$length(bm_cu) .or. -
     f$locate("$SEVERITY", bm_cu) .lt. f$length(bm_cu) then bm_cond = ""
$ if f$locate("F$SEARCH", bm_cu) .lt. f$length(bm_cu) then bm_cond = "?FS"
$ if f$extract(0, 1, bm_cond) .eqs. "(" .and. -
     f$extract(f$length(bm_cond) - 1, 1, bm_cond) .eqs. ")" then -
    bm_cond = f$extract(1, f$length(bm_cond) - 2, bm_cond)
$ if f$length(bm_cond) .gt. 40 then bm_cond = f$extract(0, 37, bm_cond) + "..."
$ return
$!
$! DO_CALL: a call of bm_spec (parameters bm_params) from the current
$! procedure, made directly (bm_how "@") or through a table entry ("T",
$! label bm_tlab, bm_topt if it may be absent). Adds the entry and sets
$! bm_push when it should be read next.
$do_call:
$ bm_pe = bm_ce
$ if bm_spec .eqs. "" then return
$ if f$locate("'", bm_spec) .lt. f$length(bm_spec) .or. -
     f$locate("*", bm_spec) .lt. f$length(bm_spec) .or. -
     f$locate("%", bm_spec) .lt. f$length(bm_spec)
$ then
$   if bm_tab_'bm_sd' .gt. 0 then return    ! a table loop: entries listed
$   if bm_md .eqs. "PROD" .and. .not. bm_full
$   then
$     bm_e'bm_pe'_cal = bm_e'bm_pe'_cal + 1
$     return
$   endif
$   bm_a_nam = "@" + bm_spec
$   bm_a_fil = ""
$   bm_a_st  = "name set at run time"
$   bm_pmod  = "SITE"
$   if bm_md .eqs. "PROD" then bm_pmod = "PROD"
$   gosub dc_add
$   return
$ endif
$ bm_cn = f$parse(bm_spec,,, "NAME", "SYNTAX_ONLY")
$ if bm_cn .eqs. "" then return
$ if f$locate("MOUNT", bm_cn) .lt. f$length(bm_cn) .and. bm_params .nes. "" -
     then gosub mount_params
$ if bm_md .eqs. "PROD" .and. .not. bm_full
$ then
$   bm_e'bm_pe'_cal = bm_e'bm_pe'_cal + 1
$   return
$ endif
$ bm_pf = bm_e'bm_pe'_fil
$ bm_find = f$parse(bm_spec, f$parse(bm_pf,,, "DEVICE") + -
            f$parse(bm_pf,,, "DIRECTORY") + ".COM",,, "SYNTAX_ONLY")
$ if bm_find .eqs. "" then bm_find = bm_spec
$ gosub find
$! A table entry that names no file we can find, and does not look like a
$! startup procedure, is some other string: ignore it.
$ if bm_how .eqs. "T" .and. bm_found .eqs. "" .and. -
     f$locate(".COM", bm_spec) .ge. f$length(bm_spec) .and. -
     f$locate("STARTUP", bm_spec) .ge. f$length(bm_spec) then return
$ if bm_md .eqs. "OS" .and. bm_found .eqs. "" then return
$ if bm_how .eqs. "T" then bm_tab_'bm_sd' = bm_tab_'bm_sd' + 1
$! Read it as a site procedure, unless it is a product's or the OS's own.
$ bm_pmod = "SITE"
$ bm_fu = f$edit(bm_found, "UPCASE")
$ if f$locate("SYS$STARTUP", bm_spec) .eq. 0 .or. -
     f$locate("[SYS$STARTUP]", bm_fu) .lt. f$length(bm_fu) .or. -
     f$locate("SYS$SYSTEM:", bm_spec) .eq. 0 .or. -
     f$locate("[SYSEXE]", bm_fu) .lt. f$length(bm_fu) .or. -
     f$locate("[SYSUPD]", bm_fu) .lt. f$length(bm_fu) then bm_pmod = "PROD"
$ bm_cmode = "SITE"
$ gosub classify
$ if bm_ccat .nes. "Hook" .and. bm_ccat .nes. "Disks" .and. -
     bm_ccat .nes. "Site" then bm_pmod = "PROD"
$ if bm_md .eqs. "PROD" then bm_pmod = "PROD"
$ bm_a_nam = bm_cn
$ bm_a_fil = bm_found
$ bm_a_st  = ""
$ if bm_found .eqs. "" then bm_a_st = "missing"
$ if bm_found .eqs. "" .and. (bm_topt .or. bm_guard) then -
    bm_a_st = "optional, not installed"
$! Inside a product's startup a missing file is usually an unused option.
$ if bm_found .eqs. "" .and. bm_md .eqs. "PROD" then bm_a_st = "not present"
$! Already read once (a procedure called twice)?
$ if bm_found .nes. ""
$ then
$   bm_k = 0
$dc_seen:
$   bm_k = bm_k + 1
$   if bm_k .gt. bm_ne then goto dc_new
$   if bm_e'bm_k'_fil .nes. bm_found then goto dc_seen
$   bm_a_st = "again"
$ endif
$dc_new:
$ gosub dc_add
$ if bm_found .eqs. "" .or. bm_a_st .nes. "" then return
$ if bm_sd .ge. bm_maxdep .or. bm_sd .ge. 9 then return
$! Never follow into the OS's own tools (AUTOGEN, STARTUP, SHUTDOWN ...).
$ if f$locate("[SYSEXE]", bm_fu) .lt. f$length(bm_fu) .or. -
     f$locate("[SYSUPD]", bm_fu) .lt. f$length(bm_fu) .or. -
     f$locate("[SYSLIB]", bm_fu) .lt. f$length(bm_fu) then return
$ bm_push = bm_ne
$ return
$!
$! DC_ADD: add the called entry below the current one.
$dc_add:
$ bm_a_dep = bm_e'bm_pe'_dep + 1
$ bm_a_how = bm_how
$ bm_a_lab = bm_tlab
$ bm_a_pha = bm_e'bm_pe'_pha
$ bm_a_cnd = bm_cond
$ bm_a_mod = bm_pmod
$ bm_a_par = bm_pe
$ bm_a_db  = bm_e'bm_pe'_db
$ gosub add_entry
$ return
$!
$! TABLE_ENTRY: an assignment of a quoted string. If one of its |-separated
$! parts names a procedure, treat it as a call (see SYSTARTUP_VMS lists).
$table_entry:
$ bm_val = f$element(1, """", bm_o)
$ bm_vu  = f$edit(bm_val, "UPCASE")
$ if f$locate("|", bm_vu) .ge. f$length(bm_vu) .and. -
     f$locate(".COM", bm_vu) .ge. f$length(bm_vu) .and. -
     f$locate("STARTUP", bm_vu) .ge. f$length(bm_vu) then return
$ bm_spec = ""
$ bm_tlab = ""
$ bm_topt = 0
$ bm_params = ""
$ bm_j = 0
$te_el:
$ bm_el = f$element(bm_j, "|", bm_val)
$ if bm_el .eqs. "|" then goto te_done
$ bm_elu = f$edit(bm_el, "UPCASE,TRIM")
$ if bm_elu .eqs. "OPTIONAL" then bm_topt = 1
$ bm_w1 = f$element(0, " ", bm_elu)
$ if bm_spec .eqs. "" .and. f$locate("'", bm_w1) .ge. f$length(bm_w1) .and. -
     (f$locate(":", bm_w1) .lt. f$length(bm_w1) .or. -
      f$locate("]", bm_w1) .lt. f$length(bm_w1) .or. -
      f$locate(".COM", bm_w1) .lt. f$length(bm_w1))
$ then
$   bm_spec = bm_w1
$   bm_params = f$edit(f$extract(f$length(bm_w1), 999, bm_elu), "TRIM")
$   if bm_j .gt. 0 then bm_tlab = f$edit(f$element(0, "|", bm_val), "TRIM")
$ endif
$ bm_j = bm_j + 1
$ goto te_el
$te_done:
$ if bm_spec .eqs. "" then return
$ bm_how = "T"
$ gosub do_call
$ return
$!
$! MOUNT_PARAMS: a mount helper called with parameters, such as
$! @CLU_DISK_MOUNT device label logical or @MSCPMOUNT MOUNT device label.
$mount_params:
$ bm_mp = bm_params
$ if f$element(0, " ", bm_mp) .eqs. "MOUNT" .or. -
     f$element(0, " ", bm_mp) .eqs. """MOUNT""" then -
    bm_mp = f$edit(f$extract(f$length(f$element(0, " ", bm_mp)), 999, bm_mp), "TRIM")
$ bm_mdv = f$element(0, " ", bm_mp) - """" - """"
$ if bm_mdv .eqs. "" .or. f$locate("'", bm_mdv) .lt. f$length(bm_mdv) then return
$ if f$extract(0, 1, bm_mdv) .eqs. "P" .and. f$length(bm_mdv) .eq. 2 then return
$ bm_mlb = f$element(1, " ", bm_mp) - """" - """"
$ bm_mln = f$element(2, " ", bm_mp) - """" - """"
$ if bm_mlb .eqs. " " then bm_mlb = ""
$ if bm_mln .eqs. " " then bm_mln = ""
$ gosub add_mount
$ return
$!
$! ACT_MOUNT: bm_got = 1 if this command mounts a disk.
$act_mount:
$ bm_got = 0
$ bm_j = 0
$am_tok:
$ bm_tk = f$element(bm_j, " ", bm_u)
$ if bm_tk .eqs. " " .or. bm_tk .eqs. "" then return
$ bm_tv = f$element(0, "/", bm_tk)
$ bm_tvl = f$length(bm_tv)
$ if bm_j .eq. 0 .and. bm_tvl .ge. 3 .and. bm_tv .eqs. f$extract(0, bm_tvl, "MOUNT") -
     then goto am_found
$ if bm_j .gt. 0 .and. bm_tv .eqs. "MOUNT" then goto am_found
$ if f$locate("""", bm_tk) .lt. f$length(bm_tk) then return  ! in a string
$ bm_j = bm_j + 1
$ if bm_j .gt. 3 then return
$ goto am_tok
$am_found:
$ bm_got = 1
$ bm_mx = 0
$ bm_mdv = ""
$ bm_mlb = ""
$ bm_mln = ""
$am_arg:
$ bm_j = bm_j + 1
$ bm_tk = f$element(bm_j, " ", bm_o)
$ if bm_tk .eqs. " " .or. bm_tk .eqs. "" then goto am_done
$ bm_tk = f$element(0, "/", bm_tk)
$ if bm_tk .eqs. "" .or. f$locate("'", bm_tk) .lt. f$length(bm_tk) then goto am_arg
$ bm_tk = bm_tk - """" - """"
$ bm_mx = bm_mx + 1
$ if bm_mx .eq. 1 then bm_mdv = f$edit(bm_tk, "UPCASE")
$ if bm_mx .eq. 2 then bm_mlb = bm_tk
$ if bm_mx .eq. 3 then bm_mln = f$edit(bm_tk, "UPCASE")
$ goto am_arg
$am_done:
$ if bm_mdv .eqs. "" then return
$ gosub add_mount
$ return
$!
$! ADD_MOUNT: record a mount of bm_mdv (label bm_mlb, logical bm_mln).
$add_mount:
$ bm_nm = bm_nm + 1
$ if bm_mln .eqs. "" .and. bm_mlb .nes. "" then -
    bm_mln = "DISK$" + f$edit(bm_mlb, "UPCASE")
$ bm_m'bm_nm'_dev = bm_mdv
$ bm_m'bm_nm'_lab = bm_mlb
$ bm_m'bm_nm'_lnm = bm_mln
$ bm_m'bm_nm'_e   = bm_ce
$ bm_m'bm_nm'_cnd = bm_cond
$ bm_e'bm_ce'_mnt = bm_e'bm_ce'_mnt + 1
$ return
$!
$! ACT_PAGE: bm_got = 1 if this installs a page or swap file.
$act_page:
$ bm_got = 0
$ bm_pt = "page"
$ bm_pp = f$locate("/PAGEFILE", bm_u)
$ if bm_pp .ge. f$length(bm_u)
$ then
$   bm_pp = f$locate("/SWAPFILE", bm_u)
$   bm_pt = "swap"
$ endif
$ if bm_pp .ge. f$length(bm_u) then return
$ if f$locate("INSTALL", bm_u) .ge. f$length(bm_u) .and. -
     f$locate("CREATE", bm_u) .ge. f$length(bm_u) then return
$ bm_got = 1
$! The file is the word holding the qualifier, or the one after INSTALL.
$ bm_j = 0
$ bm_pf = ""
$ap_tok:
$ bm_tk = f$element(bm_j, " ", bm_u)
$ if bm_tk .eqs. " " .or. bm_tk .eqs. "" then goto ap_done
$ bm_j = bm_j + 1
$ bm_t0 = f$element(0, "/", bm_tk)
$ if bm_t0 .eqs. "" .or. bm_t0 .eqs. "SYSGEN" .or. bm_t0 .eqs. "MCR" .or. -
     bm_t0 .eqs. "INSTALL" .or. bm_t0 .eqs. "CREATE" then goto ap_tok
$ if bm_pf .eqs. "" then bm_pf = bm_t0
$ goto ap_tok
$ap_done:
$ bm_ng = bm_ng + 1
$ bm_g'bm_ng'_txt = "Installs " + bm_pt + " file " + bm_pf
$ bm_junk = f$search("SYS$SYSTEM:BOOTMAP$$NONE.NONE", 8)
$ if bm_pf .nes. "" .and. f$locate("'", bm_pf) .ge. f$length(bm_pf)
$ then
$   if f$search(bm_pf, 8) .eqs. "" then bm_g'bm_ng'_txt = -
      bm_g'bm_ng'_txt + " (not present now, so skipped)"
$ endif
$ bm_g'bm_ng'_e   = bm_ce
$ bm_g'bm_ng'_cnd = ""
$ if f$type(bm_cond) .nes. "" then bm_g'bm_ng'_cnd = bm_cond
$ if bm_data then bm_g'bm_ng'_cnd = ""
$ bm_e'bm_ce'_pgf = bm_e'bm_ce'_pgf + 1
$ return
$!
$! ACT_DEFINE: a system logical name (DEFINE/SYSTEM or /TABLE=LNM$SYSTEM).
$act_define:
$ if f$locate("/KEY", bm_u) .lt. f$length(bm_u) .or. -
     f$locate("/CHAR", bm_vq) .lt. f$length(bm_vq) then return
$ if f$locate("/FORM", bm_vq) .lt. f$length(bm_vq)
$ then
$   if bm_md .eqs. "PROD" .and. .not. bm_full then return
$   bm_txt = "Defines form " + f$element(0, " ", bm_rest_o)
$   bm_qstart = 0
$   gosub add_queue
$   return
$ endif
$ if f$locate("/SYS", bm_u) .ge. f$length(bm_u) .and. -
     f$locate("LNM$SYS", bm_u) .ge. f$length(bm_u) .and. -
     f$locate("CLUSTER_SYS", bm_u) .ge. f$length(bm_u) then return
$ bm_e'bm_ce'_def = bm_e'bm_ce'_def + 1
$ if bm_md .eqs. "PROD" then return
$ bm_ln = f$element(0, "/", f$element(0, " ", bm_rest_o))
$ bm_lv = f$edit(f$extract(f$length(f$element(0, " ", bm_rest_o)), 9999, bm_rest_o), "TRIM")
$ bm_nl = bm_nl + 1
$ bm_l'bm_nl'_nam = f$edit(bm_ln, "UPCASE")
$ bm_l'bm_nl'_val = bm_lv
$ bm_l'bm_nl'_e   = bm_ce
$ bm_l'bm_nl'_cnd = bm_cond
$ return
$!
$! ACT_START: START/QUEUE[/MANAGER] and START/NETWORK.
$act_start:
$ if f$locate("/NET", bm_vq) .lt. f$length(bm_vq)
$ then
$   bm_nw = bm_nw + 1
$   bm_w'bm_nw'_txt = "Starts DECnet Phase IV (START/NETWORK " + bm_rest_o + ")"
$   bm_w'bm_nw'_e   = bm_ce
$   bm_w'bm_nw'_cnd = bm_cond
$   return
$ endif
$ if f$locate("/QUE", bm_vq) .ge. f$length(bm_vq) then return
$ bm_qstart = 1
$ if f$locate("/MAN", bm_vq) .lt. f$length(bm_vq)
$ then
$   bm_txt = "Starts the queue manager"
$ else
$   bm_txt = "Starts queue " + f$element(0, "/", f$element(0, " ", bm_rest_o))
$ endif
$ gosub add_queue
$ return
$!
$! ADD_QUEUE: record queue command bm_txt (bm_qstart if it starts queues).
$add_queue:
$ bm_nq = bm_nq + 1
$ bm_seq = bm_seq + 1
$ bm_q'bm_nq'_txt = bm_txt
$ bm_q'bm_nq'_e   = bm_ce
$ bm_q'bm_nq'_cnd = bm_cond
$ bm_q'bm_nq'_seq = bm_seq
$ bm_q'bm_nq'_start = bm_qstart
$ bm_e'bm_ce'_que = bm_e'bm_ce'_que + 1
$ return
$!
$! ACT_SUBMIT: a batch job.
$act_submit:
$ bm_e'bm_ce'_sub = bm_e'bm_ce'_sub + 1
$ bm_sf = ""
$ bm_j = 0
$as_tok:
$ bm_tk = f$element(bm_j, " ", bm_rest_o)
$ if bm_tk .eqs. " " .or. bm_tk .eqs. "" then goto as_done
$ bm_j = bm_j + 1
$ bm_t0 = f$element(0, "/", bm_tk)
$ if bm_t0 .eqs. "" then goto as_tok
$ bm_sf = bm_t0
$as_done:
$ bm_txt = "Submits " + bm_sf
$ bm_v = ""
$ bm_kw2 = "/NAME="
$ gosub qual_val
$ if bm_v .nes. "" then bm_txt = bm_txt + " as " + bm_v
$ bm_kw2 = "/QUEUE="
$ gosub qual_val
$ if bm_v .eqs. ""
$ then
$   bm_kw2 = "/QUE="
$   gosub qual_val
$ endif
$ if bm_v .nes. "" then bm_txt = bm_txt + " to " + bm_v
$ bm_ns = bm_ns + 1
$ bm_seq = bm_seq + 1
$ bm_s'bm_ns'_txt = bm_txt
$ bm_s'bm_ns'_e   = bm_ce
$ bm_s'bm_ns'_cnd = bm_cond
$ bm_s'bm_ns'_seq = bm_seq
$ return
$!
$! ACT_RUN: a detached process (RUN/DETACHED, /PROCESS_NAME or LOGINOUT).
$act_run:
$ if f$locate("/DET", bm_u) .ge. f$length(bm_u) .and. -
     f$locate("/PROC", bm_u) .ge. f$length(bm_u) .and. -
     f$locate("LOGINOUT", bm_u) .ge. f$length(bm_u) then return
$ bm_e'bm_ce'_det = bm_e'bm_ce'_det + 1
$ bm_img = f$element(0, "/", f$element(0, " ", bm_rest_o))
$ bm_v = ""
$ bm_kw2 = "/PROCESS_NAME="
$ gosub qual_val
$ if bm_v .eqs. ""
$ then
$   bm_kw2 = "/PROC="
$   gosub qual_val
$ endif
$ bm_txt = "Runs " + f$parse(bm_img,,, "NAME", "SYNTAX_ONLY")
$ if bm_img .eqs. "" .or. f$locate("'", bm_img) .lt. f$length(bm_img) then -
    bm_txt = "Runs a program"
$ if f$locate("LOGINOUT", bm_u) .lt. f$length(bm_u)
$ then
$   bm_kw2 = "/INPUT="
$   bm_pn = bm_v
$   gosub qual_val
$   bm_txt = "Runs procedure " + bm_v
$   if bm_v .eqs. "" .or. f$locate("'", bm_v) .lt. f$length(bm_v) then -
      bm_txt = "Runs a procedure"
$   bm_v = bm_pn
$ endif
$ if bm_v .nes. "" then bm_txt = bm_txt + " as process " + bm_v
$ bm_nd = bm_nd + 1
$ bm_d'bm_nd'_txt = bm_txt
$ bm_d'bm_nd'_pn  = bm_v
$ bm_d'bm_nd'_e   = bm_ce
$ bm_d'bm_nd'_cnd = bm_cond
$ return
$!
$! QUAL_VAL: bm_v = the value of qualifier bm_kw2 (e.g. "/NAME=") in bm_o.
$qual_val:
$ bm_v = ""
$ bm_pq = f$locate(bm_kw2, bm_u)
$ if bm_pq .ge. f$length(bm_u) then return
$ bm_v = f$extract(bm_pq + f$length(bm_kw2), 999, bm_o)
$ bm_v = f$element(0, " ", f$element(0, "/", bm_v)) - """" - """"
$ return
$!
$! ACT_SET: a few SET commands worth knowing about.
$act_set:
$ bm_t2 = f$element(0, "/", f$element(0, " ", bm_rest_u))
$ bm_t2l = f$length(bm_t2)
$ if bm_t2l .lt. 3 then return
$ bm_txt = ""
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "LOGINS")
$ then
$   bm_kw2 = "/INTERACTIVE="
$   gosub qual_val
$   if bm_v .eqs. ""
$   then
$     bm_kw2 = "/INTER="
$     gosub qual_val
$   endif
$   bm_txt = "Sets the interactive login limit"
$   if bm_v .nes. "" then bm_txt = bm_txt + " to " + bm_v
$ endif
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "ACCOUNTING") then -
    bm_txt = "Changes accounting (SET " + bm_rest_o + ")"
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "AUDIT") then -
    bm_txt = "Changes security auditing (SET " + bm_rest_o + ")"
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "TERMINAL") .and. -
     f$locate("/PERM", bm_rest_u) .lt. f$length(bm_rest_u) then -
    bm_txt = "Sets up terminal " + f$element(0, "/", f$element(1, " ", bm_rest_o))
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "DEVICE") .and. -
     f$locate("/SERV", bm_rest_u) .lt. f$length(bm_rest_u) then -
    bm_txt = "Serves a disk to the cluster (SET " + bm_rest_o + ")"
$ if bm_t2 .eqs. f$extract(0, bm_t2l, "HOST") .and. -
     f$locate("/DUP", bm_rest_u) .lt. f$length(bm_rest_u) then bm_txt = ""
$ if bm_txt .eqs. "" then return
$ if f$length(bm_txt) .gt. 90 then bm_txt = f$extract(0, 87, bm_txt) + "..."
$ gosub add_other
$ return
$!
$! ADD_OTHER: record setting bm_txt.
$add_other:
$ bm_nx = bm_nx + 1
$ bm_x'bm_nx'_txt = bm_txt
$ bm_x'bm_nx'_e   = bm_ce
$ bm_x'bm_nx'_cnd = bm_cond
$ return
$!
$!==============================================================================
$! Subroutines: writing the report
$!==============================================================================
$!
$! SAY: write bm_out inside the box (bm_vl = its visible length). With PAGE,
$! close the box when the screen is full, pause, and reopen it.
$say:
$ if bm_rows .gt. 0 .and. bm_lines .ge. bm_rows - 2
$ then
$   write sys$output " ", bm_gon, bm_c_bl, bm_hline, bm_c_br, bm_goff
$   read/prompt="  -- Press RETURN for more, Ctrl/Z to stop -- " -
         /end_of_file=cleanup/error=cleanup sys$command bm_nada
$   write sys$output " ", bm_gon, bm_c_tl, bm_hline, bm_c_tr, bm_goff
$   bm_lines = 1
$ endif
$ bm_fill = bm_cw - bm_vl
$ bm_sp2 = ""
$ if bm_fill .gt. 0 then bm_sp2 = f$fao("!''bm_fill'* ")
$ write sys$output " ", bm_gon, bm_c_v, bm_goff, " ", bm_out, bm_sp2, " ", -
                   bm_gon, bm_c_v, bm_goff
$ bm_lines = bm_lines + 1
$ return
$!
$! RULE: a line across the box, ending in bm_l and bm_r.
$rule:
$ write sys$output " ", bm_gon, bm_l, bm_hline, bm_r, bm_goff
$ bm_lines = bm_lines + 1
$ return
$!
$! HEADING: start a new section of the box titled bm_hd.
$heading:
$ bm_l = bm_c_ml
$ bm_r = bm_c_mr
$ gosub rule
$ bm_out = bm_head + bm_hd + bm_off
$ bm_vl  = f$length(bm_hd)
$ gosub say
$ return
$!
$! WRAP: write the plain text bm_wt word-wrapped to the box, the first line
$! starting with bm_wf and later ones indented bm_wi spaces. WRAP_KEY shows
$! bm_wf in the label colour, WRAP_DIM and WRAP_COL colour the text (bm_wc).
$wrap_key:
$ bm_wkc = bm_key
$ bm_wtc = ""
$ goto wr_start
$wrap_dim:
$ bm_wkc = ""
$ bm_wtc = bm_dim
$ goto wr_start
$wrap_col:
$ bm_wkc = ""
$ bm_wtc = bm_wc
$ goto wr_start
$wrap:
$ bm_wkc = ""
$ bm_wtc = ""
$wr_start:
$ bm_wlead = bm_wkc + bm_wf + bm_off
$ bm_wll = f$length(bm_wf)
$ bm_wl = ""
$ bm_wk = 0
$ bm_wn = 0
$wr_next:
$ bm_ww = f$element(bm_wk, " ", bm_wt)
$ if bm_ww .eqs. " " then goto wr_flush
$ bm_wk = bm_wk + 1
$ if bm_ww .eqs. "" then goto wr_next
$ if bm_wn .gt. 0 .and. -
     bm_wll + f$length(bm_wl) + 1 + f$length(bm_ww) .gt. bm_cw
$ then
$   gosub wr_line
$   bm_wlead = ""
$   if bm_wi .gt. 0 then bm_wlead = f$fao("!''bm_wi'* ")
$   bm_wll = bm_wi
$   bm_wl = ""
$   bm_wn = 0
$ endif
$ if bm_wn .gt. 0 then bm_wl = bm_wl + " "
$ bm_wl = bm_wl + bm_ww
$ bm_wn = bm_wn + 1
$ goto wr_next
$wr_flush:
$ if bm_wn .gt. 0 .or. bm_wll .gt. 0 then gosub wr_line
$ return
$wr_line:
$ if bm_wll + f$length(bm_wl) .gt. bm_cw then -
    bm_wl = f$extract(0, bm_cw - bm_wll, bm_wl)
$ bm_out = bm_wlead + bm_wtc + bm_wl + bm_off
$ bm_vl  = bm_wll + f$length(bm_wl)
$ gosub say
$ return
$!
$! KV_NOTE: "label  value  note" with label bm_kn, value bm_v, note bm_note.
$kv_note:
$ bm_kk = bm_kn
$ if f$length(bm_kk) .gt. bm_kw then bm_kk = f$extract(0, bm_kw, bm_kk)
$ bm_room = bm_cw - bm_kw - 3
$ if bm_note .nes. "" then bm_room = bm_room - f$length(bm_note) - 1
$ if bm_room .lt. 8 then bm_room = 8
$ if f$length(bm_v) .gt. bm_room then bm_v = f$extract(0, bm_room - 3, bm_v) + "..."
$ bm_out = "  " + bm_key + f$fao("!''bm_kw'AS", bm_kk) + bm_off + " " + bm_v
$ bm_vl  = 2 + bm_kw + 1 + f$length(bm_v)
$ if bm_note .nes. ""
$ then
$   bm_out = bm_out + " " + bm_yel + bm_note + bm_off
$   bm_vl  = bm_vl + 1 + f$length(bm_note)
$ endif
$ gosub say
$ return
$!
$! CAT_ROWS: one line per working entry of category bm_cat: name, what it
$! is, who calls it and when. bm_rows_out = lines written.
$cat_rows:
$ bm_kw = 22
$ bm_rows_out = 0
$ bm_i = 0
$cr_next:
$ bm_i = bm_i + 1
$ if bm_i .gt. bm_ne
$ then
$   bm_kw = 18
$   return
$ endif
$ if bm_e'bm_i'_cat .nes. bm_cat then goto cr_next
$ bm_rows_out = bm_rows_out + 1
$ bm_kn = bm_e'bm_i'_nam
$ bm_v = bm_e'bm_i'_dsc
$ if bm_v .eqs. "" then bm_v = bm_e'bm_i'_lab
$ bm_up = bm_e'bm_i'_par
$ bm_by = "startup database"
$ if bm_up .gt. 0 then bm_by = bm_e'bm_up'_nam
$ bm_v = f$edit(bm_v + ", from " + bm_by + " (" + bm_e'bm_i'_pha + ")", "TRIM")
$ if f$extract(0, 1, bm_v) .eqs. "," then bm_v = f$edit(f$extract(1, 999, bm_v), "TRIM")
$ bm_note = bm_e'bm_i'_st
$ if bm_e'bm_i'_cnd .nes. "" then bm_note = f$edit("[if " + bm_e'bm_i'_cnd + "] " + bm_note, "TRIM")
$ gosub kv_note
$ goto cr_next
$!
$! SUMMARY: bm_sum = what entry bm_e does, e.g. "12 logicals, 3 disks".
$summary:
$ bm_sum = ""
$ bm_sk2 = 0
$sm_next:
$ bm_sk2 = bm_sk2 + 1
$ bm_sx = f$element(bm_sk2 - 1, "/", "def|!UL logical!%S/" + -
          "mnt|!UL disk mount!%S/ins|!UL image!%S/" + -
          "det|!UL detached process!1%C!%Ees!%F/sub|!UL batch job!%S/" + -
          "que|!UL queue command!%S/pgf|!UL page or swap file!%S/" + -
          "cal|calls !UL procedure!%S")
$ if bm_sx .eqs. "/" then return
$ bm_sf2 = f$element(0, "|", bm_sx)
$ bm_sn = bm_e'bm_e'_'bm_sf2'
$ if bm_sn .eq. 0 then goto sm_next
$ if bm_sum .nes. "" then bm_sum = bm_sum + ", "
$ bm_sum = bm_sum + f$fao(f$element(1, "|", bm_sx), bm_sn, bm_sn)
$ goto sm_next
$!
$! SHORT_NAME: bm_short = a friendly name for entry bm_e.
$short_name:
$ bm_short = bm_e'bm_e'_dsc
$ if bm_short .nes. "" then return
$ bm_short = bm_e'bm_e'_nam
$ bm_short = bm_short - "$STARTUP" - "_STARTUP" - "STARTUP"
$ if f$extract(f$length(bm_short) - 1, 1, bm_short) .eqs. "$" .or. -
     f$extract(f$length(bm_short) - 1, 1, bm_short) .eqs. "_" then -
    bm_short = f$extract(0, f$length(bm_short) - 1, bm_short)
$ if bm_short .eqs. "" then bm_short = bm_e'bm_e'_nam
$ return
$!
$! JOIN_AND: bm_joined = the |-terminated list bm_cl as "a, b and c".
$join_and:
$ bm_joined = ""
$ bm_jn = 0
$ja_count:
$ if f$element(bm_jn, "|", bm_cl) .eqs. "|" .or. -
     f$element(bm_jn, "|", bm_cl) .eqs. "" then goto ja_build
$ bm_jn = bm_jn + 1
$ goto ja_count
$ja_build:
$ bm_jk = 0
$ja_next:
$ if bm_jk .ge. bm_jn then return
$ bm_jv = f$element(bm_jk, "|", bm_cl)
$ if bm_jk .gt. 0 .and. bm_jk .eq. bm_jn - 1 then bm_joined = bm_joined + " and "
$ if bm_jk .gt. 0 .and. bm_jk .lt. bm_jn - 1 then bm_joined = bm_joined + ", "
$ bm_joined = bm_joined + bm_jv
$ bm_jk = bm_jk + 1
$ goto ja_next
$!
$! FMT_DUR: bm_dtxt = bm_dur seconds as "48 seconds" or "3 min 12 s".
$fmt_dur:
$ if bm_dur .lt. 120
$ then
$   bm_dtxt = f$fao("!UL second!%S", bm_dur)
$ else
$   bm_dtxt = f$fao("!UL min !UL s", bm_dur / 60, bm_dur - (bm_dur / 60) * 60)
$ endif
$ return
$!
$! CIVIL: from bm_t ("yyyy-mm-dd hh:mm:ss..."), bm_days = days since a
$! fixed epoch and bm_secs = seconds into that day.
$civil:
$ bm_y = f$integer(f$extract(0, 4, bm_t))
$ bm_mo = f$integer(f$extract(5, 2, bm_t))
$ bm_dd = f$integer(f$extract(8, 2, bm_t))
$ bm_secs = f$integer(f$extract(11, 2, bm_t)) * 3600 + -
            f$integer(f$extract(14, 2, bm_t)) * 60 + -
            f$integer(f$extract(17, 2, bm_t))
$ if bm_mo .le. 2 then bm_y = bm_y - 1
$ bm_era = bm_y / 400
$ bm_yoe = bm_y - bm_era * 400
$ bm_mp2 = bm_mo - 3
$ if bm_mo .le. 2 then bm_mp2 = bm_mo + 9
$ bm_doy = (153 * bm_mp2 + 2) / 5 + bm_dd - 1
$ bm_doe = bm_yoe * 365 + bm_yoe / 4 - bm_yoe / 100 + bm_doy
$ bm_days = bm_era * 146097 + bm_doe
$ return
