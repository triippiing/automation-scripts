#!/bin/ksh
#
# hmcinfogather.ksh - Collect HMC inventory data
#
# Outputs per HMC:
#   /path/to/logs/hmc_<name>_<ts>.log   - human-readable
#   /path/to/logs/hmc_<name>_<ts>.json  - machine-readable
#
# Usage:
#   ./hmcinfogather.ksh                    # interactive prompt
#   ./hmcinfogather.ksh hmc01              # single HMC via arg
#   ./hmcinfogather.ksh "hmc01 hmc02"      # multiple HMCs via arg
#

SSH_OPTS="-T -q -o BatchMode=yes -o ConnectTimeout=10"
LOG_DIR="/home/bcadmin/jacks-stuff/testlogs"
TS=$(date '+%Y%m%d_%H%M%S')

#--------------------------------------------------------------------
# JSON string escape - pure shell, no jq required
# Order matters: backslash MUST be replaced first to avoid
# double-escaping characters introduced in later substitutions.
#--------------------------------------------------------------------
json_escape() {
    typeset s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

#--------------------------------------------------------------------
# Emit a JSON number if input is an unsigned integer,
# otherwise emit a quoted, escaped string.
#--------------------------------------------------------------------
json_num_or_str() {
    case "$1" in
        ''|*[!0-9]*) printf '"%s"' "$(json_escape "$1")" ;;
        *)           printf '%s' "$1" ;;
    esac
}

#--------------------------------------------------------------------
# Hostname validation - prevent shell metachar injection
#--------------------------------------------------------------------
validate_hostname() {
    case "$1" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        "")                return 1 ;;
        *)                 return 0 ;;
    esac
}

