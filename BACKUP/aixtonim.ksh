#!/bin/bash

# ============================================================
# NIM DR Backup Script (Sequential + Retention + BOS Ready)
# ============================================================

CLIENTS=("PH1" "PH2" "PH3")
BACKUP_DIR="/export/mksysb"
SPOT_BASE="/export/spot"
BOSINST_DIR="/export/bosinst"
DATE=$(date +%Y%m%d_%H%M)
LOGFILE="/var/log/nim_dr_backup.log"
RETENTION=3

echo "===== DR NIM Backup Run: $(date) =====" >> $LOGFILE

# ------------------------------------------------------------
# Check client exists in NIM host registry
# ------------------------------------------------------------
validate_client() {
    lsnim -l "$1" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: $1 not defined in NIM" | tee -a $LOGFILE
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# Expired MKSYSB cleanup (retention set above)
# ------------------------------------------------------------
cleanup_old_backups() {
    CLIENT=$1
    FILES=$(ls -1t ${BACKUP_DIR}/${CLIENT}_mksysb_*.mksysb 2>/dev/null)
    COUNT=0
    for f in $FILES; do
        COUNT=$((COUNT+1))
        if [ $COUNT -gt $RETENTION ]; then
            echo "Removing old backup: $f" | tee -a $LOGFILE
            rm -f "$f"
            RES=$(basename "$f" .mksysb)
            nim -o remove "$RES" >/dev/null 2>&1
        fi
    done
}

# ------------------------------------------------------------
# Process one client (sequentially)
# ------------------------------------------------------------
process_client() {
    CLIENT=$1
    echo "---- [$CLIENT] START ----" | tee -a $LOGFILE

    validate_client "$CLIENT" || return

    MKSYSB_NAME="${CLIENT}_mksysb_${DATE}"
    MKSYSB_FILE="${BACKUP_DIR}/${MKSYSB_NAME}.mksysb"
    SPOT_NAME="${CLIENT}_spot_${DATE}"
    SPOT_DIR="${SPOT_BASE}/${SPOT_NAME}"
    BOSINST_NAME="${CLIENT}_bosinst_${DATE}"
    BOSINST_FILE="${BOSINST_DIR}/${BOSINST_NAME}"

    mkdir -p "$SPOT_DIR" "$BOSINST_DIR"

    # Create mksysb
    echo "[$CLIENT] Defining mksysb..." | tee -a $LOGFILE
    nim -o define -t mksysb -a server=master -a mk_image=yes -a location=${MKSYSB_FILE} ${MKSYSB_NAME}
    if [ $? -ne 0 ]; then echo "[$CLIENT] ERROR defining mksysb" | tee -a $LOGFILE; return; fi

    echo "[$CLIENT] Creating mksysb..." | tee -a $LOGFILE
    nim -o create -a mksysb=${MKSYSB_NAME} ${CLIENT}
    if [ $? -ne 0 ]; then echo "[$CLIENT] ERROR creating mksysb" | tee -a $LOGFILE; return; fi

    # Create SPOT
    echo "[$CLIENT] Creating SPOT..." | tee -a $LOGFILE
    nim -o define -t spot -a server=master -a source=${MKSYSB_NAME} -a location=${SPOT_DIR} ${SPOT_NAME}
    if [ $? -ne 0 ]; then echo "[$CLIENT] ERROR creating SPOT" | tee -a $LOGFILE; return; fi

    # Create bosinst_data
    echo "[$CLIENT] Creating bosinst_data..." | tee -a $LOGFILE
    cat > ${BOSINST_FILE} <<EOF
control_flow:
    CONSOLE = Default
    INSTALL_METHOD = overwrite
    PROMPT = no

target_disk_data:
    LOCATION = local
    SIZE_MB = 0
EOF

    nim -o define -t bosinst_data -a server=master -a location=${BOSINST_FILE} ${BOSINST_NAME}
    if [ $? -ne 0 ]; then echo "[$CLIENT] ERROR creating bosinst_data" | tee -a $LOGFILE; return; fi

    # Cleanup old backups
    cleanup_old_backups "$CLIENT"

    echo "---- [$CLIENT] COMPLETE ----" | tee -a $LOGFILE
}

# ------------------------------------------------------------
# Sequential loop
# ------------------------------------------------------------
for CLIENT in "${CLIENTS[@]}"; do
    process_client "$CLIENT"
done

echo "===== DR NIM Backup Completed: $(date) =====" >> $LOGFILE