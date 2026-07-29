#!/usr/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly FORGE_IP=192.168.50.179
readonly MAX_MINUTES=480
readonly AUTHORIZED=/boot/config/ssh/root/authorized_keys
readonly AUDIT_LOG=/boot/config/ssh/root/forge-agent-root-access.log
readonly EXPECTED_SELF=/boot/config/custom/forge-agent-access/forge/manage-unraid-agent-root.sh

readonly MARKER=forge-agent-unraid-root
readonly AUTHORIZED_LOCK="${AUTHORIZED}.forge-agent.lock"

usage() {
  /usr/bin/cat >&2 <<'EOF'
Usage:
  manage-unraid-agent-root.sh grant PUBLIC_KEY MINUTES TASK_ID REASON
  manage-unraid-agent-root.sh revoke TASK_ID REASON
  manage-unraid-agent-root.sh status

MINUTES must be 1-480. TASK_ID is an issue or task reference without spaces.
REASON is a quoted, single-line explanation.
EOF
  exit 2
}

[[ ${EUID} -eq 0 ]] || {
  echo "Run this helper as root on Arc/Unraid." >&2
  exit 1
}

validate_root_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] || {
    echo "Missing or unsafe regular file: ${path}" >&2
    exit 1
  }
  [[ "$(/usr/bin/stat -c '%U' "${path}")" == root ]] || {
    echo "File must be owned by root: ${path}" >&2
    exit 1
  }
  local mode
  mode="$(/usr/bin/stat -c '%a' "${path}")"
  (( (8#${mode} & 8#022) == 0 )) || {
    echo "File must not be writable by group/other: ${path}" >&2
    exit 1
  }
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

snapshot_public_key() {
  local source=$1
  local snapshot=$2
  local source_fd source_identity opened_identity final_identity
  local opened_owner opened_mode

  validate_root_file "${source}"
  exec {source_fd}<"${source}"
  source_identity="$(/usr/bin/stat -Lc '%d:%i' "${source}")"
  opened_identity="$(
    /usr/bin/stat -Lc '%d:%i' "/proc/self/fd/${source_fd}"
  )"
  opened_owner="$(
    /usr/bin/stat -Lc '%U' "/proc/self/fd/${source_fd}"
  )"
  opened_mode="$(
    /usr/bin/stat -Lc '%a' "/proc/self/fd/${source_fd}"
  )"
  [[ "${source_identity}" == "${opened_identity}" &&
     "${opened_owner}" == root &&
     ! -L "${source}" ]] || {
    echo "Public-key file changed while it was being opened." >&2
    exit 1
  }
  (( (8#${opened_mode} & 8#022) == 0 )) || {
    echo "Opened public-key file is group/world writable." >&2
    exit 1
  }

  /usr/bin/cat <&"${source_fd}" >"${snapshot}"
  final_identity="$(/usr/bin/stat -Lc '%d:%i' "${source}")"
  exec {source_fd}<&-
  [[ "${source_identity}" == "${final_identity}" &&
     ! -L "${source}" ]] || {
    echo "Public-key file changed while it was being snapshotted." >&2
    exit 1
  }
  /usr/bin/chown root:root "${snapshot}"
  /usr/bin/chmod 0600 "${snapshot}"
}

invoked_path="$(/usr/bin/readlink -m -- "${BASH_SOURCE[0]}")"
[[ "${invoked_path}" == "${EXPECTED_SELF}" &&
   ! -L "${EXPECTED_SELF}" ]] || {
  echo "Run only the protected helper: ${EXPECTED_SELF}" >&2
  exit 1
}
assert_safe_chain "${EXPECTED_SELF}"
assert_safe_chain "$(/usr/bin/dirname "${AUTHORIZED}")"

action="${1:-}"
shift || true

/usr/bin/install -d -o root -g root -m 0700 \
  "$(/usr/bin/dirname "${AUTHORIZED}")"
for protected_state in "${AUTHORIZED}" "${AUDIT_LOG}"; do
  if [[ -e "${protected_state}" || -L "${protected_state}" ]]; then
    validate_root_file "${protected_state}"
  fi
done
if [[ -e "${AUTHORIZED_LOCK}" ]]; then
  validate_root_file "${AUTHORIZED_LOCK}"
else
  ( umask 077; set -o noclobber; : >"${AUTHORIZED_LOCK}" ) 2>/dev/null || true
  validate_root_file "${AUTHORIZED_LOCK}"
fi
exec {authorized_lock_fd}<>"${AUTHORIZED_LOCK}"
/usr/bin/flock -x "${authorized_lock_fd}"

/usr/bin/touch "${AUTHORIZED}" "${AUDIT_LOG}"
/usr/bin/chown root:root "${AUTHORIZED}" "${AUDIT_LOG}"
/usr/bin/chmod 0600 "${AUTHORIZED}" "${AUDIT_LOG}"

log_event() {
  local event=$1
  local fingerprint=$2
  local expiry=$3
  local task_id=$4
  local reason=$5

  printf '%s event=%s fingerprint=%s source=%s expiry=%s task=%q reason=%q\n' \
    "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${event}" "${fingerprint}" "${FORGE_IP}" "${expiry}" \
    "${task_id}" "${reason}" >>"${AUDIT_LOG}"
  /usr/bin/logger -t forge-agent-root \
    "event=${event} fingerprint=${fingerprint} source=${FORGE_IP} expiry=${expiry} task=${task_id}"
}

remove_marked_entries() {
  local temporary
  temporary="$(/usr/bin/mktemp "${AUTHORIZED}.XXXXXX")"
  /usr/bin/grep -Ev " ${MARKER}$" \
    "${AUTHORIZED}" >"${temporary}" || true
  /usr/bin/chown root:root "${temporary}"
  /usr/bin/chmod 0600 "${temporary}"
  /usr/bin/mv -f -- "${temporary}" "${AUTHORIZED}"
}

case "${action}" in
  grant)
    [[ $# -eq 4 ]] || usage
    pubkey_file=$1
    minutes=$2
    task_id=$3
    reason=$4

    [[ "${minutes}" =~ ^[0-9]+$ ]] &&
      (( minutes >= 1 && minutes <= MAX_MINUTES )) || {
      echo "MINUTES must be between 1 and ${MAX_MINUTES}." >&2
      exit 2
    }
    [[ "${task_id}" =~ ^[A-Za-z0-9._:/#-]+$ ]] || {
      echo "TASK_ID contains unsupported characters." >&2
      exit 2
    }
    [[ -n "${reason}" && "${reason}" != *$'\n'* ]] || {
      echo "REASON must be a non-empty single line." >&2
      exit 2
    }
    key_snapshot="$(/usr/bin/mktemp /tmp/forge-agent-root-key.XXXXXX)"
    trap '/usr/bin/rm -f -- "${key_snapshot}"' EXIT
    snapshot_public_key "${pubkey_file}" "${key_snapshot}"

    [[ "$(/usr/bin/grep -cve '^[[:space:]]*$' "${key_snapshot}")" -eq 1 ]]
    read -r key_type key_body key_comment <"${key_snapshot}"
    [[ "${key_type}" == ssh-ed25519 ]]
    [[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
    [[ "${key_comment}" == "${MARKER}" ]]

    fingerprint="$(
      /usr/bin/ssh-keygen -lf "${key_snapshot}" |
        /usr/bin/awk '{print $2}'
    )"
    [[ "${fingerprint}" == SHA256:* ]]
    expiry="$(
      /usr/bin/date -u -d "+${minutes} minutes" +%Y%m%d%H%M%SZ
    )"
    entry='from="'"${FORGE_IP}"'",restrict,expiry-time="'"${expiry}"'" ssh-ed25519 '"${key_body}"' '"${MARKER}"

    remove_marked_entries
    [[ ! -s "${AUTHORIZED}" ]] || printf '\n' >>"${AUTHORIZED}"
    printf '%s\n' "${entry}" >>"${AUTHORIZED}"
    log_event grant "${fingerprint}" "${expiry}" "${task_id}" "${reason}"
    /usr/bin/rm -f -- "${key_snapshot}"
    trap - EXIT
    printf 'Granted %s until %s UTC for %s.\n' \
      "${fingerprint}" "${expiry}" "${task_id}"
    ;;

  revoke)
    [[ $# -eq 2 ]] || usage
    task_id=$1
    reason=$2
    [[ "${task_id}" =~ ^[A-Za-z0-9._:/#-]+$ ]] || usage
    [[ -n "${reason}" && "${reason}" != *$'\n'* ]] || usage

    current_entry="$(
      /usr/bin/grep -E " ${MARKER}$" "${AUTHORIZED}" || true
    )"
    if [[ -n "${current_entry}" ]]; then
      key_type="$(
        /usr/bin/awk '{print $(NF-2)}' <<<"${current_entry}"
      )"
      key_body="$(
        /usr/bin/awk '{print $(NF-1)}' <<<"${current_entry}"
      )"
      key_file="$(/usr/bin/mktemp /tmp/forge-agent-root-key.XXXXXX)"
      trap '/usr/bin/rm -f -- "${key_file}"' EXIT
      printf '%s %s %s\n' \
        "${key_type}" "${key_body}" "${MARKER}" >"${key_file}"
      fingerprint="$(
        /usr/bin/ssh-keygen -lf "${key_file}" |
          /usr/bin/awk '{print $2}'
      )"
      /usr/bin/rm -f -- "${key_file}"
      trap - EXIT
    else
      fingerprint=none
    fi
    remove_marked_entries
    log_event revoke "${fingerprint}" none "${task_id}" "${reason}"
    printf 'Revoked marked Forge agent root access (%s).\n' \
      "${fingerprint}"
    ;;

  status)
    [[ $# -eq 0 ]] || usage
    if /usr/bin/grep -qE " ${MARKER}$" "${AUTHORIZED}"; then
      /usr/bin/grep -E " ${MARKER}$" "${AUTHORIZED}" |
        /usr/bin/sed -E \
          's/(ssh-ed25519 )[A-Za-z0-9+/=]+/\1<redacted>/'
    else
      echo "No marked Forge agent root entry is installed."
    fi
    ;;

  *)
    usage
    ;;
esac
