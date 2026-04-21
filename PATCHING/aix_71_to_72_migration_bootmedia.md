# AIX 7.1 to 7.2 Migration Runbook -- Boot Media (HMC Virtual Optical / DVD / USB) Method

Version: 1.0
Scope:   Version migration of an AIX 7.1 LPAR to AIX 7.2 by booting
         the LPAR from the AIX 7.2 install media (virtual optical via
         HMC, physical DVD, or USB stick) and selecting the BOS
         installer's "Migration Install" option.
Audience: UNIX/Backup engineer with shell access and root on the
         client LPAR, plus HMC access for media attachment, console,
         and SMS-mode boot control.

---

## 1. Scope and assumptions

This runbook covers a single-LPAR AIX 7.1 -> 7.2 version migration
performed from boot media. The LPAR is shut down, booted from the
7.2 install media, and the BOS installer is driven through its
"Migration Install" option to upgrade the existing rootvg in place.

This runbook does NOT cover:

- New installations or "preservation" installs (different BOS menu
  selections; data loss implications).
- PowerHA/HACMP-clustered nodes (cluster must be quiesced; migrate
  one node at a time per IBM's PowerHA migration procedure).
- 7.1 -> 7.3 (procedure is identical; substitute 7.3 media).
- Migrations using NIM (`nimadm`) -- see the companion runbook for
  the NIM method.

Assumptions:

- HMC access to the client LPAR with rights to manage virtual media
  and activate in SMS mode.
- HMC managing the frame has the AIX 7.2 ISO loaded into a virtual
  optical device, OR a physical DVD drive is assigned to the LPAR,
  OR a bootable USB stick has been prepared and the LPAR has access
  to a USB controller.
- A free, unassigned local disk on the client of equal or greater
  size than the existing rootvg (used for `alt_disk_copy` rollback
  before booting media).
- Maintenance window of approximately 4-5 hours. Boot-media migration
  is slower than nimadm because the system is offline for the entire
  install (typically 90-180 minutes), and rollback (mksysb restore)
  is significantly slower than nimadm rollback (bootlist + reboot).

When to choose this method over nimadm:

- No NIM master available (and not feasible to build one).
- LPAR is on an isolated network with no path to a NIM master.
- Single, one-off migration where NIM setup overhead is not justified.

For repeated or fleet migrations, nimadm is strongly preferred.

---

## 2. Worked example used throughout this document

  Source level:        7100-05-12-2336   (AIX 7.1 TL5 SP12, final SP)
  Target level:        7200-05-10        (AIX 7.2 TL5 SP10, example)
  Client LPAR:         lpar01
  HMC:                 hmc01
  Managed system:      Server-9119-MME-SN12345AB
  Spare disk on client: hdisk1 (unassigned, equal size to hdisk0)
  Media:               AIX_7200-05-10_DVD_1_of_2.iso
                       AIX_7200-05-10_DVD_2_of_2.iso
                       (loaded into the HMC's virtual media library)
  Target rootvg disk:  hdisk0 (existing rootvg, will be migrated in place)

NOTE: SP versions evolve. Confirm the latest available 7.2 TL5 SP on
IBM Entitled Software Support (ESS) and substitute throughout.

---

## 3. Pre-change planning (T-7 to T-2 days)

| Item                                                          | Status |
|---------------------------------------------------------------|--------|
| Change ticket raised, CAB approval logged                     |  [ ]   |
| Maintenance window agreed with application owners             |  [ ]   |
| AIX 7.2 entitlement confirmed in ESS                          |  [ ]   |
| AIX 7.2 ISO(s) downloaded and checksum-verified               |  [ ]   |
| ISOs uploaded to HMC virtual media library (or DVD/USB ready) |  [ ]   |
| Free disk identified on client for alt_disk_copy rollback     |  [ ]   |
| HMC access tested, vterm to LPAR confirmed                    |  [ ]   |
| Backup strategy confirmed (mksysb to NFS/TSM + alt_disk_copy) |  [ ]   |
| Third-party software confirmed compatible with AIX 7.2        |  [ ]   |
| Rollback plan reviewed and signed off                         |  [ ]   |
| Console operator available for entire window (BOS menus need  |        |
| interactive input; do NOT plan to leave this unattended)      |  [ ]   |

Third-party software compatibility -- this matters MORE for a version
migration than for an SP. Verify against AIX 7.2 TL5:

- TSM/IBM Spectrum Protect client (check the IBM compat matrix).
- PowerHA/HACMP if present (do not migrate ad-hoc).
- Oracle, DB2, SAP -- each has its own AIX 7.2 cert matrix.
- Anything with a kernel extension (`genkex`).
- Java, OpenSSL, OpenSSH (newer baselines on 7.2).
- Monitoring/AV agents.

---

## 4. Boot media preparation

Three options, in order of practicality for most modern environments:

### 4.1 Option A: Virtual optical via HMC (recommended)

This is the standard approach in any environment with HMC-managed
Power frames. The HMC has a virtual media library that holds ISO
images, which can be mounted into a virtual optical drive presented
to the LPAR.

#### 4.1.1 Upload ISOs to the HMC virtual media library

Via HMC GUI:

1. HMC main menu -> Systems Management -> Servers -> select managed
   system.
2. Configuration -> Virtual Resources -> Virtual Storage Management.
3. Select the VIOS that owns virtual optical for this LPAR.
4. "Optical Devices" tab -> "Add" -> "Add Existing File" or upload
   the ISO from your workstation (slow) / from an NFS share the HMC
   can reach (faster).
5. Repeat for ISO 2.

Via HMC CLI (faster for large ISOs):

    # SSH to the HMC as hscroot
    ssh hscroot@hmc01

    # Verify managed system
    lssyscfg -r sys -F name

    # List existing media library contents
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "lsrep"

    # Upload an ISO to the VIOS media repository (from an NFS share)
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "mkrep -sp rootvg -size 10G"
    # (only needed first time -- creates the repository)

    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "mkvopt -name AIX72_TL5_SP10_DVD1 \
                         -file /home/padmin/AIX_7200-05-10_DVD_1_of_2.iso \
                         -ro"

#### 4.1.2 Load the ISO into the LPAR's virtual optical drive

    # Identify the virtual optical device assigned to the client
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "lsmap -all -type file_opt"
    # Look for the vtopt mapping to lpar01

    # Load ISO 1 into that virtual optical
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "loadopt -vtd vtopt0 -disk AIX72_TL5_SP10_DVD1"

When the BOS installer asks for ISO 2 partway through, you'll come
back here to swap:

    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "unloadopt -vtd vtopt0"
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "loadopt -vtd vtopt0 -disk AIX72_TL5_SP10_DVD2"

### 4.2 Option B: Physical DVD

Decreasingly common but still supported. The LPAR profile must have
the physical DVD drive (typically owned by VIOS, presented as virtual
optical, or directly assigned via DLPAR) attached.

1. Insert AIX 7.2 DVD 1 in the frame's DVD drive.
2. Confirm the LPAR has the DVD device assigned (via HMC partition
   profile or DLPAR add operation).
3. On the client (while still running 7.1):

       lsdev -Cc cdrom
       # Expect: cd0 Available ... IDE DVD-ROM Drive

If the DVD is shared between LPARs via VIOS, ensure it's currently
allocated to lpar01 and not held by another partition.

### 4.3 Option C: Bootable USB stick

Supported on POWER8 and later with USB controllers presented to the
LPAR. The mechanism is to write the AIX install ISO to a USB stick
such that the LPAR firmware recognizes it as a bootable device.

USB stick must be at least 16 GB.

On a Linux workstation:

    # Identify the USB device (NOT a disk you care about!)
    lsblk
    # e.g. /dev/sdc

    # Write the ISO directly
    dd if=AIX_7200-05-10_DVD_1_of_2.iso of=/dev/sdc bs=1M status=progress
    sync

    # AIX 7.2 install ISO is hybrid (bootable as either DVD or USB).

On AIX 7.x (a working AIX system other than the one being migrated):

    # Identify USB stick
    lsdev -Cc disk | grep -i usb
    # e.g. usbms0

    # Write ISO
    dd if=/path/to/AIX_7200-05-10_DVD_1_of_2.iso \
       of=/dev/usbms0 \
       bs=1m

Then physically plug the USB stick into a USB port on the frame
allocated to the target LPAR. USB media is fiddlier than virtual
optical and not all firmware levels handle multi-DVD installs cleanly
from USB -- prefer virtual optical when available.

### 4.4 Verify checksum BEFORE attaching media

Wherever the ISO is staged (HMC, DVD burn source, USB write source),
verify the SHA256 against the value on the ESS download page. A
corrupted install ISO causes failures partway through the install
that look like hardware faults.

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

### 5.3 Identify obsolete / problem filesets

    lslpp -L | grep -i obsolete
    lslpp -L bos.adt.libm bos.compat.libs perfagent.tools 2>/dev/null

### 5.4 Disk space

    df -g / /usr /var /opt /tmp /home

Migration target free space:

    /        100 MB
    /usr     3 GB
    /var     1 GB
    /tmp     1 GB
    /opt     500 MB

### 5.5 Rootvg and rollback disk

    lsvg rootvg
    lsvg -p rootvg
    lsvg -l rootvg

    lspv
    # Confirm hdisk1 shows "None" in VG column and is >= hdisk0 size.

    bootinfo -s hdisk0             # size in MB
    bootinfo -s hdisk1

### 5.6 Bootlist and error log

    bootlist -m normal -o > /tmp/bootlist_pre.txt
    bootlist -m service -o >> /tmp/bootlist_pre.txt

    errpt | head -30
    errpt -a > /tmp/errpt_pre.txt

### 5.7 Snapshot of running state

    lssrc -a > /tmp/lssrc_pre.txt
    netstat -rn > /tmp/routing_pre.txt
    df -g > /tmp/df_pre.txt
    no -a > /tmp/no_pre.txt
    lsattr -El sys0 > /tmp/sys0_pre.txt
    genkex > /tmp/genkex_pre.txt

### 5.8 Critical config file capture

The migration installer preserves /etc but does three-way merges on
some files. Capture pre-migration originals to diff against later:

    mkdir -p /tmp/etc_pre
    cp /etc/inittab           /tmp/etc_pre/
    cp /etc/inetd.conf        /tmp/etc_pre/
    cp /etc/services          /tmp/etc_pre/
    cp /etc/rc.tcpip          /tmp/etc_pre/
    cp /etc/security/limits   /tmp/etc_pre/
    cp /etc/filesystems       /tmp/etc_pre/

### 5.9 Console / network info for post-install recovery

Record details you may need to bring up networking after the install
if the ODM fails to migrate cleanly:

    netstat -rn > /tmp/routes_pre.txt
    ifconfig -a > /tmp/ifconfig_pre.txt
    cat /etc/resolv.conf
    cat /etc/netsvc.conf
    lsattr -El inet0 > /tmp/inet0_pre.txt

These capture allows you to recreate IP config from the console if
needed. Print them or store off-LPAR; you will not have access to
the running 7.1 system during the install.

---

## 6. Backups

### 6.1 mksysb to NFS or local backup target

    df -g /backup
    mksysb -i -X /backup/$(hostname)_pre72_$(date +%Y%m%d_%H%M).mksysb

Verify:

    ls -l /backup/$(hostname)_pre72_*.mksysb
    lsmksysb -l -f /backup/$(hostname)_pre72_*.mksysb | head -40

### 6.2 alt_disk_copy clone (PRIMARY ROLLBACK)

This is non-negotiable for boot-media migration. Without an
alt_disk_copy clone, your only rollback is mksysb restore -- which
itself requires booting from media in maintenance mode and takes
1-3 hours. With alt_disk_copy, rollback is a bootlist change and a
reboot.

    # Confirm hdisk1 is free
    lspv | grep hdisk1
    # Expected: hdisk1  00fXXXXXXXXXXXXX  None

    # Clone -- 10-30 min depending on rootvg size and disk speed
    alt_disk_copy -B -d hdisk1

Flags:
  -B   do NOT change bootlist (we want to control that explicitly)
  -d   destination disk

Verify:

    lspv
    # Expect new line: hdisk1 ... altinst_rootvg active

    # Confirm bootlist still points at hdisk0 (the disk we will migrate)
    bootlist -m normal -o
    # Expect: hdisk0

CRITICAL: Confirm bootlist is on hdisk0, NOT hdisk1, before you boot
the install media. The migration installer will offer hdisk0 as the
target -- if you accidentally pick hdisk1 (the clone), you'll
overwrite your rollback.

---

## 7. Boot the install media via SMS

### 7.1 Open vterm and shut down the LPAR

From the HMC:

1. Open vterm to the LPAR (Selected -> Console Window -> Open
   Terminal Window) -- have this open BEFORE you shut down so you
   can watch the boot.

2. From vterm, shut down cleanly (after application shutdown):

       shutdown -F now

   (Use `shutdown -F` rather than `-Fr` because we want the LPAR to
   power off, not auto-reboot off the existing bootlist.)

3. Wait for the LPAR state in HMC to show "Not Activated".

### 7.2 Activate in SMS mode

Via HMC GUI:

1. Right-click LPAR -> Operations -> Activate -> Profile.
2. Select the appropriate profile.
3. Boot mode -> "SMS".
4. OK.

Via HMC CLI:

    chsysstate -m Server-9119-MME-SN12345AB \
               -r lpar -o on \
               -n lpar01 \
               -f default_profile \
               -b sms

### 7.3 Watch the SMS menu come up in vterm

You'll see firmware POST output, then the SMS Main Menu:

    PowerPC Firmware
    Version XXXX
    SMS 1.7 (c) Copyright IBM Corp.

      Main Menu
      1. Select Language
      2. Setup Remote IPL (Initial Program Load)
      3. Change SCSI Settings
      4. Select Console
      5. Select Boot Options

### 7.4 Navigate to boot device selection

    5. Select Boot Options
        1. Select Install/Boot Device
            7. List all Devices

`List all Devices` enumerates everything firmware can see. After a
short scan you'll get a numbered list including hard disks, tape
drives, network adapters, and the virtual optical (or DVD/USB).

Look for the entry matching your install media:

  Examples of how the entry appears:
  - "USB CD-ROM"           (virtual optical via VIOS)
  - "SATA CD-ROM"          (physical DVD)
  - "USB Mass Storage"     (USB stick)
  - "IBM 9.5mm DVD-RAM Drive"

### 7.5 Boot from the media

Select the install media entry, then:

    2. Normal Mode Boot
    1. Yes (exit SMS)

The LPAR will load the BOS installer kernel from the media. Expect
60-120 seconds of boot output, then the BOS installer's first prompt:

    ******* Please define the System Console. *******
    Type a 1 and press Enter to use this terminal as the
    system console.

Press 1 + Enter.

---

## 8. BOS installer -- Migration Install

### 8.1 Language and locale

    Type the number of your choice and press Enter.
        1   Type 1 and press Enter to have English during install.

### 8.2 Installation and Maintenance menu

    Welcome to Base Operating System
    Installation and Maintenance

    Type the number of your choice and press Enter. Choice is indicated by >>>.

    >>> 1 Start Install Now with Default Settings
        2 Change/Show Installation Settings and Install
        3 Start Maintenance Mode for System Recovery
        4 Make Additional Disks Available
        5 Select Storage Adapters

CHOOSE: 2  -- Change/Show Installation Settings and Install

DO NOT pick 1 (Default Settings) -- the default is "New and Complete
Overwrite" which will destroy your rootvg.

### 8.3 Installation and Settings menu

    Installation and Settings

    Either type 0 and press Enter to install with current settings,
    or type the number of the setting you want to change.

      1   System Settings:
            Method of Installation.............New and Complete Overwrite
            Disk Where You Want to Install.....hdisk0
      2   Primary Language Environment Settings (AFTER Install):
      3   Security Model.....................Default
      4   More Options
      5   Select Edition

CHOOSE: 1  -- System Settings

### 8.4 Method of Installation menu

    Change Method of Installation

    Type the number of your choice and press Enter.

      1 New and Complete Overwrite
        Overwrites EVERYTHING on the disk selected for installation.
        Warning: Only use this method if the disk is totally empty
        or if there is nothing on the disk you want to preserve.

      2 Preservation Install
        Preserves SOME of the existing data on the disk selected
        for installation. Warning: This method overwrites the
        usr (/usr), variable (/var), temporary (/tmp), and root
        (/) file systems.

      3 Migration Install
        Upgrades the Base Operating System to current release.
        Other product (applications) files and configuration data
        are saved.

CHOOSE: 3  -- Migration Install

### 8.5 Select target disk

    Change Disk(s) Where You Want to Install

      Name      Location Code      Size(MB)   VG Status   Bootable
    > 1 hdisk0  ...                XXXXX      rootvg      Yes
      2 hdisk1  ...                XXXXX      altinst_rootvg  Yes

CHOOSE: 1 (hdisk0 -- the disk currently holding rootvg)

CRITICAL: hdisk1 is your alt_disk_copy rollback. If you select
hdisk1 here you will destroy your rollback. The disk to select is
the one currently labeled "rootvg" in the VG Status column.

After selection, a chevron `>>>` will appear next to hdisk0
indicating it's selected. Press 0 (zero) and Enter to continue.

### 8.6 Confirm migration settings

You'll be returned to the Installation and Settings menu, now showing:

      1   System Settings:
            Method of Installation.............Migration
            Disk Where You Want to Install.....hdisk0

Optional: select 4 (More Options) to review:
- Trusted Computing Base: usually No (migration default)
- Backup Configuration: No
- Remote Services: usually No
- 64-bit Kernel: Yes (default on modern AIX)

When satisfied:

CHOOSE: 0 (Install with current settings)

### 8.7 Final confirmation

    Migration Confirmation

    The following file systems will be migrated:
      /
      /usr
      /var
      /tmp
      /home
      /opt
      /admin
      ...

    Press Enter to continue.

Press Enter.

### 8.8 Installation runs

You'll see a status display:

    Installation Status

    Approximate     Elapsed time
    % tasks complete  (in minutes)

       2              0           Restoring base operating system
       ...            ...         Installing additional software

This phase takes 60-120 minutes depending on rootvg size and IO speed.

#### 8.8.1 Media swap (when prompted)

If the install spans both DVDs, you'll be prompted around the 70-80%
mark to insert DVD 2:

    Please remove volume 1 and insert volume 2.
    Press Enter to continue.

For HMC virtual optical: switch to your HMC session and:

    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "unloadopt -vtd vtopt0"
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "loadopt -vtd vtopt0 -disk AIX72_TL5_SP10_DVD2"

Then return to the vterm and press Enter.

For physical DVD: open the drive, swap discs, close, press Enter.

### 8.9 Post-install reboot

When the install completes, the LPAR reboots automatically. If the
bootlist is set correctly (firmware will set it to the migrated
disk), the system comes up on AIX 7.2.

If it boots back into SMS or back off the install media, you may
need to manually set the bootlist from SMS:

    SMS -> 5. Select Boot Options
        -> 2. Configure Boot Device Order
        -> 1. Select 1st Boot Device
        -> 5. Hard Drive
        -> select hdisk0
    -> Exit SMS, normal boot.

---

## 9. First boot and verification

### 9.1 First boot considerations

The first boot off the migrated 7.2 rootvg may:

- Take longer than usual (kernel re-syncs ODM, rebuilds device config).
- Drop to a console TERM prompt before login -- enter `vt100` or
  `xterm` and continue.
- Generate informational entries in errpt during initial config --
  review but expect some noise.

### 9.2 Network bring-up if it doesn't come up automatically

In most cases, networking comes up cleanly from the migrated config.
If it doesn't (no IP on the expected interface), use the captured
config from section 5.9 to recreate it from the console:

    lsdev -Cc adapter | grep -i ent
    chdev -l en0 -a netaddr=A.B.C.D -a netmask=W.X.Y.Z -a state=up
    route add 0 GATEWAY_IP

Then troubleshoot why the migration didn't preserve it.

### 9.3 Post-reboot verification

    oslevel -s
    # Expect: 7200-05-10-XXXX

    oslevel -r
    # Expect: 7200-05

    instfix -i | grep ML
    # Expect: All filesets for 7200-05_AIX_ML were found.

    lppchk -v
    # MUST return clean

    errpt | head -30
    # Compare against /tmp/errpt_pre.txt

    df -g
    diff /tmp/df_pre.txt <(df -g) | head

    lssrc -a | grep -i inoperative

    bootlist -m normal -o
    # Expect: hdisk0 (the migrated disk)

    lspv
    # hdisk0 = rootvg (now 7.2)
    # hdisk1 = altinst_rootvg (still 7.1, your rollback)

    diff /tmp/genkex_pre.txt <(genkex) | head

### 9.4 Diff config files

    diff /tmp/etc_pre/inittab     /etc/inittab
    diff /tmp/etc_pre/inetd.conf  /etc/inetd.conf
    diff /tmp/etc_pre/services    /etc/services
    diff /tmp/etc_pre/rc.tcpip    /etc/rc.tcpip
    diff /tmp/etc_pre/limits      /etc/security/limits
    diff /tmp/etc_pre/filesystems /etc/filesystems

The migration installer may have added new lines (new services, new
inittab entries for 7.2 features). Review and merge any local
customisations that were lost.

### 9.5 Application validation

Hand off to application owners. Treat as in-progress until they
sign off. Keep the rollback warm.

---

## 10. Rollback procedure

Trigger conditions:

- LPAR fails to boot off the migrated rootvg.
- `lppchk -v` reports broken filesets post-migration.
- New error classes in `errpt` linked to the migration.
- Application owners report a regression that cannot be remediated
  in the maintenance window.

### 10.1 Rollback while booted on the migrated 7.2 rootvg

This is your fast path -- and the reason alt_disk_copy was mandatory
in section 6.2.

    # Repoint bootlist to the alt_disk_copy clone (pre-migration 7.1)
    bootlist -m normal hdisk1
    bootlist -m normal -o

    shutdown -Fr now

After reboot:

    oslevel -s                     # expect 7100-05-12-2336

    lspv
    # rootvg now on hdisk1; the migrated 7.2 will show as
    # old_rootvg or altinst_rootvg on hdisk0

### 10.2 Rollback if the migrated system will not boot

From the HMC, vterm to LPAR:

1. Power off (Operations -> Shut Down -> Immediate).
2. Activate in SMS mode.
3. SMS Main Menu:

       5. Select Boot Options
           1. Select Install/Boot Device
               5. Hard Drive
                   List the hard drives, select hdisk1 (the alt_disk_copy)
       2. Normal Mode Boot
       1. Yes (exit SMS)

4. System boots from hdisk1 (pre-migration 7.1 clone).

Then follow 10.1 verification.

### 10.3 Worst case: no bootable disk -- mksysb restore

If both disks are unbootable:

1. Re-attach the AIX 7.1 install media (NOT the 7.2 media -- the
   7.1 maintenance shell is needed to restore a 7.1 mksysb).
2. Boot the LPAR in SMS mode and boot from 7.1 install media.
3. From the BOS Installation menu:

       3. Start Maintenance Mode for System Recovery
           4. Install from a System Backup
               (select the device holding your mksysb -- network,
                tape, or another disk)

4. The mksysb restore wizard walks through disk selection and
   network setup if the mksysb is on NFS.

This is slow (1-3 hours of restore plus reboot). It works, but it's
why alt_disk_copy is the rollback you actually want to use.

### 10.4 Post-rollback cleanup

Once stable on the rolled-back rootvg:

    # If rolled back via 10.1 (bootlist swap):
    alt_rootvg_op -X old_rootvg
    # OR (depending on what label the failed migration left)
    alt_rootvg_op -X altinst_rootvg

    # File a problem ticket with IBM if migration failed unexpectedly.
    # Preserve install logs:
    # /var/adm/ras/devinst.log
    # /var/adm/ras/bos.log
    # /var/adm/ras/bosinst.data

---

## 11. Cleanup (T+5 to T+14 days, after burn-in)

Only after the migrated system has run cleanly and application owners
have signed off:

    # Remove the alt_disk_copy clone, freeing hdisk1
    alt_rootvg_op -X altinst_rootvg

    lspv
    # hdisk1 should now show "None" in VG column.

    # Optional: extend rootvg onto hdisk1 for mirroring or growth
    # extendvg rootvg hdisk1
    # mirrorvg rootvg hdisk1
    # bosboot -ad /dev/hdisk1
    # bootlist -m normal hdisk0 hdisk1

    # Detach the install ISO from the virtual optical
    # (on HMC / VIOS):
    viosvrcmd -m Server-9119-MME-SN12345AB -p vios1 \
              -c "unloadopt -vtd vtopt0"

    # Optionally remove ISO from VIOS media library if not needed
    # for other LPARs:
    # viosvrcmd -m ... -c "rmvopt -name AIX72_TL5_SP10_DVD1"
    # viosvrcmd -m ... -c "rmvopt -name AIX72_TL5_SP10_DVD2"

    # Archive change logs
    tar -cvf /backup/change_$(hostname)_$(date +%Y%m%d).tar \
        /tmp/preflight_*.log \
        /tmp/errpt_pre.txt /tmp/lssrc_pre.txt /tmp/df_pre.txt \
        /tmp/no_pre.txt /tmp/sys0_pre.txt /tmp/genkex_pre.txt \
        /tmp/etc_pre/

Update the change ticket with completion timestamp and close.

---

## Appendix A: SMS menu navigation cheat sheet

  Boot from install media path:
    Main Menu
      5. Select Boot Options
        1. Select Install/Boot Device
          7. List all Devices              (or 3. CD/DVD, 6. USB)
            <select your media>
            2. Normal Mode Boot
              1. Yes (exit SMS)

  Set permanent boot device order:
    Main Menu
      5. Select Boot Options
        2. Configure Boot Device Order
          1. Select 1st Boot Device
            5. Hard Drive
              <list and select disk>

  Boot from a specific hard disk one-time:
    Main Menu
      5. Select Boot Options
        1. Select Install/Boot Device
          5. Hard Drive
            <select disk>
            2. Normal Mode Boot
              1. Yes

---

## Appendix B: BOS Installer common pitfalls

| Symptom                                          | Cause / Fix |
|---------------------------------------------------|-------------|
| Default option is "New and Complete Overwrite"    | Always pick "2. Change/Show Installation Settings", then change Method to Migration. NEVER "Start Install Now with Default Settings". |
| Migration option not offered                     | Target disk does not contain a recognised AIX rootvg, OR target version on media is older than installed version. |
| Install hangs at media swap                      | Virtual optical not actually swapped on VIOS, OR DVD not seated. Check loadopt status. |
| Reboot loops back to install media               | Bootlist not set to hard disk. From SMS, set hdisk0 as 1st boot device. |
| First boot drops to console "Set TERM" prompt    | Normal on first boot post-migration. Type vt100 or xterm. |
| First boot has no network                        | ODM did not migrate cleanly. Use captured config from preflight to manually rebuild. |
| `lppchk -v` reports broken filesets              | A migration prerequisite failed silently. Try `installp -C` then re-run any specific failed filesets from a 7.2 lpp_source. |

---

## Appendix C: Worked example -- single command sequence

For reference, the entire happy-path sequence:

    # === On client, pre-flight ===
    oslevel -s
    lppchk -v
    lspv
    bootlist -m normal -o > /tmp/bootlist_pre.txt
    errpt -a > /tmp/errpt_pre.txt
    mkdir -p /tmp/etc_pre
    cp /etc/{inittab,inetd.conf,services,rc.tcpip,filesystems} /tmp/etc_pre/

    # === On client, backups ===
    mksysb -i -X /backup/$(hostname)_pre72_$(date +%Y%m%d).mksysb
    alt_disk_copy -B -d hdisk1
    lspv                                  # confirm altinst_rootvg on hdisk1
    bootlist -m normal -o                 # confirm still hdisk0

    # === On HMC, prepare media ===
    viosvrcmd -m <managed_system> -p vios1 \
              -c "loadopt -vtd vtopt0 -disk AIX72_TL5_SP10_DVD1"

    # === On client, shutdown ===
    shutdown -F now

    # === On HMC, activate in SMS ===
    chsysstate -m <managed_system> -r lpar -o on \
               -n lpar01 -f default_profile -b sms

    # === On client vterm, in SMS ===
    # 5 -> 1 -> 7 -> select virtual optical -> 2 -> 1
    # ... BOS installer launches ...
    # Choose: 2 (Change settings) -> 1 (System Settings)
    #         -> 3 (Migration Install) -> select hdisk0 -> 0
    #         -> 0 (Install) -> Enter (confirm)
    # ... wait 60-120 minutes, swap DVD if prompted ...

    # === On HMC mid-install, swap DVD ===
    viosvrcmd -m <managed_system> -p vios1 -c "unloadopt -vtd vtopt0"
    viosvrcmd -m <managed_system> -p vios1 \
              -c "loadopt -vtd vtopt0 -disk AIX72_TL5_SP10_DVD2"

    # === On client, post-reboot verify ===
    oslevel -s                            # 7200-05-10-XXXX
    lppchk -v
    instfix -i | grep ML
    errpt | head

    # === On client, cleanup after burn-in ===
    alt_rootvg_op -X altinst_rootvg

---

End of runbook.
