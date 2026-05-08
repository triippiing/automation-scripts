#!/usr/bin/env bash
# Cross-platform disk grower. Idempotent script that detects and expands the root
# partition / filesystem to fill available disk space. Supports LVM and direct-
# partition layouts on Debian/Ubuntu and RHEL-family distributions.
#
# Usage:
#   ./rootlvresize.sh                       # dry-run (default, safe)
#   sudo ./rootlvresize.sh --apply --yes    # actually expand the disk
#   sudo ./rootlvresize.sh --apply --no-install
#
# Notes:
#   - Online filesystem grows are performed on the live root FS. Take a snapshot
#     or verified backup first.
#   - Requires growpart (cloud-guest-utils / cloud-utils-growpart), lvm2, parted.
#   - sgdisk (gdisk package) recommended on GPT disks to relocate the backup
#     header before parted resizepart.

set -uo pipefail

prog_name="$(basename "$0")"
LOGFILE="/var/log/rootlvresize.log"
LOCKFILE="/var/lock/rootlvresize.lock"

usage() {
  cat <<-EOF
	$prog_name [--apply] [--yes] [--no-install] [--no-log]

	By default this script performs a dry-run and prints the actions it would take.
	  --apply      Perform changes (requires root).
	  --yes        Skip the confirmation prompt when --apply is set.
	  --no-install Do not attempt to install missing tools.
	  --no-log     Do not tee output to $LOGFILE.
	  -h, --help   Show this help.
	EOF
}

APPLY=0
NO_INSTALL=0
ASSUME_YES=0
NO_LOG=0

while (( $# )); do
  case "$1" in
    --apply)      APPLY=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --no-log)     NO_LOG=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------- logging ----------
if [[ $NO_LOG -eq 0 && $APPLY -eq 1 ]]; then
  # Only log to file when actually applying changes; dry-runs stay on stdout.
  if touch "$LOGFILE" 2>/dev/null; then
    exec > >(tee -a "$LOGFILE") 2>&1
    echo "=== $(date -Is) $prog_name run by ${SUDO_USER:-$USER} ==="
  fi
fi

# ---------- single-instance lock ----------
if [[ $APPLY -eq 1 ]]; then
  exec 9>"$LOCKFILE" || { echo "ERROR: cannot open lock file $LOCKFILE" >&2; exit 1; }
  if ! flock -n 9; then
    echo "ERROR: another instance is running (lock: $LOCKFILE)" >&2
    exit 1
  fi
fi

# ---------- helpers ----------
need() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
  if [[ $APPLY -eq 1 ]]; then
    echo "+ $*"
    bash -c "$*"
  else
    echo "DRYRUN: $*"
  fi
}

# Confirmation prompt for destructive operations
confirm() {
  if [[ $APPLY -eq 1 && $ASSUME_YES -eq 0 ]]; then
    read -r -p "Proceed with disk/partition/LV changes? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted by user."; exit 0 ;;
    esac
  fi
}

# Get block device size in bytes (0 if unknown)
get_size() {
  local sz
  sz=$(lsblk -bdn -o SIZE "$1" 2>/dev/null | head -n1)
  echo "${sz:-0}"
}

# Resolve disk + partition number from a partition device using sysfs.
# Robust across sd*, nvme*, mmcblk*, vd*, xvd*, loop*.
# Sets globals: DISK, PART_NUM
resolve_disk_part() {
  local part_dev="$1"
  local pkname part_num
  pkname=$(lsblk -ndo PKNAME "$part_dev" 2>/dev/null)
  if [[ -z "$pkname" ]]; then
    echo "ERROR: cannot determine parent disk of $part_dev" >&2
    return 1
  fi
  part_num=$(cat "/sys/class/block/$(basename "$part_dev")/partition" 2>/dev/null)
  if [[ -z "$part_num" ]]; then
    echo "ERROR: $part_dev does not appear to be a partition" >&2
    return 1
  fi
  DISK="/dev/$pkname"
  PART_NUM="$part_num"
}

