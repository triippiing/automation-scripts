# VIOS / AIX maintenance scripts

Refactored from the scripts recovered from the old NIM server (September 2026). The
"Replaces" column below names the original script each one came from.

## Layout

| Refactored                   | Replaces                              | Purpose |
|------------------------------|---------------------------------------|---------|
| `vios_lib.ksh`               | (copy-pasted code in every script)    | Shared logging, root/platform checks, `/repo1` mount helpers, config loading |
| `vios.conf.example`          | hard-coded paths                      | Site settings: log dir, repo export/mount, toolbox root, push user/hostfile |
| `examples/dnf/`              | `/software/dnf/dnf.conf_client_NN` (lost) | Client `dnf.conf` per AIX level pointing at the `/repo1` mirror. Used when the mount has none |
| `examples/logrotate/`        | `/software/logrotate/*` (lost)        | `system`, `dnf`, `httpd` rotation configs. Used when the mount has none |
| `install_efix.ksh`           | `security_fix.ksh`, `curl_fix.ksh`    | Install an IBM interim fix with `emgr` from any directory of epkg files; emgr's own preview decides which one applies |
| `installp_update.ksh`        | `openssl_update_new.ksh`              | Install/update any installp product (OpenSSL by default) from any directory of installp images |
| `install_dnf.ksh`            | `install_dnf.ksh`                     | Install DNF from the IBM bundle, drop in client `dnf.conf`, update, install `sudo_noldap` |
| `install_logrotate.ksh`      | `install_logrotate.ksh`               | Install logrotate via DNF, drop in rotation configs, ensure the nightly cron entry |
| `rulestoset.ksh` + `adapter_rules.conf` | `rulestoset.ksh`           | Apply VIOS `rules` for FC adapters (by model id) and standard defaults, then deploy |
| `unused_adapters.ksh`        | `unused_adapters.ksh`                 | Read-only audit of unused fcs/ent adapters, prints the removal commands |
| `lldp_setup.ksh`             | `lldp_setup.ksh`                      | Enable LLDP on each SEA and report the connected switch/port |
| `sea_status.ksh`             | `port_status.ksh`, `port_link.ksh`    | Quick SEA link/status view; `-v` VLANs, `-n` NPIV mappings, `-a` both |
| `vios_standardise.ksh`       | `Vios_3.1.2.60.ksh`, `Vios_4.1.1.00.ksh`, `Vios_4.1.2.10_fresh_install.ksh` | Post-install standard build: filesystems, paging, herald, limits, sshd, syslog, profile/kshrc/banner/sudoers, language cleanup, adapter rules; optional fix tree install. Idempotent, `-n` dry run, `-s` step selection |
| `push_files.ksh` + `push_files.manifest.example` | `rollout.ksh`     | Push files from an admin host to a list of VIOS/AIX hosts and install them as root |
| `rotate_ssh_key.sh`          | `vdikey_update.bash`                  | Swap one public key for another in your authorized_keys across a host list |
| `payload/`                   | files rollout.ksh pushed              | The standard VIO login environment and access files (see below) |
| `payload/removeunwanted.ksh` | `removeunwanted.ksh`                  | Remove non-English `openssh.msg.*` filesets; queries what is installed, `-n` dry run |

## Conventions

* All scripts take `getopts` flags and print usage on `-h`/bad args. The old wrapper
  (`slcntrl`) called scripts with `-m mountpoint -t type -a apply -n nimsource`; those
  flags are still accepted everywhere so a rebuilt wrapper can pass them.
* Scripts that change something default to **test/preview mode** where the underlying
  tool supports it (`install_efix`, `installp_update`) or offer `-n` dry run
  (`rulestoset`, `push_files`). `-a apply` makes changes.
* Run as root. On a VIO server: `oem_setup_env` first. `push_files.ksh` runs from the
  admin host as the remote user (`padmin` by default) and escalates via `oem_setup_env`.
* Logs go to `$LOGDIR` (default `/var/log/vios_scripts`), one file per script. The screen
  shows a two-column summary; the log has full command output.
* Install `vios_lib.ksh` and `vios.conf` alongside the scripts. Nothing else is required.
* **Nothing site-specific is committed.** Hostnames, IPs and credentials live only in gitignored
  files: `vios.conf`, `vios.conf.<env>` and `hosts/<env>.hosts`. Copy the `.example` files to
  create them. Set `VIOS_ENV=<env>` to layer an environment's config and host list on top of the base.

## Behaviour changes from the originals worth knowing

* `install_efix`: no more hand-maintained `Advisory.asc` index and no fixed directory
  layout. Download the advisory's epkg files from IBM Fix Central into any directory and
  run with `-d <dir>`; every `*.epkg.Z` there is previewed and those that pass are
  installed. `-e <file>` names one package, `-m <mnt> -f <name>` is the old layout.
  Packages are not kept in this repo. NIM master is detected from the `bos.sysmgt.nim.master` fileset
  rather than from the hostname. The AIX path now actually installs (the original only
  previewed twice).
* `installp_update`: any product, not just OpenSSL, from any directory (`-d <dir>`), or
  the old `<mnt>/<product>/<version>` layout with `-m -p -v`. `-F "fileset list"`
  restricts what is installed; default is `all`. No hard-coded list of supported OS levels.
* `install_dnf`: skips the bundle install if DNF is already present (`-F` to force).
  AIX 7.1 is handled. `/repo1` is mounted once and always unmounted on exit.
