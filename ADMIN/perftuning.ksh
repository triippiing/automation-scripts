#!/usr/bin/ksh

######################################################################
#  _        _ _             _ _                  ____  _             #
# | |_ _ __(_|_)_ __  _ __ (_|_)_ __   __       |___ \| | __         #
# | __| '__| | | '_ \| '_ \| | | '_ \ / _` |      __) | |/ /         #
# | |_| |  | | | |_) | |_) | | | | | | (_| |     / __/|   <          #
#  \__|_|  |_|_| .__/| .__/|_|_|_| |_|\__,      |_____|_|\_\         #
#              |_|   |_|              |___/                          #
#                                                                    #
######################################################################
# AIX Performance Tuning Script (JSON output variant)               #
# Tunes disk, adapter, system-wide tunables, and ODM defaults        #
# Produces: timestamped .log and .json with before/after values      #
# Requires: root, AIX 7.1+                                           #
# Usage: ./perftuning_json.ksh [-n]  (-n = dry-run, no changes)      #
######################################################################

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="/var/log/perftuning_${TIMESTAMP}.log"
JSONFILE="/var/log/perftuning_${TIMESTAMP}.json"
DATESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DRY_RUN=0
DRY_RUN_STR="false"
ERRORS=0
WARNINGS=0

# JSON section accumulators
JSON_DISKS=""
JSON_ADAPTERS=""
JSON_TUNABLES=""
JSON_ODM_DISK=""
JSON_ODM_ADAPTER=""
DISK_COUNT=0
ADAPTER_COUNT=0
TUNABLE_COUNT=0
ODM_DISK_COUNT=0
ODM_ADAPTER_COUNT=0

# JSON fragment set by apply_chdev for caller to consume
LAST_ATTR_JSON=""

# --- Dry-run flag ---
if [[ "$1" == "-n" ]]; then
    DRY_RUN=1
    DRY_RUN_STR="true"
fi

# --- Root check ---
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# ==============================================================================
# Value capture helpers
# ==============================================================================

# Get current ODM attribute value for a device
get_attr() {
    lsattr -El "$1" 2>/dev/null | awk -v a="$2" '$1 == a {print $2}'
}

# Get current ioo tunable value
get_ioo() {
    ioo -o "$1" 2>/dev/null | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}'
}

# Get current no tunable value
get_no() {
    no -o "$1" 2>/dev/null | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}'
}

# Get current acfo tunable value
get_acfo() {
    acfo -d -t "$1" 2>/dev/null | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
}

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
        FAILED)  echo "  [${TS}] [ FAIL ] ${MSG}" >> "$LOGFILE" ;;
        WARN)    echo "  [${TS}] [ WARN ] ${MSG}" >> "$LOGFILE" ; WARNINGS=$((WARNINGS + 1)) ;;
        INFO)    echo "  [${TS}] [ INFO ] ${MSG}" >> "$LOGFILE" ;;
        DRYRUN)  echo "  [${TS}] [DRYRN] ${MSG}" >> "$LOGFILE" ;;
    esac
}

# ==============================================================================
# chdev wrapper - captures before/after, logs result, sets LAST_ATTR_JSON
# ==============================================================================

apply_chdev() {
    local DEV="$1"
    local ATTR="$2"
    local VAL="$3"
    local BEFORE AFTER RC STATUS_STR

    BEFORE=$(get_attr "$DEV" "$ATTR")

    if [[ $DRY_RUN -eq 1 ]]; then
        log_result "DRYRUN" "Would apply: chdev -l $DEV -a ${ATTR}=${VAL} -P"
        AFTER="$BEFORE"
        STATUS_STR="dry_run"
    else
        chdev -l "$DEV" -a "${ATTR}=${VAL}" -P >> "$LOGFILE" 2>&1
        RC=$?
        AFTER=$(get_attr "$DEV" "$ATTR")
        if [[ $RC -eq 0 ]]; then
            log_result "SUCCESS" "${ATTR}=${VAL} applied to ${DEV}"
            STATUS_STR="ok"
        else
            log_result "FAILED" "${ATTR}=${VAL} on ${DEV} (rc=${RC})"
            STATUS_STR="failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    LAST_ATTR_JSON="\"${ATTR}\": {\"before\": \"${BEFORE}\", \"after\": \"${AFTER}\", \"status\": \"${STATUS_STR}\"}"
}