install_packages() {
  if [[ $NO_INSTALL -eq 1 ]]; then
    echo "Skipping package install (--no-install)."
    return
  fi
  if need apt-get; then
    echo "Installing required packages (apt)..."
    if [[ $APPLY -eq 1 ]]; then
      apt-get update -y
      apt-get install -y cloud-guest-utils lvm2 parted gdisk
    else
      echo "DRYRUN: apt-get update -y && apt-get install -y cloud-guest-utils lvm2 parted gdisk"
    fi
  elif need dnf || need yum; then
    local pm=dnf
    need dnf || pm=yum
    echo "Installing required packages ($pm)..."
    if [[ $APPLY -eq 1 ]]; then
      $pm install -y cloud-utils-growpart lvm2 parted gdisk || true
    else
      echo "DRYRUN: $pm install -y cloud-utils-growpart lvm2 parted gdisk"
    fi
  else
    echo "WARNING: no known package manager; ensure growpart, parted, lvm2, sgdisk are installed."
  fi
}

ensure_tools() {
  local missing=()
  for t in "$@"; do
    need "$t" || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    echo "Missing tools: ${missing[*]}"
    install_packages
  fi
}

# Relocate GPT backup header to end-of-disk before parted/growpart on GPT disks.
fix_gpt_backup() {
  local disk="$1"
  local pttype
  pttype=$(blkid -o value -s PTTYPE "$disk" 2>/dev/null || true)
  if [[ "$pttype" == "gpt" ]] && need sgdisk; then
    echo "GPT detected on $disk; relocating backup header to end-of-disk."
    run_cmd "sgdisk -e '$disk'"
  fi
}

# Grow a partition using growpart (preferred) or parted resizepart.
grow_partition() {
  local disk="$1" part_num="$2" part_dev="$3"
  ensure_tools growpart parted partprobe
  fix_gpt_backup "$disk"
  if need growpart; then
    # growpart returns 1 ("NOCHANGE") if already at max - treat as success.
    if [[ $APPLY -eq 1 ]]; then
      echo "+ growpart $disk $part_num"
      growpart "$disk" "$part_num" || {
        rc=$?
        if [[ $rc -eq 1 ]]; then
          echo "growpart: NOCHANGE (partition already at max)"
        else
          echo "ERROR: growpart exited $rc" >&2
          return $rc
        fi
      }
    else
      echo "DRYRUN: growpart '$disk' $part_num"
    fi
  else
    run_cmd "parted -s '$disk' resizepart $part_num 100%"
  fi
  run_cmd "partprobe '$disk' || true"
  [[ $APPLY -eq 1 ]] && sleep 2 || true
}

# ---------- pre-flight ----------
if [[ $APPLY -eq 1 && $EUID -ne 0 ]]; then
  echo "ERROR: --apply requires root (use sudo)." >&2
  exit 1
fi

echo "# Current state"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
df -h /
echo

# Capture starting size for post-flight verification
SIZE_BEFORE=$(df -B1 --output=size / 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)

# Resolve root source. Strip btrfs subvolume suffix like [/@] if present.
ROOT_SRC="$(findmnt -no SOURCE --target / | sed 's/\[.*\]//')"
echo "Root SOURCE: $ROOT_SRC"

# Authoritative LVM check via lsblk TYPE rather than path regex.
ROOT_TYPE="$(lsblk -ndo TYPE "$ROOT_SRC" 2>/dev/null || echo unknown)"
echo "Root TYPE:   $ROOT_TYPE"

if [[ $APPLY -eq 1 ]]; then
  echo
  echo "WARNING: this will resize the live root filesystem. Ensure a recent"
  echo "         backup or storage snapshot exists before proceeding."
  confirm
fi

