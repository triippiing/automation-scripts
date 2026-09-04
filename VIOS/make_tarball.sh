#!/bin/sh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: make_tarball.sh
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Builds the deployment tarball for a blank VIO server from this directory: every script, config
#|              and payload file, plus an optional tree of fix packages. Run on the admin host; the result is
#|              copied to the new server and untarred there (see RUNBOOK.md).
#|
#|              Left out: tests/, hosts/ (internal host lists), git metadata and previously built tarballs.
#|              Included if present: vios.conf and vios.conf.<env>, so site settings travel with the scripts.
#|
#| Usage:       make_tarball.sh [-o <out.tar>] [-f <fixes dir>]
#|                -o  output file (default: ./vios_build_<yyyymmdd>.tar)
#|                -f  fixes directory to include as vios_build/fixes/, laid out as <ioslevel>/<one dir per fix>/
#|                    e.g. fixes/4.1.2.10/IJ12345/*.epkg.Z. vios_build.ksh picks fixes/<ioslevel> automatically.
#|
#| Note:        Plain POSIX sh and tar, so it runs on macOS, Linux or AIX. Fix packages are not kept in git.
#|-----------------------------------------------------------------------------------------------------------------|
#| Revision History:
#| 04/09/2026 : New
#|-----------------------------------------------------------------------------------------------------------------|

set -u
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=""
FIXES=""

usage() { echo "Usage: $0 [-o <out.tar>] [-f <fixes dir>]" >&2; exit 1; }

while getopts "o:f:" opt; do
    case "$opt" in
        o) OUT=$OPTARG ;;
        f) FIXES=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ -n "$OUT" ] || OUT="$PWD/vios_build_$(date +%Y%m%d).tar"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
if [ -n "$FIXES" ] && [ ! -d "$FIXES" ]; then
    echo "ERROR: fixes dir not found: $FIXES" >&2
    exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/vios_build.XXXXXX") || exit 1
trap 'rm -rf "$STAGE"' EXIT
TOP="$STAGE/vios_build"
mkdir "$TOP"

cp -R "$SRC/." "$TOP/" || exit 1
rm -rf "$TOP/tests" "$TOP/hosts" "$TOP/.git" "$TOP/.DS_Store"
rm -f "$TOP"/vios_build_*.tar
chmod 755 "$TOP"/*.ksh "$TOP"/*.sh "$TOP"/payload/*.ksh 2>/dev/null

if [ -n "$FIXES" ]; then
    mkdir "$TOP/fixes"
    cp -R "$FIXES/." "$TOP/fixes/" || exit 1
fi

( cd "$STAGE" && tar cf "$OUT" vios_build ) || exit 1

echo "written: $OUT"
echo "contents:"
tar tf "$OUT" | grep -v '/$' | sed 's/^/  /' | head -40
n=$(tar tf "$OUT" | grep -vc '/$')
[ "$n" -gt 40 ] && echo "  ... $n files"
echo ""
echo "on the new server (as padmin):  scp <admin>:$OUT /home/padmin/ ; oem_setup_env"
echo "                                cd /home/padmin && tar xf $(basename "$OUT") && cd vios_build"
echo "                                ksh vios_build.ksh -n     # then without -n"
exit 0
