#!/bin/ksh
#|-----------------------------------------------------------------------------------------------------------------|
#| Program Name: rotate_ssh_key.sh          (replaces vdikey_update.bash)
#|-----------------------------------------------------------------------------------------------------------------|
#| Description: Replaces one public key with another in your own authorized_keys on a list of hosts.
#|              Old key removed (if present), new key added (if absent), nothing else touched.
#|
#| Usage:       rotate_ssh_key.sh -H <hostfile> -o <old.pub> -N <new.pub> [-u <user>] [-n]
#|                -H  hosts, one per line, # comments allowed
#|                -o  file holding the public key to remove (may be empty to only add)
#|                -N  file holding the public key to add
#|                -u  remote user (default: current user)
#|                -n  dry run
#|
#| Note:        Uses the remote user's login shell via ssh, so works on VIOS padmin (ksh) as well as AIX/Linux.
#|              Connects with the *current* key, so run it before the old key is revoked.
#|-----------------------------------------------------------------------------------------------------------------|

set -u
HOSTFILE="" OLDF="" NEWF="" USER_=$(id -un) DRYRUN=0

usage() { print -u2 "Usage: $0 -H <hostfile> -o <old.pub> -N <new.pub> [-u <user>] [-n]"; exit 1; }
while getopts "H:o:N:u:n" opt; do
    case "$opt" in
        H) HOSTFILE="$OPTARG" ;;
        o) OLDF="$OPTARG" ;;
        N) NEWF="$OPTARG" ;;
        u) USER_="$OPTARG" ;;
        n) DRYRUN=1 ;;
        *) usage ;;
    esac
done
[[ -r "$HOSTFILE" && -r "$NEWF" ]] || { print -u2 "ERROR: -H and -N are required and must be readable"; usage; }
[[ -z "$OLDF" || -r "$OLDF" ]] || { print -u2 "ERROR: cannot read $OLDF"; exit 1; }

NEW_KEY=$(head -1 "$NEWF")
OLD_KEY=""; [[ -n "$OLDF" ]] && OLD_KEY=$(head -1 "$OLDF")
[[ "$NEW_KEY" == ssh-* || "$NEW_KEY" == ecdsa-* ]] || { print -u2 "ERROR: $NEWF does not look like a public key"; exit 1; }

# remote script: keys passed as positional args so no quoting inside the script body
remote='
umask 077
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
AK="$HOME/.ssh/authorized_keys"; TMP="$AK.tmp.$$"
touch "$AK"
if [ -n "$1" ]; then grep -vF "$1" "$AK" > "$TMP"; else cat "$AK" > "$TMP"; fi
grep -qF "$2" "$TMP" || echo "$2" >> "$TMP"
mv "$TMP" "$AK"; chmod 600 "$AK"
echo "keys now: $(grep -c . "$AK")"
'

rc=0
grep -v '^[[:space:]]*#' "$HOSTFILE" | awk 'NF {print $1}' | while read -r host; do
    if (( DRYRUN )); then
        print "would update ${USER_}@${host}"
        continue
    fi
    printf "%-40s " "${USER_}@${host}"
    if out=$(ssh -q -o BatchMode=yes -o ConnectTimeout=10 "${USER_}@${host}" sh -s -- "$OLD_KEY" "$NEW_KEY" <<< "$remote" 2>&1); then
        print "OK  ($out)"
    else
        print "FAILED  $out"; rc=1
    fi
done
exit $rc
