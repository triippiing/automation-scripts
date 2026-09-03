#|-----------------------------------------------------------------------------------------------------------------|
#| Library Name: vios_lib.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Shared functions for the VIOS/AIX maintenance scripts. Source it, do not execute it:
#|
#|                  . "$(dirname "$0")/vios_lib.ksh"
#|
#|              Provides: logging      log_init, log_and_screen, log_only, screen_only, die, log_close
#|                        environment  require_root, is_vios, is_nim_master, os_level_short, os_type
#|                        NFS repo     mount_repo, umount_repo, is_mounted
#|                        misc         run_logged, tmpfile
#|
#| Config:      Site settings are read, in order, from /etc/vios_scripts.conf, vios.conf next to the script,
#|              and vios.conf.<env> next to the script when VIOS_ENV=<env> is set (e.g. VIOS_ENV=prod).
#|              Every setting can also be set in the environment. See vios.conf.example for the full list.
#|-----------------------------------------------------------------------------------------------------------------|
#| Revision History:
#| 2026-09-03 : Extracted from install_dnf.ksh / install_logrotate.ksh / security_fix.ksh common code
#| 2026-09-03 : Config file support, is_nim_master via NIM master fileset, log dir moved to /var/log
#|-----------------------------------------------------------------------------------------------------------------|

_libdir=$(dirname "$0")
for _conf in /etc/vios_scripts.conf "${_libdir}/vios.conf" "${_libdir}/vios.conf.${VIOS_ENV:-none}"; do
    [[ -r "$_conf" ]] && . "$_conf"
done

LOGDIR=${LOGDIR:-/var/log/vios_scripts}
REPO_MNT=${REPO_MNT:-/repo1}
REPO_EXPORT=${REPO_EXPORT:-/repo1}
FREEWARE=${FREEWARE:-/opt/freeware}
IOSCLI=${IOSCLI:-/usr/ios/cli/ioscli}
TMPDIR=${TMPDIR:-/tmp}
logfile=""

#############################################
# Logging
#
# log_init <logfile> [args...] : truncate/create the log, save the terminal on fd 3 and send all
#                      other output to the log. After this, plain echo/printf goes to the
#                      log only; use the helpers below to reach the screen.
#############################################

log_init() {
    logfile=$1
    shift
    logdir=$(dirname "$logfile")

    [[ -d "$logdir" ]] || mkdir -p "$logdir" || { print -u2 "ERROR: cannot create $logdir"; exit 1; }

    if [[ -f "$logfile" && ! -w "$logfile" ]]; then
        chmod u+w "$logfile" || { print -u2 "ERROR: $logfile not writable"; exit 1; }
    fi
    : > "$logfile" || { print -u2 "ERROR: cannot write $logfile"; exit 1; }

    exec 3>&1
    exec >> "$logfile" 2>&1

    print "########## $(date) : $0 $* ##########"
    print "########## host: $(uname -n)  user: $(id -un)"
}

# Two-column line to screen and log:   label : value
log_and_screen() {
    if (( $# >= 2 )); then
        printf "   %-35s : %s\n" "$1" "$2" | tee -a "$logfile" >&3
    else
        printf "%s\n" "$1" | tee -a "$logfile" >&3
    fi
}

log_only() {
    printf "%s\n" "$*" >> "$logfile"
}

screen_only() {
    printf "%s\n" "$*" >&3
}

# die <message> [rc]
die() {
    log_and_screen "ERROR" "$1"
    exit "${2:-1}"
}

log_close() {
    print "########## $(date) : finished ##########"
    exec 3>&-
}

# run_logged <cmd...> : run a command with its output in the log, return its rc
run_logged() {
    print "----- $(date) : $*"
    "$@"
    rc=$?
    print "----- rc=$rc"
    return $rc
}

#############################################
# Environment checks
#############################################

require_root() {
    if (( $(id -u) != 0 )); then
        print -u2 "ERROR: must be run as root (padmin: use oem_setup_env)"
        exit 1
    fi
}

is_vios() {
    [[ -x "$IOSCLI" ]]
}

is_aix() {
    [[ "$(uname -s)" == "AIX" ]]
}

# NIM master is identified by its fileset, not by the hostname
is_nim_master() {
    lslpp -l bos.sysmgt.nim.master >/dev/null 2>&1
}

# VIO | AIX | <other uname>
os_type() {
    if is_vios; then print VIO
    elif is_aix; then print AIX
    else uname -s
    fi
}

# 7300 / 7200 / 7100 / 6100  (from oslevel -s, e.g. 7300-02-01-2346)
os_level_short() {
    oslevel -s | awk -F- '{print $1}'
}

# Full dotted level: VIOS 4.1.0.10 -> 4.1.0.10 ; AIX 7300-02-01 -> 7.3.2.1
os_level_dotted() {
    if is_vios; then
        "$IOSCLI" ioslevel
    else
        oslevel -s | awk -F- '{ tl=$2+0; sp=$3+0; printf "%s.%s.%d.%d\n", substr($1,1,1), substr($1,2,1), tl, sp }'
    fi
}

tmpfile() {
    print "${TMPDIR}/${1:-tmp}.$$"
}

#############################################
# NFS repo mount
#############################################

is_mounted() {
    mount | awk '{print $2; print $3}' | grep -qx "$1"
}

# mount_repo <nimsource>  : mounts nimsource:REPO_EXPORT on REPO_MNT if not already mounted
mount_repo() {
    nimsource=$1
    [[ -n "$nimsource" ]] || die "mount_repo: no NIM source given"

    if is_mounted "$REPO_MNT"; then
        log_and_screen "Mount $REPO_MNT" "already mounted"
        return 0
    fi

    [[ -d "$REPO_MNT" ]] || mkdir -p "$REPO_MNT" || die "cannot create $REPO_MNT"

    if mount "${nimsource}:${REPO_EXPORT}" "$REPO_MNT"; then
        log_and_screen "Mount $REPO_MNT" "mounted from ${nimsource}:${REPO_EXPORT}"
    else
        die "failed to mount ${nimsource}:${REPO_EXPORT} on $REPO_MNT" 99
    fi
}

umount_repo() {
    if is_mounted "$REPO_MNT"; then
        umount "$REPO_MNT" && log_and_screen "Unmount $REPO_MNT" "done" \
                            || log_and_screen "Unmount $REPO_MNT" "FAILED (still mounted)"
    fi
}
