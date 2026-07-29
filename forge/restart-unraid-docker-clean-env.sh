#!/usr/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly STOCK_RESTART=/etc/rc.d/rc.docker
readonly REQUIRED_CONFIRMATION=all-containers-will-restart
readonly EXPECTED_SELF=/boot/config/custom/forge-agent-access/forge/restart-unraid-docker-clean-env.sh

usage() {
  /usr/bin/cat >&2 <<'EOF'
Usage:
  restart-unraid-docker-clean-env.sh restart all-containers-will-restart

This performs a stock Unraid Docker restart with XDG_RUNTIME_DIR and
DBUS_SESSION_BUS_ADDRESS removed from the rc.docker environment. Every
container will stop and restart. Schedule downtime before running it.

The helper does not patch rc.docker or install persistent environment changes.
EOF
  exit 2
}

assert_safe_chain() {
  local requested=$1
  local current=/
  local component owner mode normalized
  normalized="$(/usr/bin/readlink -m -- "${requested}")"
  [[ "${normalized}" == "${requested}" ]] || {
    echo "Path is not normalized: ${requested}" >&2
    exit 1
  }
  IFS=/ read -r -a components <<<"${requested#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -e "${current}" && ! -L "${current}" ]] || {
      echo "Missing or symlinked protected path: ${current}" >&2
      exit 1
    }
    owner="$(/usr/bin/stat -Lc '%U:%G' "${current}")"
    mode="$(/usr/bin/stat -Lc '%a' "${current}")"
    [[ "${owner}" == root:root ]] || {
      echo "Non-root owner in protected path: ${current}" >&2
      exit 1
    }
    (( (8#${mode} & 8#022) == 0 )) || {
      echo "Group/world-writable protected path: ${current}" >&2
      exit 1
    }
  done
}

[[ "${EUID}" -eq 0 ]] || {
  echo "Run this helper as root on Arc/Unraid." >&2
  exit 1
}
invoked_path="$(/usr/bin/readlink -m -- "${BASH_SOURCE[0]}")"
[[ "${invoked_path}" == "${EXPECTED_SELF}" &&
   ! -L "${EXPECTED_SELF}" ]] || {
  echo "Run only the protected helper: ${EXPECTED_SELF}" >&2
  exit 1
}
assert_safe_chain "${EXPECTED_SELF}"
[[ "${1:-}" == restart &&
   "${2:-}" == "${REQUIRED_CONFIRMATION}" &&
   "$#" -eq 2 ]] || usage
[[ -f "${STOCK_RESTART}" && ! -L "${STOCK_RESTART}" &&
   -x "${STOCK_RESTART}" ]] || {
  echo "Missing or unsafe stock Docker restart script: ${STOCK_RESTART}" >&2
  exit 1
}
[[ "$(/usr/bin/stat -c '%U:%G' "${STOCK_RESTART}")" == root:root ]] || {
  echo "Unexpected owner for ${STOCK_RESTART}." >&2
  exit 1
}
stock_mode="$(/usr/bin/stat -c '%a' "${STOCK_RESTART}")"
(( (8#${stock_mode} & 8#022) == 0 )) || {
  echo "${STOCK_RESTART} must not be group/world writable." >&2
  exit 1
}

/usr/bin/cat >&2 <<'EOF'
WARNING: restarting Unraid Docker now; every container will be unavailable.
The stock rc.docker script is invoked without XDG_RUNTIME_DIR or D-Bus session
state. No stock script or persistent boot configuration is modified.
EOF

/usr/bin/logger -t forge-docker-restart \
  'event=restart-clean-environment requested_by=root'
/usr/bin/env \
  -u XDG_RUNTIME_DIR \
  -u DBUS_SESSION_BUS_ADDRESS \
  /etc/rc.d/rc.docker restart

verify_process_environment() {
  local process_name=$1
  local found=0
  local pid

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    found=1
    if /usr/bin/tr '\0' '\n' <"/proc/${pid}/environ" |
       /usr/bin/grep -Eq '^(XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)='
    then
      echo "${process_name} pid ${pid} retained a login-session variable." >&2
      return 1
    fi
  done < <(/usr/bin/pgrep -x "${process_name}" || true)

  [[ "${found}" -eq 1 ]] || {
    echo "No ${process_name} process was found after restart." >&2
    return 1
  }
}

verify_shim_environments() {
  local found=0
  local pid

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    found=1
    if /usr/bin/tr '\0' '\n' <"/proc/${pid}/environ" |
       /usr/bin/grep -Eq \
         '^(XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)='
    then
      echo "containerd-shim-runc-v2 pid ${pid} retained a login-session variable." >&2
      return 1
    fi
  done < <(
    /usr/bin/pgrep -f \
      '^/usr/bin/containerd-shim-runc-v2( |$)' || true
  )

  [[ "${found}" -eq 1 ]] || {
    echo "No containerd-shim-runc-v2 process was found after restart." >&2
    return 1
  }
}

verify_process_environment dockerd
verify_process_environment containerd
verify_shim_environments
/usr/bin/docker info >/dev/null
/usr/bin/docker ps --format '{{.Names}}' >/dev/null

/usr/bin/logger -t forge-docker-restart \
  'event=restart-clean-environment-verified dockerd=clean containerd=clean shims=clean'
echo "Docker restarted and verified without login-session variables."
