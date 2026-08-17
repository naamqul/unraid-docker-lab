#!/bin/sh
# Host-side, single-service memory guard for an approved Qwen3.8 benchmark run.

set -u

usage() {
  printf 'Usage: %s SERVICE ABORT_FILE [MIN_FREE_GIB]\n' "$0" >&2
  exit 64
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

service=$1
abort_file=$2
min_free_gib=${3:-${MIN_FREE_GIB:-8}}

case "$service" in
  qwen38-upstream|qwen38-sycl|qwen38-vulkan|qwen38-ik|qwen38-openvino-262k-vision|qwen38-openvino-262k-text|qwen38-openvino-131k-vision|qwen38-openvino-131k-text|qwen38-openvino-gpu-262k-text|qwen38-openvino-gpu-131k-text|qwen38-openvino-gpu-262k-mtp1|qwen38-openvino-gpu-131k-mtp1|qwen38-openvino-gpu-262k-vision|qwen38-openvino-gpu-131k-vision|qwen38-openvino-f16-cpu-131k-text|qwen38-openvino-q8-cpukv-cpu-131k-text|qwen38-openvino-f16-gpu-131k-text|qwen38-ovms-int8-cpu-131k|qwen38-ovms-int8-gpu-131k|qwen38-ovms-int8-cpu-262k|qwen38-ovms-int8-gpu-262k|qwen38-ovms-int8-npu-1k)
    ;;
  *)
    printf 'Refusing unknown service: %s\n' "$service" >&2
    exit 64
    ;;
esac

case "$abort_file" in
  /*) ;;
  *)
    printf 'ABORT_FILE must be an absolute path.\n' >&2
    exit 64
    ;;
esac

if [ -e "$abort_file" ] || [ -L "$abort_file" ]; then
  printf 'Refusing to start because ABORT_FILE already exists: %s\n' "$abort_file" >&2
  exit 65
fi

abort_parent=${abort_file%/*}
[ -n "$abort_parent" ] || abort_parent=/
if [ ! -d "$abort_parent" ] || [ ! -w "$abort_parent" ]; then
  printf 'ABORT_FILE parent must already exist and be writable: %s\n' "$abort_parent" >&2
  exit 73
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'docker is unavailable; refusing to run without the Komodo stop path.\n' >&2
  exit 69
fi

threshold_kib=$(awk -v gib="$min_free_gib" 'BEGIN {
  if (gib !~ /^[0-9]+([.][0-9]+)?$/ || gib <= 0) exit 1
  printf "%.0f", gib * 1024 * 1024
}') || {
  printf 'MIN_FREE_GIB must be a positive number: %s\n' "$min_free_gib" >&2
  exit 64
}

read_available_kib() {
  awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo
}

if ! available_kib=$(read_available_kib); then
  printf 'MemAvailable is unavailable; refusing to run an unguarded load.\n' >&2
  exit 69
fi

printf 'Watching MemAvailable every second for %s; threshold=%s GiB; abort=%s\n' \
  "$service" "$min_free_gib" "$abort_file"

trap 'printf "Safety watch interrupted; no service action taken.\n" >&2; exit 130' INT TERM HUP

while :; do
  if ! available_kib=$(read_available_kib); then
    printf 'MemAvailable became unreadable; touching abort file and stopping only %s.\n' "$service" >&2
    available_kib=0
  fi

  if [ "$available_kib" -lt "$threshold_kib" ]; then
    printf 'Memory floor crossed (%s KiB < %s KiB); aborting and stopping only %s.\n' \
      "$available_kib" "$threshold_kib" "$service" >&2
    if ! touch -- "$abort_file"; then
      printf 'Warning: could not touch abort file; continuing with the scoped Komodo stop.\n' >&2
    fi
    docker exec komodo km execute -y stop-stack ai 10 "$service"
    status=$?
    if [ "$status" -ne 0 ]; then
      printf 'Komodo failed to stop %s (status %s). No broader stop was attempted.\n' \
        "$service" "$status" >&2
    fi
    exit "$status"
  fi

  sleep 1
done
