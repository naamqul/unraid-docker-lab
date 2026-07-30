#!/usr/bin/env bash
set -Eeuo pipefail

readonly EXPECTED_FINGERPRINT=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
readonly KEY_URL=https://downloads.1password.com/linux/keys/1password.asc
readonly POLICY_URL=https://downloads.1password.com/linux/debian/debsig/1password.pol
readonly KEYRING=/usr/share/keyrings/1password-archive-keyring.gpg
readonly SOURCE_LIST=/etc/apt/sources.list.d/1password.list
readonly POLICY_DIR=/etc/debsig/policies/AC2D62742012EA22
readonly DEBSIG_KEY_DIR=/usr/share/debsig/keyrings/AC2D62742012EA22
: "${ADMIN_USER:=luqmaan}"
: "${SERVICE_TOKEN_SOURCE:=/tmp/forge-op-service-account-token}"

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

ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
ADMIN_GROUP="$(id -gn "${ADMIN_USER}")"
[[ -d "${ADMIN_HOME}" && ! -L "${ADMIN_HOME}" ]]
[[ -f "${SERVICE_TOKEN_SOURCE}" && ! -L "${SERVICE_TOKEN_SOURCE}" ]] || {
  echo "Missing staged service-account token: ${SERVICE_TOKEN_SOURCE}" >&2
  exit 1
}
[[ "$(stat -c '%a' "${SERVICE_TOKEN_SOURCE}")" == 600 ]] || {
  echo "The staged service-account token must be mode 0600." >&2
  exit 1
}
[[ "$(grep -cve '^[[:space:]]*$' "${SERVICE_TOKEN_SOURCE}")" -eq 1 ]] || {
  echo "The staged service-account token must contain exactly one value." >&2
  exit 1
}

OP_CONFIG_DIR="${ADMIN_HOME}/.config/1password"
OP_TOKEN_FILE="${OP_CONFIG_DIR}/service-account-token"
OP_WRAPPER="${ADMIN_HOME}/.local/bin/op"
install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0700 \
  "${OP_CONFIG_DIR}" "${ADMIN_HOME}/.local/bin"
install -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0600 \
  "${SERVICE_TOKEN_SOURCE}" "${OP_TOKEN_FILE}"
rm -f -- "${SERVICE_TOKEN_SOURCE}"

temporary_wrapper="$(mktemp "${OP_WRAPPER}.XXXXXX")"
cat >"${temporary_wrapper}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly TOKEN_FILE="${HOME}/.config/1password/service-account-token"
[[ -f "${TOKEN_FILE}" && ! -L "${TOKEN_FILE}" ]]
[[ "$(stat -c '%a' "${TOKEN_FILE}")" == 600 ]]
IFS= read -r OP_SERVICE_ACCOUNT_TOKEN <"${TOKEN_FILE}"
[[ -n "${OP_SERVICE_ACCOUNT_TOKEN}" ]]
export OP_SERVICE_ACCOUNT_TOKEN
exec /usr/bin/op "$@"
EOF
chown "${ADMIN_USER}:${ADMIN_GROUP}" "${temporary_wrapper}"
chmod 0750 "${temporary_wrapper}"
mv -f -- "${temporary_wrapper}" "${OP_WRAPPER}"

printf 'Installed 1Password CLI %s.\n' "$(
  runuser -u "${ADMIN_USER}" -- \
    env HOME="${ADMIN_HOME}" "${OP_WRAPPER}" --version
)"
printf '%s\n' \
  "The service-account token is stored at ${OP_TOKEN_FILE} (mode 0600)." \
  "Only ${OP_WRAPPER} loads it, immediately before executing /usr/bin/op."
