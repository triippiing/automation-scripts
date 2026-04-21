# AIX 7.1 Technology Level / Service Pack Patching Runbook

Version: 1.0
Scope: In-place TL/SP update of an AIX 7.1 LPAR using `alt_disk_copy` as the rollback mechanism.

---

## 1. Scope and assumptions

This runbook covers a single-LPAR, non-clustered, in-place TL or SP update
applied via `install_all_updates` against an `alt_disk_copy` clone of
rootvg. It does NOT cover:

- NIM-driven mass updates.
- PowerHA/HACMP-managed nodes.
- Migration between major versions (7.1 -> 7.2, 7.2 -> 7.3); those are
  `migration installations` (`nimadm` or DVD/NIM migrate), not updates.

Assumptions:

- Root or sudo-to-root access on the target LPAR.
- A free, unassigned local disk of equal-or-greater size than rootvg,
  available for `alt_disk_copy`.
- Outbound access (or a local Fix Central mirror / NIM lpp_source) to
  retrieve the update bundle.
- A maintenance window of approximately 90 minutes for an SP, 2-3 hours
  for a TL. Network/SAN-attached storage operations may extend this.

---

## 2. Worked example used throughout this document

  Source level:   7100-05-11-2347   (AIX 7.1 TL5 SP11)
  Target level:   7100-05-12-2336   (AIX 7.1 TL5 SP12 -- final 7.1 SP)
  Bundle name:    7100-05-12-2336-FP.tar
  Spare disk:     hdisk1 (unassigned, equal size to hdisk0)
  Update staging: /var/update_staging/7100-05-12

All commands below assume these values so sub in package names as needed.

---

## 3. Pre-change planning (T-7 to T-2 days)

| Item                                                     | Status |
|----------------------------------------------------------|--------|
| Change ticket raised, CAB approval logged                |  [ ]   |
| Maintenance window agreed with Customer                  |  [ ]   |
| Backup strategy confirmed (mksysb destination + TSM)     |  [ ]   |
| Free disk identified for alt_disk_copy (>= rootvg size)  |  [ ]   |
| Third-party software compatibility checked               |  [ ]   |
| Update bundle downloaded and checksum-verified           |  [ ]   |

---

## 4. Pre-flight checks (T-0, before window start)

Run these from a logged session (`script /tmp/preflight_$(date +%Y%m%d).log`)
so the output is captured for the change record.

### 4.1 Current state

    oslevel -s                   # expect: 7100-05-11-2347
    oslevel -r                   # expect: 7100-05
    instfix -i | grep ML         # all prior MLs/TLs cleanly applied?
    uname -a
    prtconf | head -30           # CPU/memory/serial for change record

### 4.2 Fileset consistency

    lppchk -v                    # MUST return clean (no output)
    lppchk -c                    # checksum verify (slower, optional)

If `lppchk -v` reports broken or missing pre reqs, STOP and fix prior to patching. The most common cause is a previous half-applied
update. Run `installp -C` to clean up uncommitted state.

### 4.3 Disk space

    df -g / /usr /var /opt /tmp /home /admin

Minimum recommended free space for an SP update:

  /        100 MB
  /usr     2 GB   (most filesets land here)
  /var     500 MB (logs, lpp metadata)
  /tmp     1 GB
  /opt     500 MB

For a TL update, double those. Imperative the /usr has enough space or youre cooked

### 4.4 Rootvg health

    lsvg rootvg                  # check FREE PPs
    lsvg -p rootvg               # all PVs active?
    lsvg -l rootvg               # any open/syncd issues?
    lspv                         # confirm spare disk (hdisk1) is free

`hdisk1` should show `None` in the VG column.

### 4.5 Bootlist and error log

    bootlist -m normal -o > /tmp/bootlist_pre.txt
    bootlist -m service -o >> /tmp/bootlist_pre.txt
    cat /tmp/bootlist_pre.txt    # expect hdisk0 in normal list

    errpt | head -30             # any hardware errors? fix first or once again you might be cooked with no idea until you reboot
    errpt -a | head -100 > /tmp/errpt_pre.txt

### 4.6 Running services snapshot

    lssrc -a > /tmp/lssrc_pre.txt
    netstat -rn > /tmp/routing_pre.txt
    df -g > /tmp/df_pre.txt

These give you a known-good baseline to diff against post-patch.

---

## 5. Backups

Two layers. Both required for a production change. Nomrally a mksysb to nim / nfs with TSM file level grabbing said mksysb and datavvg

### 5.1 mksysb (offline rootvg image)

