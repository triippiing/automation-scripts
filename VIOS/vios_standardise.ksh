#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: vios_standardise.ksh
#|               (replaces Vios_3.1.2.60.ksh, Vios_4.1.1.00.ksh, Vios_4.1.2.10_fresh_install.ksh)
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Brings a freshly installed or upgraded VIO server up to the standard build. Every step is
#|              idempotent, so the script can be re-run safely and individual steps can be selected.
#|
#|              Steps (in order):
#|                filesystems   grow /usr /var /opt to the standard sizes (never shrinks)
#|                padmin_env    padmin .profile loads .kshrc; /var/adm/commandlog exists
#|                payload       install the standard files (profile, bashrc, banner, sudoers, scripts) from
#|                              the manifest, exactly as push_files.ksh would from the admin host
#|                languages     remove non-English openssh message filesets
#|                rules         apply adapter rules (rulestoset.ksh)
#|                herald        login herald text
#|                dumpcheck     dumpcheck LC_MESSAGES fix
#|                limits        default fsize / nofiles
#|                sshd          Banner, ClientAliveInterval, X11Forwarding; restart sshd if changed
#|                syslog        *.debug to /var/log/messages with rotation
#|                paging        grow hd6 to the standard size, remove paging00 if present
#|                loginname     max_logname=256 for long LDAP names (needs reboot)
#|                tunables      ioo / no / acfo settings from TUNABLES (default: j2_dynamicBufferPreallocation,
#|                              tcp_fastlo, in_core_enabled), each read first and only set when different
#|                fixes         only with -F: install every fix directory under the given path
#|
#| Usage:       vios_standardise.ksh [-n] [-s <step,...>] [-M <manifest>] [-F <fixes dir>] [-l]
#|                -n  dry run - show what would change
#|                -s  run only these steps (comma separated), default all except fixes
#|                -M  manifest of files to install (default: push_files.manifest next to this script,
#|                    falling back to push_files.manifest.example)
#|                -F  directory of fix sub-directories, e.g. <mnt>/vios/vios_standards/4.1.2.0
#|                    *.epkg.Z dirs go through install_efix.ksh, viodb dirs through updateios,
#|                    anything else through installp_update.ksh
#|                -l  list steps and exit
#|
#|              Sizes and texts can be overridden in vios.conf: FS_SIZES, PAGING_GB, HERALD, LIMIT_NOFILES,
#|              SSHD_CLIENT_ALIVE, SSHD_X11, TUNABLES.
#|
#| Note:        Run as root (padmin: oem_setup_env) from the mounted vios_standards tree, so that
#|              vios_lib.ksh, the manifest and payload/ are alongside. Reboot afterwards.
#|-----------------------------------------------------------------------------------------------------------------|
#| Origin: original script dated 02/04/2025, recovered from the old NIM server
#| Revision History:
#| 02/04/2025 : original : Base script (per-release copies)
#| 27/08/2026 : original : Modified for a fresh install of 4.1.2.10
#| 03/09/2026 :            : Merged the three release copies. Idempotent steps, dry run, step selection,
#|                           padmin .profile edit now targets /home/padmin (was the current directory),
#|                           paging grown to a target size instead of adding a fixed number of partitions,
#|                           sshd options set/replaced rather than appended after the commented default,
#|                           GSKit/LDAP client install dropped, FC tuning moved to adapter_rules.conf
#| 04/09/2026 :            : tunables step driven by TUNABLES with before/after values (absorbs the ioo/no/acfo
#|                           part of ADMIN/perftuning.ksh; its device defaults went to adapter_rules.conf)
#|-----------------------------------------------------------------------------------------------------------------|

set -u
BASEDIR=$(cd "$(dirname "$0")" && pwd)
. "${BASEDIR}/vios_lib.ksh"

