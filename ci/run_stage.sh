#!/bin/bash
set -euo pipefail

stage="${1:?stage number required}"
ROOTFS_BASE="${ROOTFS_BASE:-/workspace/rootfs}"
LIBERO_PATH="/mnt/libero"
SOURCE_CACHE="/workspace/cache/sources"
ISO_OUTPUT="/workspace/${ISO_ARTIFACT_PATH:-artifacts/libero-server-edition.iso}"
COMMON_APT_PACKAGES_DEFAULT="build-essential binutils bison gawk texinfo xz-utils m4 python3 python3-distutils python3-setuptools perl tar patch diffutils findutils gzip sed grep coreutils git curl wget rsync parted xorriso sudo ca-certificates udev proot"
COMMON_APT_PACKAGES="${COMMON_APT_PACKAGES:-$COMMON_APT_PACKAGES_DEFAULT}"
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"
USE_PROOT="${USE_PROOT:-1}"
PROOT_BIN="${PROOT_BIN:-proot}"

install_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $COMMON_APT_PACKAGES
  apt-get clean
}

setup_rootfs() {
  if [[ "$stage" == "02" ]]; then
    rm -rf "$ROOTFS_BASE"
  fi
  mkdir -p "$ROOTFS_BASE"
  rm -rf "$LIBERO_PATH"
  ln -s "$ROOTFS_BASE" "$LIBERO_PATH"
}

export_environment() {
  export LIBERO_AUTOMATION=1
  export LIBERO_SKIP_PARTITIONS=1
  export LIBERO_SOURCE_CACHE="$SOURCE_CACHE"
  export LIBERO_CACHE_UID="$HOST_UID"
  export LIBERO_CACHE_GID="$HOST_GID"
  export LIBERO_ISO_OUTPUT="$ISO_OUTPUT"
  export LIBERO_USE_PROOT="$USE_PROOT"
}

setup_chroot_mounts() {
  bind_targets=(
    "$LIBERO_PATH/dev"
    "$LIBERO_PATH/dev/pts"
    "$LIBERO_PATH/proc"
    "$LIBERO_PATH/sys"
    "$LIBERO_PATH/run"
  )

  mkdir -p "$LIBERO_PATH/dev" "$LIBERO_PATH/dev/pts" "$LIBERO_PATH/proc" \
           "$LIBERO_PATH/sys" "$LIBERO_PATH/run"

  mount --bind /dev "$LIBERO_PATH/dev"
  mount --bind /dev/pts "$LIBERO_PATH/dev/pts"
  mount -t proc proc "$LIBERO_PATH/proc"
  mount -t sysfs sysfs "$LIBERO_PATH/sys"
  mount -t tmpfs tmpfs "$LIBERO_PATH/run"

  if [[ -h "$LIBERO_PATH/dev/shm" ]]; then
    mkdir -p "$LIBERO_PATH/$(readlink "$LIBERO_PATH/dev/shm")"
  else
    mount -t tmpfs -o nosuid,nodev tmpfs "$LIBERO_PATH/dev/shm"
    bind_targets+=("$LIBERO_PATH/dev/shm")
  fi
}

teardown_mounts() {
  local targets=(
    "$LIBERO_PATH/dev/shm"
    "$LIBERO_PATH/dev/pts"
    "$LIBERO_PATH/dev"
    "$LIBERO_PATH/proc"
    "$LIBERO_PATH/sys"
    "$LIBERO_PATH/run"
  )
  for target in "${targets[@]}"; do
    umount -l "$target" 2>/dev/null || true
  done
}

run_host_script() {
  bash "./${1}"
}

run_chroot_script() {
  local script_name="$1"
  local runner_path="$LIBERO_PATH/root/libero-ci"

  mkdir -p "$runner_path"
  cp "/workspace/${script_name}" "$runner_path/${script_name}"
  chmod +x "$runner_path/${script_name}"

  local quoted_script
  quoted_script=$(printf '%q' "./${script_name}")
  local chroot_command="set -euo pipefail; source /etc/profile; export LIBERO_AUTOMATION=1; cd /root/libero-ci; bash ${quoted_script}"

  if [[ "$USE_PROOT" == "1" ]]; then
    local proot_args=("$PROOT_BIN" -0 -r "$LIBERO_PATH" -w /root/libero-ci)
    local proot_binds=("/proc" "/sys" "/dev" "/dev/pts" "/run" "/tmp")

    for bind_path in "${proot_binds[@]}"; do
      if [[ -e "$bind_path" ]]; then
        proot_args+=(-b "${bind_path}")
      fi
    done

    "${proot_args[@]}" /bin/bash -lc "$chroot_command"
  else
    setup_chroot_mounts
    sudo chroot "$LIBERO_PATH" /bin/bash -lc "$chroot_command"
    teardown_mounts
  fi
}

finalize_sources() {
  mkdir -p "$SOURCE_CACHE"
  chown -R "$HOST_UID:$HOST_GID" "$SOURCE_CACHE" || true
}

install_dependencies
setup_rootfs
export_environment

case "$stage" in
  "01")
    run_host_script "01Requirements"
    finalize_sources
    exit 0
    ;;
  "02")
    run_host_script "02Preparation"
    finalize_sources
    exit 0
    ;;
  "03") stage_script="03CrossCompiler" ;;
  "04") stage_script="04CrossCompilingTools" ;;
  "05") stage_script="05PrepChrootEnv" ;;
  "06") stage_script="06ChrootEnv" ;;
  "07") stage_script="07AdditionalCrossCompilingTools" ;;
  "08") stage_script="08BasicSystemSoftware" ;;
  "09") stage_script="09SystemConfiguration" ;;
  "10") stage_script="10MakingLiberoBootable" ;;
  "11") stage_script="11MakeBootableISO" ;;
  *)
    echo "Unknown stage: $stage" >&2
    exit 1
    ;;
esac

if [[ "$stage" =~ ^0[6-9]$ || "$stage" == "10" ]]; then
  run_chroot_script "$stage_script"
else
  run_host_script "$stage_script"
  if [[ "$stage" == "05" && "$USE_PROOT" != "1" ]]; then
    teardown_mounts
  fi
fi

finalize_sources

if [[ "$stage" == "11" ]]; then
  chown "$HOST_UID:$HOST_GID" "$ISO_OUTPUT" 2>/dev/null || true
fi
