#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: unused_adapters.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Read-only audit listing adapters on a VIO server that are not in use.
#|                fcs : any FC adapter that does not appear in lsnports
#|                ent : any ethernet adapter that is not a physical card, VLAN, SEA (or SEA member),
#|                      EtherChannel (or member) or mapped to a client. Adapters that are in use but have
#|                      "Physical link down" errors in errpt are reported separately.
#|              Prints the padmin commands to remove what it finds. It never removes anything itself.
#|
#| Usage:       unused_adapters.ksh [-f] [-e]
#|                -f  FC adapters only
#|                -e  ethernet adapters only
#|
#| Note:        Requires vios_lib.ksh alongside this script. Run as root (padmin: oem_setup_env).
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 07/05/2025, recovered from the old NIM server
#| Revision History:
#| 07/05/2025 : original : Base script
#| 03/09/2026 :          : Refactor - shared logging, whole-word matching (fcs1 no longer matches fcs10), adapter
#|                         lists built with real newlines, ent list anchored to ^ent<n>, -f/-e filters
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

DO_FCS=1
DO_ETH=1

usage() { print -u2 "Usage: $0 [-f] [-e]"; exit 1; }

while getopts "fe" opt; do
    case "$opt" in
        f) DO_ETH=0 ;;
        e) DO_FCS=0 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

require_root
is_vios || { print -u2 "ERROR: not a VIO server"; exit 1; }

log_init "${LOGDIR}/unused_adapters.$(date +%Y%m%d).log" "$@"
trap log_close EXIT

# numeric suffix of a device name: ent12 -> 12
devnum() { print -- "${1##*[!0-9]}"; }

#############################################
# Fibre channel
#############################################

check_fcs() {
    log_and_screen "Checking FC adapters (fcs) against lsnports"
    all_fcs=$(lsdev -Cc adapter | awk '/^fcs[0-9]+ / {print $1}')
    nports=$("$IOSCLI" lsnports 2>/dev/null)
    print "$nports" >> "$logfile"

    unused=""
    for fcs in $all_fcs; do
        if print -- "$nports" | awk '{print $1}' | grep -qx "$fcs"; then
            log_only "$fcs in use"
        else
            log_and_screen "  $fcs" "not in lsnports - unused"
            unused="$unused $(devnum "$fcs")"
        fi
    done

    if [[ -n "$unused" ]]; then
        screen_only ""
        log_and_screen "To remove, as padmin:"
        log_and_screen "  for num in$unused; do"
        log_and_screen "    rmdev -dev fcs\${num} -ucfg -recursive"
        log_and_screen "    chdev -dev fscsi\${num} -attr autoconfig=defined -perm"
        log_and_screen "  done"
        log_and_screen "  cfgdev"
    else
        log_and_screen "  all fcs adapters are in use"
    fi
    screen_only ""
}

#############################################
# Ethernet
#############################################

check_eth() {
    log_and_screen "Checking ethernet adapters (ent)"
    adapters=$(lsdev -Cc adapter)
    all_ent=$(print -- "$adapters" | awk '/^ent[0-9]+ / {print $1}' | sort -t t -k 3 -n)

    used=""
    add_used() { for d in "$@"; do [[ -n "$d" ]] && used="${used}${d}
"; done; }

    # physical cards and VLAN pseudo-adapters
    add_used $(print -- "$adapters" | awk '/^ent[0-9]+ / && /Available/ && /PCI/ {print $1}')
    add_used $(print -- "$adapters" | awk '/^ent[0-9]+ / && /VLAN/ {print $1}')

    # SEAs and their members
    for sea in $(print -- "$adapters" | awk '/^ent[0-9]+ / && /Shared Ethernet/ {print $1}'); do
        attrs=$(lsattr -El "$sea")
        real=$(print -- "$attrs" | awk '$1=="real_adapter" {print $2}')
        virt=$(print -- "$attrs" | awk '$1=="virt_adapters" {print $2}' | tr ',' ' ')
        ctl=$(print -- "$attrs" | awk '$1=="ctl_chan" {print $2}')
        log_only "SEA $sea: real=$real virt=$virt ctl_chan=$ctl"
        add_used "$sea" "$real" "$ctl" $virt
    done

    # EtherChannels and their members
    for ec in $(print -- "$adapters" | awk '/^ent[0-9]+ / && /EtherChannel/ {print $1}'); do
        members=$(lsattr -El "$ec" | awk '$1=="adapter_names" || $1=="backup_adapter" {print $2}' | tr ',' ' ')
        log_only "EtherChannel $ec: $members"
        add_used "$ec" $members
    done

    # anything mapped to a client
    add_used $("$IOSCLI" lsmap -all -net 2>/dev/null | awk '/^ent[0-9]+ / {print $1}')

    used=$(print -- "$used" | sort -u)
    link_down=$(errpt 2>/dev/null | awk '/Physical link down/ && $5 ~ /^ent[0-9]+$/ {print $5}' | sort -u)
    log_only "used:"; log_only "$used"; log_only "link down:"; log_only "$link_down"

    unused=""
    for ent in $all_ent; do
        if print -- "$used" | grep -qx "$ent"; then
            if print -- "$link_down" | grep -qx "$ent"; then
                log_and_screen "  $ent" "in use but has link-down errors (check)"
                unused="$unused $(devnum "$ent")"
            else
                log_only "$ent in use"
            fi
        else
            log_and_screen "  $ent" "not in use"
            unused="$unused $(devnum "$ent")"
        fi
    done

    if [[ -n "$unused" ]]; then
        screen_only ""
        log_and_screen "To remove, as padmin (verify link-down ones first):"
        log_and_screen "  for num in$unused; do"
        log_and_screen "    rmtcpip -f -interface et\${num}"
        log_and_screen "    rmtcpip -f -interface en\${num}"
        log_and_screen "    rmdev -dev en\${num} -recursive -ucfg"
        log_and_screen "    rmdev -dev et\${num} -recursive -ucfg"
        log_and_screen "    rmdev -dev ent\${num} -recursive -ucfg"
        log_and_screen "    chdev -dev ent\${num} -attr autoconfig=defined"
        log_and_screen "  done"
    else
        log_and_screen "  all ent adapters are in use"
    fi
    screen_only ""
}

(( DO_FCS )) && check_fcs
(( DO_ETH )) && check_eth
screen_only "Full detail in $logfile"
exit 0
