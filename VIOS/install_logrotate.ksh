#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: install_logrotate.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Installs the logrotate package via DNF if missing, drops the SE rotation configs into
#|              logrotate.d and ensures the nightly root cron entry exists.
#|
#| Usage:       install_logrotate.ksh -m <mountpoint> -n <nimsource> [-t <type>] [-a <apply>]
#|                -m  NIM software mount point holding logrotate/ (system, dnf, httpd config files)
#|                -n  NIM server hostname exporting /repo1
#|                -t  host type (VIO|AIX) - accepted for wrapper compatibility, not used
#|                -a  apply mode          - accepted for wrapper compatibility, not used
#|
#| Note:        Files installed into /opt/freeware/etc/logrotate.d : system, dnf, httpd
#|              taken from ${mountpoint}/logrotate/ if present, else examples/logrotate/ next to this script.
#|              The cron entry runs logrotate against logrotate.conf (which includes logrotate.d); the old
#|              entry that pointed straight at the logrotate.d directory is replaced if found.
#|              Requires vios_lib.ksh alongside this script and DNF already installed. Run as root.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 11/04/2025, recovered from the old NIM server
#| Revision History:
#| 11/04/2025 : original : Base script to install DNF logrotate package and associated files
#| 03/09/2026 :          : Refactor - shared library, rpm -q instead of conf-file check, mount errors handled,
#|                         cron entry replacement simplified, copies checked
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

MNT=""
NIMSOURCE=""
TYPE=""
APPLY=""

LOGROTATE_D="${FREEWARE}/etc/logrotate.d"
LOGROTATE_CONF="${FREEWARE}/etc/logrotate.conf"
CRON_JOB="0 0 * * * ${FREEWARE}/sbin/logrotate ${LOGROTATE_CONF} > /dev/null 2>&1"
OLD_CRON_JOB="0 0 * * * ${FREEWARE}/sbin/logrotate ${LOGROTATE_D} > /dev/null 2>&1"

usage() {
    print -u2 "Usage: $0 -m <mountpoint> -n <nimsource> [-t <type>] [-a <apply>]"
    exit 1
}

while getopts "m:t:a:n:" opt; do
    case "$opt" in
        m) MNT="$OPTARG" ;;
        t) TYPE="$OPTARG" ;;
        a) APPLY="$OPTARG" ;;
        n) NIMSOURCE="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$MNT" && -n "$NIMSOURCE" ]] || { print -u2 "ERROR: -m and -n are required"; usage; }
CFG_SRC="$MNT/logrotate"
[[ -d "$CFG_SRC" ]] || CFG_SRC="$(dirname "$0")/examples/logrotate"
[[ -d "$CFG_SRC" ]] || { print -u2 "ERROR: no logrotate configs at $MNT/logrotate or examples/logrotate"; exit 1; }
command -v dnf >/dev/null 2>&1 || { print -u2 "ERROR: dnf not installed - run install_dnf.ksh first"; exit 1; }

require_root
log_init "${LOGDIR}/install_logrotate.log" "$@"

cleanup() {
    umount_repo
    log_close
}
trap cleanup EXIT

#############################################
# Package
#############################################

if rpm -q logrotate >/dev/null 2>&1; then
    log_and_screen "logrotate package" "already installed"
else
    log_and_screen "logrotate package" "not installed, installing"
    mount_repo "$NIMSOURCE"
    dnf -y install logrotate || die "dnf install logrotate failed - see $logfile"
    umount_repo
    log_and_screen "logrotate package" "installed"
fi
[[ -f "$LOGROTATE_CONF" ]] && chmod 640 "$LOGROTATE_CONF"

#############################################
# Rotation configs
#############################################

mkdir -p "$LOGROTATE_D"
for cfg in system dnf httpd; do
    src="${CFG_SRC}/${cfg}"
    [[ -f "$src" ]] || die "config not found: $src"
    cp "$src" "${LOGROTATE_D}/${cfg}" || die "failed to copy $cfg"
    chmod 644 "${LOGROTATE_D}/${cfg}"
    log_and_screen "Config installed" "$cfg ($(basename "$(dirname "$src")"))"
done
ls -l "$LOGROTATE_D"

#############################################
# Cron entry (replace any existing active or commented copy)
#############################################

crontab_tmp="${TMPDIR}/root_crontab.$$"
crontab -l > "$crontab_tmp" 2>/dev/null

if grep -Fxq "$CRON_JOB" "$crontab_tmp"; then
    log_and_screen "Cron entry" "already present"
else
    if grep -Fq "$OLD_CRON_JOB" "$crontab_tmp"; then
        log_and_screen "Cron entry" "replacing old logrotate.d entry"
        grep -Fv "$OLD_CRON_JOB" "$crontab_tmp" > "${crontab_tmp}.new"
        mv "${crontab_tmp}.new" "$crontab_tmp"
    fi
    if grep -Fq "$CRON_JOB" "$crontab_tmp"; then
        log_and_screen "Cron entry" "present but commented out, replacing"
        grep -Fv "$CRON_JOB" "$crontab_tmp" > "${crontab_tmp}.new"
        mv "${crontab_tmp}.new" "$crontab_tmp"
    else
        log_and_screen "Cron entry" "adding"
    fi
    print -- "$CRON_JOB" >> "$crontab_tmp"
    crontab "$crontab_tmp" || die "failed to install crontab"
    log_and_screen "Cron entry" "installed"
fi
rm -f "$crontab_tmp"

log_and_screen "Logrotate install" "completed"
exit 0
