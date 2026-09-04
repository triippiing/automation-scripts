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
