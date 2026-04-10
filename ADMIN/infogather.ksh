#!/bin/ksh
# =============================================================================
# aix_sysinfo.sh - AIX System Information Gathering Script
# Collects system config, storage, network and filesystem info to a log file
# =============================================================================

HOSTNAME=$(hostname -s)
DATESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="${PWD}/${HOSTNAME}_sysinfo_${DATESTAMP}.log"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
section() {
    echo "" >> "${LOGFILE}"
    echo "################################################################################" >> "${LOGFILE}"
    echo "# $1" >> "${LOGFILE}"
    echo "################################################################################" >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
}

divider() {
    echo "--------------------------------------------------------------------------------" >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
}

run_cmd() {
    # $1 = label, $2+ = command
    local label="$1"
    shift
    echo "[ ${label} ]" >> "${LOGFILE}"
    "$@" >> "${LOGFILE}" 2>&1
    echo "" >> "${LOGFILE}"
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
cat >> "${LOGFILE}" << EOF
################################################################################
#                        AIX SYSTEM INFORMATION REPORT                        #
################################################################################
  Hostname  : $(hostname)
  Date/Time : $(date)
  Collected : $(whoami)@$(hostname)
  Log File  : ${LOGFILE}
################################################################################
EOF

# -----------------------------------------------------------------------------
# Section 1: Hardware Configuration
# -----------------------------------------------------------------------------
section "HARDWARE CONFIGURATION (prtconf / lparstat)"

echo "[ prtconf ]" >> "${LOGFILE}"
prtconf 2>/dev/null | head -13 >> "${LOGFILE}"
echo "" >> "${LOGFILE}"

echo "[ lparstat -i (LPAR Identity / Entitlement / SMT) ]" >> "${LOGFILE}"
lparstat -i 2>/dev/null >> "${LOGFILE}"
echo "" >> "${LOGFILE}"
divider

# -----------------------------------------------------------------------------
# Section 2: OS Level
# -----------------------------------------------------------------------------
section "OS LEVEL"
run_cmd "oslevel -s (Technology Level / Service Pack)" oslevel -s
divider

# -----------------------------------------------------------------------------
# Section 3: Physical Volumes
# -----------------------------------------------------------------------------
section "PHYSICAL VOLUMES (lspv with sizes)"

printf "%-20s %-20s %-18s %-10s %-10s\n" \
    "DISK" "PVID" "VG" "STATUS" "SIZE(GB)" >> "${LOGFILE}"
echo "--------------------------------------------------------------------------------" >> "${LOGFILE}"

lspv 2>/dev/null | while read disk pvid vg status; do
    # Get disk size in MB via bootinfo -s, convert to GB
    size_mb=$(bootinfo -s "${disk}" 2>/dev/null)
    if [[ -n "${size_mb}" && "${size_mb}" -gt 0 ]]; then
        size_gb=$(echo "scale=1; ${size_mb} / 1024" | bc 2>/dev/null)
        [[ -z "${size_gb}" ]] && size_gb="N/A"
    else
        size_gb="N/A"
    fi
    printf "%-20s %-20s %-18s %-10s %-10s\n" \
        "${disk}" "${pvid}" "${vg:-None}" "${status:-N/A}" "${size_gb}" >> "${LOGFILE}"
done
echo "" >> "${LOGFILE}"

echo "[ lsdev -Cc disk (ODM device config - includes MPIO / virtual disks) ]" >> "${LOGFILE}"
lsdev -Cc disk 2>/dev/null >> "${LOGFILE}"
echo "" >> "${LOGFILE}"
divider

# -----------------------------------------------------------------------------
# Section 4: Volume Groups
# -----------------------------------------------------------------------------
section "VOLUME GROUPS (lsvg summary)"
run_cmd "lsvg (all VGs)" lsvg
divider

# -----------------------------------------------------------------------------
# Section 5: Volume Group Detail (lsvg -l per VG)
# -----------------------------------------------------------------------------
section "VOLUME GROUP LOGICAL VOLUME DETAIL (lsvg -l)"

for vg in $(lsvg 2>/dev/null); do
    echo "[ VG: ${vg} ]" >> "${LOGFILE}"
    echo "  --- VG Attributes ---" >> "${LOGFILE}"
    lsvg "${vg}" 2>/dev/null | sed 's/^/  /' >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
    echo "  --- Logical Volumes ---" >> "${LOGFILE}"
    lsvg -l "${vg}" 2>/dev/null | sed 's/^/  /' >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
    echo "--------------------------------------------------------------------------------" >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
done

# -----------------------------------------------------------------------------
# Section 6: Filesystem Usage
# -----------------------------------------------------------------------------
section "MOUNTED FILESYSTEMS AND USAGE"

printf "%-45s %-10s %-10s %-10s %-8s %-20s\n" \
    "FILESYSTEM" "SIZE" "USED" "AVAIL" "USE%" "MOUNTED ON" >> "${LOGFILE}"
echo "--------------------------------------------------------------------------------" >> "${LOGFILE}"

df -g 2>/dev/null | awk 'NR>1 {
    printf "%-45s %-10s %-10s %-10s %-8s %-20s\n", $1, $2, $3, $4, $5, $7
}' >> "${LOGFILE}"
echo "" >> "${LOGFILE}"
divider

