#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: install_dnf.ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Installs DNF from the IBM bundle on an SE VIO server / AIX host, drops in the per-oslevel client
#|              dnf.conf, then updates existing packages and installs sudo_noldap from the NIM /repo1 repository.
#|
#| Usage:       install_dnf.ksh -m <mountpoint> -n <nimsource> [-t <type>] [-a <apply>] [-F]
#|                -m  NIM software mount point holding dnf/ (bundles and dnf.conf_client_NN files)
#|                -n  NIM server hostname exporting /repo1
#|                -t  host type (VIO|AIX) - accepted for wrapper compatibility, not used
#|                -a  apply mode          - accepted for wrapper compatibility, not used
#|                -F  force reinstall of DNF even if already present
#|
#| Note:        Client dnf.conf per oslevel, all using /repo1 as the mount point:
#|                  ${mountpoint}/dnf/dnf.conf_client_73 / _72 / _71 / _61
#|              Requires vios_lib.ksh alongside this script. Run as root.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 11/04/2025, recovered from the old NIM server
#| Revision History:
#| 11/04/2025 : original : Base script to install DNF and packages on SE infrastructure VIO Servers
#| 03/09/2026 :          : Refactor - shared library, single /repo1 mount, skip-if-installed restored, oslevel
#|                         mapping unified, bare printf and duplicate mount removed, cleanup on exit
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

MNT=""
NIMSOURCE=""
TYPE=""
APPLY=""
FORCE=0

usage() {
    print -u2 "Usage: $0 -m <mountpoint> -n <nimsource> [-t <type>] [-a <apply>] [-F]"
    exit 1
}

while getopts "m:t:a:n:F" opt; do
    case "$opt" in
        m) MNT="$OPTARG" ;;
        t) TYPE="$OPTARG" ;;
        a) APPLY="$OPTARG" ;;
        n) NIMSOURCE="$OPTARG" ;;
        F) FORCE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$MNT" && -n "$NIMSOURCE" ]] || { print -u2 "ERROR: -m and -n are required"; usage; }
[[ -d "$MNT/dnf" ]] || { print -u2 "ERROR: $MNT/dnf not found - is the NIM software mount in place?"; exit 1; }

require_root
log_init "${LOGDIR}/install_dnf.log" "$@"

OSver=$(os_level_short)
tmpdir="${TMPDIR}/dnf.$$"

cleanup() {
    rm -rf "$tmpdir"
    umount_repo
    log_close
}
trap cleanup EXIT

#############################################
# Pick the bundle for this oslevel
#############################################

case "$OSver" in
    7300)      tarfile="dnf_bundle_aix_73.tar" ;;
    7200|7100) tarfile="dnf_bundle_aix_71_72.tar" ;;
    6100)      die "AIX 6.1 requires yum - use yum_6100.ksh" ;;
    *)         die "oslevel $OSver is not configured in this script" ;;
esac
log_and_screen "OS level" "$OSver"
log_and_screen "DNF bundle" "$tarfile"

#############################################
# Install DNF (unless already present)
#############################################

install_dnf() {
    [[ -f "${MNT}/dnf/${tarfile}" ]] || die "bundle not found: ${MNT}/dnf/${tarfile}"

    log_and_screen "Extracting bundle" "$tmpdir"
    mkdir -p "$tmpdir" || die "cannot create $tmpdir"
    tar -xf "${MNT}/dnf/${tarfile}" -C "$tmpdir" \
        || die "failed to extract ${tarfile} - check free space in /tmp"

    [[ -x "$tmpdir/install_dnf.sh" ]] || die "install_dnf.sh missing from bundle"

    log_and_screen "Installing DNF" "running install_dnf.sh -d"
    ( cd "$tmpdir" && ./install_dnf.sh -d ) || die "install_dnf.sh failed - see $logfile"

    if [[ ! -e /usr/bin/dnf ]]; then
        ln -s "${FREEWARE}/bin/dnf" /usr/bin/dnf && log_and_screen "Link /usr/bin/dnf" "created"
    else
        log_and_screen "Link /usr/bin/dnf" "already exists"
    fi
}

if [[ -x "${FREEWARE}/bin/dnf" ]] && (( ! FORCE )); then
    log_and_screen "DNF" "already installed, skipping (use -F to force)"
else
    install_dnf
fi

#############################################
# Client dnf.conf for this oslevel
#############################################

conf_src="${MNT}/dnf/dnf.conf_client_${OSver%00}"
[[ -f "$conf_src" ]] || conf_src="$(dirname "$0")/examples/dnf/dnf.conf_client_${OSver%00}"
[[ -f "$conf_src" ]] || die "dnf.conf not found on the mount or in examples/dnf for level ${OSver%00}"
mkdir -p "${FREEWARE}/etc/dnf"
cp "$conf_src" "${FREEWARE}/etc/dnf/dnf.conf" || die "failed to copy dnf.conf"
log_and_screen "dnf.conf" "installed from $(basename "$conf_src")"

#############################################
# Update and install packages from /repo1
#############################################

mount_repo "$NIMSOURCE"

log_and_screen "Updating packages" "dnf -y update --nobest"
dnf -y update --nobest || die "dnf update failed - see $logfile"

log_and_screen "Installing package" "sudo_noldap.ppc"
dnf -y install sudo_noldap.ppc || die "dnf install sudo_noldap failed - see $logfile"

log_and_screen "DNF install" "completed"
exit 0
