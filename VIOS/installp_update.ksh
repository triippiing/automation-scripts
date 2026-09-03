#!/bin/ksh93
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: installp_update.ksh       (replaces openssl_update_new.ksh)
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Installs or updates an installp product (OpenSSL, OpenSSH, Java ...) on a VIO server or AIX host
#|              from a versioned directory on the NIM software mount:
#|
#|                  <mountpoint>/<product>/<version>/     e.g. /software/openssl/3.0.16.1000/
#|
#|              A preview is always run first. In apply mode the install proceeds only if the preview reports
#|              something to install. If the install fails because filesets are locked by an existing efix,
#|              the offending efix labels and the emgr command to remove them are printed.
#|
#| Usage:       installp_update.ksh -d <dir> [-p <product>]  |  -m <mountpoint> -p <product> -v <version>
#|                                  [-a test|apply] [-F "<filesets>"]
#|                -d  directory containing the installp images (.bff / fileset files) - any layout
#|                -m  NIM software mount point            (shortcut: -d <mnt>/<product>/<version>)
#|                -p  product name, used for the log name and to report the current level (default: openssl)
#|                -v  version directory name under <mountpoint>/<product>
#|                -a  test   : preview only (default)
#|                    apply  : preview then install
#|                -F  filesets to install (default: all - everything in the directory)
#|                -t / -n / -f  accepted for wrapper compatibility, not used
#|
#| Note:        Requires vios_lib.ksh alongside this script. Run as root (padmin: oem_setup_env).
#|              Exit codes: 0 installed/nothing to do, 1 error, 2 preview failed.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 06/05/2026, recovered from the old NIM server
#| Revision History:
#| 06/05/2026 : original : Base script for OpenSSL (openssl_update.ksh)
#| 03/09/2026 :          : Generalised to any installp product, shared library, log no longer truncated by
#|                         the spinner, hard-coded OS level list removed, unused flags dropped, log path
#|                         reported correctly
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

MNT=""
SRC_DIR=""
PRODUCT="openssl"
VERSION=""
APPLY="test"
FILESETS="all"

usage() {
    print -u2 "Usage: $0 -d <dir> [-p <product>] | -m <mountpoint> -p <product> -v <version>   [-a test|apply] [-F \"<filesets>\"]"
    exit 1
}

while getopts "d:m:p:v:a:F:t:n:f:" opt; do
    case "$opt" in
        d) SRC_DIR="$OPTARG" ;;
        m) MNT="$OPTARG" ;;
        p) PRODUCT="$OPTARG" ;;
        v) VERSION="$OPTARG" ;;
        a) APPLY=$(print -- "$OPTARG" | tr '[:upper:]' '[:lower:]') ;;
        F) FILESETS="$OPTARG" ;;
        t|n|f) ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ "$APPLY" == "test" || "$APPLY" == "apply" ]] || { print -u2 "ERROR: -a must be test or apply"; usage; }

if [[ -n "$SRC_DIR" ]]; then
    src_dir="$SRC_DIR"
    [[ -n "$VERSION" ]] || VERSION=$(basename "$src_dir")
elif [[ -n "$MNT" && -n "$PRODUCT" && -n "$VERSION" ]]; then
    src_dir="${MNT}/${PRODUCT}/${VERSION}"
else
    print -u2 "ERROR: give -d <dir>, or -m <mountpoint> -p <product> -v <version>"
    usage
fi
[[ -d "$src_dir" ]] || { print -u2 "ERROR: source directory not found: $src_dir"; exit 1; }

require_root
log_init "${LOGDIR}/installp_${PRODUCT}_${VERSION}.log" "$@"
trap log_close EXIT

type=$(os_type)
case "$type" in
    VIO|AIX) ;;
    *) die "unsupported platform: $type" ;;
esac

#############################################
# Helpers
#############################################

# Currently installed level of the first fileset matching the product name
current_level() {
    lslpp -Lc 2>/dev/null | awk -F: -v p="$PRODUCT" 'tolower($2) ~ p".base" || tolower($2) == p {print $3; exit}'
}

# Show a spinner on the terminal while a background pid runs
spinner() {
    pid=$1
    spin='|/-\'
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\b%s" "${spin:i++%4:1}" >&3
        sleep 0.2
    done
    printf "\b \b" >&3
}

# Run a command in the background with its output appended to the log and a spinner on screen
run_with_spinner() {
    print "----- $(date) : $*"
    "$@" >> "$logfile" 2>&1 &
    pid=$!
    spinner "$pid"
    wait "$pid"
    rc=$?
    print "----- rc=$rc"
    return $rc
}

# After a failed install, list filesets locked by efixes and how to remove them
check_efix_locks() {
    locked=$(awk '
        /The following selected filesets are locked by EFIX manager:/ { found=1; next }
        found && NF { if ($0 !~ /^installp|^You|^$/) print $1 }
        found && !NF { found=0 }
    ' "$logfile" | sort -u)
    [[ -n "$locked" ]] || return 0

    log_and_screen "Locked by efix" "the following filesets are locked; remove the efix and re-run"
    for fs in $locked; do
        label=$(emgr -P 2>/dev/null | awk -v f="$fs" '$1 == f {print $3}' | sort -u)
        for l in $label; do
            log_and_screen "  $fs" "emgr -r -L $l"
        done
    done
}

#############################################
# Preview
#############################################

log_and_screen "Host" "$(uname -n)"
log_and_screen "Platform" "$type $(os_level_dotted)"
log_and_screen "Product" "$PRODUCT"
log_and_screen "Current level" "$(current_level)"
log_and_screen "Requested" "$VERSION ($src_dir)"
log_and_screen "Filesets" "$FILESETS"
log_and_screen "Mode" "$APPLY"

cd "$src_dir" || die "cannot cd to $src_dir"
[[ -n "$(ls -A "$src_dir")" ]] || die "$src_dir is empty"

preview=$(installp -p -Y -a -g -X -d . $FILESETS 2>&1)
print "$preview" >> "$logfile"

if print -- "$preview" | grep -qE "^0  Total to be installed|Already installed|already at the same level"; then
    if ! print -- "$preview" | grep -qE "^[1-9][0-9]*  Total to be installed"; then
        log_and_screen "Preview" "nothing to install - already at $VERSION or newer"
        exit 0
    fi
fi

if print -- "$preview" | grep -qiE "^installp: .*(FAILED|ERROR)|Failure|requisite failures|BUILDDATE"; then
    log_and_screen "Preview" "FAILED"
    print -- "$preview" | grep -iE "fail|error|requisite|builddate" | while read -r line; do
        log_and_screen "  " "$line"
    done
    exit 2
fi

to_install=$(print -- "$preview" | awk '/Total to be installed/ {print $1}')
log_and_screen "Preview" "OK - ${to_install:-?} fileset(s) to install"

if [[ "$APPLY" == "test" ]]; then
    log_and_screen "Result" "test mode - no changes made"
    exit 0
fi

#############################################
# Apply
#############################################

printf "   %-35s :  " "Installing $PRODUCT $VERSION" >&3
if run_with_spinner installp -Y -a -g -X -d . $FILESETS; then
    printf "OK\n" >&3
    log_only "Install OK"
else
    printf "FAILED\n" >&3
    log_only "Install FAILED"
    check_efix_locks
    die "install failed - see $logfile"
fi

lslpp -L 2>/dev/null | grep -i "$PRODUCT" >> "$logfile"
log_and_screen "New level" "$(current_level)"
log_and_screen "Result" "installed successfully"
exit 0
