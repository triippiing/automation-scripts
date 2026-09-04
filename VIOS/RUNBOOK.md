# VIO server build runbook

From a blank VIOS install to the standard build, using the deployment tarball made by `make_tarball.sh`.
Part A is done by hand at the console. Everything from Part B on is one command, run twice
(before and after the reboot).

> Nothing in this tree has run on real VIOS hardware yet. The first run on a real server must be the
> dry run in step B4, read end to end, before the real run.

## A. Attended: install and first login

Done from the HMC console (or `vtmenu`). The script does none of this.

1. **Install VIOS** from the ISO or NIM. Pick the target disk(s) yourself in the installer.
   Take the defaults for everything else.
2. **First login** as `padmin`. Set the padmin password when prompted.
3. **Accept the license:**
   ```
   license -accept
   ```
4. **Network**, so the tarball can be copied over. Either configure it now:
   ```
   mktcpip -hostname <name> -inetaddr <ip> -interface en0 -netmask <mask> -gateway <gw> \
           -nsrvaddr <dns ip> -nsrvdomain <domain>
   ```
   or skip this and let the `check` phase prompt for the same values. In that case the tarball has to
   arrive another way (virtual optical media, USB).
5. **Copy the tarball** from the admin host:
   ```
   scp vios_build_<date>.tar padmin@<name>:/home/padmin/
   ```

## B. Build (first run)

As padmin on the new server:

```
oem_setup_env
cd /home/padmin
tar xf vios_build_<date>.tar
cd vios_build
ksh vios_build.ksh -n          # B4: dry run - read it all
ksh vios_build.ksh             # B5: real run
```

The real run does, in order:

| Phase | What happens | Where it is logged |
|-------|--------------|--------------------|
| `check` | License accepted, hostname set, default route, DNS, NTP. Offers to run `mktcpip` if there is no network. Fails the run if the license or network is missing. | `/var/log/vios_scripts/vios_build.log` |
| `build` | `vios_standardise.ksh`, every step: filesystems, padmin env, payload files, language cleanup, adapter rules, herald, dumpcheck, limits, sshd, syslog, paging, max_logname, tunables | `vios_standardise.log`, `rulestoset.log` |
| `fixes` | `vios_standardise.ksh -F fixes/<ioslevel>` if that directory is in the tarball: epkg fixes with `install_efix.ksh`, `ios.viodb*` with `updateios`, anything else with `installp_update.ksh`. Skipped with a message when there is no fixes directory. | `install_efix.log`, `installp_update.log` |

It then stops and prints:

```
Result : OK - reboot now (shutdown -restart), then run vios_build.ksh again for the verify phase
```

Each completed phase is recorded in `/var/log/vios_scripts/vios_build.state`. A failed phase is not
recorded; fix the cause and run the same command again, it resumes at the failed phase.

## C. Reboot and verify (second run)

```
exit                            # back to padmin
shutdown -restart
```

Log in again after the reboot:

```
oem_setup_env
cd /home/padmin/vios_build
ksh vios_build.ksh
```

The state file shows the pre-reboot phases done, so only `verify` runs: `rulestoset.ksh -n` (rules
compliance), `sea_status.ksh -a`, `unused_adapters.ksh` and `lldp_setup.ksh`. If you run it before
rebooting it refuses and says so. When verify finishes it prints the day-two steps below.

## D. After the build

Per server, by hand: SEA, NPIV and storage mappings. These are not standardisation and the script does
not touch them. `sea_status.ksh -a` and `lldp_setup.ksh` are worth re-running once the SEAs exist.

From the admin host, later:

* `push_files.ksh -M push_files.manifest -h <name>` whenever the standard files change.
* `install_dnf.ksh` and `install_logrotate.ksh` once the NIM `/repo1` export is reachable from the server.
  They need the repo and are not part of the offline build.

## Options and recovery

| Command | Effect |
|---------|--------|
| `vios_build.ksh -l` | List the phases and what the state file says about each |
| `vios_build.ksh -n` | Dry run of whatever would run next; nothing changed, nothing recorded |
| `vios_build.ksh -p build` | Run one phase (or a comma list) regardless of the state file |
| `vios_build.ksh -F <dir>` | Use this fixes directory instead of `fixes/<ioslevel>` |
| `vios_build.ksh -y` | Never prompt; a failed check exits instead of offering `mktcpip` |
| `vios_build.ksh -r` | Forget the state file and start from `check` next time |

Every step in `vios_standardise.ksh` is idempotent, so re-running `build` on a server that is already
built only reports "already" for each item. `vios_standardise.ksh -l` lists the steps and `-s <step>`
runs one.

