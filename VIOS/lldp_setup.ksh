#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: lldp_setup.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Enables LLDP on every Shared Ethernet Adapter of a VIO server and reports the neighbouring
#|              switch, port and port description for each one.
#|
#| Usage:       lldp_setup.ksh [-r] [-s <sea>[,sea...]]
#|                -r  report only, do not change anything
#|                -s  limit to the named SEA(s) instead of all of them
#|
#| Note:        Requires vios_lib.ksh alongside this script. Run as root (padmin: oem_setup_env).
#|              Exit code 1 if any SEA has no LLDP neighbour (switch side probably not configured).
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 14/04/2025, recovered from the old NIM server
#| Revision History:
#| 16/04/2025 : original : Base script
#| 03/09/2026 :          : Refactor - shared logging, fd 3 set up once before use, portlist check uses whole-word
#|                         match, single lldpsync, report-only and SEA-filter options, summary loop no longer
#|                         re-queries lldpctl, trailing hints used a stale $sea
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

REPORT_ONLY=0
SEA_LIST=""

usage() {
    print -u2 "Usage: $0 [-r] [-s <sea,...>]"
    exit 1
}

while getopts "rs:" opt; do
    case "$opt" in
        r) REPORT_ONLY=1 ;;
        s) SEA_LIST=$(print -- "$OPTARG" | tr ',' ' ') ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

require_root
is_vios || { print -u2 "ERROR: not a VIO server"; exit 1; }
command -v lldpctl >/dev/null 2>&1 || { print -u2 "ERROR: lldpctl not found - is LLDP installed?"; exit 1; }

log_init "${LOGDIR}/lldp_setup.log" "$@"
trap log_close EXIT

[[ -n "$SEA_LIST" ]] || SEA_LIST=$(lsdev -l 'ent*' | awk '/Shared Ethernet Adapter/ {print $1}')
[[ -n "$SEA_LIST" ]] || die "no Shared Ethernet Adapters found"

lpar=$(uname -n)
errors=0
summary=""

neighbour_field() {   # neighbour_field <sea> "<Field Name>"
    lldpctl show neighbor "$1" 2>/dev/null | awk -F': *' -v f="$2" '$1 ~ f {sub(/^[ \t]+/, "", $2); print $2; exit}'
}

for sea in $SEA_LIST; do
    log_and_screen "SEA" "$sea"

    if lldpctl show portlist 2>/dev/null | grep -qw "$sea"; then
        log_and_screen "  LLDP on $sea" "already enabled"
    elif (( REPORT_ONLY )); then
        log_and_screen "  LLDP on $sea" "NOT enabled (report only, not changing)"
    else
        if run_logged chdev -l "$sea" -a lldpsvc=yes; then
            log_and_screen "  LLDP on $sea" "enabled"
        else
            log_and_screen "  LLDP on $sea" "FAILED to enable (see $logfile)"
            errors=1
            continue
        fi
        run_logged lldpsync
        sleep 3
    fi

    packets=$(lldpctl show port "$sea" 2>/dev/null | awk '/FramesOutTotal/ {print $NF}')
    mac=$(lldpctl show port "$sea" 2>/dev/null | awk -F'Chassis ID: ' '/Chassis ID:/ {print $2}' | awk '{print $1}')
    log_and_screen "  frames sent" "${packets:-0}"

    if lldpctl show neighbor "$sea" >/dev/null 2>&1; then
        switch=$(neighbour_field "$sea" "System Name")
        pdesc=$(neighbour_field "$sea" "Port Description")
        log_and_screen "  neighbour" "${switch:-?} port ${pdesc:-?} (${mac:-?})"
        summary="${summary}${lpar} ${sea} ${switch:-?} ${mac:-?} ${pdesc:-?}\n"
    else
        log_and_screen "  neighbour" "NONE - switch port may not have LLDP configured"
        errors=1
        summary="${summary}${lpar} ${sea} - - NO NEIGHBOUR\n"
    fi
done

screen_only ""
log_and_screen "Summary" "hostname  sea  switch  switch-port-mac  port-description"
printf "$summary" | while read -r line; do log_and_screen "  " "$line"; done
screen_only ""
screen_only "  Useful commands:  lldpctl show port <sea>"
screen_only "                    lldpctl show neighbor <sea> | egrep 'Port Description:|System Name:'"
exit $errors
