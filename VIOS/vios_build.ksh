#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: vios_build.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Builds a freshly installed VIO server to the standard, from the untarred deployment tree.
#|              Runs the phases below in order and records each one in a state file, so the same command is
#|              run again after the reboot and carries on where it stopped.
#|
#|              Phases:
#|                check    preflight of the attended steps: license, hostname, default route, DNS, NTP.
#|                         Read only, except that it offers to run mktcpip when no network is configured
#|                build    vios_standardise.ksh, all steps (filesystems ... tunables)
#|                fixes    vios_standardise.ksh -F <fixes dir>; skipped when there is no fixes directory
#|                         ---- reboot ----
#|                verify   rulestoset.ksh -n, sea_status.ksh -a, unused_adapters.ksh, lldp_setup.ksh,
#|                         then prints the day-two steps that run from the admin host
#|
#| Usage:       vios_build.ksh [-p <phase>[,phase...]] [-n] [-F <fixes dir>] [-y] [-l] [-r]
#|                -p  run only these phases; default is every phase not yet recorded as done
#|                -n  dry run - passed to every script, nothing recorded, no prompts
#|                -F  fixes directory (default: fixes/<ioslevel> next to this script)
#|                -y  never prompt; a failed check exits instead of offering to fix it
#|                -l  list phases with their recorded state and exit
#|                -r  reset the state file and exit
#|
#| State:       $LOGDIR/vios_build.state, one line per phase: "<phase> <done|skipped> <boot time>".
#|              verify refuses to run until the boot time has changed since build/fixes.
#|
#| Note:        Run as root (padmin: oem_setup_env) from the untarred tree. See RUNBOOK.md.
#|-----------------------------------------------------------------------------------------------------------------|
#| Revision History:
#| 04/09/2026 : New - phase driver for the blank-install runbook
#|-----------------------------------------------------------------------------------------------------------------|

set -u
BASEDIR=$(cd "$(dirname "$0")" && pwd)
. "${BASEDIR}/vios_lib.ksh"

ALL_PHASES="check build fixes verify"
PRE_REBOOT="check build fixes"
STATE="${LOGDIR}/vios_build.state"
PHASES=""
DRYRUN=0
FIXDIR=""
ASSUME_YES=0
LIST=0
RESET=0

usage() {
    print -u2 "Usage: $0 [-p <phase>[,phase...]] [-n] [-F <fixes dir>] [-y] [-l] [-r]"
    exit 1
}

while getopts "p:nF:ylr" opt; do
    case "$opt" in
        p) PHASES=$(print -- "$OPTARG" | tr ',' ' ') ;;
        n) DRYRUN=1 ;;
        F) FIXDIR="$OPTARG" ;;
        y) ASSUME_YES=1 ;;
        l) LIST=1 ;;
        r) RESET=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

for p in $PHASES; do
    [[ " $ALL_PHASES " == *" $p "* ]] || { print -u2 "ERROR: unknown phase '$p' (use -l to list)"; exit 1; }
done
[[ -z "$FIXDIR" || -d "$FIXDIR" ]] || { print -u2 "ERROR: fixes dir not found: $FIXDIR"; exit 1; }

#############################################
# State file
#############################################