#--------------------------------------------------------------------
# Argument handling
#--------------------------------------------------------------------
if [ $# -ge 1 ]; then
    HMC_LIST="$*"
else
    printf "Enter HMC hostname(s) [space separated for multiple]: "
    read HMC_LIST
fi

HMC_LIST=$(echo "$HMC_LIST" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -z "$HMC_LIST" ]; then
    echo "ERROR: no HMC hostname provided" >&2
    exit 1
fi

for HMC in $HMC_LIST; do
    if ! validate_hostname "$HMC"; then
        echo "ERROR: invalid hostname '$HMC' (allowed: A-Z a-z 0-9 . _ -)" >&2
        exit 1
    fi
done

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
    JSON="${LOG_DIR}/hmc_${HMC}_${TS}.json"
    RAW="${LOG_DIR}/.hmc_${HMC}_${TS}.raw"

    echo "Collecting $HMC -> $LOG (+ .json)"
    LOGS_CREATED="$LOGS_CREATED $LOG $JSON"

    # Pre-flight SSH check
    ssh $SSH_OPTS "${HMC}" "true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: SSH to $HMC failed (check key auth / connectivity / DNS)" \
            | tee "$LOG" >&2
        printf '{"error":"ssh_failed","hmc":"%s","timestamp":"%s"}\n' \
            "$(json_escape "$HMC")" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$JSON"
        ERR=$(( ERR + 1 ))
        continue
    fi

    # ---------------------------------------------------------------
    # Single SSH session: emit raw data with section markers.
    # All formatting is done on the collector side from this capture.
    # ---------------------------------------------------------------
    ssh $SSH_OPTS "${HMC}" <<'REMOTE_CMDS' > "$RAW" 2>&1
echo "###HOSTNAME###"
lshmc -n | grep '^hostname=' | cut -d= -f2 | cut -d, -f1

echo "###VERSION###"
lshmc -V | while IFS= read -r vline; do
    vline="${vline//\"/}"
    [ -z "$vline" ] && continue
    [ "$vline" = "," ] && continue
    vline="${vline#,}"
    echo "$vline"
done

echo "###FILESYSTEMS###"
lshmcfs

echo "###FRAMES###"
lssyscfg -r sys -F "name,type_model,serial_num,ipaddr,state"

echo "###LPARS_BEGIN###"
for FRAME in $(lssyscfg -r sys -F name); do
    echo "###FRAME:${FRAME}###"
    lssyscfg -r lpar -m "$FRAME" -F "lpar_id,name,state,rmc_state,os_version" | sort -t, -n -k1
done
echo "###LPARS_END###"

echo "###END###"
REMOTE_CMDS

    # ---------------------------------------------------------------
    # Parse raw data, emit both human log and JSON in one pass
    # ---------------------------------------------------------------

    # Initialize log
    {
        echo "================================================================"
        echo "Report Date : $(date '+%a %b %d %T %Z %Y')"
        echo "Target HMC  : $HMC"
        echo "================================================================"
        echo ""
    } > "$LOG"

    # Initialize JSON
    {
        printf '{\n'
        printf '  "report_date": "%s",\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf '  "hmc": "%s",\n'        "$(json_escape "$HMC")"
    } > "$JSON"

    # State variables
    section=""
    current_frame=""
    hostname_val=""
    first_fs=1
    first_frame=1
    first_lpar=1

    # Version field accumulators
    v_version=""
    v_release=""
    v_sp=""
    v_build=""
    v_base=""

    while IFS= read -r line; do
        #----- Section transitions ------------------------------------
        case "$line" in
            "###HOSTNAME###")
                section="hostname"
                echo "----- HMC Identity -----" >> "$LOG"
                continue ;;

            "###VERSION###")
                # Finalize identity block in JSON
                printf '  "identity": {"hostname": "%s"},\n' \
                    "$(json_escape "$hostname_val")" >> "$JSON"
                section="version"
                echo "" >> "$LOG"
                echo "----- HMC Version -----" >> "$LOG"
                continue ;;

            "###FILESYSTEMS###")
                # Finalize version block in JSON
                {
                    printf '  "version": {\n'
                    printf '    "version": "%s",\n'       "$(json_escape "$v_version")"
                    printf '    "release": "%s",\n'       "$(json_escape "$v_release")"
                    printf '    "service_pack": "%s",\n'  "$(json_escape "$v_sp")"
                    printf '    "build": "%s",\n'         "$(json_escape "$v_build")"
                    printf '    "base_version": "%s"\n'   "$(json_escape "$v_base")"
                    printf '  },\n'
                } >> "$JSON"

                section="filesystems"
                {
                    echo ""
                    echo "----- Filesystem Usage -----"
                    printf "%-20s %10s %10s %14s\n" "Filesystem" "Size(MB)" "Avail(MB)" "Temp Files(MB)"
                    printf "%-20s %10s %10s %14s\n" "--------------------" "----------" "----------" "--------------"
                } >> "$LOG"
                printf '  "filesystems": [' >> "$JSON"
                continue ;;

            "###FRAMES###")
                # Close filesystems array
                if [ $first_fs -eq 1 ]; then
                    printf '],\n' >> "$JSON"
                else
                    printf '\n  ],\n' >> "$JSON"
                fi

                section="frames"
                {
                    echo ""
                    echo "----- Managed Systems (Frames) -----"
                    printf "%-20s %-12s %-10s %-18s %-25s\n" "Name" "Type/Model" "Serial" "IP Address" "State"
                    printf "%-20s %-12s %-10s %-18s %-25s\n" "--------------------" "------------" "----------" "------------------" "-------------------------"
                } >> "$LOG"
                printf '  "frames": [' >> "$JSON"
                continue ;;

            "###LPARS_BEGIN###")
                # Close frames array
                if [ $first_frame -eq 1 ]; then
                    printf '],\n' >> "$JSON"
                else
                    printf '\n  ],\n' >> "$JSON"
                fi

                section="lpars"
                {
                    echo ""
                    echo "----- LPARs by Frame (sorted by LPAR ID) -----"
                } >> "$LOG"
                printf '  "lpars": [' >> "$JSON"
                continue ;;

            "###FRAME:"*)
                current_frame="${line#\#\#\#FRAME:}"
                current_frame="${current_frame%\#\#\#}"
                {
                    echo "Frame: $current_frame"
                    printf "  %-4s %-20s %-18s %-12s %-30s\n" "ID" "Name" "State" "RMC State" "OS Version"
                    printf "  %-4s %-20s %-18s %-12s %-30s\n" "----" "--------------------" "------------------" "------------" "------------------------------"
                } >> "$LOG"
                continue ;;

            "###LPARS_END###")
                # Close lpars array and the root object
                if [ $first_lpar -eq 1 ]; then
                    printf ']\n' >> "$JSON"
                else
                    printf '\n  ]\n' >> "$JSON"
                fi
                printf '}\n' >> "$JSON"
                section="done"
                continue ;;

            "###END###")
                continue ;;
        esac

        # Skip blank lines outside of meaningful sections
        [ -z "$line" ] && continue

        #----- Section content handlers -------------------------------
        case "$section" in

            hostname)
                hostname_val="$line"
                echo "Hostname : $line" >> "$LOG"
                ;;

            version)
                echo "$line" >> "$LOG"
                # Parse known fields for structured JSON output
                case "$line" in
                    *"Version:"*)
                        v_version="${line#*Version:}"; v_version="${v_version# }" ;;
                    *"Release:"*)
                        v_release="${line#*Release:}"; v_release="${v_release# }" ;;
                    *"Service Pack:"*)
                        v_sp="${line#*Service Pack:}"; v_sp="${v_sp# }" ;;
                    *"HMC Build level"*)
                        v_build="${line#*HMC Build level }" ;;
                    "base_version="*)
                        v_base="${line#base_version=}" ;;
                esac
                ;;

            filesystems)
                # Format: filesystem=/var,filesystem_size=5983,filesystem_avail=5073,temp_files_start_time=06/22/2018 11:55:00,temp_files_size=181
                IFS=',' read -r f1 f2 f3 f4 f5 frest <<EOF_FS
