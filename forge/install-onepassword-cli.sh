#!/usr/bin/env bash
set -Eeuo pipefail

readonly EXPECTED_FINGERPRINT=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
readonly KEY_URL=https://downloads.1password.com/linux/keys/1password.asc
readonly POLICY_URL=https://downloads.1password.com/linux/debian/debsig/1password.pol
readonly KEYRING=/usr/share/keyrings/1password-archive-keyring.gpg
readonly SOURCE_LIST=/etc/apt/sources.list.d/1password.list
readonly POLICY_DIR=/etc/debsig/policies/AC2D62742012EA22
readonly DEBSIG_KEY_DIR=/usr/share/debsig/keyrings/AC2D62742012EA22

[[ ${EUID} -eq 0 ]] || {
  echo "Run this installer as root on Forge." >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
temporary_key="$(mktemp /tmp/1password-key.XXXXXX)"
trap 'rm -f -- "${temporary_key}"' EXIT

curl -fsS "${KEY_URL}" -o "${temporary_key}"
fingerprint="$(
  gpg --show-keys --with-colons "${temporary_key}" |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
[[ "${fingerprint}" == "${EXPECTED_FINGERPRINT}" ]] || {
  echo "Unexpected 1Password repository key fingerprint." >&2
  exit 1
}

gpg --dearmor --yes --output "${KEYRING}" "${temporary_key}"
architecture="$(dpkg --print-architecture)"
printf '%s\n' \
  "deb [arch=${architecture} signed-by=${KEYRING}] https://downloads.1password.com/linux/debian/${architecture} stable main" \
  >"${SOURCE_LIST}"

install -d -o root -g root -m 0755 "${POLICY_DIR}" "${DEBSIG_KEY_DIR}"
curl -fsS "${POLICY_URL}" -o "${POLICY_DIR}/1password.pol"
gpg --dearmor --yes \
  --output "${DEBSIG_KEY_DIR}/debsig.gpg" \
  "${temporary_key}"

apt-get update
apt-get install -y 1password-cli

printf 'Installed 1Password CLI %s.\n' "$(op --version)"
printf '%s\n' \
  "No account, vault, item, or service-account token was configured." \
  "Follow the canonical credential runbook before provisioning access."