NFS-mounted backup target preferred; local disk acceptable as a stopgap.

    # Verify destination has space (mksysb size ~= used PPs in rootvg)
    df -g /backup

    mksysb -ipX /backup/$(hostname)_$(date +%Y%m%d_%H%M).mksysb

Flags:
  -i   regenerate /image.data (captures current LV layout)
  -X   automatically extend /tmp if needed during backup
  -p   disables software packing

Verify the resulting file:

    ls -l /backup/$(hostname)_*.mksysb
    lsmksysb -l -f /backup/$(hostname)_*.mksysb | head -40

### 5.2 alt_disk_copy (bootable clone of rootvg)

This is the primary rollback mechanism. It clones rootvg to the spare
disk, leaving you with a bootable pre-patch image one `bootlist` away.

    # Confirm hdisk1 is free
    lspv | grep hdisk1
    # Expected: hdisk1  00f6...        None

    # Clone (this takes 10-30 min depending on rootvg size and disk speed)
    alt_disk_copy -B -d hdisk1

Flags:
  -B   do NOT update bootlist yet
  -d   destination disk

Verify:

    lspv
    # Expected new line: hdisk1 ... altinst_rootvg active
    lsvg altinst_rootvg

NOTE: You can use `alt_disk_copy` WITHOUT `-B`, letting it
automatically point the bootlist at the clone before patching. The
choice is about which disk you want to be patching:

- WITH -B (this runbook): patch the LIVE rootvg on hdisk0, keep clone
  on hdisk1 as cold rollback. Simpler, more common.
- WITHOUT -B + alt_rootvg_op -W: wake the clone, patch it offline,
  reboot onto patched clone, original disk becomes rollback. More steps,
  but the running system stays untouched until reboot.

This runbook follows the first pattern.

---

## 6. Stage the update tar ball

### 6.1 Create staging directory

    mkdir -p /var/update_staging/7100-05-12
    cd /var/update_staging/7100-05-12

### 6.2 Transfer the bundle

From your jump host or NFS share:

    scp 7100-05-12-2336-FP.tar root@dr_nim_01:/var/update_staging/7100-05-12/
    # OR
    mount nfs-server:/aix_updates /mnt/updates
    cp /mnt/updates/7100-05-12-2336-FP.tar /var/update_staging/7100-05-12/

### 6.3 Verify checksum

Verify before unpacking:

    csum -h SHA256 7100-05-12-2336-FP.tar 

Ensure it matched csum listed on fix central / ESS

### 6.4 Extract and build .toc

    tar -xvf 7100-05-12-2336-FP.tar
    ls -1 *.bff | head
    # Expect filenames like:
    #   bos.64bit.7.1.5.41.bff
    #   bos.mp64.7.1.5.41.bff
    #   bos.rte.7.1.5.41.bff
    #   bos.rte.boot.7.1.5.41.bff
    #   devices.common.IBM.fc.rte.7.1.5.40.bff
    #   ... (typically 100-300 filesets in a full SP)

    inutoc .
    ls -l .toc

CRITICAL: `inutoc` builds the table-of-contents file that `installp`
reads. Without a current `.toc`, installp will report "No filesets on
the media" and fail. Always re-run `inutoc` after adding or removing
files from the directory.

### 6.5 Preview what will be installed (dry run)

    install_all_updates -d /var/update_staging/7100-05-12 -p
    # -p == preview only, no changes made

Review the output carefully. Confirm:
- Target level matches expectation (7.1.5.x)
- No "FAILURES" reported
- No unexpected filesets being downgraded
- "REQUISITE" warnings have a path to resolution

---

## 7. Apply the update

### 7.1 Final pre-apply checks

    date                           # log start time
    who                            # any other users logged in?
    ps -ef | grep -v "^root\|^daemon\|^bin\|^sys" | head
                                   # any application processes still up?

If applications are still running, alert application team and have them halt DB.

### 7.2 Run the update

    script /var/update_staging/7100-05-12/install_$(date +%Y%m%d_%H%M).log

    install_all_updates \
        -d /var/update_staging/7100-05-12 \
        -Y \
        -c

    # When complete: exit the script session
    exit

Flags:
  -d   source directory (must contain .toc)
  -Y   accept software licenses non-interactively
  -c   commit (vs apply-only)

`apply` vs `commit`:
- APPLY (default if -c omitted): old fileset version retained on disk;
  can be `reject`ed to roll back individual filesets without rebooting.
  Consumes ~2x disk space in /usr.
- COMMIT (-c): old version discarded. Smaller footprint. Rollback is
  via alt_disk_copy / mksysb only. Recommended for SPs where you have
  alt_disk_copy in place anyway.

