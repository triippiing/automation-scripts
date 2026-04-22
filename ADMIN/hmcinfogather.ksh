#!/bin/ksh

HMC_LIST="dr_hmc_01"
SSH_USER="hscroot"
SSH_OPTS="-T -q -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
LOG_DIR="/var/log/hmc_monitor"
TS=$(date '+%Y%m%d_%H%M%S')

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" || { printf "ERROR: cannot create %s\n" "$LOG_DIR" >&2; exit 1; }
fi

if [ ! -w "$LOG_DIR" ]; then
    printf "ERROR: cannot write to %s\n" "$LOG_DIR" >&2
    exit 1
fi

ERR=0

for HMC in $HMC_LIST; do
    LOG="${LOG_DIR}/hmc_${HMC}_${TS}.log"
    printf "Collecting %s -> %s\n" "$HMC" "$LOG"

    ssh $SSH_OPTS ${SSH_USER}@${HMC} "true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "ERROR: SSH to %s failed (check key auth / connectivity)\n" "$HMC" | tee "$LOG" >&2
        ERR=$(( ERR + 1 ))
        continue
    fi

    {
        printf "================================================================\n"
        printf "Report Date : %s\n" "$(date '+%a %b %d %T %Z %Y')"
        printf "Target HMC  : %s\n" "$HMC"
        printf "================================================================\n\n"

        ssh $SSH_OPTS ${SSH_USER}@${HMC} '
            printf "----- HMC Identity -----\n"
            lshmc -n -F "hostname,ipaddr,networkroute"
            printf "\n"

            printf "----- HMC Version -----\n"
            lshmc -V
            printf "\n"

            printf "----- Filesystem Usage -----\n"
            df -h /var /dump /extra / 2>/dev/null
            printf "\n"

            printf "----- Managed Systems (Frames) -----\n"
            lssyscfg -r sys -F "name,type_model,serial_num,ipaddr,state"
            printf "\n"

            printf "----- LPARs by Frame (sorted by LPAR ID) -----\n"
            for FRAME in $(lssyscfg -r sys -F name); do
                printf "Frame: %s\n" "$FRAME"
                printf "  lpar_id,name,state,rmc_state,os_version\n"
                lssyscfg -r lpar -m "$FRAME" \
                    -F "lpar_id,name,state,rmc_state,os_version" 2>/dev/null \
                    | sort -t, -n -k1
                printf "\n"
            done

            printf "----- Console Service Events (Last 30 Days) -----\n"
            lssvcevents -t console -d 30
        '
    } > "$LOG" 2>&1
done

printf "\nDone. Errors: %d\n" "$ERR"
exit $ERR
