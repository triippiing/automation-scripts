#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: rulestoset.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Applies the standard VIOS "rules" for this server: per-adapter-model FC settings, plus the
#|              fixed defaults every VIO server gets, then deploys them.
#|
#|              Settings come from adapter_rules.conf next to this script, one per line:
#|
#|                  <adapter id>   <attribute=value>        # FC adapter, matched on the id lscfg shows in ()
#|                  default        <attribute=value>        # used for any fcs adapter with no explicit entry
#|                  <rule type>    <attribute=value>        # applied unconditionally, e.g.
#|                                                            adapter/vdevice/IBM,l-lan  max_buf_huge=128
#|
#| Usage:       rulestoset.ksh [-c <conf>] [-n]
#|                -c  alternative config file
#|                -n  dry run - print the rules commands without running them
#|
#| Note:        Requires vios_lib.ksh alongside this script. Run as root (padmin: oem_setup_env).
#|              "rules -o modify" is tried first and "rules -o add" used only if the rule does not yet exist.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 19/05/2025, recovered from the old NIM server
#| Revision History:
#| 19/05/2025 : original : Base script
#| 27/08/2026 : original : Updated rules for VIOS 4.1.2.10
#| 03/09/2026 :            : Refactor - settings moved to adapter_rules.conf, modify-then-add instead of a
#|                           failing add, dry run, exact-match dedup of adapter ids, shared logging
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

CONF="$(dirname "$0")/adapter_rules.conf"
DRYRUN=0

usage() { print -u2 "Usage: $0 [-c <conf>] [-n]"; exit 1; }

while getopts "c:n" opt; do
    case "$opt" in
        c) CONF="$OPTARG" ;;
        n) DRYRUN=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -r "$CONF" ]] || { print -u2 "ERROR: config not found: $CONF"; exit 1; }
require_root
is_vios || { print -u2 "ERROR: not a VIO server"; exit 1; }

log_init "${LOGDIR}/rulestoset.log" "$@"
trap log_close EXIT
(( DRYRUN )) && log_and_screen "Mode" "DRY RUN - nothing will be changed"

conf_lines() { grep -v '^[[:space:]]*#' "$CONF" | awk 'NF >= 2 {print $1, $2}'; }

errors=0
apply_rule() {   # apply_rule <rule type> <attr=value>
    rtype=$1 setting=$2
    if (( DRYRUN )); then
        log_and_screen "  would set" "$rtype $setting"
        return 0
    fi
    if run_logged rules -o modify -t "$rtype" -a "$setting" || run_logged rules -o add -t "$rtype" -a "$setting"; then
        log_and_screen "  set" "$rtype $setting"
    else
        log_and_screen "  FAILED" "$rtype $setting (see $logfile)"
        errors=1
    fi
}

#############################################
# FC adapters by model id
#############################################

log_and_screen "FC adapter rules"
seen=""
for dev in $(lsdev -Cc adapter | awk '/^fcs[0-9]+ / {print $1}'); do
    id=$(lscfg -vl "$dev" 2>/dev/null | awk -v d="$dev" '$1 == d { if (match($0, /\([^)]+\)/)) print substr($0, RSTART+1, RLENGTH-2) }')
    [[ -n "$id" ]] || { log_and_screen "  $dev" "no adapter id found, skipping"; continue; }
    print -- "$seen" | grep -qx "$id" && continue
    seen="${seen}${id}
"

    settings=$(conf_lines | awk -v i="$id" '$1 == i {print $2}')
    if [[ -z "$settings" ]]; then
        settings=$(conf_lines | awk '$1 == "default" {print $2}')
        if [[ -z "$settings" ]]; then
            log_and_screen "  $dev ($id)" "WARNING no settings in $CONF and no default"
            continue
        fi
        log_and_screen "  $dev ($id)" "no explicit settings, using default"
    else
        log_and_screen "  $dev ($id)"
    fi
    for s in $settings; do
        apply_rule "adapter/pciex/$id" "$s"
    done
done

#############################################
# Fixed rules for every VIO server
#############################################

log_and_screen "Standard rules"
conf_lines | awk '$1 ~ /\// {print $1, $2}' | while read -r rtype setting; do
    apply_rule "$rtype" "$setting"
done

#############################################
# Deploy
#############################################

if (( DRYRUN )); then
    log_and_screen "Deploy" "skipped (dry run)"
    exit 0
fi
if run_logged rules -o deploy && run_logged rulescfgset; then
    log_and_screen "Deploy" "rules deployed and applied"
else
    log_and_screen "Deploy" "FAILED (see $logfile)"
    errors=1
fi
(( errors )) && log_and_screen "Result" "completed with errors" || log_and_screen "Result" "OK"
exit $errors
