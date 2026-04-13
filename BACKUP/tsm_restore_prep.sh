#!/bin/ksh
# =============================================================================
# tsm_restore_prep.sh - TSM Image Mode Restore Preparation
#
# Parses an aix_sysinfo log from a source system and prepares a target system
# for TSM image mode restores by recreating the VG / LV / mountpoint structure.
#
# MODES:
#   --prerestore  : Creates VGs, LVs, and mount point directories on target
#   --postrestore : Writes /etc/filesystems stanzas and optionally mounts
#   --dryrun      : Prints all commands without executing anything
#
# USAGE:
#   tsm_restore_prep.sh --prerestore  --log <sysinfo_log> [--vg <vgname>|all]
#   tsm_restore_prep.sh --postrestore --log <sysinfo_log> [--vg <vgname>|all]
#   tsm_restore_prep.sh --dryrun      --log <sysinfo_log> [--vg <vgname>|all]
#
# NOTES:
#   - rootvg is always excluded - never recreated via this script
#   - All LVs are created unmirrored regardless of source mirror config
#   - LV sizing is based on LP count x PP size from source log
#   - /etc/filesystems stanzas are written in --postrestore mode only
#   - jfs2log, sysdump, and paging LVs are created but not added to /etc/filesystems
# =============================================================================

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------
SCRIPT=$(basename "$0")
MODE=""
LOGFILE=""
TARGET_VG="all"
DRYRUN=0
RUNBOOK="${PWD}/restore_runbook_$(date +%Y%m%d_%H%M%S).sh"

# Temp working arrays - using files as ksh88 has no associative arrays
WRKDIR="/tmp/.tsm_restore_$$"
mkdir -p "${WRKDIR}"
trap "rm -rf ${WRKDIR}" EXIT INT TERM

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------
log()     { echo "[$(date +%H:%M:%S)] $*"; }
info()    { echo "  INFO  : $*"; }
warn()    { echo "  WARN  : $*"; }
error()   { echo "  ERROR : $*" >&2; }
fatal()   { echo "  FATAL : $*" >&2; exit 1; }

separator() {
    echo "--------------------------------------------------------------------------------"
}

run() {
    # Execute or dryrun a command. Always appends to runbook.
    local cmd="$*"
    echo "${cmd}" >> "${RUNBOOK}"
    if [[ ${DRYRUN} -eq 1 ]]; then
        echo "  [DRYRUN] ${cmd}"
    else
        log "EXEC: ${cmd}"
        eval "${cmd}"
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            error "Command failed (rc=${rc}): ${cmd}"
            return ${rc}
        fi
    fi
    return 0
}

usage() {
    cat << EOF

Usage: ${SCRIPT} <mode> --log <sysinfo_logfile> [--vg <vgname>|all]

Modes:
  --prerestore    Create VGs, LVs, and mount point directories (run before TSM restore)
  --postrestore   Write /etc/filesystems stanzas and mount filesystems (run after TSM restore)
  --dryrun        Print all commands that would be run, write runbook, no execution

Options:
  --log <file>    Path to aix_sysinfo log from source system (required)
  --vg  <name>    Target a specific VG by name, or 'all' for all non-rootvg VGs (default: all)

Examples:
  ${SCRIPT} --prerestore  --log /tmp/aixprod01_sysinfo_20260406.log
  ${SCRIPT} --prerestore  --log /tmp/aixprod01_sysinfo_20260406.log --vg datavg
  ${SCRIPT} --postrestore --log /tmp/aixprod01_sysinfo_20260406.log
  ${SCRIPT} --dryrun      --log /tmp/aixprod01_sysinfo_20260406.log

EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
[[ $# -lt 2 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerestore)   MODE="prerestore";  DRYRUN=0 ;;
        --postrestore)  MODE="postrestore"; DRYRUN=0 ;;
        --dryrun)       MODE="prerestore";  DRYRUN=1 ;;
        --log)          shift; LOGFILE="$1" ;;
        --vg)           shift; TARGET_VG="$1" ;;
        -h|--help)      usage ;;
        *)              error "Unknown argument: $1"; usage ;;
    esac
    shift
