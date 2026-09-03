#!/bin/ksh
#=============================================================================
# ech_rebuild.ksh
#
# Purpose : Tear down and rebuild an AIX EtherChannel (ibm_ech) adapter and
#           its physical members after a host failover / DR test / failback.
#           All addressing is discovered from ODM at runtime - nothing is
#           hardcoded.
#
# Usage   : ech_rebuild.ksh [-x] [-y] [-e entN] [-i ip] [-m netmask] [-g gw]
#
#   -x        Execute. Without this the script runs in DRY-RUN and only
#             prints what it would do. Default is dry-run.
#   -y        Assume yes to all prompts (unattended - use with care).
#   -e entN   EtherChannel device to rebuild. Only needed if the host has
#             more than one ibm_ech device.
#   -i ip     Override the IP taken from ODM (e.g. bringing the host up on
#             a DR subnet rather than restoring the production address).
#   -m mask   Override the netmask.
#   -g gw     Override the default gateway.
#
# WARNING : This removes every Ethernet adapter on the host. If you run it
#           over ssh/telnet you will cut your own session mid-flight and the
#           host will be left with no network. Run it from an HMC vterm,
#           a serial console, or the physical console.
#
# Requires: root
#=============================================================================

PROGNAME=${0##*/}
TS=$(date +%Y%m%d_%H%M%S)
LOGDIR=/var/log/ech_rebuild
LOG=${LOGDIR}/rebuild.${TS}.log
STATE=${LOGDIR}/state.${TS}

#-- Machine serials that get an extra "this is production" prompt ------------
#   Space separated. Populate with your real serials.
PROD_SERIALS="XXXXXXXX YYYYYYYY"

#-- Defaults ------------------------------------------------------------------
DRYRUN=1
ASSUME_YES=0
ECH=""
OVR_IP=""
OVR_MASK=""
OVR_GW=""

#=============================================================================
# Helpers
#=============================================================================
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG" ; }

die() { log "FATAL: $*" ; log "State captured under ${STATE}.*" ; exit 1 ; }

# run <cmd...>  - logged, honours dry-run, non-fatal on error
run() {
    if (( DRYRUN )); then
        log "DRYRUN: $*"
        return 0
    fi
    log "EXEC  : $*"
    "$@" >> "$LOG" 2>&1
    rc=$?
    (( rc != 0 )) && log "WARN  : rc=${rc} from: $*"
    return $rc
}

# run_must <cmd...> - as run(), but aborts on failure
run_must() {
    run "$@" || { (( DRYRUN )) || die "command failed: $*" ; }
}

# run_eval <string> - for commands built dynamically (mkdev/chdev attr lists)
run_eval() {
    if (( DRYRUN )); then
        log "DRYRUN: $1"
        return 0
    fi
    log "EXEC  : $1"
    eval "$1" >> "$LOG" 2>&1
    rc=$?
    (( rc != 0 )) && log "WARN  : rc=${rc} from: $1"
    return $rc
}

confirm() {
    typeset ans
    (( ASSUME_YES )) && { log "AUTO-YES: $1" ; return 0 ; }
    print -n "$1 [y/N]: "
    read ans
    case "$ans" in
        y|Y|yes|YES) log "Operator confirmed: $1" ;;
        *)           log "Aborted by operator at: $1" ; exit 1 ;;
    esac
}

pause_ack() {
    typeset ans
    (( ASSUME_YES )) && return 0
    print -n "$1 [press Enter to continue]: "
    read ans
}

# getattr <device> <attribute> - clean ODM read, no grep/awk pipeline
getattr() { lsattr -El "$1" -a "$2" -F value 2>/dev/null ; }

# link_status <entN> - returns Up / Down / Unknown
link_status() {
    typeset s
    s=$(entstat -d "$1" 2>/dev/null \
        | awk -F: '/Link Status/ { gsub(/[ \t]/,"",$2); print $2; exit }')
    print -r -- "${s:-Unknown}"
}

usage() {
    print "Usage: $PROGNAME [-x] [-y] [-e entN] [-i ip] [-m netmask] [-g gw]"
    exit 2
}

#=============================================================================
# Argument parsing
#=============================================================================
while getopts ":xye:i:m:g:" opt; do
    case "$opt" in
        x) DRYRUN=0        ;;
        y) ASSUME_YES=1    ;;
        e) ECH="$OPTARG"   ;;
        i) OVR_IP="$OPTARG"   ;;
        m) OVR_MASK="$OPTARG" ;;
        g) OVR_GW="$OPTARG"   ;;
        *) usage ;;
    esac
done

[[ $(id -u) -eq 0 ]] || { print "Must be run as root." ; exit 1 ; }
mkdir -p "$LOGDIR" 2>/dev/null

