#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: removeunwanted.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Removes the OpenSSH message catalogue filesets (openssh.msg.*) for every locale except the ones
#|              listed in KEEP. Queries what is actually installed rather than working from a fixed list.
#|
#| Usage:       removeunwanted.ksh [-n] [-k <locale,...>]
#|                -n  dry run - list what would be removed
#|                -k  locales to keep (default: en_US,EN_US)
#|
#| Note:        Standalone - no library needed, so it can be dropped into /usr/local/bin on its own.
#|              Run as root (padmin: oem_setup_env).
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 11/04/2025, recovered from the old NIM server
#| Revision History:
#| 11/04/2025 : original : Base script - fixed list of 33 locales, one updateios call each
#| 03/09/2026 :          : Query installed openssh.msg.* filesets, keep-list, dry run, own log file, no /dev/tty
#|-----------------------------------------------------------------------------------------------------------------|

set -u

IOSCLI=/usr/ios/cli/ioscli
LOGDIR=${LOGDIR:-/var/log/vios_scripts}
KEEP="en_US,EN_US"
DRYRUN=0

usage() { print -u2 "Usage: $0 [-n] [-k <locale,...>]"; exit 1; }

while getopts "nk:" opt; do
    case "$opt" in
        n) DRYRUN=1 ;;
        k) KEEP="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

(( $(id -u) == 0 )) || { print -u2 "ERROR: must be run as root (padmin: use oem_setup_env)"; exit 1; }

mkdir -p "$LOGDIR" 2>/dev/null
logfile="${LOGDIR}/removeunwanted.log"
print "########## $(date) : $0 $*" >> "$logfile"

installed=$(lslpp -Lc 2>/dev/null | awk -F: '$2 ~ /^openssh\.msg\./ {print $2}' | sort -u)
[[ -n "$installed" ]] || { print "No openssh.msg.* filesets installed - nothing to do"; exit 0; }

keep_pat=$(print -- "$KEEP" | sed 's/,/|/g')
remove=$(print -- "$installed" | grep -vE "\.msg\.(${keep_pat})\$")

print "Installed openssh.msg filesets : $(print -- "$installed" | wc -l | tr -d ' ')"
print "Keeping                        : $KEEP"

if [[ -z "$remove" ]]; then
    print "Nothing to remove"
    exit 0
fi

print "To remove                      :"
print -- "$remove" | sed 's/^/    /'

if (( DRYRUN )); then
    print "Dry run - no changes made"
    exit 0
fi

rc=0
for fs in $remove; do
    if "$IOSCLI" updateios -remove "$fs" >> "$logfile" 2>&1; then
        printf "    %-40s removed\n" "$fs"
    else
        printf "    %-40s FAILED (see %s)\n" "$fs" "$logfile"
        rc=1
    fi
done

(( rc == 0 )) && print "All unwanted openssh message filesets removed" || print "Completed with errors"
exit $rc