## Building the tarball (admin host)

```
cd automation-scripts/VIOS
cp vios.conf.example vios.conf          # once; site settings, gitignored
sh make_tarball.sh -f /path/to/fixes    # -> vios_build_<yyyymmdd>.tar
```

The fixes directory is laid out as `<ioslevel>/<one directory per fix>/`, for example
`fixes/4.1.2.10/IJ54321/*.epkg.Z`. Download the packages from IBM Fix Central per advisory; they are not
kept in git. `vios_build.ksh` looks for `fixes/<ioslevel>` where ioslevel is what `ioslevel` reports, so
a tarball can carry fixes for several releases.

The tarball holds every script, `adapter_rules.conf`, `push_files.manifest` (or the `.example`),
`payload/`, `vios.conf*` if present and the fixes tree. It leaves out `tests/` and `hosts/`.

## Appendix: what a run looks like

A simulated transcript, assembled from the scripts' actual output formats. It has not been captured from
real hardware. Sample inputs: hostname `vios1`, IP `10.20.30.41/24`, gateway `10.20.30.1`,
DNS `10.20.1.10` in `example.com`, VIOS 4.1.2.10, one fix `IJ54321` in the tarball, two physical
(`ent0`, `ent1`) and two virtual (`ent2`, `ent3`) ethernet adapters, two FC adapters, no SEA yet.

### First run, network not yet configured

```
# ksh vios_build.ksh
   Host                                : vios1  VIOS 4.1.2.10
   Phases                              : check build fixes

== check
Network is not configured. Configure it now [n]: y

No network is configured. The answers below are passed to mktcpip.
Hostname: vios1
Interface [en0]:
IP address: 10.20.30.41
Netmask [255.255.255.0]:
Gateway: 10.20.30.1
DNS server (blank for none): 10.20.1.10
DNS domain: example.com
     mktcpip                           : done
     license                           : ok - ioscli answers (ioslevel 4.1.2.10)
     hostname                          : ok - vios1
     default route                     : ok - 10.20.30.1
     DNS                               : ok - 10.20.1.10
     NTP                               : WARNING xntpd not running (cfgassist or startnetsvc ntp)

== build
   Host                                : vios1  VIOS 4.1.2.10
   Steps                               : filesystems padmin_env payload languages rules herald dumpcheck limits sshd syslog paging loginname tunables

   == filesystems
     /usr                              : 3G -> 8G
     /var                              : 1G -> 3G
     /opt                              : 1G -> 3G

   == padmin_env
     padmin .profile                   : ENV=/home/padmin/.kshrc added
     /var/adm/commandlog               : created

   == payload
     manifest                          : /home/padmin/vios_build/push_files.manifest.example
     /etc/profile                      : installed
     /usr/local/bin/default.bashrc     : installed
     /etc/ssh/SEbanner                 : installed
     /etc/sudoers.d/Unix_Admin         : installed
     /usr/local/bin/filestosave.txt    : installed
     /usr/local/bin/removeunwanted.ksh : installed
     /usr/local/bin/default.profile    : installed
     /home/padmin/.kshrc               : installed
     /etc/sudoers.d/IBMi_VIO           : installed

   == languages
Installed openssh.msg filesets : 12
Keeping                        : en_US,EN_US
To remove                      :
    openssh.msg.CA_ES
    openssh.msg.DE_DE
    openssh.msg.ES_ES
    openssh.msg.FR_FR
    openssh.msg.IT_IT
    openssh.msg.JA_JP
    openssh.msg.KO_KR
    openssh.msg.PT_BR
    openssh.msg.RU_RU
    openssh.msg.ZH_CN
All unwanted openssh message filesets removed

   == rules
   FC adapter rules
     fcs0 (df1000e21410f103)
     set                               : adapter/pciex/df1000e21410f103 max_xfer_size=0x400000
     set                               : adapter/pciex/df1000e21410f103 num_io_queues=16
     set                               : adapter/pciex/df1000e21410f103 num_cmd_elems=2048
   Standard rules
     set                               : adapter/vdevice/IBM,l-lan max_buf_huge=128
     set                               : adapter/vdevice/IBM,l-lan max_buf_large=256
     set                               : adapter/vdevice/IBM,l-lan max_buf_medium=2048
     set                               : adapter/vdevice/IBM,l-lan max_buf_small=4096
     set                               : adapter/vdevice/IBM,l-lan max_buf_tiny=4096
     set                               : adapter/vdevice/IBM,l-lan queues_rx=4
     set                               : disk/fcp/mpioosdisk reserve_policy=no_reserve
     set                               : disk/fcp/mpioosdisk algorithm=shortest_queue
     set                               : disk/fcp/mpioosdisk queue_depth=32
     set                               : disk/fcp/mpioosdisk max_transfer=0x100000
   Deploy                              : rules deployed and applied
   Result                              : OK

   == herald
     herald                            : set

   == dumpcheck
     dumpcheck                         : patched

   == limits
     limits fsize                      : unset -> -1
     limits nofiles                    : 2000 -> 8000

   == sshd
     sshd Banner                       : unset -> /etc/ssh/SEbanner
     sshd ClientAliveInterval          : unset -> 600
     sshd X11Forwarding                : no -> yes
     sshd                              : restarted

   == syslog
     syslog.conf                       : added and syslogd refreshed

   == paging
     hd6                               : 512MB -> 8192MB (+60 x 128MB)

   == loginname
     LOGIN_NAME_MAX                    : 9 -> 256 (after reboot)

   == tunables
     ioo j2_dynamicBufferPreallocation : 16 -> 256
     no tcp_fastlo                     : 0 -> 1
     acfo in_core_enabled              : 0 -> 1

   Result                              : OK
   Reboot required                     : for: rules max_logname  (shutdown -restart)
   Next                                : reboot, then verify with: rulestoset.ksh -n, sea_status.ksh, unused_adapters.ksh

== fixes
   Host                                : vios1  VIOS 4.1.2.10
   Steps                               : fixes

   == fixes
   Host                                : vios1
   Platform                            : VIO 4.1.2.10
   Fix                                 : IJ54321
   Mode                                : apply
   Preview IJ54321s1a.240601.epkg.Z    : OK
   Install IJ54321s1a.240601.epkg.Z    : OK
   Reboot required                     : IJ54321s1a.240601.epkg.Z
   Result                              : installed successfully

   Result                              : OK

   Result                              : OK - reboot now (shutdown -restart), then run vios_build.ksh again for the verify phase
```