log "=== ${PROGNAME} starting on $(hostname) ==="
(( DRYRUN )) && log "MODE  : DRY-RUN (no changes will be made). Re-run with -x to execute."
(( DRYRUN )) || log "MODE  : EXECUTE"

#=============================================================================
# 1. Discovery
#=============================================================================
if [[ -z "$ECH" ]]; then
    ECH=$(lsdev -Cc adapter -t ibm_ech -F name)
    case "$(print -r -- "$ECH" | wc -l | tr -d ' ')" in
        0) die "No ibm_ech (EtherChannel) device found on this host." ;;
        1) : ;;
        *) log "Multiple EtherChannel devices found:" ; log "$ECH"
           die "Specify which one with -e entN" ;;
    esac
fi

lsdev -Cl "$ECH" >/dev/null 2>&1 || die "${ECH} is not a valid device."

EN="en${ECH#ent}"          # standard Ethernet interface
ET="et${ECH#ent}"          # IEEE 802.3 interface

MACHSERIAL=$(lsattr -El sys0 -a systemid -F value 2>/dev/null | sed 's/^IBM,02//')
[[ -z "$MACHSERIAL" ]] && MACHSERIAL=$(prtconf 2>/dev/null | awk -F: '/Machine Serial Number/ {gsub(/ /,"",$2); print $2}')

#-- EtherChannel attributes (all preserved, not just adapter_names) ----------
PRIMARY=$(getattr "$ECH" adapter_names)     # may be a comma separated list
BACKUP=$(getattr  "$ECH" backup_adapter)
MODE=$(getattr    "$ECH" mode)              # standard / round_robin / 8023ad
HASH=$(getattr    "$ECH" hash_mode)
PINGADDR=$(getattr "$ECH" netaddr)          # NB: ECH netaddr = failover ping target
JUMBO=$(getattr   "$ECH" use_jumbo_frame)
RETRIES=$(getattr "$ECH" num_retries)
RETRYT=$(getattr  "$ECH" retry_time)
[[ -z "$RETRIES" ]] && RETRIES=3
[[ -z "$RETRYT"  ]] && RETRYT=3

#-- Interface attributes ------------------------------------------------------
SERVIP=$(getattr   "$EN" netaddr)
SERVMASK=$(getattr "$EN" netmask)
MTU=$(getattr      "$EN" mtu)
ALIAS4=$(getattr   "$EN" alias4)
GW=$(netstat -rn 2>/dev/null | awk '$1=="default" {print $2; exit}')
[[ -z "$GW" ]] && GW=$(lsattr -El inet0 -a route -F value 2>/dev/null | awk -F, '{print $6}' | awk '{print $1}')

#-- Cross-check ODM against what is actually live -----------------------------
LIVEIP=$(ifconfig "$EN" 2>/dev/null | awk '/inet /{print $2; exit}')
if [[ -n "$LIVEIP" && -n "$SERVIP" && "$LIVEIP" != "$SERVIP" ]]; then
    log "WARN  : live IP on ${EN} (${LIVEIP}) differs from ODM (${SERVIP})."
    log "WARN  : ODM value will be used on rebuild. Override with -i if wrong."
fi

#-- Apply any operator overrides ---------------------------------------------
[[ -n "$OVR_IP"   ]] && { log "Override IP      : ${SERVIP:-none} -> ${OVR_IP}"     ; SERVIP="$OVR_IP" ; }
[[ -n "$OVR_MASK" ]] && { log "Override netmask : ${SERVMASK:-none} -> ${OVR_MASK}" ; SERVMASK="$OVR_MASK" ; }
[[ -n "$OVR_GW"   ]] && { log "Override gateway : ${GW:-none} -> ${OVR_GW}"         ; GW="$OVR_GW" ; }

[[ -z "$SERVIP"   ]] && die "No IP address discovered on ${EN} and none supplied with -i."
[[ -z "$SERVMASK" ]] && die "No netmask discovered on ${EN} and none supplied with -m."
[[ -z "$PRIMARY"  ]] && die "Could not read adapter_names from ${ECH}."
[[ -z "$GW"       ]] && log "WARN  : no default gateway found. Routing will not be verified."

#=============================================================================
# 2. Capture current state to disk BEFORE destroying anything
#=============================================================================
if (( ! DRYRUN )); then
    lsattr -El "$ECH"  > "${STATE}.ech"     2>&1
    lsattr -El "$EN"   > "${STATE}.en"      2>&1
    lsattr -El inet0   > "${STATE}.inet0"   2>&1
    lsdev  -Cc adapter > "${STATE}.adapters" 2>&1
    lsdev  -Cc if      > "${STATE}.if"      2>&1
    ifconfig -a        > "${STATE}.ifconfig" 2>&1
    netstat -rn        > "${STATE}.route"   2>&1
    for a in $(print -r -- "${PRIMARY},${BACKUP}" | tr ',' ' '); do
        [[ "$a" = "NONE" || -z "$a" ]] && continue
        lscfg -vl "$a" >> "${STATE}.loccodes" 2>&1
    done
    log "Pre-change state saved to ${STATE}.*"