boot_id() {
    who -b 2>/dev/null | sed 's/.*boot *//' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

phase_status() {   # phase_status <phase> : done | skipped | (empty)
    [[ -f "$STATE" ]] && awk -v p="$1" '$1 == p {print $2}' "$STATE"
}

phase_boot() {     # boot id recorded with the phase
    [[ -f "$STATE" ]] && awk -v p="$1" '$1 == p {$1=""; $2=""; sub(/^ +/, ""); print}' "$STATE"
}

record() {         # record <phase> <status>
    (( DRYRUN )) && return 0
    [[ -d "$(dirname "$STATE")" ]] || mkdir -p "$(dirname "$STATE")"
    if [[ -f "$STATE" ]]; then
        grep -v "^$1 " "$STATE" > "${STATE}.new" 2>/dev/null
        cat "${STATE}.new" > "$STATE"; rm -f "${STATE}.new"
    fi
    print "$1 $2 $(boot_id)" >> "$STATE"
}

if (( LIST )); then
    for p in $ALL_PHASES; do
        printf "%-8s %s\n" "$p" "$(phase_status "$p")"
    done
    exit 0
fi

if (( RESET )); then
    rm -f "$STATE"
    print "state reset: $STATE"
    exit 0
fi

require_root
is_vios || { print -u2 "ERROR: not a VIO server"; exit 1; }

log_init "${LOGDIR}/vios_build.log" "$@"
trap log_close EXIT

#############################################
# Which phases run
#############################################

if [[ -z "$PHASES" ]]; then
    for p in $ALL_PHASES; do
        [[ -n "$(phase_status "$p")" ]] || PHASES="$PHASES $p"
    done
    PHASES=${PHASES# }
    # verify only runs after the reboot that follows build/fixes, so never in the same run as them
    if [[ " $PHASES " == *" verify "* ]]; then
        for p in $PRE_REBOOT; do
            [[ " $PHASES " == *" $p "* ]] && { PHASES=${PHASES% verify}; break; }
        done
    fi
fi
[[ -n "$PHASES" ]] || { log_and_screen "Nothing to do" "every phase is recorded in $STATE (use -r to start again)"; exit 0; }

log_and_screen "Host" "$(uname -n)  VIOS $(os_level_dotted)"
log_and_screen "Phases" "$PHASES"
(( DRYRUN )) && log_and_screen "Mode" "DRY RUN - nothing will be changed or recorded"

# run a sibling script with its screen output on our screen; returns its rc
run_script() {
    print "----- $(date) : $*"
    "$@" 1>&3
}

ask() {   # ask <prompt> [default] : answer on stdout, read from the terminal
    print -u3 -n "$1${2:+ [$2]}: "
    read -r ans
    print -- "${ans:-${2:-}}"
}

#############################################
# check
#############################################

check_failures=""
check_item() {   # check_item <label> <ok> <detail>
    if (( $2 )); then
        log_and_screen "  $1" "ok - $3"
    else
        log_and_screen "  $1" "MISSING - $3"
        check_failures="$check_failures $1"
    fi
}

network_ok() {
    h=$(hostname 2>/dev/null)
    [[ -n "$h" && "$h" != localhost* ]] && netstat -rn 2>/dev/null | awk '$1 == "default"' | grep -q .
}

configure_network() {
    print -u3 ""
    print -u3 "No network is configured. The answers below are passed to mktcpip."
    hn=$(ask "Hostname")
    ifc=$(ask "Interface" en0)
    ip=$(ask "IP address")
    nm=$(ask "Netmask" 255.255.255.0)
    gw=$(ask "Gateway")
    dns=$(ask "DNS server (blank for none)")
    dom=""
    [[ -n "$dns" ]] && dom=$(ask "DNS domain")
    set -- mktcpip -hostname "$hn" -inetaddr "$ip" -interface "$ifc" -netmask "$nm" -gateway "$gw"
    [[ -n "$dns" ]] && set -- "$@" -nsrvaddr "$dns" -nsrvdomain "$dom"
    if run_logged "$IOSCLI" "$@" 1>&3; then
        log_and_screen "  mktcpip" "done"
    else
        log_and_screen "  mktcpip" "FAILED (see $logfile)"
    fi
}

phase_check() {
    lic=$("$IOSCLI" ioslevel 2>&1)
    if (( $? == 0 )) && [[ "$lic" != *icense* ]]; then
        check_item "license" 1 "ioscli answers (ioslevel $lic)"
    else
        check_item "license" 0 "license not accepted - run: license -accept"
    fi

    if ! network_ok && (( ! ASSUME_YES && ! DRYRUN )); then
        yn=$(ask "Network is not configured. Configure it now" n)
        [[ "$yn" == [Yy]* ]] && configure_network
    fi
    h=$(hostname 2>/dev/null)
    if [[ -n "$h" && "$h" != localhost* ]]; then check_item "hostname" 1 "$h"; else check_item "hostname" 0 "hostname is '${h:-unset}' - run mktcpip"; fi
    route=$(netstat -rn 2>/dev/null | awk '$1 == "default" {print $2; exit}')
    if [[ -n "$route" ]]; then check_item "default route" 1 "$route"; else check_item "default route" 0 "no default route - run mktcpip"; fi

    if grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
        log_and_screen "  DNS" "ok - $(awk '/^nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ')"
    else
        log_and_screen "  DNS" "WARNING no nameserver in /etc/resolv.conf"
    fi
    if lssrc -s xntpd 2>/dev/null | grep -q active; then
        log_and_screen "  NTP" "ok - xntpd active"
    else
        log_and_screen "  NTP" "WARNING xntpd not running (cfgassist or startnetsvc ntp)"
    fi

    if [[ -n "$check_failures" ]]; then
        log_and_screen "  check" "FAILED:$check_failures"
        return 1
    fi
    return 0
}

#############################################
# build / fixes / verify
#############################################

phase_build() {
    set -- "${BASEDIR}/vios_standardise.ksh"
    (( DRYRUN )) && set -- "$@" -n
    run_script "$@"
}

phase_fixes() {
    dir=$FIXDIR
    if [[ -z "$dir" ]]; then
        dir="${BASEDIR}/fixes/$(os_level_dotted)"
        if [[ ! -d "$dir" ]]; then
            log_and_screen "  fixes" "no fixes directory at $dir - skipped"
            record fixes skipped
            return 0
        fi
    fi
    set -- "${BASEDIR}/vios_standardise.ksh" -s fixes -F "$dir"
    (( DRYRUN )) && set -- "$@" -n
    run_script "$@"
}

phase_verify() {
    for pre in build fixes; do
        b=$(phase_boot "$pre")
        if [[ -n "$b" && "$b" == "$(boot_id)" ]]; then
            log_and_screen "  verify" "$pre ran in this boot - reboot first (shutdown -restart), then run again"
            return 1
        fi
    done
    rc=0
    run_script "${BASEDIR}/rulestoset.ksh" -n     || rc=1
    run_script "${BASEDIR}/sea_status.ksh" -a     || rc=1
    run_script "${BASEDIR}/unused_adapters.ksh"   || rc=1
    run_script "${BASEDIR}/lldp_setup.ksh"        || rc=1
    screen_only ""
    log_and_screen "Day two, from the admin host" "push_files.ksh -M push_files.manifest -h $(uname -n)   (later changes to the standard files)"
    log_and_screen "                            " "install_dnf.ksh / install_logrotate.ksh once the NIM repo is reachable"
    log_and_screen "                            " "SEA, NPIV and storage mappings are per server and not part of this build"
    return $rc
}

#############################################
# Main
#############################################

last_pre=""
for phase in $PHASES; do
    screen_only ""
    log_and_screen "== $phase"
    if "phase_$phase"; then
        [[ "$phase" == fixes && "$(phase_status fixes)" == skipped ]] || record "$phase" done
        [[ " $PRE_REBOOT " == *" $phase "* ]] && last_pre=$phase
    else
        screen_only ""
        log_and_screen "Result" "$phase FAILED - fix and run again (see $logfile)"
        exit 1
    fi
done

screen_only ""
if [[ -n "$last_pre" && " $PHASES " != *" verify "* ]]; then
    if (( DRYRUN )); then
        log_and_screen "Result" "dry run complete - a real run would reboot here"
    else
        log_and_screen "Result" "OK - reboot now (shutdown -restart), then run $(basename "$0") again for the verify phase"
    fi
elif (( DRYRUN )); then
    log_and_screen "Result" "dry run complete"
else
    log_and_screen "Result" "OK"
fi
exit 0
