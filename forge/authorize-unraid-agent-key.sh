#!/usr/bin/env bash
set -Eeuo pipefail

FORGE_IP=192.168.50.179
REPO=/mnt/user/appdata/unraid-docker-lab
rotate=false

if [[ ${1:-} == --rotate ]]; then
  rotate=true
  shift
fi
PUBKEY_FILE="${1:?Usage: authorize-unraid-agent-key.sh [--rotate] /path/to/public-key}"
[[ $# -eq 1 ]] || {
  echo "Usage: authorize-unraid-agent-key.sh [--rotate] /path/to/public-key" >&2
  exit 2
}
AUTHORIZED=/boot/config/ssh/root/authorized_keys
WRAPPER="${REPO}/forge/unraid-readonly-wrapper.sh"

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
  [[ "$(stat -c '%U' "${path}")" == root ]] || {
    echo "File must be owned by root: ${path}" >&2
    exit 1
  }
  local mode
  mode="$(stat -c '%a' "${path}")"
  (( (8#${mode} & 8#022) == 0 )) || {
    echo "File must not be writable by group/other: ${path}" >&2
    exit 1
  }
}

validate_root_file "${PUBKEY_FILE}"
validate_root_file "${WRAPPER}"
[[ -x "${WRAPPER}" ]] || {
  echo "Forced-command wrapper is not executable: ${WRAPPER}" >&2
  exit 1
}

[[ "$(grep -cve '^[[:space:]]*$' "${PUBKEY_FILE}")" -eq 1 ]]
read -r key_type key_body key_comment <"${PUBKEY_FILE}"
[[ "${key_type}" == ssh-ed25519 ]]
[[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
[[ "${key_comment}" == forge-codex-unraid-readonly ]]

fingerprint="$(ssh-keygen -lf "${PUBKEY_FILE}" | awk '{print $2}')"
[[ "${fingerprint}" == SHA256:* ]]

entry='from="'"${FORGE_IP}"'",restrict,command="'"${WRAPPER}"'" ssh-ed25519 '"${key_body}"' forge-codex-unraid-readonly'
expected_options='from="'"${FORGE_IP}"'",restrict,command="'"${WRAPPER}"'"'

install -d -o root -g root -m 0700 "$(dirname "${AUTHORIZED}")"
touch "${AUTHORIZED}"
chown root:root "${AUTHORIZED}"
chmod 0600 "${AUTHORIZED}"

mapfile -t marked_entries < <(
  grep -E ' forge-codex-unraid-readonly$' "${AUTHORIZED}" || true
)

if grep -qF -- "${key_body}" "${AUTHORIZED}"; then
  grep -qxF -- "${entry}" "${AUTHORIZED}" || {
    echo "The Forge key already exists with unexpected restrictions." >&2
    exit 1
  }
else
  old_entry=
  if [[ "${#marked_entries[@]}" -gt 0 ]]; then
    [[ "${#marked_entries[@]}" -eq 1 ]] || {
      echo "Multiple marked Forge codex keys exist; review them manually." >&2
      exit 1
    }
    old_entry="${marked_entries[0]}"
    read -r old_options old_type old_body old_comment <<<"${old_entry}"
    [[ "${old_options}" == "${expected_options}" &&
       "${old_type}" == ssh-ed25519 &&
       "${old_body}" =~ ^[A-Za-z0-9+/=]+$ &&
       "${old_comment}" == forge-codex-unraid-readonly ]] || {
      echo "The existing marked Forge key has unsafe restrictions." >&2
      exit 1
    }
    [[ "${rotate}" == true ]] || {
      echo "A different Forge codex key exists; rerun with --rotate after review." >&2
      exit 1
    }
  fi

  temporary="$(mktemp "${AUTHORIZED}.XXXXXX")"
  old_key_file="$(mktemp /tmp/forge-codex-old-key.XXXXXX)"
  trap 'rm -f -- "${temporary}" "${old_key_file}"' EXIT
  if [[ -n "${old_entry}" ]]; then
    grep -vxF -- "${old_entry}" "${AUTHORIZED}" >"${temporary}" || true
    printf 'ssh-ed25519 %s forge-codex-unraid-readonly\n' \
      "${old_body}" >"${old_key_file}"
    old_fingerprint="$(
      ssh-keygen -lf "${old_key_file}" | awk '{print $2}'
    )"
  else
    cat "${AUTHORIZED}" >"${temporary}"
    old_fingerprint=none
  fi
  [[ ! -s "${temporary}" ]] || printf '\n' >>"${temporary}"
  printf '%s\n' "${entry}" >>"${temporary}"
  chown root:root "${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${AUTHORIZED}"
  rm -f -- "${old_key_file}"
  trap - EXIT
  printf 'Previous marked fingerprint: %s\n' "${old_fingerprint}"
fi

printf 'Authorized %s from %s through %s\n' \
  "${fingerprint}" "${FORGE_IP}" "${WRAPPER}"
