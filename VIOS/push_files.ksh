#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: push_files.ksh          (replaces rollout.ksh)
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Pushes a set of files to a list of VIO servers or AIX hosts and installs them with the right
#|              owner and mode. Runs from the NIM master (or any admin host with ssh access).
#|
#|              Files to push are listed in a manifest, one per line:
#|
#|                  <local source>   <remote destination>   <owner:group>   <mode>   [backup]
#|
#|              e.g.
#|                  Unix_Admin.sudo    /etc/sudoers.d/Unix_Admin   root:system   440
#|                  default.profile    /etc/profile                bin:bin       555   backup
#|
#|              Each file is copied to /tmp on the remote host, then moved into place as root. For VIO servers
#|              root is reached via oem_setup_env; for AIX hosts the remote user runs the commands directly.
#|              Files destined for /etc/sudoers.d are checked with visudo before they are moved into place.
#|              A "backup" flag keeps a timestamped copy of any existing destination file.
#|
#| Usage:       push_files.ksh -M <manifest> [-H <hostfile> | -h <host>[,host...]] [-u <user>] [-A] [-n]
#|                -M  manifest file (see above)
#|                -H  file of hostnames, one per line, # comments allowed (default: PUSH_HOSTFILE from config)
#|                -h  comma-separated host list instead of -H
#|                -u  remote user (default: PUSH_USER from config, else padmin)
#|                -A  hosts are plain AIX, not VIOS (no oem_setup_env; user must be root or have sudo -n)
#|                -n  dry run - show what would be done
#|-----------------------------------------------------------------------------------------------------------------|
#| Revision History:
#| 03/09/2026 : Rewrite of rollout.ksh - manifest driven, hostfile as argument, broken quoting in the scp/ssh
#|              one-liners fixed by sending the remote commands over stdin, sudoers validated with visudo
#|-----------------------------------------------------------------------------------------------------------------|

set -u
. "$(dirname "$0")/vios_lib.ksh"

MANIFEST=""
HOSTFILE=${PUSH_HOSTFILE:-}
HOSTS=""
USER_=${PUSH_USER:-padmin}
PLAIN_AIX=0
DRYRUN=0

usage() {
    print -u2 "Usage: $0 -M <manifest> [-H <hostfile> | -h <host,...>] [-u <user>] [-A] [-n]"
    exit 1
}

while getopts "M:H:h:u:An" opt; do
    case "$opt" in
        M) MANIFEST="$OPTARG" ;;
        H) HOSTFILE="$OPTARG" ;;
        h) HOSTS=$(print -- "$OPTARG" | tr ',' ' ') ;;
        u) USER_="$OPTARG" ;;
        A) PLAIN_AIX=1 ;;
        n) DRYRUN=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$MANIFEST" ]] || { print -u2 "ERROR: -M manifest is required"; usage; }
[[ -r "$MANIFEST" ]] || { print -u2 "ERROR: cannot read manifest $MANIFEST"; exit 1; }

if [[ -z "$HOSTS" ]]; then
    [[ -n "$HOSTFILE" ]] || { print -u2 "ERROR: give -H <hostfile> or -h <hosts>"; usage; }
    [[ -r "$HOSTFILE" ]] || { print -u2 "ERROR: cannot read hostfile $HOSTFILE"; exit 1; }
    HOSTS=$(grep -v '^[[:space:]]*#' "$HOSTFILE" | awk 'NF {print $1}')
fi
[[ -n "$HOSTS" ]] || { print -u2 "ERROR: no hosts to push to"; exit 1; }

# Validate manifest and local sources before touching any host
grep -v '^[[:space:]]*#' "$MANIFEST" | awk 'NF' | while read -r src dest owner mode backup; do
    [[ -n "$mode" ]] || { print -u2 "ERROR: manifest line needs src dest owner mode: $src $dest $owner"; exit 1; }
    [[ -r "$src" ]] || { print -u2 "ERROR: local file not found: $src"; exit 1; }
    [[ "$dest" == /* ]] || { print -u2 "ERROR: destination must be absolute: $dest"; exit 1; }
done || exit 1

log_init "${LOGDIR}/push_files.log" "$@"
trap log_close EXIT

# Build the root-level command block to install one file on the remote side
remote_install_cmds() {
    src=$1 dest=$2 owner=$3 mode=$4 backup=$5
    tmp="/tmp/$(basename "$src").push.$$"
    print "set -e"
    print "test -f '$tmp' || { echo 'upload missing: $tmp' >&2; exit 1; }"
    case "$dest" in
        /etc/sudoers.d/*|/etc/sudoers)
            print "if command -v visudo >/dev/null 2>&1; then visudo -cf '$tmp' || { rm -f '$tmp'; exit 1; }; fi" ;;
    esac
    [[ "$backup" == "backup" ]] && \
        print "[ -f '$dest' ] && /usr/bin/cp -p '$dest' '${dest}.bak_'\$(date +%Y%m%d_%H%M%S)"
    print "/usr/bin/mkdir -p '$(dirname "$dest")'"
    print "/usr/bin/mv -f '$tmp' '$dest'"
    print "/usr/bin/chown $owner '$dest'"
    print "/usr/bin/chmod $mode '$dest'"
    print "/usr/bin/ls -l '$dest'"
}

# Run a block of root commands on a host: via oem_setup_env on VIOS, directly on AIX
run_as_root() {
    host=$1
    if (( PLAIN_AIX )); then
        ssh -q -o BatchMode=yes "${USER_}@${host}" /bin/ksh
    else
        ssh -q -o BatchMode=yes "${USER_}@${host}" oem_setup_env
    fi
}

overall=0
for host in $HOSTS; do
    screen_only ""
    log_and_screen "Host" "$host"

    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=10 "${USER_}@${host}" true 2>>"$logfile"; then
        log_and_screen "  connection" "FAILED - skipping host"
        overall=1
        continue
    fi

    grep -v '^[[:space:]]*#' "$MANIFEST" | awk 'NF' | while read -r src dest owner mode backup; do
        tmp="/tmp/$(basename "$src").push.$$"

        if (( DRYRUN )); then
            log_and_screen "  would push" "$src -> $dest ($owner $mode${backup:+ $backup})"
            continue
        fi

        if ! scp -q -o BatchMode=yes "$src" "${USER_}@${host}:${tmp}" 2>>"$logfile"; then
            log_and_screen "  $dest" "scp FAILED"
            overall=1
            continue
        fi

        if remote_install_cmds "$src" "$dest" "$owner" "$mode" "${backup:-}" | run_as_root "$host" >>"$logfile" 2>&1; then
            log_and_screen "  $dest" "installed"
        else
            log_and_screen "  $dest" "install FAILED (see $logfile)"
            overall=1
        fi
    done
done

screen_only ""
if (( overall )); then
    log_and_screen "Result" "completed with errors - see $logfile"
else
    log_and_screen "Result" "all files pushed"
fi
exit $overall