* `install_logrotate`: presence checked with `rpm -q`, not by looking for a config file.
  The cron entry now runs `logrotate` against `logrotate.conf` (which includes
  `logrotate.d`) instead of the directory; an existing directory-style entry is replaced.
  The original rotation configs were lost; `examples/logrotate/` is a rewrite: sulog, cron
  log, script logs and wtmp under `system`, the four dnf logs, and Toolbox httpd with a
  graceful restart. `/var/log/messages` is left to syslogd's own rotation.
* `install_dnf`: the original per-level `dnf.conf` files were lost; `examples/dnf/` is a
  rewrite against the IBM Toolbox mirror layout (`RPMS/ppc-7.3`, `RPMS/ppc`, `RPMS/noarch`).
  Check the `baseurl` lines against `ls /repo1/RPMS` before first use.
* `rulestoset`: adapter settings live in `adapter_rules.conf`. The original entries for
  `df1000e21410f103` used attribute names that do not exist on fcs adapters
  (`max_transfer_size`, `num_control_elems`); they are corrected to `max_xfer_size` and
  `num_cmd_elems` in the conf and flagged there. Verify against `lsattr -El fcsN`.
* `push_files`: manifest-driven. Files for `/etc/sudoers.d` are validated with `visudo`
  on the remote host before being moved into place. `backup` in the manifest keeps a
  timestamped copy of the existing file.
* `unused_adapters` / `lldp_setup` / `sea_status`: device names match as whole words
  (`fcs1` no longer matches `fcs10`).

## Payload files

What `push_files.ksh` installs on every VIO, from `payload/` via `push_files.manifest.example`:

| File | Installed as | Notes |
|------|--------------|-------|
| `v4.1.1.00.profile` | `/etc/profile` | IBM stock profile plus an SE section: history settings, login banner, and for non-padmin users a copy of the managed bashrc into `$HOME` at each login |
| `default.bashrc` | `/usr/local/bin/default.bashrc` | Prompt, vi/emacs mode by group, `sudo ioscli` aliases matching the sudoers file |
| `SEbanner` | `/etc/ssh/SEbanner` | SSH pre-login banner. `sshd_config` still needs `Banner /etc/ssh/SEbanner` set; the push does not do that |
| `Unix_Admin.sudo` | `/etc/sudoers.d/Unix_Admin` | Read-only `ioscli` commands for the Unix_Admin group, plus `su - padmin`. Validated with `visudo` before install |
| `filestosave.txt` | `/usr/local/bin/filestosave.txt` | List of files to keep from a VIO before rebuild |
| `removeunwanted.ksh` | `/usr/local/bin/removeunwanted.ksh` | See above |
| `default.profile` | `/usr/local/bin/default.profile` | Per-user `.profile` template |
| `padmin.kshrc` | `/home/padmin/.kshrc` | padmin prompt, vi mode, arrow keys. The old `$ugroup` switch was dropped: nothing sets it any more |
| `IBMi_VIO.sudo` | `/etc/sudoers.d/IBMi_VIO` | IBMi_VIO group may `su - padmin` |

Fixes applied to the originals: `default.bashrc` assigned to `GROUPS`, a bash built-in that ignores
assignments, so the group check never matched. `v4.1.1.00.profile` now checks the managed bashrc
exists before copying it. `filestosave.txt` had a duplicate entry.

Host lists live in `hosts/` and are **not** committed to GitHub (internal hostnames).

## Standing up a VIO server

1. Install VIOS from the ISO, configure networking, mount the NIM software share.
2. As root (`oem_setup_env`), from the mounted `VIOS/` directory:
   ```sh
   ksh vios_standardise.ksh -n                      # review
   ksh vios_standardise.ksh -F <mnt>/vios/vios_standards/4.1.2.0   # apply, plus the fix tree
   shutdown -restart
   ```
3. After the reboot: `rulestoset.ksh -n`, `sea_status.ksh -a`, `unused_adapters.ksh`, `lldp_setup.ksh`.
4. Later changes to the standard files go out with `push_files.ksh` from the admin host.

The fix tree layout is one sub-directory per fix: epkg files are installed with `install_efix.ksh`,
`ios.viodb*` with `updateios`, anything else with `installp_update.ksh`. Fix packages are
downloaded from IBM Fix Central per advisory and are not kept in git.

## Retired

Scripts from the old NIM server that are deliberately not carried forward:

* `perl_fix12.ksh`, `rpm_fix4.ksh`, `security_fix_python.ksh`, `openssl_fix.ksh`, `openssl_update.ksh`
  and the `.org/.v3` variants: one-off wrappers, all covered by `installp_update.ksh -d` / `install_efix.ksh -d`.
* `setup_ldap_misc.ksh`, `setup_ldap_sddc.ksh`: LDAP client setup with embedded credentials. Out of scope.
* The vulnerability-scanner service account scripts and sudoers file. Out of scope.
* The GSKit / IDS LDAP client fileset install that the standardisation scripts did. Dropped with LDAP.
* Run logs and host lists: internal hostnames, kept out of the public repo.

## Testing

Everything was syntax-checked with ksh93 and exercised end to end against stubbed AIX
commands (`emgr`, `installp`, `lsdev`, `rules`, `lldpctl`, `ssh`, ...). It has **not** been
run on a real VIO server yet. First run on a real box should be in test/dry-run mode.
