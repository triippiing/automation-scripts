#!/usr/bin/ksh
#==============================================================================
# Script  : gen_rman_sched_my.ksh
# Purpose : Interactively generate Oracle RMAN Monthly and Yearly backup
#           schedule wrappers (.sched) and RMAN cmdfiles (.rman) for
#           TSM/TDPO integration.
# Shell   : KSH (ksh88 compatible, AIX/RHEL)
#==============================================================================

#------------------------------------------------------------------------------
# CONSTANTS
#------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0")
readonly DEFAULT_ORACLE_HOME="/u01/app/oracle/product/11.2.0/dbhome_1"
readonly DEFAULT_TDPO_OPTFILE_M="/usr/tivoli/tsm/client/oracle/bin64/tdpo_m.opt"
readonly DEFAULT_TDPO_OPTFILE_Y="/usr/tivoli/tsm/client/oracle/bin64/tdpo_y.opt"
readonly DEFAULT_SCHED_DIR="/home/oracle/sched"

#------------------------------------------------------------------------------
# TERMINAL SETUP
#------------------------------------------------------------------------------
STTY_SAVE=$(stty -g 2>/dev/null)
if [[ -n "$STTY_SAVE" ]]; then
    trap 'stty "$STTY_SAVE" 2>/dev/null' EXIT INT TERM HUP
    # AIX/PuTTY sessions typically send ^H (0x08) for backspace.
    # Change \010 to \177 if your terminal sends DEL instead.
    stty erase "$(printf '\010')" 2>/dev/null
fi

#------------------------------------------------------------------------------
# sanitize_input  value
# Strip non-printable bytes then remove CSI sequence remnants.
#------------------------------------------------------------------------------
sanitize_input() {
    printf '%s' "$1" | tr -cd '[:print:]' | sed 's/\[[0-9;]*[A-Za-z~]//g'
}

#------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#------------------------------------------------------------------------------

print_banner() {
    print ""
    print "============================================================"
    print "  Oracle RMAN / TSM-TDPO Monthly & Yearly Script Generator"
    print "============================================================"
    print ""
}

print_section() {
    print ""
    print "------------------------------------------------------------"
    print "  $1"
    print "------------------------------------------------------------"
}

# prompt_default VARNAME "Prompt text" "default value"
prompt_default() {
    typeset _var="$1"
    typeset _prompt="$2"
    typeset _default="$3"
    typeset _input _clean

    if [[ -n "$_default" ]]; then
        printf '  %s [%s]: ' "$_prompt" "$_default"
    else
        printf '  %s: ' "$_prompt"
    fi

    IFS= read -r _input
    _clean=$(sanitize_input "$_input")

    if [[ -z "$_clean" ]]; then
        eval "${_var}=\"${_default}\""
    else
        eval "${_var}=\"${_clean}\""
    fi
}

# prompt_secret VARNAME "Prompt text"
prompt_secret() {
    typeset _var="$1"
    typeset _prompt="$2"
    typeset _input

    printf '  %s: ' "$_prompt"
    stty -echo 2>/dev/null
    IFS= read -r _input
    stty echo 2>/dev/null
    print ""
    eval "${_var}=\"${_input}\""
}

# prompt_int VARNAME "Prompt text" default min max
prompt_int() {
    typeset _var="$1"
    typeset _prompt="$2"
    typeset _default="$3"
    typeset _min="$4"
    typeset _max="$5"
    typeset _input _clean _valid

    while :; do
        printf '  %s [%s] (%s-%s): ' "$_prompt" "$_default" "$_min" "$_max"
        IFS= read -r _input
        _clean=$(sanitize_input "$_input")
        [[ -z "$_clean" ]] && _clean="$_default"

        _valid=0
        case "$_clean" in
            ''|*[!0-9]*)  _valid=0 ;;
            *)  (( _clean >= _min && _clean <= _max )) && _valid=1 ;;
        esac

        if (( _valid == 1 )); then
            eval "${_var}=${_clean}"
            return
        fi
        print "  [ERROR] Enter an integer between ${_min} and ${_max}."
    done
}

# assert_nonempty value "label"
assert_nonempty() {
    if [[ -z "$1" ]]; then
        print "[FATAL] ${2} cannot be empty. Aborting." >&2
        exit 1
    fi
}

# confirm "Prompt text" -- returns 0 for yes, 1 for no
confirm() {
    typeset _prompt="$1"
    typeset _input _ans
    while :; do
        printf '  %s (y/n): ' "$_prompt"
        IFS= read -r _input
        _ans=$(sanitize_input "$_input")
        case "$_ans" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) print "  Please enter y or n." ;;
        esac
    done
}