Expected runtime: 20-60 minutes for an SP, 60-120 minutes for a TL.

### 7.3 Interpret the summary

`install_all_updates` ends with a summary table. The column to watch is
`Result`. Acceptable values:

  SUCCESS   fileset installed cleanly
  ALREADY   target version already present (skipped)

Anything else - FAILED, BROKEN, CANCELLED, Do
NOT reboot. Investigate via `/var/adm/ras/install_all_updates.log` and
the per-fileset logs in `/var/adm/ras/`.

---

## 8. Reboot and verify

### 8.1 Reboot

    sync; sync; sync    (disk writes are updated)
    shutdown -Fr now

### 8.2 Post-reboot verification

After the LPAR returns:

    oslevel -s
    # Expect: 7100-05-12-2336

    oslevel -s -l $(oslevel -s)
    # Expect: no output (no filesets below the reported level)
    # If filesets are listed, they were not in the bundle 

    instfix -i | grep ML
    # Expect: "All filesets for 7100-05_AIX_ML were found."

    lppchk -v
    # MUST return clean

    errpt | head -30
    # Compare against /tmp/errpt_pre.txt -- any new error classes?

    df -g
    # Compare against /tmp/df_pre.txt -- /usr will have grown

    lssrc -a | grep -i inoperative
    # Any subsystems that should be active but aren't?

    bootlist -m normal -o
    # Should still show hdisk0 (we used -B during alt_disk_copy)

---

## 9. Rollback procedure

Trigger conditions:
- `lppchk -v` reports broken filesets after reboot.
- LPAR fails to boot cleanly off hdisk0.

### 9.1 Rollback while system is booted

    # Repoint bootlist to the pre-patch clone on hdisk1
    bootlist -m normal hdisk1
    bootlist -m normal -o          # verify

    shutdown -Fr now

After reboot:

    oslevel -s
    # Expect: 7100-05-11-2347 (pre-patch level)

    lspv
    # rootvg is now on hdisk1; old (patched) rootvg shows as
    # old_rootvg on hdisk0

    bootlist -m normal hdisk1      # confirm bootlist sticks for next boot

### 9.2 Rollback if system will not boot

From the HMC:
1. Activate LPAR in SMS mode.
2. Select boot device, choose hdisk1.
3. Boot normally.

Then follow 9.1 verification steps.

### 9.3 Post-rollback cleanup

Once stable on the rollback disk:

    # Remove the failed alt_rootvg (the patched one, now on hdisk0)
    alt_rootvg_op -X old_rootvg

    # Preserve /var/adm/ras/install_all_updates.log for support.

---

## 10. Cleanup (T+3 to T+7 days, after burn-in)

If patching has completed successfully and nobody has kicked off yet, your probably good to clear down the alt disk:

    # Remove the alt_disk_copy clone definition, freeing hdisk1
    alt_rootvg_op -X altinst_rootvg

    lspv
    # hdisk1 should now show "None" in VG column

    # Remove staged update files
    rm -rf /var/update_staging/7100-05-12

    # Archive change logs for audit
    tar -cvf /backup/change_$(hostname)_$(date +%Y%m%d).tar \
        /tmp/preflight_*.log \
        /tmp/errpt_pre.txt /tmp/lssrc_pre.txt /tmp/df_pre.txt \
        /var/update_staging/7100-05-12/install_*.log \
        /var/adm/ras/install_all_updates.log

    # Optional: remove the mksysb if alt_disk_copy + TSM cover you
    # ls -l /backup/$(hostname)_*.mksysb

Now close that change, you earned it!

---

## Appendix A: Sample Fix Central bundle contents

A typical AIX 7.1 SP bundle (`7100-05-12-2336-FP.tar`) extracts to a
flat directory of `.bff` files plus a generated `.toc`. Example:

    /var/update_staging/7100-05-12/
        .toc                                          (built by inutoc)
        bos.64bit.7.1.5.41.bff
        bos.acct.7.1.5.40.bff
        bos.mp64.7.1.5.41.bff
        bos.net.tcp.client.7.1.5.41.bff
        bos.net.tcp.server.7.1.5.41.bff
        bos.perf.libperfstat.7.1.5.41.bff
        bos.perf.perfstat.7.1.5.41.bff
        bos.perf.tools.7.1.5.41.bff
        bos.rte.7.1.5.41.bff
        bos.rte.boot.7.1.5.41.bff
        bos.rte.install.7.1.5.41.bff
        bos.rte.libc.7.1.5.41.bff
        bos.rte.security.7.1.5.41.bff
        clic.rte.kernext.4.10.0.4.bff
        devices.common.IBM.ethernet.rte.7.1.5.41.bff
        devices.common.IBM.fc.rte.7.1.5.40.bff
        devices.common.IBM.scsi.rte.7.1.5.41.bff
        devices.fcp.disk.rte.7.1.5.40.bff
        ... (typically 150-300 filesets total)

