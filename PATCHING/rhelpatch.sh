#!/bin/bash

##############################################################################
# RHEL 8.x / 9.x System Update & Patching Script
##############################################################################

set -euo pipefail

# --- Configuration ---
LOG_DIR="/var/log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/rhelpatching_${TIMESTAMP}.log"
SUMMARY_LOG="${LOG_DIR}/rhelpatching_summary.log"
SNAPSHOT_FILE="${LOG_DIR}/rpm_snapshot_${TIMESTAMP}.txt"

AUTO_REBOOT=false
SECURITY_ONLY=false

# --- Colors (only if interactive) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

# --- Functions ---

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%F %T')] [$level] $msg" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR" "$1"
    {
        echo "===== $(date) ====="
        echo "Host: $(hostname)"
        echo "Log: $LOG_FILE"
        echo "Result: FAILED - $1"
        echo ""
    } >> "$SUMMARY_LOG"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || fail "Must be run as root."
}

check_log_dir_writable() {
    [[ -w "$LOG_DIR" ]] || fail "Log directory '$LOG_DIR' is not writable."
}

check_dnf_not_running() {
    if pgrep -x dnf &>/dev/null || pgrep -x dnf5 &>/dev/null; then
        fail "DNF is already running (possibly dnf-automatic). Aborting to avoid conflicts."
    fi
}

ensure_dnf_utils() {
    if ! command -v needs-restarting &>/dev/null; then
        log "INFO" "needs-restarting not found; installing dnf-utils..."
        dnf -y install dnf-utils -q >> "$LOG_FILE" 2>&1 \
            || log "WARNING" "Could not install dnf-utils; reboot detection will use fallback."
    fi
}

# --- Start ---

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

log "INFO" "==== RHEL 9 Patching Started ===="
log "INFO" "Log file:      $LOG_FILE"
log "INFO" "Snapshot file: $SNAPSHOT_FILE"
log "INFO" "Security only: $SECURITY_ONLY"
log "INFO" "Auto reboot:   $AUTO_REBOOT"

check_root
check_log_dir_writable
check_dnf_not_running

# --- Step 1: Pre-patch RPM Snapshot ---
log "INFO" "Taking pre-patch RPM snapshot..."
rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort > "$SNAPSHOT_FILE" \
    || log "WARNING" "RPM snapshot failed; continuing anyway."
log "INFO" "Snapshot saved to $SNAPSHOT_FILE"

# --- Step 2: Ensure needs-restarting is available ---
ensure_dnf_utils

# --- Step 3: Refresh Metadata ---
log "INFO" "Refreshing DNF metadata..."
dnf -y makecache >> "$LOG_FILE" 2>&1 \
    || fail "Failed to refresh DNF metadata. Check repo configuration."

# --- Step 4: Check for Updates ---
log "INFO" "Checking for available updates..."

set +e
dnf check-update >> "$LOG_FILE" 2>&1
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
    log "INFO" "System is already up to date. Nothing to do."

    {
        echo "===== $(date) ====="
        echo "Host: $(hostname)"
        echo "Log: $LOG_FILE"
        echo "Result: Already up to date"
        echo "Reboot required: false"
        echo ""
    } >> "$SUMMARY_LOG"

    exit 0

elif [[ $rc -eq 100 ]]; then
    log "INFO" "Updates are available."
else
    fail "dnf check-update returned unexpected exit code $rc."
fi

# --- Step 5: Apply Updates ---
log "INFO" "Applying updates..."

if [[ "$SECURITY_ONLY" == true ]]; then
    log "INFO" "Mode: security patches only."
    dnf -y upgrade \
        --refresh \
        --best \
        --security \
        >> "$LOG_FILE" 2>&1 || fail "DNF security upgrade failed."
else
    log "INFO" "Mode: all available updates."
    dnf -y upgrade \
        --refresh \
        --best \
        >> "$LOG_FILE" 2>&1 || fail "DNF upgrade failed."
fi

log "INFO" "Updates installed successfully."

# --- Step 6: Post-Update Verification ---
log "INFO" "Verifying no updates remain..."

REMAINING=$(dnf list updates -q 2>/dev/null | tail -n +2 | wc -l || echo "unknown")
log "INFO" "Remaining packages with pending updates: $REMAINING"

if [[ "$REMAINING" != "0" && "$REMAINING" != "unknown" ]]; then
    log "WARNING" "$REMAINING package(s) still have updates available. Review $LOG_FILE."
fi

# --- Step 7: Kernel Check ---
RUNNING_KERNEL=$(uname -r)

# rpm -q kernel --last outputs lines like:
#   kernel-5.14.0-362.el9.x86_64   Mon 01 Jan 2024 ...
# Strip the 'kernel-' prefix so it matches uname -r output.
LATEST_KERNEL=$(rpm -q kernel --last \
    | head -n1 \
    | awk '{print $1}' \
    | sed 's/^kernel-//')

log "INFO" "Running kernel:          $RUNNING_KERNEL"
log "INFO" "Latest installed kernel: $LATEST_KERNEL"

# --- Step 8: Reboot Check ---
log "INFO" "Checking if reboot is required..."

REBOOT_REQUIRED=false

if command -v needs-restarting &>/dev/null; then
    # needs-restarting -r exits 0 = no reboot needed, 1 = reboot required.
    if ! needs-restarting -r >> "$LOG_FILE" 2>&1; then
        REBOOT_REQUIRED=true
    fi
else
    log "WARNING" "needs-restarting unavailable; falling back to kernel version comparison."
    if [[ "$RUNNING_KERNEL" != "$LATEST_KERNEL" ]]; then
        REBOOT_REQUIRED=true
    fi
fi

if [[ "$REBOOT_REQUIRED" == true ]]; then
    log "WARNING" "Reboot is required to complete patching."

    if [[ "$AUTO_REBOOT" == true ]]; then
        log "WARNING" "AUTO_REBOOT is enabled. System will reboot in 5 minutes."
        log "WARNING" "To cancel: run 'shutdown -c' as root."
        shutdown -r +5 "System rebooting after patching. Run 'shutdown -c' to cancel."
    else
        log "INFO" "AUTO_REBOOT is disabled. Please schedule a manual reboot."
    fi
else
    log "INFO" "No reboot required."
fi

# --- Step 9: Summary Log ---
{
    echo "===== $(date) ====="
    echo "Host:              $(hostname)"
    echo "Log:               $LOG_FILE"
    echo "Snapshot:          $SNAPSHOT_FILE"
    echo "Security only:     $SECURITY_ONLY"
    echo "Remaining updates: $REMAINING"
    echo "Running kernel:    $RUNNING_KERNEL"
    echo "Latest kernel:     $LATEST_KERNEL"
    echo "Reboot required:   $REBOOT_REQUIRED"
    echo "Result:            SUCCESS"
    echo ""
} >> "$SUMMARY_LOG"

log "INFO" "==== Patching complete ===="
exit 0