#------------------------------------------------------------------------------
# WRITE FUNCTIONS
#------------------------------------------------------------------------------

# write_sched_file  filepath  rman_cmdfile  rman_msglog
write_sched_file() {
    typeset _file="$1"
    typeset _rman_cmdfile="$2"
    typeset _rman_msglog="$3"

    cat > "$_file" << SCHED_EOF
#!/usr/bin/ksh
su - oracle -c "
export ORACLE_HOME=${ORACLE_HOME}
export LD_LIBRARY_PATH=\\\$ORACLE_HOME/lib
export LIBPATH=\\\$ORACLE_HOME/lib
export ORACLE_SID=${ORACLE_SID}
export PATH=\\\$PATH:\\\$ORACLE_HOME/bin
rman target ${TARGET_USER}/${TARGET_PASS}@${ORACLE_SID} catalog ${CATALOG_USER}/${CATALOG_PASS}@${CATALOG_TNS} cmdfile ${_rman_cmdfile} msglog ${_rman_msglog}
"
SCHED_EOF

    chmod 750 "$_file"
}

# build_channels count optfile -- emits allocate channel lines to stdout
build_channels() {
    typeset _count="$1"
    typeset _optfile="$2"
    typeset _i=0
    while (( _i < _count )); do
        printf '\tallocate channel t%d type '"'"'sbt_tape'"'"' parms '"'"'ENV=(TDPO_OPTFILE=%s)'"'"';\n' \
            "$_i" "$_optfile"
        (( _i = _i + 1 ))
    done
}

# Monthly: incremental level 0 with db_level_0 tag, crosscheck included
write_rman_monthly() {
    typeset _file="$1"
    {
        printf 'run {\n'
        build_channels "$M_CHANNELS" "$TDPO_OPTFILE_M"
        printf '\tbackup incremental level 0 format '"'"'%%d_%%T_%%t_%%s_%%u.dbf'"'"' database tag '"'"'db_level_0'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.arc'"'"' archivelog all tag '"'"'arch'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.spf'"'"' spfile tag '"'"'spfile'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.ctl'"'"' current controlfile tag '"'"'ctl'"'"';\n'
        printf '\tallocate channel d1 type disk;\n'
        printf '\tcrosscheck backup;\n'
        printf '\tcrosscheck copy;\n'
        printf '\tdelete noprompt archivelog all backed up 2 times to DEVICE TYPE sbt_tape;\n'
        printf '\tdelete noprompt obsolete;\n'
        printf '}\n'
    } > "$_file"
    chmod 640 "$_file"
}

# Yearly: full backup (no incremental level prefix) with Yearly_Level_0 tag
write_rman_yearly() {
    typeset _file="$1"
    {
        printf 'run {\n'
        build_channels "$Y_CHANNELS" "$TDPO_OPTFILE_Y"
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.dbf'"'"' database tag '"'"'Yearly_Level_0'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.arc'"'"' archivelog all tag '"'"'arch'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.spf'"'"' spfile tag '"'"'spfile'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.ctl'"'"' current controlfile tag '"'"'ctl'"'"';\n'
        printf '\tallocate channel d1 type disk;\n'
        printf '\tcrosscheck backup;\n'
        printf '\tcrosscheck copy;\n'
        printf '\tdelete noprompt archivelog all backed up 2 times to DEVICE TYPE sbt_tape;\n'
        printf '\tdelete noprompt obsolete;\n'
        printf '}\n'
    } > "$_file"
    chmod 640 "$_file"
}

#------------------------------------------------------------------------------
# SUMMARY
#------------------------------------------------------------------------------
print_summary() {
    print ""
    print "============================================================"
    print "  Configuration Summary"
    print "============================================================"
    print "  Oracle Home     : ${ORACLE_HOME}"
    print "  Oracle SID      : ${ORACLE_SID}"
    print "  Target User     : ${TARGET_USER}"
    print "  Catalog         : ${CATALOG_USER}@${CATALOG_TNS}"
    print "  Output Dir      : ${SCHED_DIR}"
    print ""
    print "  --- Monthly ---"
    print "  TDPO Optfile    : ${TDPO_OPTFILE_M}"
    print "  Channels        : ${M_CHANNELS}"
    print "  Sched file      : ${M_SCHED_FILE}"
    print "  RMAN cmdfile    : ${M_RMAN_FILE}"
    print "  Msglog          : ${M_LOG_FILE}"
    print ""
    print "  --- Yearly ---"
    print "  TDPO Optfile    : ${TDPO_OPTFILE_Y}"
    print "  Channels        : ${Y_CHANNELS}"
    print "  Sched file      : ${Y_SCHED_FILE}"
    print "  RMAN cmdfile    : ${Y_RMAN_FILE}"
    print "  Msglog          : ${Y_LOG_FILE}"
    print "============================================================"
    print ""
}