# ============================================================
# LVM-backed root
# ============================================================
if [[ "$ROOT_TYPE" == "lvm" ]]; then
  LV_PATH="$ROOT_SRC"
  VG_NAME="$(lvs --noheadings -o vg_name "$LV_PATH" 2>/dev/null | awk '{$1=$1;print}')"
  if [[ -z "$VG_NAME" ]]; then
    echo "ERROR: unable to determine VG for $LV_PATH" >&2
    exit 1
  fi
  echo "Detected LVM root: LV=$LV_PATH VG=$VG_NAME"

  # Iterate every PV in the VG; grow any whose backing partition has headroom.
  mapfile -t PVS < <(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" 2>/dev/null \
                      | awk '{$1=$1;print}')
  if (( ${#PVS[@]} == 0 )); then
    echo "ERROR: no PVs found for VG $VG_NAME" >&2
    exit 1
  fi
  echo "PVs in $VG_NAME: ${PVS[*]}"

  ensure_tools pvresize lvextend

  any_grown=0
  for PV_PATH in "${PVS[@]}"; do
    echo
    echo "--- Evaluating PV: $PV_PATH ---"
    if ! resolve_disk_part "$PV_PATH"; then
      echo "Skipping $PV_PATH (cannot resolve to a partition; may be whole-disk PV)."
      # Whole-disk PV: pvresize alone may pick up new space if disk grew.
      run_cmd "pvresize '$PV_PATH'"
      continue
    fi
    PART_DEV="$PV_PATH"
    echo "Disk=$DISK Partition=$PART_DEV PartNum=$PART_NUM"

    disk_size=$(get_size "$DISK")
    part_size=$(get_size "$PART_DEV")
    echo "Disk size: $disk_size bytes, Partition size: $part_size bytes"

    if (( part_size >= disk_size )); then
      echo "Partition already fills disk; skipping partition grow."
    else
      echo "Growing partition $PART_DEV to fill $DISK..."
      grow_partition "$DISK" "$PART_NUM" "$PART_DEV"
      any_grown=1
    fi

    echo "Resizing PV: $PV_PATH"
    run_cmd "pvresize '$PV_PATH'"
  done

  echo
  pvs || true
  vgs || true
  lvs || true

  # Only extend LV if there are free extents in the VG.
  free_pe=$(vgs --noheadings -o vg_free_count --units b "$VG_NAME" 2>/dev/null \
              | awk '{print $1+0}')
  echo
  echo "Free extents in $VG_NAME: ${free_pe:-0}"
  if [[ "${free_pe:-0}" -gt 0 ]]; then
    echo "Extending $LV_PATH to consume all free space (with -r to grow FS)..."
    run_cmd "lvextend -r -l +100%FREE '$LV_PATH'"
  else
    echo "No free extents available; nothing to extend."
  fi

# ============================================================
# Direct-partition root (non-LVM)
# ============================================================
else
  PART_DEV="$ROOT_SRC"
  echo "Detected non-LVM root: $PART_DEV"

  if ! resolve_disk_part "$PART_DEV"; then
    exit 1
  fi
  echo "Disk=$DISK Partition=$PART_DEV PartNum=$PART_NUM"

  disk_size=$(get_size "$DISK")
  part_size=$(get_size "$PART_DEV")
  echo "Disk size: $disk_size bytes, Partition size: $part_size bytes"

  if (( part_size >= disk_size )); then
    echo "Partition already fills disk. Nothing to do."
    exit 0
  fi

  grow_partition "$DISK" "$PART_NUM" "$PART_DEV"

  fs_type="$(lsblk -ndo FSTYPE "$PART_DEV" 2>/dev/null || true)"
  echo "Filesystem type on $PART_DEV: $fs_type"
  case "$fs_type" in
    xfs)
      # XFS online grow MUST use the mountpoint, not the device.
      echo "Growing XFS filesystem (online, via mountpoint)..."
      run_cmd "xfs_growfs /"
      ;;
    ext4|ext3|ext2)
      echo "Growing ext filesystem (online via resize2fs)..."
      run_cmd "resize2fs '$PART_DEV'"
      ;;
    btrfs)
      echo "Growing btrfs filesystem (online)..."
      run_cmd "btrfs filesystem resize max /"
      ;;
    "")
      echo "WARNING: could not determine FS type; skipping FS grow."
      ;;
    *)
      echo "WARNING: unsupported filesystem '$fs_type'; grow it manually."
      ;;
  esac
fi

# ---------- post-flight ----------
echo
echo "# After"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
df -h /

if [[ $APPLY -eq 1 ]]; then
  SIZE_AFTER=$(df -B1 --output=size / 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)
  echo
  echo "Root FS bytes: before=$SIZE_BEFORE after=$SIZE_AFTER"
  if [[ "$SIZE_BEFORE" == "$SIZE_AFTER" ]]; then
    echo "WARNING: root filesystem size did not change."
    echo "         This may be expected (already at max) or may indicate the"
    echo "         kernel did not re-read the partition table. A reboot may help."
    # Not a hard failure - already-at-max is a legitimate no-op.
  else
    echo "Root filesystem grew successfully."
  fi
fi

echo
echo "Done.$([[ $APPLY -eq 0 ]] && echo ' (Use --apply to actually perform the operations.)')"