# -----------------------------------------------------------------------------
# Section 7: Adapters and MAC/WWN Addresses
# -----------------------------------------------------------------------------
section "ADAPTERS (lsdev -Cc adapter) WITH MAC / WWN DETAIL"

lsdev -Cc adapter 2>/dev/null | while read dev status loc desc; do
    echo "[ ${dev} ] - ${status} | ${loc} | ${desc}" >> "${LOGFILE}"

    case "${dev}" in
        en*|et*)
            # Ethernet - grab MAC via lscfg
            mac=$(lscfg -vpl "${dev}" 2>/dev/null | awk '/Network Address/{print $NF}')
            [[ -n "${mac}" ]] && echo "  MAC Address   : ${mac}" >> "${LOGFILE}"
            ;;
        fcs*)
            # Fibre Channel - grab WWPN and WWNN via lscfg
            wwpn=$(lscfg -vpl "${dev}" 2>/dev/null | awk '/Network Address/{print $NF}' | head -1)
            [[ -z "${wwpn}" ]] && wwpn=$(lscfg -vpl "${dev}" 2>/dev/null | awk '/World Wide Port Name/{print $NF}')
            wwnn=$(lscfg -vpl "${dev}" 2>/dev/null | awk '/World Wide Node Name/{print $NF}')
            [[ -n "${wwpn}" ]] && echo "  WWPN          : ${wwpn}" >> "${LOGFILE}"
            [[ -n "${wwnn}" ]] && echo "  WWNN          : ${wwnn}" >> "${LOGFILE}"
            ;;
    esac
    echo "" >> "${LOGFILE}"
done
divider

# -----------------------------------------------------------------------------
# Section 8: Routing Table
# -----------------------------------------------------------------------------
section "ROUTING TABLE (netstat -rn)"
run_cmd "netstat -rn" netstat -rn
divider

# -----------------------------------------------------------------------------
# Section 9: HA / PowerHA Cluster
# -----------------------------------------------------------------------------
section "HA / POWERHA CLUSTER"

if lslpp -l cluster.es.server.rte > /dev/null 2>&1; then

    echo "[ PowerHA Filesets ]" >> "${LOGFILE}"
    lslpp -l cluster.es.* 2>/dev/null >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"

    echo "[ lssrc -g cluster (Cluster Subsystem State) ]" >> "${LOGFILE}"
    lssrc -g cluster 2>/dev/null >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"

    echo "[ cltopinfo (Cluster Topology - Nodes / Networks / Disks) ]" >> "${LOGFILE}"
    cltopinfo 2>/dev/null >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"

    echo "[ clmgr view cluster (PowerHA 7.x - Version / Heartbeat / Repo Disk) ]" >> "${LOGFILE}"
    clmgr view cluster 2>/dev/null >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"

else
    echo "  cluster.es.server.rte not installed - node is not a PowerHA cluster member." >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
fi
divider

# -----------------------------------------------------------------------------
# Section 10: WPAR Configuration
# -----------------------------------------------------------------------------
section "WPAR CONFIGURATION (lswpar -L)"

wpar_count=$(lswpar 2>/dev/null | grep -v "^Name" | grep -v "^$" | wc -l | tr -d ' ')

if [[ "${wpar_count}" -gt 0 ]]; then
    echo "  WPARs detected: ${wpar_count}" >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
    run_cmd "lswpar -L (WPAR detail - name, state, rootvg device, hostname)" lswpar -L
else
    echo "  No WPARs configured on this system." >> "${LOGFILE}"
    echo "" >> "${LOGFILE}"
fi
divider

# -----------------------------------------------------------------------------
# Footer
# -----------------------------------------------------------------------------
cat >> "${LOGFILE}" << EOF

################################################################################
#  Collection complete: $(date)
################################################################################
EOF

echo "Log written to: ${LOGFILE}"

# -----------------------------------------------------------------------------
# Post-collection prompt: optional snap -ac
# -----------------------------------------------------------------------------
echo ""
echo "################################################################################"
echo "# Collection complete. Run 'snap -ac' to gather full AIX system snap?          #"
echo "# Note: snap -ac requires root and writes to /tmp/ibmsupt by default.          #"
echo "################################################################################"
echo ""
printf "Run snap -ac now? [y/N]: "
read SNAP_ANSWER

case "${SNAP_ANSWER}" in
    [Yy]|[Yy][Ee][Ss])
        if [[ "$(id -u)" -ne 0 ]]; then
            echo "ERROR: snap -ac requires root privileges. Re-run as root or via sudo."
        else
            echo ""
            echo "Running snap -ac - this may take a few minutes..."
            snap -ac 2>&1
            echo ""
            echo "snap complete. Archive written to /tmp/ibmsupt/"
        fi
        ;;
    *)
        echo "Skipping snap."
        ;;
esac