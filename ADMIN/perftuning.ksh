#!/usr/bin/ksh
# ==============================================================================
# AIX Performance Tuning Script
# Tunes disk, network adapter, system-wide tunables, and ODM defaults
# Requires: root, AIX 7.1+
# Usage: ./perftuning.ksh [-n]   (-n = dry-run, no changes applied)
# ==============================================================================

LOGFILE="/var/log/perftuning_$(date '+%Y%m%d_%H%M%S').log"
DATESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DRY_RUN=0
ERRORS=0
WARNINGS=0

# --- Dry-run flag ---
if [[ "$1" == "-n" ]]; then
    DRY_RUN=1
fi

# --- Root check ---
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# ==============================================================================
# Logging helpers
# ==============================================================================
log_header() {
    echo "" >> "$LOGFILE"
    echo "################################################################################" >> "$LOGFILE"
    echo "# $1" >> "$LOGFILE"
    echo "################################################################################" >> "$LOGFILE"
}

log_section() {
    echo "" >> "$LOGFILE"
    echo "  +------------------------------------------" >> "$LOGFILE"
    echo "  | $1" >> "$LOGFILE"
    echo "  +------------------------------------------" >> "$LOGFILE"
}

log_result() {
    local STATUS="$1"
    local MSG="$2"
    local TS
    TS=$(date '+%H:%M:%S')
    case "$STATUS" in
        SUCCESS) echo "  [${TS}] [  OK  ] ${MSG}" >> "$LOGFILE" ;;
        SKIPPED) echo "  [${TS}] [ SKIP ] ${MSG}" >> "$LOGFILE" ;;
        FAILED)  echo "  [${TS}] [ FAIL ] ${MSG}" >> "$LOGFILE" ; ERRORS=$((ERRORS + 1)) ;;
        WARN)    echo "  [${TS}] [ WARN ] ${MSG}" >> "$LOGFILE" ; WARNINGS=$((WARNINGS + 1)) ;;
        INFO)    echo "  [${TS}] [ INFO ] ${MSG}" >> "$LOGFILE" ;;
        DRYRUN)  echo "  [${TS}] [DRYRN] ${MSG}" >> "$LOGFILE" ;;
    esac
}

apply_chdev() {
    local DEV="$1"
    local ATTR="$2"
    local VAL="$3"
    if [[ $DRY_RUN -eq 1 ]]; then
        log_result "DRYRUN" "Would apply: chdev -l $DEV -a ${ATTR}=${VAL} -P"
        return 0
    fi
    chdev -l "$DEV" -a "${ATTR}=${VAL}" -P >> "$LOGFILE" 2>&1
    local RC=$?
    if [[ $RC -eq 0 ]]; then
        log_result "SUCCESS" "${ATTR}=${VAL} applied to ${DEV}"
    else
        log_result "FAILED" "${ATTR}=${VAL} on ${DEV} (rc=${RC})"
    fi
    return $RC
}

# ==============================================================================
# Initialise log
# ==============================================================================
{
    echo "################################################################################"
    echo "# AIX PERFORMANCE TUNING"
    echo "# Host     : $(hostname)"
    echo "# Started  : ${DATESTAMP}"
    [[ $DRY_RUN -eq 1 ]] && echo "# Mode     : DRY RUN - no changes will be applied"
    echo "################################################################################"
} > "$LOGFILE"

echo "Log: $LOGFILE"
[[ $DRY_RUN -eq 1 ]] && echo "DRY RUN mode active - no changes will be applied."

# ==============================================================================
# Pre-change snapshot
# ==============================================================================
log_header "PRE-CHANGE SNAPSHOT"

log_section "Disk attributes (lspv)"
for DISK in $(lspv | awk '{print $1}'); do
    echo "  --- ${DISK} ---" >> "$LOGFILE"
    lsattr -El "$DISK" 2>/dev/null >> "$LOGFILE"
done