fi

#=============================================================================
# 3. Pre-flight summary and confirmations
#=============================================================================
log "-----------------------------------------------------------------"
log " Host            : $(hostname)   Serial: ${MACHSERIAL:-unknown}"
log " EtherChannel    : ${ECH}  (interfaces ${EN} / ${ET})"
log " Primary member  : ${PRIMARY}"
log " Backup member   : ${BACKUP:-NONE}"
log " Mode / hash     : ${MODE:-default} / ${HASH:-default}"
log " Failover ping   : ${PINGADDR:-none}"
log " Jumbo frames    : ${JUMBO:-no}"
log " IP / netmask    : ${SERVIP} / ${SERVMASK}"
log " MTU / alias4    : ${MTU:-default} / ${ALIAS4:-none}"
log " Default gateway : ${GW:-none}"
log "-----------------------------------------------------------------"

#-- Remote session check ------------------------------------------------------
MYTTY=$(tty 2>/dev/null)
case "$MYTTY" in
    /dev/pts/*)
        log "WARN  : you appear to be on a network session (${MYTTY})."
        log "WARN  : this script removes ALL Ethernet adapters - your session WILL drop"
        log "WARN  : and the host will be unreachable until the rebuild completes."
        log "WARN  : run this from an HMC vterm or the physical console instead."
        confirm "Continue anyway?"
        ;;
esac

#-- Production serial check ---------------------------------------------------
for s in $PROD_SERIALS; do
    if [[ "$MACHSERIAL" = "$s" ]]; then
        log "NOTICE: machine serial ${MACHSERIAL} is listed as PRODUCTION."
        log "NOTICE: this is expected if you are failing back from a DR test."
        confirm "Confirm you intend to rebuild the EtherChannel on PRODUCTION"
        break
    fi
done

confirm "Remove and rebuild ${ECH} / ${EN} with ${SERVIP} netmask ${SERVMASK}"

#=============================================================================
# 4. Teardown  (order matters - members cannot be removed while in the channel)
#=============================================================================
log "--- Teardown ---"

run ifconfig "$EN" down detach
run ifconfig "$ET" down detach

# Removing the ECH with -R takes its en/et children with it
run_must rmdev -Rdl "$ECH"

# Now the physical members are free
for dev in $(lsdev -Cc adapter -F name | grep '^ent[0-9]'); do
    run rmdev -Rdl "$dev"
done

# Any orphaned interfaces / Defined-state Ethernet devices left behind
for dev in $(lsdev -Cc if -F name | grep -E '^(en|et)[0-9]'); do
    run rmdev -dl "$dev"
done
for dev in $(lsdev -C -S D -F name | grep -E '^(ent|en|et)[0-9]'); do
    run rmdev -Rdl "$dev"
done

log "Remaining adapters after teardown:"
(( DRYRUN )) || lsdev -Cc adapter | tee -a "$LOG"

#=============================================================================
# 5. Rediscover hardware
#=============================================================================
log "--- Running cfgmgr ---"
run_must cfgmgr
(( DRYRUN )) || lsdev -Cc adapter | grep '^ent' | tee -a "$LOG"

#-- Confirm the members we intend to use actually came back -------------------
if (( ! DRYRUN )); then
    for a in $(print -r -- "${PRIMARY},${BACKUP}" | tr ',' ' '); do
        [[ "$a" = "NONE" || -z "$a" ]] && continue
        if ! lsdev -Cl "$a" -F status | grep -q Available; then
            log "Adapter ${a} is not Available after cfgmgr."
            log "Currently present:"
            lsdev -Cc adapter -F 'name status physloc' | grep '^ent' | tee -a "$LOG"
            log "Pre-change location codes are in ${STATE}.loccodes"
            die "Cannot rebuild ${ECH} - expected member ${a} is missing or renumbered."
        fi
    done
fi

#=============================================================================
# 6. Link status checks (informational - does not abort)
#=============================================================================
log "--- Link status ---"
DOWN=0
for a in $(print -r -- "${PRIMARY},${BACKUP}" | tr ',' ' '); do
    [[ "$a" = "NONE" || -z "$a" ]] && continue
    st=$(link_status "$a")
    log "  ${a}: Link Status = ${st}"
    if [[ "$st" != "Up" ]]; then
        DOWN=$((DOWN+1))
        log "  WARN: ${a} is not showing link Up. It will still be configured"
        log "  WARN: into the EtherChannel - get it checked (entstat -d ${a})."
    fi
done
if (( DOWN > 1 )); then
    log "WARN  : MORE THAN ONE MEMBER IS DOWN. Get confirmation before proceeding."
    pause_ack "Acknowledge"
fi

#=============================================================================
# 7. Rebuild the EtherChannel with the original attribute set
#=============================================================================
log "--- Rebuilding EtherChannel ---"

MKCMD="mkdev -c adapter -s pseudo -t ibm_ech -a adapter_names='${PRIMARY}'"
[[ -n "$BACKUP"   && "$BACKUP" != "NONE" ]] && MKCMD="${MKCMD} -a backup_adapter='${BACKUP}'"
[[ -n "$MODE"     && "$MODE"   != "standard" ]] && MKCMD="${MKCMD} -a mode='${MODE}'"
[[ -n "$HASH"     && "$HASH"   != "default"  ]] && MKCMD="${MKCMD} -a hash_mode='${HASH}'"
[[ -n "$PINGADDR" && "$PINGADDR" != "0.0.0.0" ]] && MKCMD="${MKCMD} -a netaddr='${PINGADDR}'"
[[ -n "$JUMBO"    && "$JUMBO"  != "no" ]] && MKCMD="${MKCMD} -a use_jumbo_frame='${JUMBO}'"
MKCMD="${MKCMD} -a num_retries='${RETRIES}' -a retry_time='${RETRYT}'"

if (( DRYRUN )); then
    log "DRYRUN: ${MKCMD}"
    NEWECH="$ECH"
else
    log "EXEC  : ${MKCMD}"
    NEWECH=$(eval "$MKCMD" 2>&1 | tee -a "$LOG" | awk '/Available|Defined/ {print $1; exit}')
    [[ -z "$NEWECH" ]] && die "mkdev did not return a device name - EtherChannel not created."
    log "Created ${NEWECH}"
    [[ "$NEWECH" != "$ECH" ]] && log "NOTE  : device renumbered ${ECH} -> ${NEWECH}"
fi

NEWEN="en${NEWECH#ent}"

#=============================================================================
# 8. Reapply IP configuration
#=============================================================================
log "--- Configuring ${NEWEN} ---"
run_must /usr/lib/methods/defif

CHCMD="chdev -l ${NEWEN} -a netaddr='${SERVIP}' -a netmask='${SERVMASK}' -a state=up"
[[ -n "$MTU" && "$MTU" != "1500" ]] && CHCMD="${CHCMD} -a mtu='${MTU}'"
run_eval "$CHCMD"

if [[ -n "$ALIAS4" ]]; then
    log "Restoring IPv4 alias(es): ${ALIAS4}"
    run_eval "chdev -l ${NEWEN} -a alias4='${ALIAS4}'"
fi

run ifconfig "$NEWEN" up

#-- Default route -------------------------------------------------------------
run mkdev -l inet0
if [[ -n "$GW" ]] && (( ! DRYRUN )); then
    if ! netstat -rn | awk '$1=="default"' | grep -q .; then
        log "Default route missing after mkdev inet0 - adding ${GW} to ODM."
        run_eval "chdev -l inet0 -a route=net,-hopcount,0,,0,${GW}"
    fi
fi

#=============================================================================
# 9. Verification
#=============================================================================
log "--- Verification ---"
if (( DRYRUN )); then
    log "DRYRUN: would verify ifconfig / netstat -rn / entstat / ping ${GW:-<gw>}"
    log "=== ${PROGNAME} dry-run complete. Re-run with -x to execute. ==="
    exit 0
fi

ifconfig "$NEWEN" | tee -a "$LOG"
netstat -rn        | tee -a "$LOG"
entstat -d "$NEWECH" | grep -E "Active channel|Link Status|ETHERNET" | tee -a "$LOG"

RC=0
if [[ -n "$GW" ]]; then
    log "Pinging default gateway ${GW} ..."
    if ping -c 2 "$GW" >> "$LOG" 2>&1; then
        log "PASS  : gateway ${GW} is reachable."
    else
        log "FAIL  : gateway ${GW} is NOT reachable."
        RC=1
    fi
fi

for a in $(print -r -- "${PRIMARY},${BACKUP}" | tr ',' ' '); do
    [[ "$a" = "NONE" || -z "$a" ]] && continue
    log "  ${a}: Link Status = $(link_status "$a")"
done

log "=== ${PROGNAME} finished (rc=${RC}). Log: ${LOG} ==="
exit $RC