$line
EOF_FS
                fs="${f1#*=}"
                sz="${f2#*=}"
                av="${f3#*=}"
                tfs="${f4#*=}"
                tf="${f5#*=}"

                printf "%-20s %10s %10s %14s\n" "$fs" "$sz" "$av" "$tf" >> "$LOG"

                if [ $first_fs -eq 1 ]; then
                    first_fs=0
                    printf '\n    ' >> "$JSON"
                else
                    printf ',\n    ' >> "$JSON"
                fi
                printf '{"filesystem":"%s","size_mb":%s,"avail_mb":%s,"temp_files_mb":%s,"temp_files_start":"%s"}' \
                    "$(json_escape "$fs")" \
                    "$(json_num_or_str "$sz")" \
                    "$(json_num_or_str "$av")" \
                    "$(json_num_or_str "$tf")" \
                    "$(json_escape "$tfs")" >> "$JSON"
                ;;

            frames)
                IFS=',' read -r fname tm sn ip st <<EOF_FRAME
$line
EOF_FRAME

                printf "%-20s %-12s %-10s %-18s %-25s\n" "$fname" "$tm" "$sn" "$ip" "$st" >> "$LOG"

                if [ $first_frame -eq 1 ]; then
                    first_frame=0
                    printf '\n    ' >> "$JSON"
                else
                    printf ',\n    ' >> "$JSON"
                fi
                printf '{"name":"%s","type_model":"%s","serial":"%s","ip":"%s","state":"%s"}' \
                    "$(json_escape "$fname")" \
                    "$(json_escape "$tm")" \
                    "$(json_escape "$sn")" \
                    "$(json_escape "$ip")" \
                    "$(json_escape "$st")" >> "$JSON"
                ;;

            lpars)
                IFS=',' read -r id lname st rmc osv <<EOF_LPAR
$line
EOF_LPAR

                printf "  %-4s %-20s %-18s %-12s %-30s\n" "$id" "$lname" "$st" "$rmc" "$osv" >> "$LOG"

                if [ $first_lpar -eq 1 ]; then
                    first_lpar=0
                    printf '\n    ' >> "$JSON"
                else
                    printf ',\n    ' >> "$JSON"
                fi
                printf '{"frame":"%s","lpar_id":%s,"name":"%s","state":"%s","rmc_state":"%s","os_version":"%s"}' \
                    "$(json_escape "$current_frame")" \
                    "$(json_num_or_str "$id")" \
                    "$(json_escape "$lname")" \
                    "$(json_escape "$st")" \
                    "$(json_escape "$rmc")" \
                    "$(json_escape "$osv")" >> "$JSON"
                ;;
        esac
    done < "$RAW"

    # Add closing newline to LPAR section in log
    echo "" >> "$LOG"

    # Remove the raw temp file
    rm -f "$RAW"
done

#--------------------------------------------------------------------
# Summary
#--------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Collection complete."
echo "HMCs processed : $(echo $HMC_LIST | wc -w | tr -d ' ')"
echo "Errors         : $ERR"
echo "Output files   :"
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