done

[[ -z "${MODE}" ]]    && fatal "No mode specified. Use --prerestore, --postrestore, or --dryrun."
[[ -z "${LOGFILE}" ]] && fatal "--log is required."
[[ ! -f "${LOGFILE}" ]] && fatal "Log file not found: ${LOGFILE}"
[[ "$(id -u)" -ne 0 ]] && [[ ${DRYRUN} -eq 0 ]] && fatal "This script must be run as root."

# -----------------------------------------------------------------------------
# Parse source hostname from log header
# -----------------------------------------------------------------------------
SOURCE_HOST=$(awk '/Hostname  :/{print $NF; exit}' "${LOGFILE}")
log "Source system  : ${SOURCE_HOST:-unknown}"
log "Log file       : ${LOGFILE}"
log "Mode           : ${MODE}$([ ${DRYRUN} -eq 1 ] && echo ' (DRYRUN)')"
log "Target VG(s)   : ${TARGET_VG}"
log "Runbook        : ${RUNBOOK}"
separator

# Initialise runbook header
cat > "${RUNBOOK}" << EOF
#!/bin/ksh
# =============================================================================
# Restore Runbook - generated by ${SCRIPT}
# Source system : ${SOURCE_HOST}
# Generated     : $(date)
# Mode          : ${MODE}
# =============================================================================
EOF

# -----------------------------------------------------------------------------
# PARSER: Extract VG list from log (skip rootvg always)
# -----------------------------------------------------------------------------
parse_vg_list() {
    # Reads the [ VG: <name> ] markers from the lsvg -l section
    # Writes one VG name per line to ${WRKDIR}/vg_list
    awk '/^\[ VG: /{print $3}' "${LOGFILE}" | \
        grep -v '^rootvg$' > "${WRKDIR}/vg_list"

    if [[ ! -s "${WRKDIR}/vg_list" ]]; then
        fatal "No non-rootvg volume groups found in log. Check log format."
    fi

    if [[ "${TARGET_VG}" != "all" ]]; then
        if ! grep -qx "${TARGET_VG}" "${WRKDIR}/vg_list"; then
            fatal "VG '${TARGET_VG}' not found in log. Available VGs:"
            cat "${WRKDIR}/vg_list"
            exit 1
        fi
        echo "${TARGET_VG}" > "${WRKDIR}/vg_list"
    fi
}