#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------

print_banner

#--- Oracle Environment ---
print_section "Oracle Environment"
prompt_default ORACLE_HOME  "ORACLE_HOME path"  "$DEFAULT_ORACLE_HOME"
prompt_default ORACLE_SID   "ORACLE_SID"        ""
assert_nonempty "$ORACLE_SID" "ORACLE_SID"

#--- RMAN Credentials ---
print_section "RMAN Credentials"
prompt_default TARGET_USER  "RMAN target username"   "backupuser"
prompt_secret  TARGET_PASS  "RMAN target password"
assert_nonempty "$TARGET_PASS" "RMAN target password"

prompt_default CATALOG_USER "RMAN catalog username"  "rman"
prompt_secret  CATALOG_PASS "RMAN catalog password"
assert_nonempty "$CATALOG_PASS" "RMAN catalog password"

prompt_default CATALOG_TNS  "RMAN catalog TNS alias" "rcvcat4"

#--- Output Directory ---
print_section "Output Directory"
prompt_default SCHED_DIR "Schedule/script output directory" "$DEFAULT_SCHED_DIR"

#--- Monthly ---
print_section "Monthly File Names"
prompt_default TDPO_OPTFILE_M "Monthly TDPO optfile path"    "$DEFAULT_TDPO_OPTFILE_M"
prompt_int     M_CHANNELS     "Number of TDPO channels"      8 1 32
prompt_default M_SCHED_FILE   "Monthly .sched filename"      "${SCHED_DIR}/${ORACLE_SID}-0M.sched"
prompt_default M_RMAN_FILE    "Monthly RMAN cmdfile path"    "${SCHED_DIR}/${ORACLE_SID}-0M.rman"
prompt_default M_LOG_FILE     "Monthly RMAN msglog path"     "${SCHED_DIR}/${ORACLE_SID}-0M.rman.log"

#--- Yearly ---
print_section "Yearly File Names"
prompt_default TDPO_OPTFILE_Y "Yearly TDPO optfile path"     "$DEFAULT_TDPO_OPTFILE_Y"
prompt_int     Y_CHANNELS     "Number of TDPO channels"      8 1 32
prompt_default Y_SCHED_FILE   "Yearly .sched filename"       "${SCHED_DIR}/${ORACLE_SID}-0Y.sched"
prompt_default Y_RMAN_FILE    "Yearly RMAN cmdfile path"     "${SCHED_DIR}/${ORACLE_SID}-0Y.rman"
prompt_default Y_LOG_FILE     "Yearly RMAN msglog path"      "${SCHED_DIR}/${ORACLE_SID}-0Y.rman.log"

#--- Confirm ---
print_summary

confirm "Proceed and write files?" || {
    print "  Aborted. No files written."
    exit 0
}

#--- Create output directory if needed ---
if [[ ! -d "$SCHED_DIR" ]]; then
    print "  Creating directory: ${SCHED_DIR}"
    mkdir -p "$SCHED_DIR" || {
        print "[FATAL] Cannot create ${SCHED_DIR}." >&2
        exit 1
    }
    chown oracle:oinstall "$SCHED_DIR" 2>/dev/null
    chmod 750 "$SCHED_DIR"
fi

#--- Write files ---
print ""
print "  Writing Monthly sched   : ${M_SCHED_FILE}"
write_sched_file  "$M_SCHED_FILE" "$M_RMAN_FILE" "$M_LOG_FILE"

print "  Writing Monthly rman    : ${M_RMAN_FILE}"
write_rman_monthly "$M_RMAN_FILE"

print "  Writing Yearly sched    : ${Y_SCHED_FILE}"
write_sched_file  "$Y_SCHED_FILE" "$Y_RMAN_FILE" "$Y_LOG_FILE"

print "  Writing Yearly rman     : ${Y_RMAN_FILE}"
write_rman_yearly "$Y_RMAN_FILE"

#--- Ownership ---
if (( $(id -u) == 0 )); then
    chown oracle:oinstall \
        "$M_SCHED_FILE" "$M_RMAN_FILE" \
        "$Y_SCHED_FILE" "$Y_RMAN_FILE" 2>/dev/null \
    && print "  Ownership set to oracle:oinstall"
fi

print ""
print "  Done. All files generated successfully."
print ""