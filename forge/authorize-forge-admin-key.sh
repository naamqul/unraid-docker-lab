#!/usr/bin/env bash
set -Eeuo pipefail

: "${FORGE_IP:=192.168.50.179}"
: "${AUTHORIZED_KEYS:=/boot/config/ssh/root/authorized_keys}"

readonly CURRENT_MARKER=forge-admin@forge

PUBKEY_FILE="${1:?Usage: authorize-forge-admin-key.sh /path/to/public-key}"
[[ $# -eq 1 ]] || {
  echo "Usage: authorize-forge-admin-key.sh /path/to/public-key" >&2
  exit 2
}
[[ ${EUID} -eq 0 ]] || {
  echo "Run this helper as root on Arc/Unraid." >&2
  exit 1
}
[[ -f "${PUBKEY_FILE}" && ! -L "${PUBKEY_FILE}" ]] || {
  echo "Public key must be a regular, non-symlink file." >&2
  exit 1
}
mode="$(stat -c '%a' "${PUBKEY_FILE}")"
(( (8#${mode} & 8#022) == 0 )) || {
  echo "Public key must not be writable by group or other." >&2
  exit 1
}
[[ "$(grep -cve '^[[:space:]]*$' "${PUBKEY_FILE}")" -eq 1 ]]

read -r key_type key_body key_comment <"${PUBKEY_FILE}"
[[ "${key_type}" == ssh-ed25519 ]]
[[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
[[ "${key_comment}" == "${CURRENT_MARKER}" ]] || {
  echo "Expected public-key comment: ${CURRENT_MARKER}" >&2
  exit 1
}
fingerprint="$(ssh-keygen -lf "${PUBKEY_FILE}" | awk '{print $2}')"
[[ "${fingerprint}" == SHA256:* ]]
entry="from=\"${FORGE_IP}\" ssh-ed25519 ${key_body} ${CURRENT_MARKER}"

install -d -o root -g root -m 0700 "$(dirname "${AUTHORIZED_KEYS}")"
if [[ ! -e "${AUTHORIZED_KEYS}" ]]; then
  install -o root -g root -m 0600 /dev/null "${AUTHORIZED_KEYS}"
fi
[[ -f "${AUTHORIZED_KEYS}" && ! -L "${AUTHORIZED_KEYS}" ]]

# Refuse to leave the same key installed under an unmarked, less restrictive
# entry. Only entries carrying a known Forge marker are ever removed.
if awk -v body="${key_body}" \
  -v current="${CURRENT_MARKER}" '
    index($0, body) &&
    $NF != current { found = 1 }
    END { exit !found }
  ' "${AUTHORIZED_KEYS}"; then
  echo "The Forge key body already has an unmarked authorized_keys entry." >&2
  exit 1
fi

if [[ "$(grep -cFx -- "${entry}" "${AUTHORIZED_KEYS}")" -eq 1 &&
      "$(awk -v current="${CURRENT_MARKER}" '$NF == current { count++ } END { print count + 0 }' \
        "${AUTHORIZED_KEYS}")" -eq 1 ]]; then
  printf 'Already authorized %s from %s.\n' "${fingerprint}" "${FORGE_IP}"
  exit 0
fi

backup="$(mktemp \
  "${AUTHORIZED_KEYS}.forge-backup.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
install -o root -g root -m 0600 "${AUTHORIZED_KEYS}" "${backup}"

temporary="$(mktemp "${AUTHORIZED_KEYS}.XXXXXX")"
trap 'rm -f -- "${temporary}"' EXIT
awk -v current="${CURRENT_MARKER}" \
  '$NF != current { print }' \
  "${AUTHORIZED_KEYS}" >"${temporary}"
[[ ! -s "${temporary}" ]] || printf '\n' >>"${temporary}"
printf '%s\n' "${entry}" >>"${temporary}"
chown root:root "${temporary}"
chmod 0600 "${temporary}"
mv -f -- "${temporary}" "${AUTHORIZED_KEYS}"
trap - EXIT

[[ "$(stat -c '%U:%G %a' "${AUTHORIZED_KEYS}")" == "root:root 600" ]]
[[ "$(grep -cFx -- "${entry}" "${AUTHORIZED_KEYS}")" -eq 1 ]]
ssh-keygen -lf "${AUTHORIZED_KEYS}" >/dev/null

printf '%s\n' \
  "Authorized ${fingerprint} for unrestricted root SSH from ${FORGE_IP} only." \
  "Backup: ${backup}"