Then, as padmin: `shutdown -restart`.

### Second run, after the reboot

```
# ksh vios_build.ksh
   Host                                : vios1  VIOS 4.1.2.10
   Phases                              : verify

== verify
   Mode                                : DRY RUN - nothing will be changed
   FC adapter rules
     fcs0 (df1000e21410f103)
     would set                         : adapter/pciex/df1000e21410f103 max_xfer_size=0x400000
     would set                         : adapter/pciex/df1000e21410f103 num_io_queues=16
     would set                         : adapter/pciex/df1000e21410f103 num_cmd_elems=2048
   Standard rules
     would set                         : adapter/vdevice/IBM,l-lan max_buf_huge=128
     ... (one line per entry in adapter_rules.conf)
   Deploy                              : skipped (dry run)
No Shared Ethernet Adapters found on vios1
NPIV logged-in mappings : 0
   Checking FC adapters (fcs) against lsnports
     all fcs adapters are in use

   Checking ethernet adapters (ent)
     ent2                              : not in use
     ent3                              : not in use

   To remove, as padmin (verify link-down ones first):
     for num in 2 3; do
       rmtcpip -f -interface et${num}
       rmtcpip -f -interface en${num}
       rmdev -dev en${num} -recursive -ucfg
       rmdev -dev et${num} -recursive -ucfg
       rmdev -dev ent${num} -recursive -ucfg
       chdev -dev ent${num} -attr autoconfig=defined
     done

Full detail in /var/log/vios_scripts/unused_adapters.log

   Summary                             : hostname  sea  switch  switch-port-mac  port-description

  Useful commands:  lldpctl show port <sea>
                    lldpctl show neighbor <sea> | egrep 'Port Description:|System Name:'

   Day two, from the admin host        : push_files.ksh -M push_files.manifest -h vios1   (later changes to the standard files)
                                       : install_dnf.ksh / install_logrotate.ksh once the NIM repo is reachable
                                       : SEA, NPIV and storage mappings are per server and not part of this build

   Result                              : OK
```

Two things to read carefully in the second run. The rules dry run says "would set" for every rule even
after they were deployed, because `rulestoset.ksh -n` prints its intended commands rather than a diff;
use `rules -o diff` for a compliance check. And `unused_adapters.ksh` lists the virtual ethernet adapters
as unused because no SEA exists yet; do not remove them, they are what the SEA will be built on.

If the second run is started before the reboot it stops with:

```
== verify
     verify                            : build ran in this boot - reboot first (shutdown -restart), then run again

   Result                              : verify FAILED - fix and run again (see /var/log/vios_scripts/vios_build.log)
```
