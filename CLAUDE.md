# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A collection of standalone AIX and Linux system administration automation scripts. There is no build system, package manager, or test framework — the scripts run directly on target systems (AIX 7.1+ or RHEL 9.x). Most require root and are designed for IBM Power/AIX enterprise environments with TSM (IBM Spectrum Protect) for backup.

## Running scripts

All scripts are standalone and run directly:

```sh
# AIX scripts (ksh)
ksh infogather.ksh
ksh fsmonitor.ksh
ksh perftuning.ksh [-n]          # -n = dry-run, no changes applied

# TSM restore prep (ksh, must be root for --prerestore/--postrestore)
ksh tsm_restore_prep.sh --dryrun --log <sysinfo_log> [--vg <vgname>|all]
ksh tsm_restore_prep.sh --prerestore  --log <sysinfo_log>
ksh tsm_restore_prep.sh --postrestore --log <sysinfo_log>

# Linux scripts (bash, must be root)
bash rhelpatch.sh
bash usercreate.sh
bash aixtonim.ksh
```

Dry-run support:
- `perftuning.ksh -n` — prints what would be changed, no writes
- `tsm_restore_prep.sh --dryrun` — prints all commands, also writes a runbook `.sh` file

## Architecture and script relationships

**Key pipeline: infogather → tsm_restore_prep**

`ADMIN/infogather.ksh` collects AIX system info (VGs, LVs, filesystems, hardware) into a structured log file (`<hostname>_sysinfo_<datestamp>.log`). `BACKUP/tsm_restore_prep.sh` consumes that log to reconstruct the storage layout (VGs, LVs, mount points) on a target/DR system before or after a TSM image restore. The parser relies on the exact section headers and table format that `infogather.ksh` writes.

**RMAN schedule generators**

`BACKUP/L1L0rmanschedcreator.sh` and `BACKUP/L0MYrmanschedcreator.sh` are interactive generators — they prompt for Oracle/TSM credentials and paths, then write `.sched` wrapper scripts and `.rman` cmdfiles to disk. They do not run backups themselves; the generated files are scheduled via TSM or cron.

**Folder layout by function:**
- `ADMIN/` — live system diagnostics and configuration (run on the source/target AIX host)
- `BACKUP/` — backup orchestration: NIM DR (`aixtonim.ksh`), Oracle RMAN via TSM-TDPO (the two `*schedcreator` scripts), TSM image restore prep (`tsm_restore_prep.sh`), JFS2 snapshot backup (`tsmsnapshot.ksh`)
- `PATCHING/` — OS patching automation (`rhelpatch.sh` for RHEL 9.x)
- `ARTIFACTS/` — static HTML runbooks and cheatsheets (rendered in a browser, not executed)
- `LOGS/` — log output from automation runs

## Conventions in this codebase

- **Shell**: AIX scripts use `#!/bin/ksh` (ksh88-compatible). Linux scripts use `#!/bin/bash` with `set -euo pipefail`.
- **Logging pattern**: scripts write timestamped entries to a `LOGFILE` variable (usually `/var/log/<scriptname>_<timestamp>.log`) and `tee` key output to the terminal.
- **Dry-run / runbook pattern**: destructive scripts (`perftuning.ksh`, `tsm_restore_prep.sh`) support a dry-run mode and/or generate a runbook shell script capturing every command that was or would be run.
- **Input sanitization in ksh**: interactive ksh scripts use a `sanitize_input()` function (tr + sed) to strip terminal escape sequences from `read` input — important for AIX PuTTY sessions that inject control characters.
- **TSM/TDPO integration**: backup scripts call `dsmc` (TSM BA client) or `rman ... type 'sbt_tape' parms 'ENV=(TDPO_OPTFILE=...)'` for tape-based Oracle backups via TDPO.
- **rootvg exclusion**: `tsm_restore_prep.sh` explicitly never recreates rootvg; all storage reconstruction is for data VGs only.