FS_SIZES=${FS_SIZES:-"/usr:8 /var:3 /opt:3"}
PAGING_GB=${PAGING_GB:-8}
HERALD=${HERALD:-'Unauthorized use of this system is prohibited.\n\nlogin:'}
LIMIT_NOFILES=${LIMIT_NOFILES:-8000}
SSHD_CLIENT_ALIVE=${SSHD_CLIENT_ALIVE:-600}
SSHD_X11=${SSHD_X11:-yes}
SSHD_BANNER=${SSHD_BANNER:-/etc/ssh/SEbanner}
TUNABLES=${TUNABLES:-"ioo:j2_dynamicBufferPreallocation=256 no:tcp_fastlo=1 acfo:in_core_enabled=1"}

ALL_STEPS="filesystems padmin_env payload languages rules herald dumpcheck limits sshd syslog paging loginname tunables"
STEPS=""
DRYRUN=0
MANIFEST=""
FIXDIR=""

usage() {
    print -u2 "Usage: $0 [-n] [-s <step,...>] [-M <manifest>] [-F <fixes dir>] [-l]"
    exit 1
}

while getopts "ns:M:F:l" opt; do
    case "$opt" in
        n) DRYRUN=1 ;;
        s) STEPS=$(print -- "$OPTARG" | tr ',' ' ') ;;
        M) MANIFEST="$OPTARG" ;;
        F) FIXDIR="$OPTARG" ;;
        l) print "$ALL_STEPS fixes" | tr ' ' '\n'; exit 0 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$STEPS" ]] || STEPS="$ALL_STEPS"
[[ -n "$FIXDIR" && " $STEPS " != *" fixes "* ]] && STEPS="$STEPS fixes"
for s in $STEPS; do
    [[ " $ALL_STEPS fixes " == *" $s "* ]] || { print -u2 "ERROR: unknown step '$s' (use -l to list)"; exit 1; }
done

if [[ -z "$MANIFEST" ]]; then
    MANIFEST="${BASEDIR}/push_files.manifest"
    [[ -r "$MANIFEST" ]] || MANIFEST="${BASEDIR}/push_files.manifest.example"
fi
[[ -r "$MANIFEST" ]] || { print -u2 "ERROR: manifest not found: $MANIFEST"; exit 1; }
[[ -z "$FIXDIR" || -d "$FIXDIR" ]] || { print -u2 "ERROR: fixes dir not found: $FIXDIR"; exit 1; }

require_root
is_vios || { print -u2 "ERROR: not a VIO server"; exit 1; }

log_init "${LOGDIR}/vios_standardise.log" "$@"
trap log_close EXIT

errors=0
reboot_needed=""

log_and_screen "Host" "$(uname -n)  VIOS $(os_level_dotted)"
log_and_screen "Steps" "$STEPS"
(( DRYRUN )) && log_and_screen "Mode" "DRY RUN - nothing will be changed"

# do_cmd <cmd...> : run (logged) unless dry run
do_cmd() {
    if (( DRYRUN )); then
        log_and_screen "  would run" "$*"
        return 0
    fi
    run_logged "$@"
}

# ok <label> <msg> : success message, prefixed in dry run so it does not read as done
ok() {
    if (( DRYRUN )); then log_and_screen "$1" "would: $2"; else log_and_screen "$1" "$2"; fi
}

# run a sibling script with its screen output on our screen
run_script() {
    if (( DRYRUN )); then
        log_and_screen "  would run" "$*"
        return 0
    fi
    print "----- $(date) : $*"
    "$@" 1>&3
}

