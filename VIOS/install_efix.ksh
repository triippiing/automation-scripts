#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: install_efix.ksh        (replaces security_fix.ksh / curl_fix.ksh)
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Installs an IBM interim fix (efix / epkg) on a VIO server or AIX host with emgr.
#|
#|              Which package applies is decided by emgr itself: every *.epkg.Z in the fix directory is
#|              previewed and those that pass are installed. This removes the need for a hand-maintained
#|              Advisory index and works for any level, including separate NIM master / client packages.
#|
#| Usage:       install_efix.ksh -d <dir> | -e <epkg file> | -m <mountpoint> -f <fix_name>   [-a test|apply]
#|                -d  directory containing the *.epkg.Z package(s) downloaded from IBM Fix Central
#|                -e  a single epkg file (full path, or a name inside -d / the fix dir)
#|                -m  NIM software mount point holding fixes/<fix_name>/   (shortcut for -d <mnt>/fixes/<name>)
#|                -f  fix name (sub-directory under <mountpoint>/fixes)
#|                -a  test   : preview only (default)
#|                    apply  : preview then install
#|                -t  host type - accepted for wrapper compatibility, detected automatically
#|                -n  NIM source - accepted for wrapper compatibility, not used
#|
#|              Packages are not kept in the repo: download the advisory's epkg files from IBM Fix Central
#|              into any directory and point -d at it. emgr decides which one fits this system.
#|
#| Note:        Requires vios_lib.ksh alongside this script. Run as root (padmin: oem_setup_env).
#|              Exit codes: 0 installed/nothing to do, 1 error, 2 preview failed for every package.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 20/11/2025, recovered from the old NIM server
#| Revision History:
#| 20/11/2025 : original : Base script (security_fix.ksh)
#| 03/09/2026 :          : Rewrite - getopts, test/apply modes, emgr-driven package selection, AIX path now
#|                         installs instead of previewing twice, NIM master detected by fileset, already-
#|                         installed check, reboot flag reported
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

MNT=""
FIX_NAME=""
FIX_DIR=""
APPLY="test"
EPKG=""

usage() {
    print -u2 "Usage: $0 -d <dir> | -e <epkg file> | -m <mountpoint> -f <fix_name>   [-a test|apply]"
    exit 1
}

while getopts "d:m:f:a:e:t:n:" opt; do
    case "$opt" in
        d) FIX_DIR="$OPTARG" ;;
        m) MNT="$OPTARG" ;;
        f) FIX_NAME="$OPTARG" ;;
        a) APPLY=$(print -- "$OPTARG" | tr '[:upper:]' '[:lower:]') ;;
        e) EPKG="$OPTARG" ;;
        t|n) ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ "$APPLY" == "test" || "$APPLY" == "apply" ]] || { print -u2 "ERROR: -a must be test or apply"; usage; }

# Work out where the packages are: -d, else -m/-f, else the directory of -e
if [[ -n "$FIX_DIR" ]]; then
    fix_dir="$FIX_DIR"
elif [[ -n "$MNT" && -n "$FIX_NAME" ]]; then
    fix_dir="${MNT}/fixes/${FIX_NAME}"
elif [[ -n "$EPKG" && "$EPKG" == /* ]]; then
    fix_dir=$(dirname "$EPKG")
else
    print -u2 "ERROR: give -d <dir>, -e </full/path.epkg.Z>, or -m <mountpoint> -f <fix_name>"
    usage
fi
[[ -d "$fix_dir" ]] || { print -u2 "ERROR: fix directory not found: $fix_dir"; exit 1; }
[[ -n "$FIX_NAME" ]] || FIX_NAME=$(basename "$fix_dir")

require_root
log_init "${LOGDIR}/install_efix_${FIX_NAME}.log" "$@"
trap log_close EXIT

type=$(os_type)
case "$type" in
    VIO|AIX) ;;
    *) die "unsupported platform: $type" ;;
esac

log_and_screen "Host" "$(uname -n)"
log_and_screen "Platform" "$type $(os_level_dotted)$(is_nim_master && print ' (NIM master)')"
log_and_screen "Fix" "$FIX_NAME"
log_and_screen "Mode" "$APPLY"

#############################################
# Candidate packages
#############################################

if [[ -n "$EPKG" ]]; then
    [[ "$EPKG" == /* ]] || EPKG="${fix_dir}/${EPKG}"
    [[ -f "$EPKG" ]] || die "epkg not found: $EPKG"
    candidates="$EPKG"
else
    candidates=$(ls "$fix_dir"/*.epkg.Z 2>/dev/null)
    [[ -n "$candidates" ]] || die "no *.epkg.Z packages found in $fix_dir"
fi

# label and reboot flag from the package header
epkg_label()  { emgr -d -e "$1" 2>/dev/null | awk -F: '/^ *LABEL:/ {gsub(/ /,"",$2); print $2; exit}'; }
epkg_reboot() { emgr -d -e "$1" -v 3 2>/dev/null | awk -F: '/REBOOT REQUIRED/ {gsub(/ /,"",$2); print $2; exit}'; }

#############################################
# Preview
#############################################

ready=""
for pkg in $candidates; do
    name=$(basename "$pkg")
    label=$(epkg_label "$pkg")

    if [[ -n "$label" ]] && emgr -l -L "$label" >/dev/null 2>&1; then
        log_and_screen "Preview $name" "already installed ($label)"
        continue
    fi

    if run_logged emgr -p -e "$pkg"; then
        log_and_screen "Preview $name" "OK"
        ready="$ready $pkg"
    else
        log_and_screen "Preview $name" "not applicable (see log)"
    fi
done

if [[ -z "$ready" ]]; then
    if grep -q "already installed" "$logfile"; then
        log_and_screen "Result" "nothing to do"
        exit 0
    fi
    log_and_screen "Result" "no package in $FIX_NAME applies to this system"
    exit 2
fi

if [[ "$APPLY" == "test" ]]; then
    log_and_screen "Result" "test mode - would install: $(for p in $ready; do basename "$p"; done | tr "\n" " ")"
    exit 0
fi

#############################################
# Apply
#############################################

failed=0
for pkg in $ready; do
    name=$(basename "$pkg")
    if run_logged emgr -X -e "$pkg"; then
        log_and_screen "Install $name" "OK"
        [[ "$(epkg_reboot "$pkg")" == "yes" ]] && log_and_screen "Reboot required" "$name"
    else
        log_and_screen "Install $name" "FAILED (see $logfile)"
        failed=1
    fi
done

emgr -l >> "$logfile" 2>&1

if (( failed )); then
    log_and_screen "Result" "one or more packages failed"
    exit 1
fi
log_and_screen "Result" "installed successfully"
exit 0
