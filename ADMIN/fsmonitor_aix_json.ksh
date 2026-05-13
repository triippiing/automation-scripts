#!/bin/ksh

WARN_THRESHOLD=80
CRIT_THRESHOLD=90
TOP_N=10
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
TMPFILE=/tmp/fs_check_$$.tmp
TMPFILES=/tmp/fs_files_$$.tmp
LOGFILE=/home/bcadmin/jacks-stuff/testlogs/fs_monitor.log
JSONFILE=/home/bcadmin/jacks-stuff/testlogs/fs_monitor.json

trap "rm -f $TMPFILE $TMPFILES" EXIT INT TERM

# Append to log via fd3; stdout still goes to terminal
exec 3>> $LOGFILE

# Write line to both terminal (stdout) and log (fd3)
out() { echo "$@" | tee /dev/fd/3; }

df -k | tail +2 > $TMPFILE

warn_count=0
crit_count=0
WARN_JSON=""
CRIT_JSON=""

out "=============================================="
out " Filesystem Usage Report - $DATE"
out " Host: $HOSTNAME"
out "=============================================="
out ""

# -----------------------------------------------
# SECTION 1: Warning (80-89%)
# -----------------------------------------------
out "--- Filesystems over ${WARN_THRESHOLD}% (Warning) ---"
out ""

while read line; do
    percent_used=$(echo "$line" | awk '{print $4}')
    mount_point=$(echo "$line" | awk '{print $7}')
    usage=$(echo "$percent_used" | sed 's/%//')
    echo "$usage" | grep -q '^[0-9][0-9]*$' || continue

    if [ "$usage" -ge "$WARN_THRESHOLD" ] && [ "$usage" -lt "$CRIT_THRESHOLD" ]; then
        out "  [WARN]  $mount_point  ${usage}% used"
        warn_count=$((warn_count + 1))
        entry="{\"mount_point\":\"${mount_point}\",\"usage_percent\":${usage}}"
        [ -n "$WARN_JSON" ] && WARN_JSON="${WARN_JSON},"
        WARN_JSON="${WARN_JSON}${entry}"
    fi
done < $TMPFILE

[ "$warn_count" -eq 0 ] && out "  No filesystems in warning state."
out ""

# -----------------------------------------------
# SECTION 2: Critical (90%+)
# -----------------------------------------------
out "--- Filesystems over ${CRIT_THRESHOLD}% (Critical) ---"
out ""

while read line; do
    percent_used=$(echo "$line" | awk '{print $4}')
    mount_point=$(echo "$line" | awk '{print $7}')
    usage=$(echo "$percent_used" | sed 's/%//')
    echo "$usage" | grep -q '^[0-9][0-9]*$' || continue

    if [ "$usage" -ge "$CRIT_THRESHOLD" ]; then
        crit_count=$((crit_count + 1))
        out "  [CRIT]  $mount_point  ${usage}% used"
        out ""
        out "  Top ${TOP_N} largest files in ${mount_point}:"
        out "  --------------------------------------------------"

        find "$mount_point" -xdev -type f -ls 2>/dev/null | \
            awk '{printf "%d %s\n", $7/1024, $11}' | \
            sort -rn | head -"$TOP_N" > $TMPFILES

        FILES_JSON=""
        while read size_kb filepath; do
            printf "  %12d KB   %s\n" "$size_kb" "$filepath" | tee /dev/fd/3
            escaped=$(echo "$filepath" | sed 's/\\/\\\\/g; s/"/\\"/g')
            fe="{\"size_kb\":${size_kb},\"path\":\"${escaped}\"}"
            [ -n "$FILES_JSON" ] && FILES_JSON="${FILES_JSON},"
            FILES_JSON="${FILES_JSON}${fe}"
        done < $TMPFILES

        out "  --------------------------------------------------"
        out ""

        ce="{\"mount_point\":\"${mount_point}\",\"usage_percent\":${usage},\"top_files\":[${FILES_JSON}]}"
        [ -n "$CRIT_JSON" ] && CRIT_JSON="${CRIT_JSON},"
        CRIT_JSON="${CRIT_JSON}${ce}"
    fi
done < $TMPFILE

[ "$crit_count" -eq 0 ] && out "  No filesystems in critical state."
out ""
out "=============================================="
out " Summary: ${warn_count} warning | ${crit_count} critical"
out "=============================================="

exec 3>&-  # close log fd

# -----------------------------------------------
# JSON output (overwrites each run)
# -----------------------------------------------
printf '{\n  "report_date": "%s",\n  "hostname": "%s",\n  "summary": {"warning_count": %d, "critical_count": %d},\n  "warning_filesystems": [%s],\n  "critical_filesystems": [%s]\n}\n' \
    "$DATE" "$HOSTNAME" "$warn_count" "$crit_count" "$WARN_JSON" "$CRIT_JSON" > $JSONFILE
