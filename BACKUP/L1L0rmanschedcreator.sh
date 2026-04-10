#!/usr/bin/ksh
#==============================================================================
# Script  : gen_rman_sched.ksh
# Purpose : Interactively generate Oracle RMAN backup schedule wrappers
#           (.sched) and RMAN cmdfiles (.rman) for TSM/TDPO integration.
# Levels  : Incremental Level 0 and Level 1
# Shell   : KSH (ksh88 compatible, AIX/RHEL)
#==============================================================================

#------------------------------------------------------------------------------
# CONSTANTS
#------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0")
readonly DEFAULT_ORACLE_HOME="/u01/app/oracle/product/11.2.0/dbhome_1"
readonly DEFAULT_TDPO_OPTFILE="/usr/tivoli/tsm/client/oracle/bin64/tdpo.opt"
readonly DEFAULT_SCHED_DIR="/home/oracle/sched"

#------------------------------------------------------------------------------
# TERMINAL SETUP
# Save terminal state; restore unconditionally on exit/signal.
# Set erase to DEL (0x7F) which is what modern terminal emulators send for
# backspace. If your terminal sends ^H (0x08) instead, change \177 to \010.
#------------------------------------------------------------------------------
STTY_SAVE=$(stty -g 2>/dev/null)
if [[ -n "$STTY_SAVE" ]]; then
    trap 'stty "$STTY_SAVE" 2>/dev/null' EXIT INT TERM HUP
    # AIX terminal sessions (PuTTY, xterm) typically send ^H (0x08) for backspace.
    # If deletion still does not work, check PuTTY Terminal->Keyboard->Backspace
    # and set stty erase to match: \177 for DEL, \010 for ^H.
    stty erase "$(printf '\010')" 2>/dev/null
fi

#------------------------------------------------------------------------------
# sanitize_input  value
#
# Cleans raw terminal input captured by read(1), which does not strip escape
# sequences.  Two-pass approach:
#
#   Pass 1 (tr):  delete every non-printable byte (0x00-0x1F, 0x7F).
#                 This removes ESC (0x1B), ^H (0x08), DEL (0x7F), and any
#                 other control character the terminal may have injected.
#
#   Pass 2 (sed): after ESC is gone, CSI sequences leave printable remnants:
#                 arrow keys  -> [A  [B  [C  [D
#                 F-keys etc. -> [15~  [17~  [1;5D  etc.
#                 Pattern \[[0-9;]*[A-Za-z~] matches and removes all of these.
#
# Result is written to stdout.
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
    print "  Oracle RMAN / TSM-TDPO Backup Script Generator"
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

# prompt_secret VARNAME "Prompt text"  -- no echo, no sanitize (passwords)
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

# confirm "Prompt text"  -- returns 0 for yes, 1 for no
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

# write_sched_file  filepath  level  rman_cmdfile  rman_msglog
write_sched_file() {
    typeset _file="$1"
    typeset _level="$2"
    typeset _rman_cmdfile="$3"
    typeset _rman_msglog="$4"

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

# build_channels count  -- emits allocate channel lines to stdout
build_channels() {
    typeset _count="$1"
    typeset _i=0
    while (( _i < _count )); do
        printf '\tallocate channel t%d type '"'"'sbt_tape'"'"' parms '"'"'ENV=(TDPO_OPTFILE=%s)'"'"';\n' \
            "$_i" "$TDPO_OPTFILE"
        (( _i = _i + 1 ))
    done
}

write_rman_level0() {
    typeset _file="$1"
    {
        printf 'run {\n'
        build_channels "$L0_CHANNELS"
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

write_rman_level1() {
    typeset _file="$1"
    {
        printf 'run {\n'
        build_channels "$L1_CHANNELS"
        printf '\tbackup incremental level 1 format '"'"'%%d_%%T_%%t_%%s_%%u.dbf'"'"' database tag '"'"'db_level_1'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.arc'"'"' archivelog all tag '"'"'arch'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.spf'"'"' spfile tag '"'"'spfile'"'"';\n'
        printf '\tbackup format '"'"'%%d_%%T_%%t_%%s_%%u.ctl'"'"' current controlfile tag '"'"'ctl'"'"';\n'
        printf '\tallocate channel d1 type disk;\n'
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
    print "  TDPO Optfile    : ${TDPO_OPTFILE}"
    print "  Target User     : ${TARGET_USER}"
    print "  Catalog         : ${CATALOG_USER}@${CATALOG_TNS}"
    print "  Output Dir      : ${SCHED_DIR}"
    print ""
    print "  --- Level 0 ---"
    print "  Channels        : ${L0_CHANNELS}"
    print "  Sched file      : ${L0_SCHED_FILE}"
    print "  RMAN cmdfile    : ${L0_RMAN_FILE}"
    print "  Msglog          : ${L0_LOG_FILE}"
    print ""
    print "  --- Level 1 ---"
    print "  Channels        : ${L1_CHANNELS}"
    print "  Sched file      : ${L1_SCHED_FILE}"
    print "  RMAN cmdfile    : ${L1_RMAN_FILE}"
    print "  Msglog          : ${L1_LOG_FILE}"
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

#--- TDPO ---
print_section "TSM/TDPO Configuration"
prompt_default TDPO_OPTFILE "TDPO optfile path" "$DEFAULT_TDPO_OPTFILE"

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

#--- Level 0 ---
print_section "Level 0 File Names"
prompt_int     L0_CHANNELS    "Number of TDPO channels (Level 0)" 8 1 32
prompt_default L0_SCHED_FILE  "Level 0 .sched filename"   "${SCHED_DIR}/${ORACLE_SID}-0.sched"
prompt_default L0_RMAN_FILE   "Level 0 RMAN cmdfile path" "${SCHED_DIR}/${ORACLE_SID}-0.rman"
prompt_default L0_LOG_FILE    "Level 0 RMAN msglog path"  "${SCHED_DIR}/${ORACLE_SID}-rman.log"

#--- Level 1 ---
print_section "Level 1 File Names"
prompt_int     L1_CHANNELS    "Number of TDPO channels (Level 1)" 4 1 32
prompt_default L1_SCHED_FILE  "Level 1 .sched filename"   "${SCHED_DIR}/${ORACLE_SID}-1.sched"
prompt_default L1_RMAN_FILE   "Level 1 RMAN cmdfile path" "${SCHED_DIR}/${ORACLE_SID}-1.rman"
prompt_default L1_LOG_FILE    "Level 1 RMAN msglog path"  "${SCHED_DIR}/${ORACLE_SID}-1-rman.log"

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
print "  Writing Level 0 sched  : ${L0_SCHED_FILE}"
write_sched_file  "$L0_SCHED_FILE" "0" "$L0_RMAN_FILE" "$L0_LOG_FILE"

print "  Writing Level 0 rman   : ${L0_RMAN_FILE}"
write_rman_level0 "$L0_RMAN_FILE"

print "  Writing Level 1 sched  : ${L1_SCHED_FILE}"
write_sched_file  "$L1_SCHED_FILE" "1" "$L1_RMAN_FILE" "$L1_LOG_FILE"

print "  Writing Level 1 rman   : ${L1_RMAN_FILE}"
write_rman_level1 "$L1_RMAN_FILE"

#--- Ownership ---
if (( $(id -u) == 0 )); then
    chown oracle:oinstall \
        "$L0_SCHED_FILE" "$L0_RMAN_FILE" \
        "$L1_SCHED_FILE" "$L1_RMAN_FILE" 2>/dev/null \
    && print "  Ownership set to oracle:oinstall"
fi

print ""
print "  Done. All files generated successfully."
print ""