#!/usr/bin/env bash
set -Eeuo pipefail

: "${FORGE_IP:=192.168.50.179}"
: "${MAX_MINUTES:=480}"
: "${AUTHORIZED:=/boot/config/ssh/root/authorized_keys}"
: "${AUDIT_LOG:=/boot/config/ssh/root/forge-agent-root-access.log}"

MARKER=forge-agent-unraid-root

usage() {
  cat >&2 <<'EOF'
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

action="${1:-}"
shift || true

install -d -o root -g root -m 0700 "$(dirname "${AUTHORIZED}")"
touch "${AUTHORIZED}" "${AUDIT_LOG}"
chown root:root "${AUTHORIZED}" "${AUDIT_LOG}"
chmod 0600 "${AUTHORIZED}" "${AUDIT_LOG}"

log_event() {
  local event=$1
  local fingerprint=$2
  local expiry=$3
  local task_id=$4
  local reason=$5

  printf '%s event=%s fingerprint=%s source=%s expiry=%s task=%q reason=%q\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${event}" "${fingerprint}" "${FORGE_IP}" "${expiry}" \
    "${task_id}" "${reason}" >>"${AUDIT_LOG}"
  logger -t forge-agent-root \
    "event=${event} fingerprint=${fingerprint} source=${FORGE_IP} expiry=${expiry} task=${task_id}"
}

remove_marked_entries() {
  local temporary
  temporary="$(mktemp "${AUTHORIZED}.XXXXXX")"
  grep -Ev " ${MARKER}$" "${AUTHORIZED}" >"${temporary}" || true
  chown root:root "${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${AUTHORIZED}"
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
    [[ -f "${pubkey_file}" && ! -L "${pubkey_file}" ]]
    [[ "$(grep -cve '^[[:space:]]*$' "${pubkey_file}")" -eq 1 ]]
    read -r key_type key_body key_comment <"${pubkey_file}"
    [[ "${key_type}" == ssh-ed25519 ]]
    [[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
    [[ "${key_comment}" == "${MARKER}" ]]

    fingerprint="$(ssh-keygen -lf "${pubkey_file}" | awk '{print $2}')"
    expiry="$(
      date -u -d "+${minutes} minutes" +%Y%m%d%H%M%SZ
    )"
    entry='from="'"${FORGE_IP}"'",restrict,expiry-time="'"${expiry}"'" ssh-ed25519 '"${key_body}"' '"${MARKER}"

    remove_marked_entries
    [[ ! -s "${AUTHORIZED}" ]] || printf '\n' >>"${AUTHORIZED}"
    printf '%s\n' "${entry}" >>"${AUTHORIZED}"
    log_event grant "${fingerprint}" "${expiry}" "${task_id}" "${reason}"
    printf 'Granted %s until %s UTC for %s.\n' \
      "${fingerprint}" "${expiry}" "${task_id}"
    ;;

  revoke)
    [[ $# -eq 2 ]] || usage
    task_id=$1
    reason=$2
    [[ "${task_id}" =~ ^[A-Za-z0-9._:/#-]+$ ]] || usage
    [[ -n "${reason}" && "${reason}" != *$'\n'* ]] || usage

    current_entry="$(grep -E " ${MARKER}$" "${AUTHORIZED}" || true)"
    if [[ -n "${current_entry}" ]]; then
      key_type="$(awk '{print $(NF-2)}' <<<"${current_entry}")"
      key_body="$(awk '{print $(NF-1)}' <<<"${current_entry}")"
      key_file="$(mktemp /tmp/forge-agent-root-key.XXXXXX)"
      trap 'rm -f -- "${key_file}"' EXIT
      printf '%s %s %s\n' \
        "${key_type}" "${key_body}" "${MARKER}" >"${key_file}"
      fingerprint="$(ssh-keygen -lf "${key_file}" | awk '{print $2}')"
      rm -f -- "${key_file}"
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
    if grep -qE " ${MARKER}$" "${AUTHORIZED}"; then
      grep -E " ${MARKER}$" "${AUTHORIZED}" |
        sed -E 's/(ssh-ed25519 )[A-Za-z0-9+/=]+/\1<redacted>/'
    else
      echo "No marked Forge agent root entry is installed."
    fi
    ;;

  *)
    usage
    ;;
esac