log_section "Adapter attributes"
for ENT in $(lsdev -Cc adapter | awk '$1 ~ /^ent[0-9]+/ {print $1}'); do
    echo "  --- ${ENT} ---" >> "$LOGFILE"
    lsattr -El "$ENT" 2>/dev/null >> "$LOGFILE"
done

log_section "System tunables"
echo "  [ioo]" >> "$LOGFILE"  ; ioo  -a >> "$LOGFILE" 2>&1
echo "  [no]"  >> "$LOGFILE"  ; no   -a >> "$LOGFILE" 2>&1
echo "  [acfo]" >> "$LOGFILE" ; acfo -d >> "$LOGFILE" 2>&1

# ==============================================================================
# Disk tuning
# ==============================================================================
log_header "DISK TUNING"
echo "Starting disk tuning..."

for DISK in $(lspv | awk '{print $1}'); do
    log_section "Disk: ${DISK}"

    # Skip non-Available devices
    if ! lsdev -l "$DISK" 2>/dev/null | grep -q "Available"; then
        log_result "SKIPPED" "${DISK} is not in Available state"
        continue
    fi

    # Algorithm
    if lsattr -El "$DISK" 2>/dev/null | grep -q "^algorithm"; then
        apply_chdev "$DISK" "algorithm" "shortest_queue"
    else
        log_result "SKIPPED" "algorithm not supported on ${DISK}"
    fi

    # Reserve policy
    if lsattr -El "$DISK" 2>/dev/null | grep -q "^reserve_policy"; then
        apply_chdev "$DISK" "reserve_policy" "no_reserve"
    else
        log_result "SKIPPED" "reserve_policy not supported on ${DISK}"
    fi

    # Queue depth
    if lsattr -El "$DISK" 2>/dev/null | grep -q "^queue_depth"; then
        apply_chdev "$DISK" "queue_depth" "32"
    else
        log_result "SKIPPED" "queue_depth not supported on ${DISK}"
    fi

    # Max transfer
    if lsattr -El "$DISK" 2>/dev/null | grep -q "^max_transfer"; then
        apply_chdev "$DISK" "max_transfer" "0x100000"
    else
        log_result "SKIPPED" "max_transfer not supported on ${DISK}"
    fi
done

# ==============================================================================
# Network adapter tuning
# ==============================================================================
log_header "NETWORK ADAPTER TUNING"
echo "Starting network adapter tuning..."

ENT_LIST=$(lsdev -Cc adapter | awk '$1 ~ /^ent[0-9]+/ {print $1}')

if [[ -z "$ENT_LIST" ]]; then
    log_result "WARN" "No ent adapters found"
fi

for ENT in $ENT_LIST; do
    log_section "Adapter: ${ENT}"

    if ! lsdev -l "$ENT" 2>/dev/null | grep -q "Available"; then
        log_result "SKIPPED" "${ENT} is not in Available state"
        continue
    fi

    for BUF_ATTR in max_buf_huge max_buf_large max_buf_medium max_buf_small max_buf_tiny; do
        if lsattr -El "$ENT" 2>/dev/null | grep -q "^${BUF_ATTR}"; then
            case "$BUF_ATTR" in
                max_buf_huge)   apply_chdev "$ENT" "$BUF_ATTR" "128"  ;;
                max_buf_large)  apply_chdev "$ENT" "$BUF_ATTR" "256"  ;;
                max_buf_medium) apply_chdev "$ENT" "$BUF_ATTR" "2048" ;;
                max_buf_small)  apply_chdev "$ENT" "$BUF_ATTR" "4096" ;;
                max_buf_tiny)   apply_chdev "$ENT" "$BUF_ATTR" "4096" ;;
            esac
        else
            log_result "SKIPPED" "${BUF_ATTR} not supported on ${ENT}"
        fi
    done
done

# ==============================================================================
# System-wide tunables
# ==============================================================================
log_header "SYSTEM-WIDE TUNABLES"
echo "Applying system-wide tunables..."

