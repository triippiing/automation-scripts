#!/bin/ksh
#
# hmc_monitor.ksh - Collect HMC inventory and service events
#
# Usage:
#   ./hmc_monitor.ksh                    # Interactive prompt
#   ./hmc_monitor.ksh hmc01              # Single HMC via arg
#   ./hmc_monitor.ksh "hmc01 hmc02"      # Multiple HMCs via arg
#
 
SSH_OPTS="-T -q -o BatchMode=yes -o ConnectTimeout=10"
LOG_DIR="/var/log/hmc_monitor"
TS=$(date '+%Y%m%d_%H%M%S')
 
#--------------------------------------------------------------------
# Validate hostname format - allow alphanumerics, dot, hyphen, underscore
# Prevents shell metachar injection into the ssh command
#--------------------------------------------------------------------
validate_hostname() {
    case "$1" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}
 
#--------------------------------------------------------------------
# Determine target HMC list: argument first, otherwise prompt
#--------------------------------------------------------------------
if [ $# -ge 1 ]; then
    HMC_LIST="$*"
else
    printf "Enter HMC hostname(s) [space separated for multiple]: "
    read HMC_LIST
fi
 
# Strip leading/trailing whitespace
HMC_LIST=$(echo "$HMC_LIST" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
 
if [ -z "$HMC_LIST" ]; then
    echo "ERROR: no HMC hostname provided" >&2
    exit 1
fi
 
# Validate each hostname before doing anything else
for HMC in $HMC_LIST; do
    if ! validate_hostname "$HMC"; then
        echo "ERROR: invalid hostname '$HMC' (allowed: A-Z a-z 0-9 . _ -)" >&2
        exit 1
    fi
done
 
#--------------------------------------------------------------------
# Log directory checks
#--------------------------------------------------------------------
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" || { echo "ERROR: cannot create $LOG_DIR" >&2; exit 1; }
fi
 
if [ ! -w "$LOG_DIR" ]; then
    echo "ERROR: cannot write to $LOG_DIR" >&2
    exit 1
fi
 
ERR=0
LOGS_CREATED=""
 
#--------------------------------------------------------------------
# Main collection loop
#--------------------------------------------------------------------
for HMC in $HMC_LIST; do
    LOG="${LOG_DIR}/hmc_${HMC}_${TS}.log"
    echo "Collecting $HMC -> $LOG"
    LOGS_CREATED="$LOGS_CREATED $LOG"
 
    # Pre-flight SSH check (key auth + reachability)
    ssh $SSH_OPTS "${HMC}" "true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: SSH to $HMC failed (check key auth / connectivity / DNS)" \
            | tee "$LOG" >&2
        ERR=$(( ERR + 1 ))
        continue
    fi
 
    {
        echo "================================================================"
        echo "Report Date : $(date '+%a %b %d %T %Z %Y')"
        echo "Target HMC  : $HMC"
        echo "================================================================"
        echo ""
 
        ssh $SSH_OPTS "${HMC}" <<'REMOTE_CMDS'
echo "----- HMC Identity -----"
HMC_NAME=$(lshmc -n | grep '^hostname=' | cut -d= -f2 | cut -d, -f1)
echo "Hostname : $HMC_NAME"
echo ""
 
echo "----- HMC Version -----"
lshmc -V | while IFS= read -r line; do
    line="${line//\"/}"
    [ -z "$line" ] && continue
    [ "$line" = "," ] && continue
    line="${line#,}"
    echo "$line"
done
echo ""
 
echo "----- Filesystem Usage -----"
printf "%-20s %10s %10s %14s\n" "Filesystem" "Size(MB)" "Avail(MB)" "Temp Files(MB)"
printf "%-20s %10s %10s %14s\n" "--------------------" "----------" "----------" "--------------"
lshmcfs | while IFS=',' read -r f1 f2 f3 f4 f5 rest; do
    fs="${f1#*=}"
    sz="${f2#*=}"
    av="${f3#*=}"
    tf="${f5#*=}"
    printf "%-20s %10s %10s %14s\n" "$fs" "$sz" "$av" "$tf"
done
echo ""
 
echo "----- Managed Systems (Frames) -----"
printf "%-20s %-12s %-10s %-18s %-25s\n" "Name" "Type/Model" "Serial" "IP Address" "State"
printf "%-20s %-12s %-10s %-18s %-25s\n" "--------------------" "------------" "----------" "------------------" "-------------------------"
lssyscfg -r sys -F "name,type_model,serial_num,ipaddr,state" | while IFS=',' read -r fname tm sn ip st; do
    printf "%-20s %-12s %-10s %-18s %-25s\n" "$fname" "$tm" "$sn" "$ip" "$st"
done
echo ""
 
echo "----- LPARs by Frame (sorted by LPAR ID) -----"
for FRAME in $(lssyscfg -r sys -F name); do
    echo "Frame: $FRAME"
    printf "  %-4s %-20s %-18s %-12s %-30s\n" "ID" "Name" "State" "RMC State" "OS Version"
    printf "  %-4s %-20s %-18s %-12s %-30s\n" "----" "--------------------" "------------------" "------------" "------------------------------"
    lssyscfg -r lpar -m "$FRAME" -F "lpar_id,name,state,rmc_state,os_version" | sort -t, -n -k1 | while IFS=',' read -r id lname st rmc osv; do
        printf "  %-4s %-20s %-18s %-12s %-30s\n" "$id" "$lname" "$st" "$rmc" "$osv"
    done
    echo ""
done
 
echo "----- Console Service Events (Last 30 Days, filtered) -----"
printf "%-20s | %s\n" "Time" "Event"
echo "---------------------+----------------------------------------------------------------"
lssvcevents -t console -d 30 | grep '^time=' | while IFS= read -r line; do
    # Skip known noise patterns - edit these to adjust signal/noise tradeoff
    case "$line" in
        *"chsvcevent -o close"*)                      continue ;;
        *"createse -i SRC_NUM"*)                      continue ;;
        *"Rearbitrate Primary Analysis"*)             continue ;;
        *"T-side code level"*)                        continue ;;
        *"PERSISTED SCHEDULED OPERATIONS"*)           continue ;;
        *"TIMER TASK HAS BEEN SCHEDULED"*)            continue ;;
        *"NEW SCHEDULED OPERATION WAS ADDED"*)        continue ;;
        *"A SCHEDULED OPERATION STARTED"*)            continue ;;
        *"A SCHEDULED OPERATION ENDED"*)              continue ;;
        *"A SCHEDULED OPERATION FAILED"*)             continue ;;
        *"The following operation started"*)          continue ;;
        *"The following operation completed"*)        continue ;;
        *"The following operation was scheduled"*)    continue ;;
        *"The following operation was attempted"*)    continue ;;
    esac
 
    # Remove double quotes (CSV wrapping)
    line="${line//\"/}"
    # Strip residual HTML fragments
    line="${line//<br\/>/}"
    line="${line//<em>/}"
    line="${line//<\/em>/}"
    line="${line//<b>/}"
    line="${line//<\/b>/}"
 
    # Split "time=X,text=Y" into separate columns
    time_part="${line#time=}"
    time_part="${time_part%%,text=*}"
    text_part="${line#*,text=}"
 
    printf "%-20s | %s\n" "$time_part" "$text_part"
done
REMOTE_CMDS
 
    } > "$LOG" 2>&1
done
 
#--------------------------------------------------------------------
# Summary
#--------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Collection complete."
echo "HMCs processed : $(echo $HMC_LIST | wc -w | tr -d ' ')"
echo "Errors         : $ERR"
echo "Log file(s)    :"
for L in $LOGS_CREATED; do
    if [ -f "$L" ]; then
        SIZE=$(wc -c < "$L" | tr -d ' ')
        echo "  $L  (${SIZE} bytes)"
    else
        echo "  $L  (NOT CREATED)"
    fi
done
echo "================================================================"
exit $ERR