Naming convention:
    <package>.<subpackage>.<V>.<R>.<M>.<F>.bff
        V = Version (7)
        R = Release (1)
        M = Modification / TL (5)
        F = Fix / SP build (41)

Not all filesets in a bundle are at the same V.R.M.F -- some
sub-components ship infrequent updates, which is why you may see
mixed `.40` and `.41` levels in the same SP.

---

## Appendix B: Common errors and remediation

| Symptom                                            | Cause / Fix |
|----------------------------------------------------|-------------|
| `installp: 0503-005 ... could not access toc`      | Run `inutoc .` in the staging dir |
| `0504-203 No filesets on the media`                | Same -- missing or stale `.toc` |
| `0503-409 ... requisite is missing`                | A prereq fileset not in the bundle. Check `oslevel -s -l` and download the missing fileset, or use a fuller bundle. |
| `0503-464 ... cannot install over a newer version` | Fileset on disk is newer than what's in the bundle. Skip with `installp -ag` (apply, ignore requisites) only if you understand WHY. |
| `lppchk -v` reports BROKEN filesets post-patch     | Run `installp -C` to clean uncommitted state, then re-run the update for affected filesets only. |
| LPAR hangs at LED `0c31` or similar on boot        | Boot from rollback disk via SMS. File a PMR. |
| `/usr` fills mid-install                           | `chfs -a size=+1G /usr`, then re-run `install_all_updates`. installp is restartable. |

---

## Appendix C: Command quick reference

    Information
      oslevel -s                       Current TL/SP level
      oslevel -s -l <level>            Filesets below the given level
      oslevel -r                       Just the TL portion
      instfix -i                       Installed ML/TL inventory
      lslpp -L                         Full fileset inventory
      lslpp -h <fileset>               Install history for a fileset
      lppchk -v                        Verify fileset consistency

    Backup / clone
      mksysb -ipX <file>               Bootable rootvg backup
      alt_disk_copy -B -d <disk>       Clone rootvg, do not change bootlist
      alt_rootvg_op -W -d <disk>       Wake an alt_rootvg for offline access
      alt_rootvg_op -S                 Sleep an alt_rootvg
      alt_rootvg_op -X <vg>            Remove an alt_rootvg definition

    Update
      inutoc <dir>                     Build .toc for an installp directory
      install_all_updates -d <dir> -p  Preview update
      install_all_updates -d <dir> -Yc Apply and commit
      installp -C                      Clean up failed/half-applied state
      installp -s                      List filesets in APPLIED (uncommitted) state
      installp -c <fileset>            Commit a specific applied fileset
      installp -r <fileset>            Reject (roll back) an applied fileset

    Boot
      bootlist -m normal -o            Show normal-mode bootlist
      bootlist -m normal <disk>        Set normal-mode bootlist
      bosboot -ad /dev/<disk>          Rebuild boot image on disk

---

## Appendix D: Worked example -- single command sequence

RUNBOOK AS FOLLOWS, DO NOT FOLLOW BLINDLY AS NAMING WILL CHANGE AND YOULL LOOK LIKE A SILLY LITTLE GUY:

    # Pre-flight
    oslevel -s; lppchk -v; df -g /usr; lspv
    bootlist -m normal -o > /tmp/bootlist_pre.txt
    errpt -a > /tmp/errpt_pre.txt

    # Backups
    mksysb -ipX /backup/$(hostname)_$(date +%Y%m%d).mksysb
    alt_disk_copy -B -d hdisk1
    lspv                                          # confirm altinst_rootvg

    # Stage
    mkdir -p /var/update_staging/7100-05-12
    cd /var/update_staging/7100-05-12
    tar -xvf /tmp/7100-05-12-2336-FP.tar
    inutoc .

    # Preview, then apply
    install_all_updates -d . -p
    script ./install_$(date +%Y%m%d_%H%M).log
    install_all_updates -d . -Yc
    exit

    # Reboot and verify
    shutdown -Fr now
    # ... wait for reboot ...
    oslevel -s                                    # 7100-05-12-2336
    lppchk -v
    instfix -i | grep ML
    errpt | head

    # Cleanup (after burn-in, days later)
    alt_rootvg_op -X altinst_rootvg
    rm -rf /var/update_staging/7100-05-12

---

End of runbook.