# ==============================================================================
# JSON append helpers
# ==============================================================================

# Append a disk JSON object to JSON_DISKS accumulator
# $1 = disk name  $2 = inner attrs JSON string (starts with newline)
json_append_disk() {
    local ENTRY
    ENTRY="        \"$1\": {$2
        }"
    [[ $DISK_COUNT -gt 0 ]] && JSON_DISKS="${JSON_DISKS},"
    JSON_DISKS="${JSON_DISKS}
${ENTRY}"
    DISK_COUNT=$((DISK_COUNT + 1))
}

# Append an adapter JSON object to JSON_ADAPTERS accumulator
json_append_adapter() {
    local ENTRY
    ENTRY="        \"$1\": {$2
        }"
    [[ $ADAPTER_COUNT -gt 0 ]] && JSON_ADAPTERS="${JSON_ADAPTERS},"
    JSON_ADAPTERS="${JSON_ADAPTERS}
${ENTRY}"
    ADAPTER_COUNT=$((ADAPTER_COUNT + 1))
}

# Append a tunable key:object entry to JSON_TUNABLES
# $1 = tunable name  $2 = JSON fragment (before/after/status)
json_append_tunable() {
    [[ $TUNABLE_COUNT -gt 0 ]] && JSON_TUNABLES="${JSON_TUNABLES},"
    JSON_TUNABLES="${JSON_TUNABLES}
        $2"
    TUNABLE_COUNT=$((TUNABLE_COUNT + 1))
}

# Append an ODM disk entry
json_append_odm_disk() {
    [[ $ODM_DISK_COUNT -gt 0 ]] && JSON_ODM_DISK="${JSON_ODM_DISK},"
    JSON_ODM_DISK="${JSON_ODM_DISK}
            $1"
    ODM_DISK_COUNT=$((ODM_DISK_COUNT + 1))
}

# Append an ODM adapter entry
json_append_odm_adapter() {
    [[ $ODM_ADAPTER_COUNT -gt 0 ]] && JSON_ODM_ADAPTER="${JSON_ODM_ADAPTER},"
    JSON_ODM_ADAPTER="${JSON_ODM_ADAPTER}
            $1"
    ODM_ADAPTER_COUNT=$((ODM_ADAPTER_COUNT + 1))
}