log_section "ioo"
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: ioo -p -o j2_dynamicBufferPreallocation=256"
else
    ioo -p -o j2_dynamicBufferPreallocation=256 >> "$LOGFILE" 2>&1
    [[ $? -eq 0 ]] && log_result "SUCCESS" "j2_dynamicBufferPreallocation=256" \
                   || log_result "FAILED"  "ioo j2_dynamicBufferPreallocation=256"
fi

log_section "acfo"
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: acfo -p -t in_core_enabled=1"
else
    acfo -p -t in_core_enabled=1 >> "$LOGFILE" 2>&1
    [[ $? -eq 0 ]] && log_result "SUCCESS" "in_core_enabled=1" \
                   || log_result "FAILED"  "acfo in_core_enabled=1"
fi

log_section "no"
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: no -p -o tcp_fastlo=1"
else
    no -p -o tcp_fastlo=1 >> "$LOGFILE" 2>&1
    [[ $? -eq 0 ]] && log_result "SUCCESS" "tcp_fastlo=1" \
                   || log_result "FAILED"  "no tcp_fastlo=1"
fi

# ==============================================================================
# ODM defaults (chdef)
# ==============================================================================
log_header "ODM DEFAULTS (chdef)"
echo "Updating ODM defaults..."

log_section "Disk - fcp/mpioosdisk"
for ATTR_VAL in \
    "algorithm=shortest_queue" \
    "reserve_policy=no_reserve" \
    "max_transfer=0x100000" \
    "queue_depth=32"
do
    ATTR="${ATTR_VAL%%=*}"
    VAL="${ATTR_VAL##*=}"
    if [[ $DRY_RUN -eq 1 ]]; then
        log_result "DRYRUN" "Would apply: chdef -a ${ATTR_VAL} -c disk -s fcp -t mpioosdisk"
    else
        chdef -a "$ATTR_VAL" -c disk -s fcp -t mpioosdisk >> "$LOGFILE" 2>&1
        [[ $? -eq 0 ]] && log_result "SUCCESS" "chdef disk/fcp/mpioosdisk ${ATTR}=${VAL}" \
                       || log_result "FAILED"  "chdef disk/fcp/mpioosdisk ${ATTR}=${VAL}"
    fi
done

log_section "Adapter - vdevice/IBM,l-lan"
for ATTR_VAL in \
    "max_buf_huge=128" \
    "max_buf_large=256" \
    "max_buf_medium=2048" \
    "max_buf_small=4096" \
    "max_buf_tiny=4096"
do
    ATTR="${ATTR_VAL%%=*}"
    VAL="${ATTR_VAL##*=}"
    if [[ $DRY_RUN -eq 1 ]]; then
        log_result "DRYRUN" "Would apply: chdef -a ${ATTR_VAL} -c adapter -s vdevice -t IBM,l-lan"
    else
        chdef -a "$ATTR_VAL" -c adapter -s vdevice -t IBM,l-lan >> "$LOGFILE" 2>&1
        [[ $? -eq 0 ]] && log_result "SUCCESS" "chdef adapter/vdevice/IBM,l-lan ${ATTR}=${VAL}" \
                       || log_result "FAILED"  "chdef adapter/vdevice/IBM,l-lan ${ATTR}=${VAL}"
    fi
done

# ==============================================================================
# Summary
# ==============================================================================
log_header "SUMMARY"
{
    echo "  Host      : $(hostname)"
    echo "  Completed : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Errors    : ${ERRORS}"
    echo "  Warnings  : ${WARNINGS}"
    [[ $DRY_RUN -eq 0 ]] && echo "  NOTE      : chdev -P changes require a reboot to take full effect"
    [[ $DRY_RUN -eq 1 ]] && echo "  Mode      : DRY RUN - no changes were applied"
} >> "$LOGFILE"

echo ""
echo "Tuning complete. Errors: ${ERRORS}  Warnings: ${WARNINGS}"
echo "Log written to: $LOGFILE"
[[ $ERRORS -gt 0 ]] && echo "WARNING: ${ERRORS} error(s) encountered - review log." >&2

exit $ERRORS