# -----------------------------------------------------------------------------
# PARSER: Extract VG attributes for a given VG from the log
#
# Populates:
#   ${WRKDIR}/vg_<name>_ppsize   - PP size in MB
#   ${WRKDIR}/vg_<name>_pvlist   - disks assigned to VG on source (for sizing ref)
# -----------------------------------------------------------------------------
parse_vg_attrs() {
    local vg="$1"

    # PP SIZE field appears on same line as VG STATE in lsvg output
    # e.g: "  VG STATE:  active   PP SIZE:  256 megabyte(s)"
    # Use pure awk to extract numeric value after PP SIZE: - AIX grep has no -o flag
    awk "/^\[ VG: ${vg} \]/{found=1}
         found && /PP SIZE:/{
             match(\$0, /PP SIZE:[[:space:]]+[0-9]+/)
             if (RSTART > 0) {
                 chunk = substr(\$0, RSTART, RLENGTH)
                 gsub(/PP SIZE:[[:space:]]+/, \"\", chunk)
                 print chunk
             }
             exit
         }" "${LOGFILE}" > "${WRKDIR}/vg_${vg}_ppsize"

    local ppsize=$(cat "${WRKDIR}/vg_${vg}_ppsize" 2>/dev/null | tr -d ' \n')
    if [[ -z "${ppsize}" ]]; then
        warn "Could not parse PP size for ${vg} - defaulting to 128MB"
        echo "128" > "${WRKDIR}/vg_${vg}_ppsize"
    fi
}

# -----------------------------------------------------------------------------
# PARSER: Extract LV list for a given VG
#
# Writes to ${WRKDIR}/vg_<name>_lvs:
#   <lvname> <type> <lp_count> <mountpoint>
#
# jfs2log, sysdump, boot entries are included but flagged
# -----------------------------------------------------------------------------
parse_lv_list() {
    local vg="$1"

    # Extract the Logical Volumes table for this VG from the log
    # Table starts after "--- Logical Volumes ---" within the VG block
    # and ends at the next "---" line or VG block boundary
    awk "
        /^\[ VG: ${vg} \]/ { invg=1 }
        invg && /--- Logical Volumes ---/ { intable=1; next }
        invg && intable && /^[[:space:]]*${vg}:/ { next }
        invg && intable && /^--/ { intable=0 }
        invg && intable && /^\[ VG:/ { invg=0; intable=0 }
        invg && intable && NF >= 4 {
            gsub(/^[[:space:]]+/,\"\")
            if (\$1 != \"LV\" && \$1 != \"\") print \$1, \$2, \$3, \$NF
        }
    " "${LOGFILE}" > "${WRKDIR}/vg_${vg}_lvs"

    if [[ ! -s "${WRKDIR}/vg_${vg}_lvs" ]]; then
        warn "No LVs found for VG: ${vg}"
    fi
}

# -----------------------------------------------------------------------------
# TARGET DISK: Interrogate target system for available unassigned disks
#
# Writes to ${WRKDIR}/target_disks:
#   <diskname> <size_mb>
# -----------------------------------------------------------------------------
get_target_disks() {
    log "Interrogating target system for available disks..."
    > "${WRKDIR}/target_disks"

    lspv 2>/dev/null | while read disk pvid vg rest; do
        # Only consider disks not already in a VG
        if [[ "${vg}" == "None" ]] || [[ -z "${vg}" ]]; then
            size_mb=$(bootinfo -s "${disk}" 2>/dev/null)
            [[ -n "${size_mb}" && "${size_mb}" -gt 0 ]] && \
                echo "${disk} ${size_mb}" >> "${WRKDIR}/target_disks"
        fi
    done

    if [[ ! -s "${WRKDIR}/target_disks" ]]; then
        fatal "No unassigned disks found on target system. Assign LUNs before running."
    fi

    log "Available unassigned disks on target:"
    while read disk size_mb; do
        size_gb=$(echo "scale=1; ${size_mb} / 1024" | bc)
        info "${disk}  ${size_gb} GB"
    done < "${WRKDIR}/target_disks"
    separator
}

# -----------------------------------------------------------------------------
# CAPACITY CHECK: Verify a disk is large enough for a given VG
#
# Args: $1=disk $2=required_mb
# Returns 0 if sufficient, 1 if not
# -----------------------------------------------------------------------------
check_disk_capacity() {
    local disk="$1"
    local required_mb="$2"
    local available_mb=$(bootinfo -s "${disk}" 2>/dev/null)

    if [[ -z "${available_mb}" || "${available_mb}" -le 0 ]]; then
        error "Could not determine size of ${disk}"
        return 1
    fi

    if [[ "${available_mb}" -lt "${required_mb}" ]]; then
        error "Disk ${disk} is too small: ${available_mb}MB available, ${required_mb}MB required"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# DISK SELECTION: Prompt operator to assign one or more disks to a VG
#
# Sets SELECTED_DISKS (space separated list of disk names)
# -----------------------------------------------------------------------------
select_disk_for_vg() {
    local vg="$1"
    local required_mb="$2"
    local required_gb=$(echo "scale=1; ${required_mb} / 1024" | bc)
    local cumulative_mb=0
    SELECTED_DISKS=""

    while true; do
        # Rebuild menu each iteration so selected disks disappear from list
        rm -f "${WRKDIR}/disk_menu_$$"
        local i=1
        while read disk size_mb; do
            # Skip disks already selected this round
            echo "${SELECTED_DISKS}" | grep -qw "${disk}" && continue
            local size_gb=$(echo "scale=1; ${size_mb} / 1024" | bc)
            printf "  %-5s  %-12s  %-10s  %-10s\n" "${i})" "${disk}" "${size_mb}" "${size_gb}"
            echo "${i} ${disk} ${size_mb}" >> "${WRKDIR}/disk_menu_$$"
            i=$((i + 1))
        done < "${WRKDIR}/target_disks"

        local remaining_mb=$((required_mb - cumulative_mb))
        local remaining_gb=$(echo "scale=1; ${remaining_mb} / 1024" | bc)
        local cumulative_gb=$(echo "scale=1; ${cumulative_mb} / 1024" | bc)

        echo ""
        separator
        echo "  VG '${vg}' - capacity required : ${required_gb} GB"
        echo "  Allocated so far              : ${cumulative_gb} GB"
        echo "  Still required                : ${remaining_gb} GB"
        [[ -n "${SELECTED_DISKS}" ]] && echo "  Disks selected so far         : ${SELECTED_DISKS}"
        echo ""
        echo "  Available unassigned disks:"
        echo ""
        printf "  %-5s  %-12s  %-10s  %-10s\n" "No." "DISK" "SIZE(MB)" "SIZE(GB)"
        echo "  -----------------------------------------------"

        # Reprint the menu (already printed above during build, reprint cleanly)
        rm -f "${WRKDIR}/disk_menu_$$"
        i=1
        while read disk size_mb; do
            echo "${SELECTED_DISKS}" | grep -qw "${disk}" && continue
            local size_gb=$(echo "scale=1; ${size_mb} / 1024" | bc)
            printf "  %-5s  %-12s  %-10s  %-10s\n" "${i})" "${disk}" "${size_mb}" "${size_gb}"
            echo "${i} ${disk} ${size_mb}" >> "${WRKDIR}/disk_menu_$$"
            i=$((i + 1))
        done < "${WRKDIR}/target_disks"

        echo ""
        printf "  Select disk number to add to VG '${vg}': "
        read DISK_CHOICE < /dev/tty

        local chosen_disk=$(awk -v c="${DISK_CHOICE}" '$1==c{print $2}' "${WRKDIR}/disk_menu_$$")
        local chosen_mb=$(awk -v c="${DISK_CHOICE}" '$1==c{print $3}' "${WRKDIR}/disk_menu_$$")

        if [[ -z "${chosen_disk}" ]]; then
            error "Invalid selection - please enter a number from the list."
            continue
        fi

        SELECTED_DISKS="${SELECTED_DISKS} ${chosen_disk}"
        cumulative_mb=$((cumulative_mb + chosen_mb))
        cumulative_gb=$(echo "scale=1; ${cumulative_mb} / 1024" | bc)
        log "Added ${chosen_disk} (${cumulative_gb}GB allocated of ${required_gb}GB required)"

        if [[ ${cumulative_mb} -ge ${required_mb} ]]; then
            log "Sufficient capacity allocated for VG ${vg}."
            rm -f "${WRKDIR}/disk_menu_$$"
            break
        fi

        # Not enough yet - offer to add another or abort
        echo ""
        printf "  Capacity not yet met. Add another disk? [Y/n]: "
        read ADD_MORE < /dev/tty
        case "${ADD_MORE}" in
            [Nn]|[Nn][Oo])
                warn "Proceeding with insufficient capacity - mkvg may fail."
                rm -f "${WRKDIR}/disk_menu_$$"
                break
                ;;
        esac
    done

    SELECTED_DISKS=$(echo "${SELECTED_DISKS}" | sed 's/^[[:space:]]*//')
    log "Final disk selection for VG ${vg}: ${SELECTED_DISKS}"
}

# -----------------------------------------------------------------------------
# PRERESTORE: Create VG, LVs, and mount point directories
# -----------------------------------------------------------------------------
do_prerestore() {
    parse_vg_list
    get_target_disks

    while read vg; do
        separator
        log "Processing VG: ${vg}"
        separator

        parse_vg_attrs "${vg}"
        parse_lv_list "${vg}"

        local ppsize=$(cat "${WRKDIR}/vg_${vg}_ppsize" | tr -d ' \n')

        # Calculate total MB required for this VG from LP counts
        local total_lps=0
        while read lvname lvtype lp_count mountpoint; do
            total_lps=$((total_lps + lp_count))
        done < "${WRKDIR}/vg_${vg}_lvs"
        local required_mb=$((total_lps * ppsize))
        local required_gb=$(echo "scale=1; ${required_mb} / 1024" | bc)

        info "VG ${vg}: PP size=${ppsize}MB, Total LPs=${total_lps}, Required=${required_gb}GB"

        # Disk selection - skip prompt in dryrun, use first available
        if [[ ${DRYRUN} -eq 1 ]]; then
            SELECTED_DISKS=$(awk '{print $1}' "${WRKDIR}/target_disks" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
            warn "DRYRUN: Using all available disks (${SELECTED_DISKS}) for VG ${vg}"
        else
            select_disk_for_vg "${vg}" "${required_mb}"
        fi

        # mkvg - PP size from source, all selected disks as PV arguments
        echo "" >> "${RUNBOOK}"
        echo "# --- VG: ${vg} ---" >> "${RUNBOOK}"
        run "mkvg -y ${vg} -s ${ppsize} ${SELECTED_DISKS}"
        local rc=$?
        if [[ ${rc} -ne 0 && ${DRYRUN} -eq 0 ]]; then
            # Check if failure was due to residual PVID/VGDA on disks from previous VG
            error "mkvg failed for ${vg} (rc=${rc})"
            echo ""
            echo "  !! One or more disks appear to have residual VGDA data from a previous VG."
            echo "     This is expected if these disks were previously used and exported."
            echo "     The -f (force) flag will overwrite the existing VGDA on each disk."
            echo ""
            echo "  WARNING: This is destructive. Only proceed if you are certain these"
            echo "           disks are not members of an active VG on any other system."
            echo ""
            printf "  Retry mkvg with -f (force) flag? [y/N]: "
            read FORCE_ANSWER < /dev/tty
            case "${FORCE_ANSWER}" in
                [Yy]|[Yy][Ee][Ss])
                    run "mkvg -f -y ${vg} -s ${ppsize} ${SELECTED_DISKS}"
                    rc=$?
                    if [[ ${rc} -ne 0 ]]; then
                        error "mkvg -f also failed for ${vg} - skipping LV creation for this VG"
                        continue
                    fi
                    ;;
                *)
                    error "Skipping VG ${vg} - mkvg not retried."
                    continue
                    ;;
            esac
        fi

        # mklv for each LV in this VG
        while read lvname lvtype lp_count mountpoint; do
            [[ -z "${lvname}" ]] && continue

            # Determine mklv type flag
            # jfs2log, sysdump, boot, paging all have specific types
            local lv_type_flag=""
            case "${lvtype}" in
                jfs2)    lv_type_flag="jfs2"    ;;
                jfs2log) lv_type_flag="jfs2log" ;;
                jfs)     lv_type_flag="jfs"     ;;
                jfslog)  lv_type_flag="jfslog"  ;;
                paging)  lv_type_flag="paging"  ;;
                sysdump) lv_type_flag="sysdump" ;;
                boot)    lv_type_flag="boot"    ;;
                *)       lv_type_flag="jfs2"    ;;
            esac

            info "  mklv: ${lvname}  type=${lv_type_flag}  LPs=${lp_count}  mount=${mountpoint}"
            run "mklv -t ${lv_type_flag} -y ${lvname} ${vg} ${lp_count}"

            # Create mount point directory for jfs/jfs2 types with a real mount point
            if [[ "${lv_type_flag}" == "jfs2" || "${lv_type_flag}" == "jfs" ]]; then
                if [[ "${mountpoint}" != "N/A" && "${mountpoint}" != "-" && -n "${mountpoint}" ]]; then
                    run "mkdir -p ${mountpoint}"
                fi
            fi

        done < "${WRKDIR}/vg_${vg}_lvs"

        log "VG ${vg} complete."

    done < "${WRKDIR}/vg_list"

    separator
    log "Pre-restore preparation complete."
    log "Runbook written to: ${RUNBOOK}"
    separator
    echo ""
    echo "  Next steps:"
    echo "  1. Run TSM image mode restore for each LV"
    echo "  2. Run this script with --postrestore to write /etc/filesystems stanzas"
    echo "  3. Mount filesystems and validate"
    echo ""
}

