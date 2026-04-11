# Design: RHEL 8 Support in rhelpatch.sh

**Date:** 2026-04-11  
**Status:** Approved  
**Scope:** Update `PATCHING/rhelpatch.sh` to support RHEL 8.x in addition to RHEL 9.x using inline version branching.

---

## Overview

The existing `rhelpatch.sh` targets RHEL 9.x only. This change adds RHEL 8.x support by detecting the OS major version at runtime and branching inline where behavior differs. No new files are introduced; all changes are within the existing script.

---

## Changes

### 1. Script Header

Update the header comment from `RHEL 9.x` to `RHEL 8.x / 9.x`.

---

### 2. OS Detection

Immediately after the configuration block, detect the RHEL major version from `/etc/os-release` and store it in `RHEL_MAJOR`. Fail fast if the version is not 8 or 9.

```bash
RHEL_MAJOR=$(source /etc/os-release && echo "${VERSION_ID%%.*}")
[[ "$RHEL_MAJOR" == "8" || "$RHEL_MAJOR" == "9" ]] || fail "Unsupported OS version: $RHEL_MAJOR"
log "INFO" "Detected RHEL major version: $RHEL_MAJOR"
```

`RHEL_MAJOR` is used by all downstream branching logic.

---

### 3. DNF Conflict Check

`check_dnf_not_running` currently checks for both `dnf` and `dnf5`. `dnf5` does not exist on RHEL 8, so the `dnf5` check is gated behind `RHEL_MAJOR == 9`.

```bash
check_dnf_not_running() {
    if pgrep -x dnf &>/dev/null; then
        fail "DNF is already running. Aborting to avoid conflicts."
    fi
    if [[ "$RHEL_MAJOR" == "9" ]] && pgrep -x dnf5 &>/dev/null; then
        fail "DNF5 is already running. Aborting to avoid conflicts."
    fi
}
```

---

### 4. Utils Package (needs-restarting)

`ensure_dnf_utils` installs the package that provides `needs-restarting`. On RHEL 8 this is `yum-utils`; on RHEL 9 it is `dnf-utils`.

```bash
ensure_dnf_utils() {
    if ! command -v needs-restarting &>/dev/null; then
        if [[ "$RHEL_MAJOR" == "8" ]]; then
            local pkg="yum-utils"
        else
            local pkg="dnf-utils"
        fi
        log "INFO" "needs-restarting not found; installing ${pkg}..."
        dnf -y install "$pkg" -q >> "$LOG_FILE" 2>&1 \
            || log "WARNING" "Could not install ${pkg}; reboot detection will use fallback."
    fi
}
```

---

### 5. Subscription-Manager Refresh Prompt

A new `prompt_subscription_refresh` function is added and called after pre-flight checks but before DNF metadata refresh. It applies to both RHEL 8 and RHEL 9.

- If stdin is a TTY: prompt Y/N. On `y`, run `subscription-manager refresh` and log the result.
- If non-interactive (cron, piped): skip silently with a log notice. Default is N to avoid blocking automated runs.

```bash
prompt_subscription_refresh() {
    if [[ -t 0 ]]; then
        read -r -p "Run subscription-manager refresh before patching? [y/N]: " yn
        if [[ "${yn,,}" == "y" ]]; then
            log "INFO" "Running subscription-manager refresh..."
            subscription-manager refresh >> "$LOG_FILE" 2>&1 \
                || log "WARNING" "subscription-manager refresh failed; continuing."
        else
            log "INFO" "Skipping subscription-manager refresh."
        fi
    else
        log "INFO" "Non-interactive session; skipping subscription-manager refresh prompt."
    fi
}
```

---

## Call Order (updated)

```
check_root
check_log_dir_writable
check_dnf_not_running         ← branches on RHEL_MAJOR for dnf5
prompt_subscription_refresh   ← new step, both versions
ensure_dnf_utils              ← branches on RHEL_MAJOR for package name
[dnf makecache → check-update → upgrade → verify → kernel check → reboot check → summary]
```

---

## Out of Scope

- RHEL 7 or earlier
- Yum (pre-dnf) support
- Changes to AUTO_REBOOT or SECURITY_ONLY behavior
- Repo configuration or Katello integration beyond the subscription-manager prompt