#############################################
step_filesystems() {
    for entry in $FS_SIZES; do
        fs=${entry%%:*}; want=${entry##*:}
        cur=$(df -g "$fs" 2>/dev/null | awk 'NR==2 {print int($2)}')
        [[ -n "$cur" ]] || { log_and_screen "  $fs" "not found, skipping"; continue; }
        if (( cur >= want )); then
            log_and_screen "  $fs" "${cur}G already >= ${want}G"
        else
            do_cmd chfs -a size="${want}G" "$fs" && ok "  $fs" "${cur}G -> ${want}G" || { log_and_screen "  $fs" "chfs FAILED"; errors=1; }
        fi
    done
}

#############################################
step_padmin_env() {
    profile=/home/padmin/.profile
    if grep -q 'ENV=/home/padmin/.kshrc' "$profile" 2>/dev/null; then
        log_and_screen "  padmin .profile" "already loads .kshrc"
    elif (( DRYRUN )); then
        log_and_screen "  padmin .profile" "would add ENV=/home/padmin/.kshrc"
    else
        print 'export ENV=/home/padmin/.kshrc' >> "$profile" && log_and_screen "  padmin .profile" "ENV=/home/padmin/.kshrc added"
    fi
    if [[ -d /var/adm/commandlog ]]; then
        log_and_screen "  /var/adm/commandlog" "exists"
    else
        do_cmd mkdir -p /var/adm/commandlog && do_cmd chmod 775 /var/adm/commandlog && ok "  /var/adm/commandlog" "created"
    fi
}

#############################################
step_payload() {
    log_and_screen "  manifest" "$MANIFEST"
    tmp=$(tmpfile manifest)
    grep -v '^[[:space:]]*#' "$MANIFEST" | awk 'NF' > "$tmp"
    while read -r src dest owner mode backup; do
        [[ "$src" == /* ]] || src="${BASEDIR}/${src}"
        if [[ ! -f "$src" ]]; then
            log_and_screen "  $dest" "SOURCE MISSING: $src"; errors=1; continue
        fi
        if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
            (( DRYRUN )) || { chown "$owner" "$dest"; chmod "$mode" "$dest"; }
            log_and_screen "  $dest" "unchanged"
            continue
        fi
        if (( DRYRUN )); then
            log_and_screen "  $dest" "would install from $(basename "$src") ($owner $mode)"
            continue
        fi
        if [[ "${backup:-}" == "backup" && -f "$dest" ]]; then
            cp -p "$dest" "${dest}.bak_$(date +%Y%m%d_%H%M%S)"
        fi
        if mkdir -p "$(dirname "$dest")" && cp "$src" "$dest" && chown "$owner" "$dest" && chmod "$mode" "$dest"; then
            log_and_screen "  $dest" "installed"
        else
            log_and_screen "  $dest" "FAILED"; errors=1
        fi
    done < "$tmp"
    rm -f "$tmp"
}

#############################################
step_languages() {
    script=/usr/local/bin/removeunwanted.ksh
    [[ -x "$script" ]] || script="${BASEDIR}/payload/removeunwanted.ksh"
    [[ -x "$script" ]] || { log_and_screen "  removeunwanted.ksh" "not found"; errors=1; return; }
    if (( DRYRUN )); then
        run_script "$script" -n
    else
        run_script "$script" || errors=1
    fi
}

#############################################
step_rules() {
    script=/usr/local/bin/rulestoset.ksh
    [[ -x "$script" ]] || script="${BASEDIR}/rulestoset.ksh"
    [[ -x "$script" ]] || { log_and_screen "  rulestoset.ksh" "not found"; errors=1; return; }
    if (( DRYRUN )); then
        run_script "$script" -n
    else
        run_script "$script" && reboot_needed="$reboot_needed rules" || errors=1
    fi
}

#############################################
step_herald() {
    cur=$(lssec -f /etc/security/login.cfg -s default -a herald 2>/dev/null | sed 's/^default herald=//')
    if [[ "$cur" == "$HERALD" ]]; then
        log_and_screen "  herald" "already set"
    else
        do_cmd chsec -f /etc/security/login.cfg -s default -a "herald=$HERALD" && ok "  herald" "set" || { log_and_screen "  herald" "FAILED"; errors=1; }
    fi
}

#############################################
step_dumpcheck() {
    # Carried over from the original scripts: replaces the literal ORIGM=LC_MESSAGES with the value of
    # LC_MESSAGES in the running environment (usually empty). Only touches the file if the literal is present.
    f=/usr/lib/ras/dumpcheck
    if grep -q 'ORIGM=LC_MESSAGES' "$f" 2>/dev/null; then
        do_cmd perl -pi.bak -e "s/ORIGM=LC_MESSAGES/ORIGM=${LC_MESSAGES:-}/g" "$f" && ok "  dumpcheck" "patched"
    else
        log_and_screen "  dumpcheck" "already patched or pattern absent"
    fi
}

#############################################
step_limits() {
    for kv in "fsize=-1" "nofiles=${LIMIT_NOFILES}"; do
        k=${kv%%=*}; v=${kv##*=}
        cur=$(lssec -f /etc/security/limits -s default -a "$k" 2>/dev/null | awk -F= '{print $2}')
        if [[ "$cur" == "$v" ]]; then
            log_and_screen "  limits $k" "already $v"
        else
            do_cmd chsec -f /etc/security/limits -s default -a "$kv" && ok "  limits $k" "${cur:-unset} -> $v" || { log_and_screen "  limits $k" "FAILED"; errors=1; }
        fi
    done
}

#############################################
sshd_changed=0
set_sshd_option() {   # set_sshd_option <key> <value>
    key=$1 val=$2 f=/etc/ssh/sshd_config
    cur=$(awk -v k="$key" '$1 == k {print $2; exit}' "$f")
    if [[ "$cur" == "$val" ]]; then
        log_and_screen "  sshd $key" "already $val"
        return
    fi
    if (( DRYRUN )); then
        log_and_screen "  sshd $key" "would set ${cur:-unset} -> $val"
        return
    fi
    if (( sshd_changed == 0 )); then
        cp -p "$f" "${f}.$(date +%Y%m%d_%H%M%S)"
    fi
    if [[ -n "$cur" ]]; then
        sed "s|^${key}[[:space:]].*|${key} ${val}|" "$f" > "${f}.new" && cat "${f}.new" > "$f" && rm -f "${f}.new"
    else
        print "${key} ${val}" >> "$f"
    fi
    sshd_changed=1
    log_and_screen "  sshd $key" "${cur:-unset} -> $val"
}

step_sshd() {
    [[ -f "$SSHD_BANNER" ]] || log_and_screen "  sshd Banner" "WARNING $SSHD_BANNER not present yet (payload step installs it)"
    set_sshd_option Banner "$SSHD_BANNER"
    set_sshd_option ClientAliveInterval "$SSHD_CLIENT_ALIVE"
    set_sshd_option X11Forwarding "$SSHD_X11"
    if (( sshd_changed )); then
        if sshd -t 2>>"$logfile"; then
            do_cmd stopsrc -s sshd; sleep 2; do_cmd startsrc -s sshd && ok "  sshd" "restarted"
        else
            log_and_screen "  sshd" "CONFIG TEST FAILED - not restarted, check $logfile"; errors=1
        fi
    fi
}

#############################################
step_syslog() {
    line='*.debug /var/log/messages rotate time 1m files 12 compress'
    if grep -qF "$line" /etc/syslog.conf; then
        log_and_screen "  syslog.conf" "already configured"
    elif (( DRYRUN )); then
        log_and_screen "  syslog.conf" "would add: $line"
    else
        cp -p /etc/syslog.conf "/etc/syslog.conf.$(date +%Y%m%d_%H%M%S)"
        print -- "$line" >> /etc/syslog.conf
        touch /var/log/messages
        refresh -s syslogd >> "$logfile" 2>&1 && log_and_screen "  syslog.conf" "added and syslogd refreshed"
    fi
}

#############################################
step_paging() {
    if lsps -a | awk 'NR>1 {print $1}' | grep -qx paging00; then
        if (( DRYRUN )); then
            log_and_screen "  paging00" "would remove"
        else
            swapoff /dev/paging00 >> "$logfile" 2>&1
            do_cmd rmps paging00 && ok "  paging00" "removed" || { log_and_screen "  paging00" "remove FAILED"; errors=1; }
        fi
    fi
    cur_mb=$(lsps -a | awk '$1 == "hd6" {sub(/MB/,"",$4); print $4}')
    pp_mb=$(lsvg rootvg | awk -F'PP SIZE:' '/PP SIZE/ {print $2}' | awk '{print $1}')
    want_mb=$(( PAGING_GB * 1024 ))
    if [[ -z "$cur_mb" || -z "$pp_mb" ]]; then
        log_and_screen "  hd6" "could not read size (lsps/lsvg)"; errors=1; return
    fi
    if (( cur_mb >= want_mb )); then
        log_and_screen "  hd6" "${cur_mb}MB already >= ${want_mb}MB"
    else
        lps=$(( (want_mb - cur_mb + pp_mb - 1) / pp_mb ))
        do_cmd chps -s "$lps" hd6 && ok "  hd6" "${cur_mb}MB -> $(( cur_mb + lps * pp_mb ))MB (+${lps} x ${pp_mb}MB)" || { log_and_screen "  hd6" "chps FAILED"; errors=1; }
    fi
}

#############################################
step_loginname() {
    cur=$(getconf LOGIN_NAME_MAX)
    if (( cur == 256 )); then
        log_and_screen "  LOGIN_NAME_MAX" "already 256"
    else
        do_cmd "$IOSCLI" chdev -dev sys0 -attr max_logname=256 && { log_and_screen "  LOGIN_NAME_MAX" "$cur -> 256 (after reboot)"; reboot_needed="$reboot_needed max_logname"; } || { log_and_screen "  LOGIN_NAME_MAX" "FAILED"; errors=1; }
    fi
}

#############################################
# TUNABLES is a list of <tool>:<name>=<value>, tool being ioo, no, vmo, schedo or acfo. Each is read first
# and only set when it differs, with the before/after values on screen and in the log.
get_tunable() {   # get_tunable <tool> <name>
    case "$1" in
        acfo) acfo -d -t "$2" 2>/dev/null | awk -F: 'NR==1 {gsub(/[[:space:]]/,"",$2); print $2}' ;;
        *)    "$1" -o "$2" 2>/dev/null | awk -F= 'NR==1 {gsub(/[[:space:]]/,"",$2); print $2}' ;;
    esac
}

step_tunables() {
    for t in $TUNABLES; do
        tool=${t%%:*}; setting=${t#*:}; name=${setting%%=*}; want=${setting##*=}
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_and_screen "  $tool $name" "not available on this level, skipping"
            continue
        fi
        cur=$(get_tunable "$tool" "$name")
        if [[ "$cur" == "$want" ]]; then
            log_and_screen "  $tool $name" "already $want"
            continue
        fi
        case "$tool" in
            acfo) set -- acfo -p -t "$setting" ;;
            *)    set -- "$tool" -p -o "$setting" ;;
        esac
        do_cmd "$@" && ok "  $tool $name" "${cur:-unset} -> $want" || { log_and_screen "  $tool $name" "FAILED"; errors=1; }
    done
}

#############################################
step_fixes() {
    for d in "$FIXDIR"/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        if ls "$d"/*.epkg.Z >/dev/null 2>&1; then
            run_script "${BASEDIR}/install_efix.ksh" -d "$d" -a apply || errors=1
        elif ls "$d"/ios.viodb* >/dev/null 2>&1; then
            do_cmd "$IOSCLI" updateios -dev "$d" -accept -install && ok "  $name" "updateios done" || { log_and_screen "  $name" "updateios FAILED"; errors=1; }
        elif [[ -n "$(ls -A "$d")" ]]; then
            run_script "${BASEDIR}/installp_update.ksh" -d "$d" -p "${name%%_*}" -a apply || errors=1
        fi
    done
}

#############################################
# Main
#############################################

for step in $STEPS; do
    screen_only ""
    log_and_screen "== $step"
    "step_$step"
done

screen_only ""
if (( errors )); then
    log_and_screen "Result" "completed with errors - see $logfile"
else
    log_and_screen "Result" "OK"
fi
[[ -n "$reboot_needed" ]] && log_and_screen "Reboot required" "for:$reboot_needed  (shutdown -restart)"
(( DRYRUN )) || log_and_screen "Next" "reboot, then verify with: rulestoset.ksh -n, sea_status.ksh, unused_adapters.ksh"
exit $errors
