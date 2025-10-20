#!/bin/bash
set -euo pipefail

stage="${1:?stage number required}"
LIBERO_IMAGE_SIZE="${LIBERO_IMAGE_SIZE:-30G}"
COMMON_APT_PACKAGES="${COMMON_APT_PACKAGES:-build-essential binutils bison gawk texinfo xz-utils m4 python3 python3-distutils python3-setuptools perl tar patch diffutils findutils gzip sed grep coreutils git curl wget rsync parted xorriso sudo ca-certificates}"
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"
IMAGE_PATH="/workspace/.ci/libero.img"
MNT_DIR="/mnt/libero"
CI_DIR="/workspace/cache/sources"
bind_mounts=()

install_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${COMMON_APT_PACKAGES}
  apt-get clean
}

detect_part_suffix() {
  local dev="$1"
  if [[ "$dev" =~ (loop[0-9]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+) ]]; then
    printf 'p'
  else
    printf ''
  fi
}

attach_disk() {
  loopdev=$(losetup --find --show --partscan "$IMAGE_PATH")
  if [[ -z "$loopdev" ]]; then
    echo "Failed to attach loop device for $IMAGE_PATH" >&2
    exit 1
  fi
  part_suffix=$(detect_part_suffix "$loopdev")
  swap_part="${loopdev}${part_suffix}2"
  root_part="${loopdev}${part_suffix}3"
}

mount_root() {
  mkdir -p "$MNT_DIR"
  mount "$root_part" "$MNT_DIR"
}

enable_swap() {
  swapon "$swap_part" 2>/dev/null || true
}

setup_chroot_mounts() {
  mount --bind /dev "$MNT_DIR/dev"
  bind_mounts+=("$MNT_DIR/dev")
  mount --bind /dev/pts "$MNT_DIR/dev/pts"
  bind_mounts+=("$MNT_DIR/dev/pts")
  mount -t proc proc "$MNT_DIR/proc"
  bind_mounts+=("$MNT_DIR/proc")
  mount -t sysfs sysfs "$MNT_DIR/sys"
  bind_mounts+=("$MNT_DIR/sys")
  mount -t tmpfs tmpfs "$MNT_DIR/run"
  bind_mounts+=("$MNT_DIR/run")
  if [[ -h "$MNT_DIR/dev/shm" ]]; then
    mkdir -p "$MNT_DIR/$(readlink "$MNT_DIR/dev/shm")"
  else
    mount -t tmpfs -o nosuid,nodev tmpfs "$MNT_DIR/dev/shm"
    bind_mounts+=("$MNT_DIR/dev/shm")
  fi
}

cleanup() {
  set +e
  if [[ -n "${bind_mounts[*]:-}" ]]; then
    for (( idx=${#bind_mounts[@]}-1 ; idx>=0 ; idx-- )); do
      umount -l "${bind_mounts[idx]}" 2>/dev/null
    done
  fi
  umount -l "$MNT_DIR" 2>/dev/null
  swapoff "$swap_part" 2>/dev/null
  losetup -d "$loopdev" 2>/dev/null
}

run_host_script() {
  local script_name="$1"
  bash "./${script_name}"
}

run_chroot_script() {
  local script_name="$1"
  local runner_path="$MNT_DIR/root/libero-ci"

  mkdir -p "$runner_path"
  cp "/workspace/${script_name}" "${runner_path}/${script_name}"
  chmod +x "${runner_path}/${script_name}"

  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'source /etc/profile' \
    'export LIBERO_AUTOMATION=1' \
    'cd /root/libero-ci' \
    "bash ./${script_name}" \
    > "${runner_path}/chroot-run.sh"
  chmod +x "${runner_path}/chroot-run.sh"

  sudo chroot "$MNT_DIR" /bin/bash /root/libero-ci/chroot-run.sh
}

finalize_sources() {
  mkdir -p "$CI_DIR"
  chown -R "$HOST_UID:$HOST_GID" "$CI_DIR" || true
}

install_dependencies

declare -A stage_scripts=(
  ["01"]="01Requirements"
  ["02"]="02Preparation"
  ["03"]="03CrossCompiler"
  ["04"]="04CrossCompilingTools"
  ["05"]="05PrepChrootEnv"
  ["06"]="06ChrootEnv"
  ["07"]="07AdditionalCrossCompilingTools"
  ["08"]="08BasicSystemSoftware"
  ["09"]="09SystemConfiguration"
  ["10"]="10MakingLiberoBootable"
  ["11"]="11MakeBootableISO"
)

script_name="${stage_scripts[$stage]:-}"
if [[ -z "$script_name" ]]; then
  echo "Unknown stage: $stage" >&2
  exit 1
fi

case "$stage" in
  "01")
    run_host_script "$script_name"
    exit 0
    ;;
  "02")
    mkdir -p /workspace/.ci
    truncate -s "$LIBERO_IMAGE_SIZE" "$IMAGE_PATH"
    ;;
  *)
    if [[ ! -f "$IMAGE_PATH" ]]; then
      echo "Disk image $IMAGE_PATH not found" >&2
      exit 1
    fi
    ;;
esac

attach_disk
trap cleanup EXIT

export DEVICE="$loopdev"
export LIBERO_AUTOMATION=1
export LIBERO_SOURCE_CACHE="$CI_DIR"
export LIBERO_CACHE_UID="$HOST_UID"
export LIBERO_CACHE_GID="$HOST_GID"
export LIBERO_ISO_OUTPUT="/workspace/${ISO_ARTIFACT_PATH:-artifacts/libero-server-edition.iso}"

if [[ "$stage" != "02" ]]; then
  mount_root
fi

if [[ "$stage" =~ ^0[3-9]$ || "$stage" =~ ^1[01]$ ]]; then
  enable_swap
fi

if [[ "$stage" =~ ^0[3-9]$ || "$stage" =~ ^1[01]$ ]]; then
  sudo partprobe "$loopdev"
  sleep 1
fi

if [[ "$stage" =~ ^0[6-9]$ || "$stage" == "10" ]]; then
  setup_chroot_mounts
  run_chroot_script "$script_name"
else
  run_host_script "$script_name"
fi

finalize_sources

if [[ "$stage" == "11" ]]; then
  iso_path="${ISO_ARTIFACT_PATH:-artifacts/libero-server-edition.iso}"
  chown "$HOST_UID:$HOST_GID" "/workspace/$iso_path" 2>/dev/null || true
fi
