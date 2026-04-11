# RHEL 8 Patching Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `PATCHING/rhelpatch.sh` to support RHEL 8.x alongside RHEL 9.x using inline version branching.

**Architecture:** Detect RHEL major version once at startup via `/etc/os-release`, store in `RHEL_MAJOR`, then branch inline in three existing functions and one new function. No new files are introduced.

**Tech Stack:** bash, dnf, rpm, subscription-manager, needs-restarting

---

## File Structure

- Modify: `PATCHING/rhelpatch.sh` — the only file changed

---

### Task 1: Update script header

**Files:**
- Modify: `PATCHING/rhelpatch.sh:3`

- [ ] **Step 1: Update the header comment**

Replace line 3:
```bash
# RHEL 9.x System Update & Patching Script
```
With:
```bash
# RHEL 8.x / 9.x System Update & Patching Script
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "chore: update script header to reflect RHEL 8/9 support"
```

---

### Task 2: Add OS detection block

**Files:**
- Modify: `PATCHING/rhelpatch.sh` — insert after the configuration block (after `SECURITY_ONLY=false`, before the colors block)

- [ ] **Step 1: Insert the OS detection block**

After line 16 (`SECURITY_ONLY=false`), insert:
```bash

# --- OS Version Detection ---
RHEL_MAJOR=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
if [[ "$RHEL_MAJOR" != "8" && "$RHEL_MAJOR" != "9" ]]; then
    echo "[ERROR] Unsupported OS version: RHEL_MAJOR=$RHEL_MAJOR. Only RHEL 8 and 9 are supported." >&2
    exit 1
fi
```

Note: uses `. /etc/os-release` (POSIX dot-source) rather than `source` because `set -euo pipefail` is active and `source` in a subshell can behave unexpectedly on some systems. The `%%.*` strips any minor version (e.g. `8.9` → `8`).

- [ ] **Step 2: Verify syntax**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 3: Manually verify detection logic**

Run this one-liner on a RHEL 8 or 9 system (or simulate locally):
```bash
VERSION_ID="8.9" && echo "${VERSION_ID%%.*}"
# Expected output: 8

VERSION_ID="9.3" && echo "${VERSION_ID%%.*}"
# Expected output: 9

VERSION_ID="7.9" && echo "${VERSION_ID%%.*}"
# Expected output: 7  (script would exit 1 for this)
```

- [ ] **Step 4: Commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "feat: detect RHEL major version at startup"
```

---

### Task 3: Update check_dnf_not_running for RHEL 8

**Files:**
- Modify: `PATCHING/rhelpatch.sh` — `check_dnf_not_running` function (currently lines 57–61)

- [ ] **Step 1: Replace the function body**

Find the existing function:
```bash
check_dnf_not_running() {
    if pgrep -x dnf &>/dev/null || pgrep -x dnf5 &>/dev/null; then
        fail "DNF is already running (possibly dnf-automatic). Aborting to avoid conflicts."
    fi
}
```

Replace with:
```bash
check_dnf_not_running() {
    if pgrep -x dnf &>/dev/null; then
        fail "DNF is already running (possibly dnf-automatic). Aborting to avoid conflicts."
    fi
    if [[ "$RHEL_MAJOR" == "9" ]] && pgrep -x dnf5 &>/dev/null; then
        fail "DNF5 is already running. Aborting to avoid conflicts."
    fi
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "fix: gate dnf5 conflict check to RHEL 9 only"
```

---

### Task 4: Update ensure_dnf_utils to install correct package per version

**Files:**
- Modify: `PATCHING/rhelpatch.sh` — `ensure_dnf_utils` function (currently lines 63–69)

- [ ] **Step 1: Replace the function body**

Find the existing function:
```bash
ensure_dnf_utils() {
    if ! command -v needs-restarting &>/dev/null; then
        log "INFO" "needs-restarting not found; installing dnf-utils..."
        dnf -y install dnf-utils -q >> "$LOG_FILE" 2>&1 \
            || log "WARNING" "Could not install dnf-utils; reboot detection will use fallback."
    fi
}
```

Replace with:
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

- [ ] **Step 2: Verify syntax**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "fix: install yum-utils on RHEL 8, dnf-utils on RHEL 9"
```

---

### Task 5: Add subscription-manager refresh prompt

**Files:**
- Modify: `PATCHING/rhelpatch.sh` — add new function in the functions block, wire into call order

- [ ] **Step 1: Add the new function**

After the `ensure_dnf_utils` function (after its closing `}`), insert:

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

- [ ] **Step 2: Wire the function into the call order**

Find the existing call sequence in the `--- Start ---` block:
```bash
check_root
check_log_dir_writable
check_dnf_not_running
```

Add the new call after `check_dnf_not_running`:
```bash
check_root
check_log_dir_writable
check_dnf_not_running
prompt_subscription_refresh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 4: Manually verify prompt behaviour**

Simulate the interactive branch:
```bash
echo "y" | bash -c '
    source PATCHING/rhelpatch.sh 2>/dev/null || true
'
# This will fail early (no root), but confirms the function is parsed correctly.
```

Confirm the non-interactive path skips cleanly by checking the log message is present in a dry test.

- [ ] **Step 5: Commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "feat: add subscription-manager refresh prompt before patching"
```

---

### Task 6: Final verification

**Files:**
- Read: `PATCHING/rhelpatch.sh` — full review

- [ ] **Step 1: Syntax check the full script**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 2: Confirm RHEL_MAJOR is set before all functions that use it**

Search for all uses of `RHEL_MAJOR` in the script and confirm the detection block appears before any of them:
```bash
grep -n "RHEL_MAJOR" PATCHING/rhelpatch.sh
```
Expected: detection block line number is lower than all other occurrences.

- [ ] **Step 3: Confirm call order in the Start block**

```bash
grep -n -A 6 "^check_root" PATCHING/rhelpatch.sh
```
Expected output (in order):
```
check_root
check_log_dir_writable
check_dnf_not_running
prompt_subscription_refresh
ensure_dnf_utils
```

- [ ] **Step 4: Confirm log message in summary still says RHEL 9 Patching Started**

Update the log message on the `==== RHEL 9 Patching Started ====` line to reflect both versions:
```bash
log "INFO" "==== RHEL ${RHEL_MAJOR} Patching Started ===="
```

- [ ] **Step 5: Verify syntax one final time**

```bash
bash -n PATCHING/rhelpatch.sh
```
Expected: no output

- [ ] **Step 6: Final commit**

```bash
git add PATCHING/rhelpatch.sh
git commit -m "chore: use RHEL_MAJOR in startup log message"
```