# -----------------------------------------------------------------------------
# POSTRESTORE: Write /etc/filesystems stanzas and optionally mount
# -----------------------------------------------------------------------------
do_postrestore() {
    parse_vg_list

    local fs_stanzas="${WRKDIR}/new_fstab_stanzas"
    > "${fs_stanzas}"

    while read vg; do
        separator
        log "Processing /etc/filesystems stanzas for VG: ${vg}"

        parse_vg_attrs "${vg}"
        parse_lv_list "${vg}"

        local ppsize=$(cat "${WRKDIR}/vg_${vg}_ppsize" | tr -d ' \n')

        # Find the jfs2log LV for this VG - needed for stanza log= field
        local log_lv=""
        while read lvname lvtype lp_count mountpoint; do
            if [[ "${lvtype}" == "jfs2log" || "${lvtype}" == "jfslog" ]]; then
                log_lv="${lvname}"
                break
            fi
        done < "${WRKDIR}/vg_${vg}_lvs"

        if [[ -z "${log_lv}" ]]; then
            warn "No jfs2log LV found for ${vg} - log= field will be omitted from stanzas"
        fi

        while read lvname lvtype lp_count mountpoint; do
            [[ -z "${lvname}" ]] && continue

            # Only write stanzas for jfs2/jfs LVs with real mount points
            case "${lvtype}" in
                jfs2|jfs) ;;
                *) continue ;;
            esac

            [[ "${mountpoint}" == "N/A" || "${mountpoint}" == "-" || -z "${mountpoint}" ]] && continue

            local dev_path="/dev/${lvname}"
            local vfs_type="${lvtype}"
            local log_entry=""
            [[ -n "${log_lv}" ]] && log_entry="        log             = /dev/${log_lv}"

            cat >> "${fs_stanzas}" << STANZA

