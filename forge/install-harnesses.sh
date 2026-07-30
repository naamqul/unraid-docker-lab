#!/usr/bin/env bash
set -Eeuo pipefail

: "${ADMIN_USER:=luqmaan}"

[[ ${EUID} -eq 0 ]] || {
  echo "Run this installer as root on Forge." >&2
  exit 1
}

ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
ADMIN_GROUP="$(id -gn "${ADMIN_USER}")"
[[ -d "${ADMIN_HOME}" && ! -L "${ADMIN_HOME}" ]]

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT

download_installer() {
  local url=$1
  local destination=$2
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    "${url}" -o "${destination}"
  chmod 0555 "${destination}"
}

run_as_admin() {
  runuser -u "${ADMIN_USER}" -- \
    env \
      HOME="${ADMIN_HOME}" \
      USER="${ADMIN_USER}" \
      LOGNAME="${ADMIN_USER}" \
      PATH="${ADMIN_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      "$@"
}

# These are the official current Linux installers. They install the latest
# release into luqmaan's home and do not perform any login or permission-mode
# setup. Rerun this script only after the user approves harness updates.
download_installer \
  https://chatgpt.com/codex/install.sh \
  "${TEMP_DIR}/install-codex.sh"
download_installer \
  https://claude.ai/install.sh \
  "${TEMP_DIR}/install-claude.sh"
download_installer \
  https://hermes-agent.nousresearch.com/install.sh \
  "${TEMP_DIR}/install-hermes.sh"

run_as_admin env CODEX_NON_INTERACTIVE=1 \
  sh "${TEMP_DIR}/install-codex.sh"
run_as_admin bash "${TEMP_DIR}/install-claude.sh"
run_as_admin bash "${TEMP_DIR}/install-hermes.sh" \
  --skip-setup --skip-browser

# Disable both Claude background checks and every update path. An approved
# manual update can temporarily remove these values, run `claude update`, and
# restore them.
install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0700 \
  "${ADMIN_HOME}/.claude"
CLAUDE_SETTINGS="${ADMIN_HOME}/.claude/settings.json"
if [[ -e "${CLAUDE_SETTINGS}" ]]; then
  [[ -f "${CLAUDE_SETTINGS}" && ! -L "${CLAUDE_SETTINGS}" ]]
  jq empty "${CLAUDE_SETTINGS}"
else
  install -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0600 \
    /dev/null "${CLAUDE_SETTINGS}"
  printf '{}\n' >"${CLAUDE_SETTINGS}"
fi
CLAUDE_TEMP="$(mktemp "${CLAUDE_SETTINGS}.XXXXXX")"
jq '
  .env.DISABLE_AUTOUPDATER = "1" |
  .env.DISABLE_UPDATES = "1"
' \
  "${CLAUDE_SETTINGS}" >"${CLAUDE_TEMP}"
chown "${ADMIN_USER}:${ADMIN_GROUP}" "${CLAUDE_TEMP}"
chmod 0600 "${CLAUDE_TEMP}"
mv -f -- "${CLAUDE_TEMP}" "${CLAUDE_SETTINGS}"

for executable in codex claude hermes; do
  run_as_admin bash -lc "command -v ${executable} >/dev/null"
  run_as_admin "${executable}" --version
done

printf '%s\n' \
  "Codex, Claude, and Hermes are installed directly for ${ADMIN_USER}." \
  "Authentication and harness permission settings were not configured."
