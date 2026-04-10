#!/bin/ksh

WARN_THRESHOLD=80
CRIT_THRESHOLD=90
TOP_N=10
TMPFILE=/tmp/fs_check_$$.tmp
LOGFILE=/var/log/fs_monitor.log
DATE=$(date '+%Y-%m-%d %H:%M:%S')

trap "rm -f $TMPFILE" EXIT INT TERM

df -k | tail +2 > $TMPFILE

{
    echo "=============================================="
    echo " Filesystem Usage Report - $DATE"
    echo "=============================================="
    echo ""

    # -----------------------------------------------
    # SECTION 1: Filesystems between 80% and 89%
    # -----------------------------------------------
    echo "--- Filesystems over ${WARN_THRESHOLD}% (Warning) ---"
    echo ""

    warn_count=0

    while read line; do
        percent_used=$(echo "$line" | awk '{print $4}')
        mount_point=$(echo "$line" | awk '{print $7}')
        usage=$(echo "$percent_used" | sed 's/%//')

        echo "$usage" | grep -q '^[0-9][0-9]*$' || continue

        if [ "$usage" -ge "$WARN_THRESHOLD" ] && [ "$usage" -lt "$CRIT_THRESHOLD" ]; then
            echo "  [WARN]  $mount_point  ${usage}% used"
            warn_count=$((warn_count + 1))
        fi
    done < $TMPFILE

    [ "$warn_count" -eq 0 ] && echo "  No filesystems in warning state."
    echo ""

    # -----------------------------------------------
    # SECTION 2: Filesystems at 90%+ (Critical)
    # -----------------------------------------------
    echo "--- Filesystems over ${CRIT_THRESHOLD}% (Critical) ---"
    echo ""

    crit_count=0

    while read line; do
        percent_used=$(echo "$line" | awk '{print $4}')
        mount_point=$(echo "$line" | awk '{print $7}')
        usage=$(echo "$percent_used" | sed 's/%//')

        echo "$usage" | grep -q '^[0-9][0-9]*$' || continue

        if [ "$usage" -ge "$CRIT_THRESHOLD" ]; then
            crit_count=$((crit_count + 1))
            echo "  [CRIT]  $mount_point  ${usage}% used"
            echo ""
            echo "  Top ${TOP_N} largest files in ${mount_point}:"
            echo "  $(printf '%0.s-' {1..50})"

            find "$mount_point" -xdev -type f -ls 2>/dev/null | \
                awk '{printf "  %12d KB   %s\n", $7/1024, $11}' | \
                sort -rn | \
                head -"$TOP_N"

            echo "  $(printf '%0.s-' {1..50})"
            echo ""
        fi
    done < $TMPFILE

    [ "$crit_count" -eq 0 ] && echo "  No filesystems in critical state."

    echo ""
    echo "=============================================="
    echo " Summary: ${warn_count} warning | ${crit_count} critical"
    echo "=============================================="

} 2>&1 | tee -a $LOGFILE