${mountpoint}:
        dev             = ${dev_path}
        vfs             = ${vfs_type}
        mount           = false
        options         = rw
        account         = false
${log_entry}

STANZA

            info "  Stanza written: ${mountpoint} -> ${dev_path}"

        done < "${WRKDIR}/vg_${vg}_lvs"

    done < "${WRKDIR}/vg_list"

    # Show generated stanzas for review before applying
    separator
    echo ""
    echo "  The following stanzas will be appended to /etc/filesystems:"
    echo ""
    cat "${fs_stanzas}"
    separator
    echo ""
    printf "  Apply stanzas to /etc/filesystems now? [y/N]: "
    read APPLY_ANSWER < /dev/tty

    case "${APPLY_ANSWER}" in
        [Yy]|[Yy][Ee][Ss])
            # Backup /etc/filesystems before modifying
            local fstab_bak="/etc/filesystems.pre_restore_$(date +%Y%m%d_%H%M%S)"
            cp /etc/filesystems "${fstab_bak}"
            log "Backed up /etc/filesystems to ${fstab_bak}"

            cat "${fs_stanzas}" >> /etc/filesystems
            log "/etc/filesystems updated."

            # Also write to runbook
            echo "" >> "${RUNBOOK}"
            echo "# --- /etc/filesystems stanzas ---" >> "${RUNBOOK}"
            echo "cp /etc/filesystems ${fstab_bak}" >> "${RUNBOOK}"
            cat "${fs_stanzas}" | sed 's/^/# /' >> "${RUNBOOK}"
            echo "cat >> /etc/filesystems << 'ENDSTANZAS'" >> "${RUNBOOK}"
            cat "${fs_stanzas}" >> "${RUNBOOK}"
            echo "ENDSTANZAS" >> "${RUNBOOK}"

            # Offer to mount all restored filesystems
            echo ""
            printf "  Mount all restored filesystems now? [y/N]: "
            read MOUNT_ANSWER < /dev/tty

            case "${MOUNT_ANSWER}" in
                [Yy]|[Yy][Ee][Ss])
                    local mount_errors=0
                    while read vg; do
                        parse_lv_list "${vg}"

                        # Find the log LV for this VG - needed for logform advice
                        local vg_log_lv=""
                        while read lvname lvtype lp_count mountpoint; do
                            if [[ "${lvtype}" == "jfs2log" || "${lvtype}" == "jfslog" ]]; then
                                vg_log_lv="${lvname}"
                                break
                            fi
                        done < "${WRKDIR}/vg_${vg}_lvs"

                        while read lvname lvtype lp_count mountpoint; do
                            [[ "${lvtype}" != "jfs2" && "${lvtype}" != "jfs" ]] && continue
                            [[ "${mountpoint}" == "N/A" || -z "${mountpoint}" ]] && continue

                            log "Mounting ${mountpoint} (/dev/${lvname})..."
                            mount "${mountpoint}" >> "${RUNBOOK}" 2>&1
                            local mrc=$?

                            if [[ ${mrc} -ne 0 ]]; then
                                mount_errors=$((mount_errors + 1))
                                error "mount failed for ${mountpoint} (rc=${mrc})"
                                echo ""
                                echo "  !! MOUNT FAILURE - /dev/${lvname} -> ${mountpoint}"
                                echo "  -------------------------------------------------------"
                                echo "  This is commonly caused by a dirty or missing JFS2 log."
                                echo "  If the jfs2log LV restore was incomplete or absent,"
                                echo "  reinitialise the log and retry the mount:"
                                echo ""
                                if [[ -n "${vg_log_lv}" ]]; then
                                echo "      logform /dev/${vg_log_lv}"
                                else
                                echo "      logform /dev/<loglvname>   # identify log LV with: lsvg -l ${vg}"
                                fi
                                echo "      mount ${mountpoint}"
                                echo ""
                                echo "  If mount still fails after logform, run fsck first:"
                                echo ""
                                echo "      fsck -p /dev/${lvname}"
                                echo "      mount ${mountpoint}"
                                echo ""
                                echo "  If fsck reports unrecoverable errors the TSM image"
                                echo "  restore for /dev/${lvname} may be incomplete or corrupt."
                                echo "  Re-run: dsmc restore image /dev/${lvname} -pick"
                                echo "  -------------------------------------------------------"
                                echo ""
                            else
                                log "OK: ${mountpoint} mounted."
                            fi

                        done < "${WRKDIR}/vg_${vg}_lvs"
                    done < "${WRKDIR}/vg_list"

                    echo ""
                    if [[ ${mount_errors} -gt 0 ]]; then
                        warn "${mount_errors} filesystem(s) failed to mount - review errors above."
                    else
                        log "All filesystems mounted successfully."
                    fi
                    log "Verify with: df -g"
                    ;;
                *)
                    log "Skipping mount. Run 'mount <mountpoint>' or 'mount all' manually."
                    ;;
            esac
            ;;
        *)
            log "Stanzas not applied. Review ${fs_stanzas} and apply manually."
            ;;
    esac

    separator
    log "Post-restore complete."
    log "Runbook written to: ${RUNBOOK}"
    separator
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
echo ""
echo "################################################################################"
echo "#               TSM IMAGE RESTORE PREPARATION SCRIPT                          #"
echo "#  Source: ${SOURCE_HOST:-unknown}   Mode: ${MODE}$([ ${DRYRUN} -eq 1 ] && echo ' (DRYRUN)')  "
echo "################################################################################"
echo ""

case "${MODE}" in
    prerestore)  do_prerestore  ;;
    postrestore) do_postrestore ;;
esac
