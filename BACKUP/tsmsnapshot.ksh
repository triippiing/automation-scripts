#!/usr/bin/ksh
#
# tsmsnapshot.ksh - JFS2 snapshot-based TSM incremental backup
#
# Usage: tsmsnapshot.ksh [-n nodename] [-v volumegroup]
#   -n  TSM node identity to run the backup under (optional)
#   -v  Volume group to back up          (default: onestopprodvg)
#
# Examples:
#   ./tsmsnapshot.ksh
#   ./tsmsnapshot.ksh -n demoprodvg.demo
#   ./tsmsnapshot.ksh -n demoprodvg.demo -v demoprodvg
#

LOGFILE="/usr/tivoli/tsm/client/ba/bin64/tsmsnap.log"
VG="demoprodvg"
NODE=""
SNAPCACHESIZE="20"   # % of each filesystem reserved for the JFS2 snapshot (1-100, dsmc default 100)

usage() {
    echo "Usage: ${0##*/} [-n nodename] [-v volumegroup]" >&2
    echo "  -n  TSM node identity for the backup session (optional)" >&2
    echo "  -v  Volume group to back up (default: $VG)" >&2
    exit 2
}

# ---- argument parsing -----------------------------------------------------
while getopts ":n:v:" opt; do
    case "$opt" in
        n) NODE="$OPTARG" ;;
        v) VG="$OPTARG" ;;
        :)  echo "Option -$OPTARG requires an argument." >&2; usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

# Build the dsmc node option only if -n was supplied.
# Uses -nodename: with PASSWORDACCESS GENERATE the stored password for the
# target node name is reused (no prompt), PROVIDED that password has already
# been seeded into the local password file once (see header prereq).
NODEOPT=""
if [ -n "$NODE" ]; then
    NODEOPT="-nodename=$NODE"
fi

# ---- start ----------------------------------------------------------------
echo "===== TSM Snapshot Backup Started: $(date) =====" >> "$LOGFILE"
echo "Volume group:  $VG" >> "$LOGFILE"
echo "Snap cache:    ${SNAPCACHESIZE}%" >> "$LOGFILE"
if [ -n "$NODE" ]; then
    echo "Node identity: $NODE" >> "$LOGFILE"
else
    echo "Node identity: (local default from dsm.sys)" >> "$LOGFILE"
fi

INPUT=$(lsvg -l "$VG" | awk 'NR>2 && $2=="jfs2" && $7!="N/A" {print $7}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [ -z "$INPUT" ]; then
    echo "No JFS2 filesystems found in $VG. Backup not started." >> "$LOGFILE"
    echo "===== TSM Snapshot Backup Finished: $(date) =====" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    exit 1
fi

echo "Filesystems included in snapshot backup:" >> "$LOGFILE"
for fs in $INPUT; do
    echo "  $fs" >> "$LOGFILE"
done
echo "" >> "$LOGFILE"

echo "Running TSM command..." >> "$LOGFILE"
# $NODEOPT is intentionally unquoted: empty -> vanishes; node names contain no spaces.
dsmc incr -snapshotproviderfs=JFS2 -snapshotcachesize=$SNAPCACHESIZE $NODEOPT -domain="$INPUT" >> "$LOGFILE" 2>&1
RC=$?

echo "" >> "$LOGFILE"
echo "Backup Return Code: $RC" >> "$LOGFILE"
echo "===== TSM Snapshot Backup Finished: $(date) =====" >> "$LOGFILE"
echo "" >> "$LOGFILE"
exit $RC
