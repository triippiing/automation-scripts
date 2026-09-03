#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: sea_status.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Show link/status detail for every Shared Ethernet Adapter on a VIO server.
#|              Optionally include VLAN detail and the NPIV client mappings that are logged in.
#|
#| Usage:       sea_status.ksh [-v] [-n] [-a]
#|                -v  include VLAN lines from entstat
#|                -n  include NPIV mappings (logged-in clients only)
#|                -a  everything (same as -v -n)
#|
#| Note:        Run as root (oem_setup_env). Replaces port_status.ksh (default) and port_link.ksh (-a).
#|-----------------------------------------------------------------------------------------------------------------|
#| Revision History:
#| 2026-09-03 : Merged port_status.ksh and port_link.ksh; fixed $entX never expanding inside single quotes
#|-----------------------------------------------------------------------------------------------------------------|

set -u

IOSCLI=/usr/ios/cli/ioscli
show_vlan=0
show_npiv=0

usage() {
    print -u2 "Usage: $0 [-v] [-n] [-a]"
    print -u2 "  -v  include VLAN detail from entstat"
    print -u2 "  -n  include NPIV client mappings (logged-in only)"
    print -u2 "  -a  everything (-v -n)"
    exit 1
}

while getopts "vna" opt; do
    case "$opt" in
        v) show_vlan=1 ;;
        n) show_npiv=1 ;;
        a) show_vlan=1; show_npiv=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
(( $# > 0 )) && usage

date

pattern='_sh|status'
(( show_vlan )) && pattern="${pattern}|vlan"

seas=$(lsdev -Cc adapter | awk '/Shared Ethernet Adapter/ {print $1}')

if [[ -z "$seas" ]]; then
    print "No Shared Ethernet Adapters found on $(uname -n)"
else
    for sea in $seas; do
        print "$sea"
        entstat -d "$sea" | grep -iE "${pattern}|${sea}"
        print "--------------------------------------------"
    done
fi

if (( show_npiv )); then
    npiv=$("$IOSCLI" lsmap -npiv -all -fmt : | grep -v NOT_LOGGED_IN)
    print "NPIV logged-in mappings : $(print -- "$npiv" | grep -c .)"
    [[ -n "$npiv" ]] && print -- "$npiv"
fi

exit 0
