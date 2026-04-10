#!/usr/bin/ksh
LOGFILE="/usr/tivoli/tsm/client/ba/bin64/tsmsnap.log"
VG="onestopprodvg"

echo "===== TSM Snapshot Backup Started: $(date) =====" >> "$LOGFILE"

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
dsmc incr -snapshotproviderfs=JFS2 -domain="$INPUT" >> "$LOGFILE" 2>&1
RC=$?

echo "" >> "$LOGFILE"
echo "Backup Return Code: $RC" >> "$LOGFILE"
echo "===== TSM Snapshot Backup Finished: $(date) =====" >> "$LOGFILE"
echo "" >> "$LOGFILE"
exit $RC