# Write final JSON file from accumulated fragments
write_json() {
    local COMPLETED
    COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$JSONFILE" << ENDJSON
{
    "host": "$(hostname)",
    "started": "${DATESTAMP}",
    "completed": "${COMPLETED}",
    "dry_run": ${DRY_RUN_STR},
    "disks": {${JSON_DISKS}
    },
    "adapters": {${JSON_ADAPTERS}
    },
    "tunables": {${JSON_TUNABLES}
    },
    "odm": {
        "disk_fcp_mpioosdisk": {${JSON_ODM_DISK}
        },
        "adapter_vdevice_ibm_l_lan": {${JSON_ODM_ADAPTER}
        }
    },
    "summary": {
        "errors": ${ERRORS},
        "warnings": ${WARNINGS}
    }
}
ENDJSON
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

echo "Log : $LOGFILE"
echo "JSON: $JSONFILE"
[[ $DRY_RUN -eq 1 ]] && echo "DRY RUN mode active - no changes will be applied."

# ==============================================================================
# Pre-change snapshot (log only)
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
echo "  [ioo]"  >> "$LOGFILE" ; ioo  -a >> "$LOGFILE" 2>&1
echo "  [no]"   >> "$LOGFILE" ; no   -a >> "$LOGFILE" 2>&1
echo "  [acfo]" >> "$LOGFILE" ; acfo -d >> "$LOGFILE" 2>&1

# ==============================================================================
# Disk tuning
# ==============================================================================
log_header "DISK TUNING"
echo "Starting disk tuning..."

for DISK in $(lspv | awk '{print $1}'); do
    log_section "Disk: ${DISK}"
    DISK_ATTRS_JSON=""
    ATTR_COUNT=0

    if ! lsdev -l "$DISK" 2>/dev/null | grep -q "Available"; then
        log_result "SKIPPED" "${DISK} is not in Available state"
        json_append_disk "$DISK" "            \"status\": \"unavailable\""
        continue
    fi

    for ATTR in algorithm reserve_policy queue_depth max_transfer; do
        case "$ATTR" in
            algorithm)      VAL="shortest_queue" ;;
            reserve_policy) VAL="no_reserve"     ;;
            queue_depth)    VAL="32"             ;;
            max_transfer)   VAL="0x100000"       ;;
        esac

        if lsattr -El "$DISK" 2>/dev/null | grep -q "^${ATTR}"; then
            apply_chdev "$DISK" "$ATTR" "$VAL"
            [[ $ATTR_COUNT -gt 0 ]] && DISK_ATTRS_JSON="${DISK_ATTRS_JSON},"
            DISK_ATTRS_JSON="${DISK_ATTRS_JSON}
            ${LAST_ATTR_JSON}"
        else
            log_result "SKIPPED" "${ATTR} not supported on ${DISK}"
            [[ $ATTR_COUNT -gt 0 ]] && DISK_ATTRS_JSON="${DISK_ATTRS_JSON},"
            DISK_ATTRS_JSON="${DISK_ATTRS_JSON}
            \"${ATTR}\": {\"status\": \"not_supported\"}"
        fi
        ATTR_COUNT=$((ATTR_COUNT + 1))
    done

    json_append_disk "$DISK" "$DISK_ATTRS_JSON"
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
    ADAPTER_ATTRS_JSON=""
    ATTR_COUNT=0

    if ! lsdev -l "$ENT" 2>/dev/null | grep -q "Available"; then
        log_result "SKIPPED" "${ENT} is not in Available state"
        json_append_adapter "$ENT" "            \"status\": \"unavailable\""
        continue
    fi

    for BUF_ATTR in max_buf_huge max_buf_large max_buf_medium max_buf_small max_buf_tiny; do
        case "$BUF_ATTR" in
            max_buf_huge)   VAL="128"  ;;
            max_buf_large)  VAL="256"  ;;
            max_buf_medium) VAL="2048" ;;
            max_buf_small)  VAL="4096" ;;
            max_buf_tiny)   VAL="4096" ;;
        esac

        if lsattr -El "$ENT" 2>/dev/null | grep -q "^${BUF_ATTR}"; then
            apply_chdev "$ENT" "$BUF_ATTR" "$VAL"
            [[ $ATTR_COUNT -gt 0 ]] && ADAPTER_ATTRS_JSON="${ADAPTER_ATTRS_JSON},"
            ADAPTER_ATTRS_JSON="${ADAPTER_ATTRS_JSON}
            ${LAST_ATTR_JSON}"
        else
            log_result "SKIPPED" "${BUF_ATTR} not supported on ${ENT}"
            [[ $ATTR_COUNT -gt 0 ]] && ADAPTER_ATTRS_JSON="${ADAPTER_ATTRS_JSON},"
            ADAPTER_ATTRS_JSON="${ADAPTER_ATTRS_JSON}
            \"${BUF_ATTR}\": {\"status\": \"not_supported\"}"
        fi
        ATTR_COUNT=$((ATTR_COUNT + 1))
    done

    json_append_adapter "$ENT" "$ADAPTER_ATTRS_JSON"
done

# ==============================================================================
# System-wide tunables
# ==============================================================================
log_header "SYSTEM-WIDE TUNABLES"
echo "Applying system-wide tunables..."

# ioo - j2_dynamicBufferPreallocation
log_section "ioo"
BEFORE=$(get_ioo "j2_dynamicBufferPreallocation")
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: ioo -p -o j2_dynamicBufferPreallocation=256"
    AFTER="$BEFORE"
    STATUS_STR="dry_run"
else
    ioo -p -o j2_dynamicBufferPreallocation=256 >> "$LOGFILE" 2>&1
    if [[ $? -eq 0 ]]; then
        log_result "SUCCESS" "j2_dynamicBufferPreallocation=256"
        STATUS_STR="ok"
    else
        log_result "FAILED"  "ioo j2_dynamicBufferPreallocation=256"
        STATUS_STR="failed"
        ERRORS=$((ERRORS + 1))
    fi
    AFTER=$(get_ioo "j2_dynamicBufferPreallocation")
