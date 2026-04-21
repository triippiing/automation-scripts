# AIX 7.1 to 7.2 Migration Runbook -- NIM (nimadm) Method

Version: 1.0
Scope:   Version migration of an AIX 7.1 LPAR to AIX 7.2 using
         `nimadm` from a NIM master, with the running 7.1 system
         left untouched until reboot.
Audience: UNIX/Backup engineer with shell access and root on both
         the NIM master and the client LPAR, plus HMC access to the
         client LPAR for emergency console.

---

## 1. Scope and assumptions

This runbook covers a single-LPAR AIX 7.1 -> 7.2 version migration
performed via `nimadm` (NIM Alternate Disk Migration). The migration
runs on a CLONE of the client's rootvg, executed from the NIM master
across NFS. The running 7.1 system is not modified during the
migration; the cutover is a single reboot.

This runbook does NOT cover:

- New installations or "preservation" installs.
- PowerHA/HACMP-clustered nodes (cluster must be quiesced; migrate
  one node at a time per IBM's PowerHA migration procedure).
- LPAR migrations (LPM) -- nimadm and LPM are unrelated.
- Building a NIM master from scratch (assumes one exists).
- 7.1 -> 7.3 (use a 7.3 NIM master and target a 7.3 lpp_source;
  procedure is otherwise identical).

Assumptions:

- A working NIM master exists at AIX 7.2 or higher (NIM master must
  be at the same level as, or higher than, the target client level).
- Network connectivity between client and NIM master, with NFS
  (TCP/UDP 2049) and the standard NIM ports (1058) open in both
  directions.
- The client is already a defined NIM machine object on the master,
  or you have rights to define one.
- A free, unassigned local disk on the client of equal or greater
  size than the existing rootvg, available for the migration.
- Root or sudo-to-root on both NIM master and client LPAR.
- HMC access to the client for console / SMS recovery if needed.
- Maintenance window of approximately 3-4 hours. nimadm itself runs
  90-180 minutes depending on rootvg size, network speed, and NIM
  master CPU.

---

## 2. Worked example used throughout this document

  Source level:        7100-05-12-2336   (AIX 7.1 TL5 SP12, final SP)
  Target level:        7200-05-10        (AIX 7.2 TL5 SP10, example)
  Client LPAR:         lpar01
  NIM master:          nimsrv01 (already at 7.2 TL5 or higher)
  NIM client object:   lpar01 (already defined on master)
  Spare disk on client: hdisk1 (unassigned, equal size to hdisk0)
  NIM master VG for
  working storage:     nimadmvg (separate VG, not rootvg, with at
                       least 2x rootvg size in free PPs)
  lpp_source name:     lpp_aix72tl5sp10
  SPOT name:           spot_aix72tl5sp10
  Media location on
  master:              /export/nim/media/AIX_7.2_TL5_SP10/

NOTE: SP versions evolve. Confirm the latest available 7.2 TL5 SP on
IBM Entitled Software Support (ESS) and substitute throughout. As of
this runbook's publication, target the latest SP available -- there
is no benefit to migrating to an older SP and then patching forward.

---

## 3. Pre-change planning (T-7 to T-2 days)

| Item                                                          | Status |
|---------------------------------------------------------------|--------|
| Change ticket raised, CAB approval logged                     |  [ ]   |
| Maintenance window agreed with application owners             |  [ ]   |
| AIX 7.2 entitlement confirmed in ESS                          |  [ ]   |
| AIX 7.2 base media downloaded to NIM master                   |  [ ]   |
| NIM master at >= target client level (oslevel -s)             |  [ ]   |
| NIM master has free space for lpp_source (~6 GB) and SPOT     |  [ ]   |
| NIM master has nimadmvg with >= 2x client rootvg free PPs     |  [ ]   |
| Client LPAR has free disk for migration target                |  [ ]   |
| Client is reachable from NIM master and resolves both ways    |  [ ]   |
| Backup strategy confirmed (mksysb to NIM, plus TSM)           |  [ ]   |
| Third-party software confirmed compatible with AIX 7.2        |  [ ]   |
| Rollback plan reviewed and signed off                         |  [ ]   |
| HMC console access tested for client LPAR                     |  [ ]   |

Third-party software compatibility -- this matters MORE for a version
migration than for an SP. Verify against AIX 7.2 TL5:

- TSM/IBM Spectrum Protect client: check the IBM support matrix for
  AIX 7.2 TL5 SPx supported client versions. Older clients may need
  upgrading post-migration.
- PowerHA/HACMP: hard version dependency. Do not migrate clustered
  nodes ad-hoc.
- Oracle, DB2, SAP: each has its own AIX 7.2 certification matrix.
- Anything with a kernel extension (`genkex` shows the loaded list).
- Java, OpenSSL, OpenSSH versions ship at newer baselines on 7.2.
- Monitoring/AV agents (ITM, Nagios, Tanium, etc.).

---

## 4. NIM master preparation (T-7 to T-1 days)

These steps run on the NIM master as root. They build the NIM resources
the migration will consume. If the resources already exist for another
client at the same target level, skip to section 4.4.

### 4.1 Verify NIM master state

    oslevel -s
    # Must be >= 7200-05-10 (target client level) or higher.
    # A 7.1 NIM master CANNOT migrate clients to 7.2.

    lsnim -l master
    # Confirm master is initialized.

    lssrc -ls nimesis
    # NIM service must be active.

### 4.2 Stage the AIX 7.2 base media

The 7.2 install media from ESS comes as one or more ISOs (typically
`AIX_7200-05-10_DVD_1_of_2.iso` and `_2_of_2.iso`). Place them on
the NIM master:

    mkdir -p /export/nim/media/AIX_7.2_TL5_SP10
    cd /export/nim/media/AIX_7.2_TL5_SP10

    # Transfer ISOs here (scp, sftp, or NFS from your media share)
    ls -l
    # Expect:
    # AIX_7200-05-10_DVD_1_of_2.iso
    # AIX_7200-05-10_DVD_2_of_2.iso

    # Verify checksums against ESS download page
    csum -h SHA256 *.iso

### 4.3 Define the lpp_source and SPOT

The lpp_source is the fileset repository (directory of `.bff` files
extracted from the install media). The SPOT (Shared Product Object
Tree) is a bootable mini-image used by NIM operations.

Easiest path: define lpp_source directly from ISO 1, then add ISO 2.

    # Create the target directory for the lpp_source
    mkdir -p /export/nim/lpp_source/lpp_aix72tl5sp10

    # Define the lpp_source from the first ISO
    nim -o define -t lpp_source \
        -a server=master \
        -a location=/export/nim/lpp_source/lpp_aix72tl5sp10 \
        -a source=/export/nim/media/AIX_7.2_TL5_SP10/AIX_7200-05-10_DVD_1_of_2.iso \
        -a packages=all \
        lpp_aix72tl5sp10

    # Add the contents of ISO 2 to the same lpp_source
    loopmount -i /export/nim/media/AIX_7.2_TL5_SP10/AIX_7200-05-10_DVD_2_of_2.iso \
              -o "-V cdrfs -o ro" \
              -m /mnt/iso2

    bffcreate -d /mnt/iso2/installp/ppc \
              -t /export/nim/lpp_source/lpp_aix72tl5sp10/installp/ppc \
              all

    loopumount -i /export/nim/media/AIX_7.2_TL5_SP10/AIX_7200-05-10_DVD_2_of_2.iso \
               -m /mnt/iso2

    # Rebuild the .toc so NIM sees the new filesets
    cd /export/nim/lpp_source/lpp_aix72tl5sp10/installp/ppc
    inutoc .

    # Tell NIM to re-check the lpp_source
    nim -o check lpp_aix72tl5sp10

    lsnim -l lpp_aix72tl5sp10
    # Look for: simages = yes  (means it contains a complete BOS image)

The `simages = yes` attribute is critical -- without it, nimadm will
refuse to use this lpp_source for migration. If absent, the lpp_source
is incomplete and you need to confirm both ISOs were processed.

### 4.4 Define the SPOT

    nim -o define -t spot \
        -a server=master \
        -a location=/export/nim/spot \
        -a source=lpp_aix72tl5sp10 \
        spot_aix72tl5sp10

    # SPOT creation takes 15-30 minutes -- it builds a bootable image.
    lsnim -l spot_aix72tl5sp10

    nim -o check spot_aix72tl5sp10
    # Expect no errors.

### 4.5 Verify or create the working VG for nimadm

nimadm needs scratch space on the NIM master to NFS-export and
manipulate the client's cloned rootvg. This MUST be a separate VG
(not rootvg) with at least 2x the client's rootvg size in free PPs.

    lsvg
    # If 'nimadmvg' does not exist, create it on a dedicated disk:
    # mkvg -y nimadmvg -s 64 hdiskN

    lsvg nimadmvg
    # Note FREE PPs and PP SIZE; multiply for free GB.

### 4.6 Verify or define the client NIM machine object

    lsnim -l lpar01
    # If "0042-053 lsnim: there is no NIM object named "lpar01""
    # then define it:

    nim -o define -t standalone \
        -a platform=chrp \
        -a netboot_kernel=64 \
        -a if1="find_net lpar01 0" \
        -a cable_type1=N/A \
        lpar01

    # Confirm the client is reachable
    nim -o lslpp lpar01 | head
    # If this returns lpp data, client communication is working.

---

## 5. Pre-flight checks on the client LPAR (T-0)

Run from a captured session: `script /tmp/preflight_$(date +%Y%m%d).log`

### 5.1 Current state

    oslevel -s                     # expect: 7100-05-12-2336
    oslevel -r
    instfix -i | grep ML
    uname -a
    prtconf | head -30

### 5.2 Fileset health

    lppchk -v                      # MUST return clean
    lppchk -c                      # checksum verify (optional)

If `lppchk -v` reports issues, remediate BEFORE migration. A migration
inheriting a broken 7.1 fileset state will not produce a clean 7.2.

### 5.3 Identify obsolete / problem filesets

    lslpp -L | grep -i obsolete
    # Any filesets here will be removed by the migration -- confirm
    # nothing application-critical depends on them.

    # Check for filesets known not to migrate cleanly
    lslpp -L bos.adt.libm bos.compat.libs perfagent.tools 2>/dev/null

### 5.4 Disk space

    df -g / /usr /var /opt /tmp /home

Migration needs healthy free space; rule of thumb:

    /        100 MB
    /usr     3 GB
    /var     1 GB
    /tmp     1 GB
    /opt     500 MB

### 5.5 Rootvg and target disk

    lsvg rootvg
    lsvg -p rootvg
    lsvg -l rootvg

    lspv
    # Identify the spare disk (e.g. hdisk1) -- must show "None" in
    # the VG column and be >= the size of hdisk0.

    bootinfo -s hdisk0             # size in MB
    bootinfo -s hdisk1             # must be >= hdisk0

### 5.6 Bootlist and error log

    bootlist -m normal -o > /tmp/bootlist_pre.txt
    bootlist -m service -o >> /tmp/bootlist_pre.txt

    errpt | head -30
    errpt -a > /tmp/errpt_pre.txt

### 5.7 Network reachability to NIM master

    ping -c 3 nimsrv01
    rpcinfo -p nimsrv01 | grep -E 'nfs|portmapper|nim'
    # Confirm portmapper, nfs, and nimesis are listening.

### 5.8 Snapshot of running state

    lssrc -a > /tmp/lssrc_pre.txt
    netstat -rn > /tmp/routing_pre.txt
    df -g > /tmp/df_pre.txt
    no -a > /tmp/no_pre.txt
    lsattr -El sys0 > /tmp/sys0_pre.txt
    genkex > /tmp/genkex_pre.txt    # loaded kernel extensions

These provide the diff baseline post-migration.

---

## 6. Backups

### 6.1 mksysb to NIM master (preferred)

A NIM-resident mksysb gives you the option to recover the LPAR via
`nim -o bos_inst` if both the live rootvg and the migrated clone
become unbootable.

On the NIM master:

    nim -o define -t mksysb \
        -a server=master \
        -a location=/export/nim/mksysb/lpar01_pre72_$(date +%Y%m%d).mksysb \
        -a source=lpar01 \
        -a mk_image=yes \
        lpar01_pre72_$(date +%Y%m%d)

This pulls a mksysb FROM the client TO the master in one operation.
Runtime depends on rootvg size and network speed (allow 30-90 min).

### 6.2 Local mksysb (fallback)

If NIM-resident mksysb is impractical, take a local mksysb to NFS:

    df -g /backup
    mksysb -i -X /backup/$(hostname)_pre72_$(date +%Y%m%d_%H%M).mksysb

### 6.3 Verify the spare disk is ready for nimadm

    lspv | grep hdisk1
    # Expect: hdisk1  00fXXXXXXXXXXXXX  None

If hdisk1 has stale VG metadata (`old_rootvg`, `altinst_rootvg` from a
previous operation), clean it first:

    # Only if necessary -- destructive to whatever is on hdisk1
    alt_rootvg_op -X old_rootvg     # for old_rootvg
    # OR
    chpv -C hdisk1                  # clears VGDA, USE WITH CARE

NOTE: nimadm will create its own clone of rootvg on hdisk1 -- you do
NOT need to take a separate alt_disk_copy first. nimadm IS the clone
operation. Taking alt_disk_copy on top would just consume another disk.

---

## 7. Run the migration

### 7.1 Pre-execution checks on the NIM master

    # Confirm all resources are ready
    lsnim -l lpp_aix72tl5sp10 | grep simages
    lsnim -l spot_aix72tl5sp10
    lsnim -l lpar01
    lsvg nimadmvg | grep "FREE PPs"

### 7.2 Optional: nimadm dry run / phase preview

nimadm runs in 12 phases. You can preview without committing:

    # On NIM master
    nimadm -c lpar01 \
           -s spot_aix72tl5sp10 \
           -l lpp_aix72tl5sp10 \
           -j nimadmvg \
           -d hdisk1 \
           -P 1                       # run only phase 1

`-P N` runs only phase N. Phase 1 is the validation phase -- it
checks all prerequisites without modifying anything on the client.
Useful for catching configuration errors before the real run.

### 7.3 Execute the full migration

    # On NIM master, in a captured session:
    script /var/log/nim/nimadm_lpar01_$(date +%Y%m%d_%H%M).log

    nimadm -c lpar01 \
           -s spot_aix72tl5sp10 \
           -l lpp_aix72tl5sp10 \
           -j nimadmvg \
           -d hdisk1 \
           -Y

    # exit the script session when complete
    exit

Flag breakdown:
  -c   client (NIM machine object name)
  -s   SPOT
  -l   lpp_source
  -j   VG on NIM master for working storage
  -d   destination disk on the client
  -Y   accept software licenses non-interactively

### 7.4 nimadm phases (what to expect in the log)

  Phase  1   Initialization and prerequisite check
  Phase  2   Client alt_disk_install setup
  Phase  3   Cloning rootvg from hdisk0 to hdisk1 on client
  Phase  4   Export client's hdisk1 alt rootvg via NFS to master
  Phase  5   Mount alt rootvg on master, configure for migration
  Phase  6   Run pre-migration scripts
  Phase  7   Migrate filesets (longest phase; new BOS installed here)
  Phase  8   Run post-migration scripts
  Phase  9   Bosboot the alt rootvg
  Phase 10   Unmount and clean up NFS export
  Phase 11   Wake up alt_disk on client (re-import VG metadata)
  Phase 12   Set client bootlist to alt disk, finalize

If nimadm halts at a phase, the error is usually clear in the log. The
most common failures: insufficient space (phase 7), broken filesets
inherited from the client (phase 1 or 7), or NFS export problems
(phase 4 -- check firewalls and `/etc/exports` on master).

### 7.5 Monitor progress from the client side

In a separate session on the client:

    # Watch the alt rootvg appear on hdisk1
    while true; do lspv | grep hdisk1; sleep 30; done

    # When phase 4 begins you'll see hdisk1 NFS-mounted FROM the master
    df -g | grep nfs

    # When phase 12 completes, bootlist will have been updated:
    bootlist -m normal -o
    # Expect: hdisk1

### 7.6 Confirm completion

The nimadm log ends with:

    Bootlist is set to boot from disk hdisk1.
    nimadm: Migration completed successfully.

At this point the client is still running 7.1 from hdisk0, but is
configured to boot 7.2 from hdisk1 on next reboot.

---

## 8. Cutover and verification

### 8.1 Final pre-reboot checks on client

    # Confirm bootlist points at the migrated disk
    bootlist -m normal -o
    # Expect: hdisk1

    # Confirm services are still up (we haven't rebooted yet)
    lssrc -a | grep -i inoperative

### 8.2 Application shutdown

Follow your application shutdown runbook. Database engines, JVMs,
and middleware should be stopped cleanly before reboot.

### 8.3 Reboot onto the migrated rootvg

    sync; sync; sync
    shutdown -Fr now

### 8.4 First boot considerations

The first boot off the migrated 7.2 rootvg may:

- Take longer than usual while the kernel re-syncs ODM and rebuilds
  device configuration.
- Drop to a console TERM prompt before login -- enter `vt100` or
  `xterm` and continue. Subsequent boots will not prompt.
- Generate informational entries in errpt during initial config --
  review but expect some noise.

### 8.5 Post-reboot verification

    oslevel -s
    # Expect: 7200-05-10-XXXX (your chosen target SP)

    oslevel -r
    # Expect: 7200-05

    instfix -i | grep ML
    # Expect: All filesets for 7200-05_AIX_ML were found.

    lppchk -v
    # MUST return clean

    errpt | head -30
    # Compare against /tmp/errpt_pre.txt

    df -g
    # /usr will have grown notably
    diff /tmp/df_pre.txt <(df -g) | head

    lssrc -a | grep -i inoperative
    # Anything that should be active but isn't?

    bootlist -m normal -o
    # Expect: hdisk1 (the migrated disk is now your live rootvg)

    lspv
    # hdisk0 will show as 'old_rootvg' -- this is your rollback

    # Check kernel extensions reloaded
    diff /tmp/genkex_pre.txt <(genkex) | head

### 8.6 Application validation

Hand off to application owners for service validation. Treat the
change as in-progress until they sign off. Keep the rollback warm.

---

## 9. Rollback procedure

Trigger conditions:

- Client fails to boot off the migrated rootvg.
- `lppchk -v` reports broken filesets post-migration.
- New error classes in `errpt` linked to the migration.
- Application owners report a regression that cannot be remediated
  in the maintenance window.

### 9.1 Rollback while booted on the migrated 7.2 rootvg

    # Repoint bootlist to the original 7.1 disk (now 'old_rootvg')
    bootlist -m normal hdisk0
    bootlist -m normal -o          # verify

    shutdown -Fr now

After reboot:

    oslevel -s                     # expect: 7100-05-12-2336

    lspv
    # rootvg is back on hdisk0; the migrated 7.2 will show as
    # altinst_rootvg or similar on hdisk1

### 9.2 Rollback if the migrated system will not boot

From the HMC:

1. Open a vterm to the LPAR.
2. Power off the LPAR (Operations -> Shut Down -> Immediate).
3. Activate the LPAR with profile, in SMS mode.
4. SMS Main Menu -> "5. Select Boot Options"
   -> "1. Select Install/Boot Device"
   -> "5. Hard Drive"
   -> select hdisk0 (the original disk)
   -> "2. Normal Mode Boot"
5. System boots from hdisk0 (original 7.1 rootvg).

Then follow 9.1 verification.

### 9.3 Worst case: restore from mksysb via NIM

If neither disk boots:

    # On NIM master
    nim -o bos_inst \
        -a source=mksysb \
        -a mksysb=lpar01_pre72_<date> \
        -a spot=spot_aix71tl5sp12 \
        -a no_client_boot=no \
        lpar01

This requires a 7.1 SPOT on the NIM master in addition to the 7.2 one
created earlier -- worth keeping the old 7.1 SPOT around until burn-in
is complete.

### 9.4 Post-rollback cleanup

Once stable on the rolled-back rootvg:

    # Remove the failed 7.2 alt_rootvg
    alt_rootvg_op -X altinst_rootvg

    # File a problem ticket with IBM if migration failed unexpectedly.
    # Preserve the nimadm log from the master:
    # /var/log/nim/nimadm_lpar01_*.log
    # /var/adm/ras/nim.installp on the client

---

## 10. Cleanup (T+5 to T+14 days, after burn-in)

Only after the migrated system has run cleanly and application owners
have signed off:

### 10.1 On the client

    # Remove the old 7.1 rootvg clone, freeing hdisk0
    alt_rootvg_op -X old_rootvg

    lspv
    # hdisk0 should now show "None" in VG column.

    # Optional: extend rootvg onto hdisk0 for mirroring or growth
    # extendvg rootvg hdisk0
    # mirrorvg rootvg hdisk0
    # bosboot -ad /dev/hdisk0
    # bootlist -m normal hdisk1 hdisk0

    # Update local archive
    tar -cvf /backup/change_$(hostname)_$(date +%Y%m%d).tar \
        /tmp/preflight_*.log \
        /tmp/errpt_pre.txt /tmp/lssrc_pre.txt /tmp/df_pre.txt \
        /tmp/no_pre.txt /tmp/sys0_pre.txt /tmp/genkex_pre.txt

### 10.2 On the NIM master

    # Remove the pre-migration mksysb (after retention period)
    nim -o remove lpar01_pre72_<date>
    rm /export/nim/mksysb/lpar01_pre72_<date>.mksysb

    # Keep the lpp_source and SPOT if more clients are pending
    # migration to the same level. Otherwise:
    #   nim -o remove spot_aix72tl5sp10
    #   nim -o remove lpp_aix72tl5sp10
    #   rm -rf /export/nim/lpp_source/lpp_aix72tl5sp10
    #   rm -rf /export/nim/spot/spot_aix72tl5sp10

    # Clean up nimadmvg working storage if not needed
    # (nimadm cleans this automatically on success)

Update the change ticket with completion timestamp and close.

---

## Appendix A: NIM resource quick reference

  lsnim                          List all NIM objects
  lsnim -l <object>              Show all attributes of an object
  lsnim -t lpp_source            List objects of type lpp_source
  lsnim -t spot                  List SPOTs
  lsnim -t standalone            List client (standalone) machines

  nim -o check <resource>        Re-validate a resource
  nim -o remove <object>         Delete a NIM object
  nim -o reset <client>          Clear stuck NIM state on a client
  nim -o deallocate -a subclass=all <client>
                                 Free all resources allocated to client

  nimadm -c <client> -P 1 ...    Run only phase 1 (validation)
  nimadm -c <client> ...         Full migration
  nimadm -B -c <client>          "BOS only" mode -- skip non-BOS filesets

---

## Appendix B: nimadm phase failure quick reference

| Phase  | Common failure                          | Remediation |
|--------|------------------------------------------|-------------|
| 1      | Client unreachable                       | Check network, ping, rpcinfo |
| 1      | lpp_source missing simages=yes           | Re-add ISO 2 contents, inutoc, nim -o check |
| 1      | Client lppchk -v not clean               | Fix broken filesets on 7.1 first |
| 3      | Spare disk not free / wrong size         | Confirm hdisk1 has VG=None and size >= hdisk0 |
| 4      | NFS mount fails                          | Firewall between client and master, /etc/exports |
| 7      | "Not enough space in /usr" (alt rootvg)  | Increase rootvg size or use larger target disk |
| 7      | Fileset prereq missing in lpp_source     | Add missing fileset to lpp_source, inutoc, restart |
| 9      | bosboot fails                            | Usually disk error; check errpt on client |
| 11     | Cannot wake alt_disk_install             | Manual `alt_rootvg_op -W -d hdisk1` on client |

If nimadm fails mid-run, it can usually be restarted from a specific
phase using `-r` (resume) or `-P N` (run from phase N). Read the
error message at the top of the failure for the suggested restart.

---

## Appendix C: Worked example -- single command sequence

For reference, the entire happy-path sequence:

    # === On NIM master, one-time setup ===
    mkdir -p /export/nim/media/AIX_7.2_TL5_SP10
    # ... transfer ISOs here ...

    nim -o define -t lpp_source \
        -a server=master \
        -a location=/export/nim/lpp_source/lpp_aix72tl5sp10 \
        -a source=/export/nim/media/AIX_7.2_TL5_SP10/AIX_7200-05-10_DVD_1_of_2.iso \
        -a packages=all \
        lpp_aix72tl5sp10
    # ... add ISO 2 contents via bffcreate, then inutoc and nim -o check ...

    nim -o define -t spot \
        -a server=master \
        -a location=/export/nim/spot \
        -a source=lpp_aix72tl5sp10 \
        spot_aix72tl5sp10

    # === On client, pre-flight ===
    oslevel -s
    lppchk -v
    lspv
    bootlist -m normal -o > /tmp/bootlist_pre.txt
    errpt -a > /tmp/errpt_pre.txt

    # === On NIM master, take pre-migration mksysb ===
    nim -o define -t mksysb \
        -a server=master \
        -a location=/export/nim/mksysb/lpar01_pre72_$(date +%Y%m%d).mksysb \
        -a source=lpar01 \
        -a mk_image=yes \
        lpar01_pre72_$(date +%Y%m%d)

    # === On NIM master, run migration ===
    script /var/log/nim/nimadm_lpar01_$(date +%Y%m%d_%H%M).log
    nimadm -c lpar01 -s spot_aix72tl5sp10 -l lpp_aix72tl5sp10 \
           -j nimadmvg -d hdisk1 -Y
    exit

    # === On client, reboot and verify ===
    shutdown -Fr now
    # ... wait for reboot ...
    oslevel -s                     # expect 7200-05-10-XXXX
    lppchk -v
    instfix -i | grep ML
    errpt | head

    # === On client, cleanup after burn-in ===
    alt_rootvg_op -X old_rootvg

---

End of runbook.