fi
json_append_tunable "ioo" "\"ioo\": {\"j2_dynamicBufferPreallocation\": {\"before\": \"${BEFORE}\", \"after\": \"${AFTER}\", \"status\": \"${STATUS_STR}\"}}"

# acfo - in_core_enabled
log_section "acfo"
BEFORE=$(get_acfo "in_core_enabled")
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: acfo -p -t in_core_enabled=1"
    AFTER="$BEFORE"
    STATUS_STR="dry_run"
else
    acfo -p -t in_core_enabled=1 >> "$LOGFILE" 2>&1
    if [[ $? -eq 0 ]]; then
        log_result "SUCCESS" "in_core_enabled=1"
        STATUS_STR="ok"
    else
        log_result "FAILED"  "acfo in_core_enabled=1"
        STATUS_STR="failed"
        ERRORS=$((ERRORS + 1))
    fi
    AFTER=$(get_acfo "in_core_enabled")
fi
json_append_tunable "acfo" "\"acfo\": {\"in_core_enabled\": {\"before\": \"${BEFORE}\", \"after\": \"${AFTER}\", \"status\": \"${STATUS_STR}\"}}"

# no - tcp_fastlo
log_section "no"
BEFORE=$(get_no "tcp_fastlo")
if [[ $DRY_RUN -eq 1 ]]; then
    log_result "DRYRUN" "Would apply: no -p -o tcp_fastlo=1"
    AFTER="$BEFORE"
    STATUS_STR="dry_run"
else
    no -p -o tcp_fastlo=1 >> "$LOGFILE" 2>&1
    if [[ $? -eq 0 ]]; then
        log_result "SUCCESS" "tcp_fastlo=1"
        STATUS_STR="ok"
    else
        log_result "FAILED"  "no tcp_fastlo=1"
        STATUS_STR="failed"
        ERRORS=$((ERRORS + 1))
    fi
    AFTER=$(get_no "tcp_fastlo")
fi
json_append_tunable "no" "\"no\": {\"tcp_fastlo\": {\"before\": \"${BEFORE}\", \"after\": \"${AFTER}\", \"status\": \"${STATUS_STR}\"}}"

# ==============================================================================
# ODM defaults (chdef)
# ODM defaults apply to future device instantiations, not live devices.
# JSON records intended value and apply status only (no before/after).
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
        STATUS_STR="dry_run"
    else
        chdef -a "$ATTR_VAL" -c disk -s fcp -t mpioosdisk >> "$LOGFILE" 2>&1
        if [[ $? -eq 0 ]]; then
            log_result "SUCCESS" "chdef disk/fcp/mpioosdisk ${ATTR}=${VAL}"
            STATUS_STR="ok"
        else
            log_result "FAILED"  "chdef disk/fcp/mpioosdisk ${ATTR}=${VAL}"
            STATUS_STR="failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    json_append_odm_disk "\"${ATTR}\": {\"value\": \"${VAL}\", \"status\": \"${STATUS_STR}\"}"
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
        STATUS_STR="dry_run"
    else
        chdef -a "$ATTR_VAL" -c adapter -s vdevice -t IBM,l-lan >> "$LOGFILE" 2>&1
        if [[ $? -eq 0 ]]; then
            log_result "SUCCESS" "chdef adapter/vdevice/IBM,l-lan ${ATTR}=${VAL}"
            STATUS_STR="ok"
        else
            log_result "FAILED"  "chdef adapter/vdevice/IBM,l-lan ${ATTR}=${VAL}"
            STATUS_STR="failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    json_append_odm_adapter "\"${ATTR}\": {\"value\": \"${VAL}\", \"status\": \"${STATUS_STR}\"}"
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

# Write JSON output
write_json

echo ""
echo "Tuning complete. Errors: ${ERRORS}  Warnings: ${WARNINGS}"
echo "Log written to : $LOGFILE"
echo "JSON written to: $JSONFILE"
[[ $ERRORS -gt 0 ]] && echo "WARNING: ${ERRORS} error(s) encountered - review log." >&2

exit $ERRORS
