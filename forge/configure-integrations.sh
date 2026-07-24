#!/usr/bin/env bash
set -Eeuo pipefail

: "${STAGE_DIR:=/tmp/forge-integrations}"
: "${KOMODO_VERSION:=v2.2.0}"
: "${KOMODO_CORE:=https://komodo.arc.bonfireboogie.com}"
: "${FORGE_SERVER_NAME:=Forge}"

PERIPHERY_SHA256=ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660
KM_SHA256=414102fbb259064166702dc7173ffcb1e9acb0707888ffaeba74d5d479a741c5

[[ ${EUID} -eq 0 ]] || {
  echo "Run this script as root."
  exit 1
}

[[ -d "${STAGE_DIR}" && ! -L "${STAGE_DIR}" ]] || {
  echo "The integration staging directory is missing or unsafe."
  exit 1
}
[[ "$(stat -c '%U' "${STAGE_DIR}")" == root ]] || {
  echo "The integration staging directory must be owned by root."
  exit 1
}
stage_mode="$(stat -c '%a' "${STAGE_DIR}")"
[[ "${stage_mode}" == 700 ]] || {
  echo "The integration staging directory must be mode 0700."
  exit 1
}

for file in \
  onboarding-key \
  onboarding-public-key \
  api-key \
  api-secret \
  compose.yaml \
  enroll-beszel.py \
  stabilize.sh \
  unraid-host-ed25519.pub; do
  staged_file="${STAGE_DIR}/${file}"
  [[ -f "${staged_file}" && ! -L "${staged_file}" ]] || {
    echo "Missing or unsafe staged file: ${staged_file}"
    exit 1
  }
  [[ "$(stat -c '%U' "${staged_file}")" == root ]] || {
    echo "Staged file must be owned by root: ${staged_file}"
    exit 1
  }
  staged_mode="$(stat -c '%a' "${staged_file}")"
  (( (8#${staged_mode} & 8#022) == 0 )) || {
    echo "Staged file must not be writable by group/other: ${staged_file}"
    exit 1
  }
done

for secret_file in \
  onboarding-key \
  onboarding-public-key \
  api-key \
  api-secret; do
  [[ "$(stat -c '%a' "${STAGE_DIR}/${secret_file}")" == 600 ]] || {
    echo "Staged credential must be mode 0600: ${secret_file}"
    exit 1
  }
done

ONBOARDING_KEY="$(tr -d '\r\n' <"${STAGE_DIR}/onboarding-key")"
ONBOARDING_PUBLIC_KEY="$(
  tr -d '\r\n' <"${STAGE_DIR}/onboarding-public-key"
)"
API_KEY="$(tr -d '\r\n' <"${STAGE_DIR}/api-key")"
API_SECRET="$(tr -d '\r\n' <"${STAGE_DIR}/api-secret")"

[[ "${ONBOARDING_KEY}" =~ ^[A-Za-z0-9._~+/=-]{32,256}$ ]] || {
  echo "Unexpected Komodo onboarding-key format."
  exit 1
}
[[ "${ONBOARDING_PUBLIC_KEY}" =~ ^[A-Za-z0-9+/=]{32,256}$ ]] || {
  echo "Unexpected Komodo onboarding public-key format."
  exit 1
}
[[ "${API_KEY}" =~ ^[A-Za-z0-9._~+/=-]{32,256}$ ]] || {
  echo "Unexpected Komodo API-key format."
  exit 1
}
[[ "${API_SECRET}" =~ ^[A-Za-z0-9._~+/=-]{32,256}$ ]] || {
  echo "Unexpected Komodo API-secret format."
  exit 1
}

TEMP_DIR="$(mktemp -d)"
KOMODO_CURL_CONFIG="${TEMP_DIR}/komodo-curl.conf"
PERIPHERY_CONFIG=/etc/komodo/periphery.config.toml
onboarding_embedded=false
onboarding_removed=false
onboarding_revoked=false

remove_onboarding_from_config() {
  [[ -f "${PERIPHERY_CONFIG}" ]] || return 0
  local temporary
  temporary="$(mktemp "${PERIPHERY_CONFIG}.XXXXXX")" || return 1
  awk '!/^[[:space:]]*onboarding_key[[:space:]]*=/' \
    "${PERIPHERY_CONFIG}" >"${temporary}" || {
      rm -f -- "${temporary}"
      return 1
    }
  chown root:root "${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  chmod 0600 "${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  mv -f -- "${temporary}" "${PERIPHERY_CONFIG}" || {
    rm -f -- "${temporary}"
    return 1
  }
  onboarding_removed=true
}

cleanup() {
  if [[ "${onboarding_embedded}" == true &&
        "${onboarding_removed}" != true ]]; then
    if remove_onboarding_from_config; then
      systemctl restart periphery.service >/dev/null 2>&1 || true
    else
      systemctl stop periphery.service >/dev/null 2>&1 || true
      printf '%s\n' \
        "WARNING: Failed to strip onboarding_key from ${PERIPHERY_CONFIG}." \
        "Periphery was stopped; remove the key manually before restart." >&2
    fi
  fi
  if [[ "${onboarding_revoked}" != true ]]; then
    if revoke_onboarding_key >/dev/null 2>&1; then
      onboarding_revoked=true
    else
      printf '%s\n' \
        "WARNING: Komodo onboarding-key revocation failed." \
        "Its public identifier remains at:" \
        "  ${STAGE_DIR}/onboarding-public-key" \
        "Revoke that exact key in Komodo before retrying." >&2
    fi
  fi
  rm -rf -- "${TEMP_DIR}"
  rm -f -- \
    "${STAGE_DIR}/onboarding-key" \
    "${STAGE_DIR}/api-key" \
    "${STAGE_DIR}/api-secret"
  if [[ "${onboarding_revoked}" == true ]]; then
    rm -f -- "${STAGE_DIR}/onboarding-public-key"
  else
    chown root:root "${STAGE_DIR}/onboarding-public-key" 2>/dev/null || true
    chmod 0600 "${STAGE_DIR}/onboarding-public-key" 2>/dev/null || true
  fi
}
trap cleanup EXIT

download_verified() {
  local url=$1
  local expected=$2
  local destination=$3

  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    "${url}" -o "${destination}"
  printf '%s  %s\n' "${expected}" "${destination}" | sha256sum --check
}

wait_for_forge_core() {
  local _
  for _ in $(seq 1 30); do
    if runuser -u codex -- \
      env HOME="${CODEX_HOME}" \
      XDG_CONFIG_HOME="${CODEX_HOME}/.config" \
      /usr/local/bin/km list servers \
        --all --format json --name "${FORGE_SERVER_NAME}" \
        2>/dev/null |
      grep -Eq '"state"[[:space:]]*:[[:space:]]*"Ok"'; then
      return 0
    fi
    sleep 2
  done
  echo "Komodo did not report Forge healthy within 60 seconds." >&2
  return 1
}

wait_for_fresh_periphery_login() {
  local service_pid=$1
  local _
  for _ in $(seq 1 30); do
    if [[ -n "$(
      journalctl \
        "_PID=${service_pid}" \
        --grep='Logged in to Komodo Core' \
        --no-pager \
        --quiet \
        -o cat
    )" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Periphery did not establish a fresh Core login within 60 seconds." >&2
  return 1
}

restart_periphery_and_wait() {
  systemctl restart periphery.service
  systemctl is-active --quiet periphery.service
  local service_pid
  service_pid="$(
    systemctl show periphery.service --property MainPID --value
  )"
  [[ "${service_pid}" =~ ^[1-9][0-9]*$ ]]
  wait_for_fresh_periphery_login "${service_pid}"
}

revoke_onboarding_key() {
  printf '{"public_key":"%s"}' "${ONBOARDING_PUBLIC_KEY}" |
    curl --fail --silent --show-error \
      --config "${KOMODO_CURL_CONFIG}" \
      --data-binary @- \
      "${KOMODO_CORE}/write/DeleteOnboardingKey" \
      >/dev/null
}

ensure_user_directory() {
  local user=$1
  local group=$2
  local mode=$3
  local path=$4

  if [[ -e "${path}" || -L "${path}" ]]; then
    [[ -d "${path}" && ! -L "${path}" ]] || {
      echo "Unsafe user directory: ${path}" >&2
      exit 1
    }
  else
    runuser -u "${user}" -- mkdir -m "${mode}" -- "${path}"
  fi

  [[ "$(stat -c '%U:%G' "${path}")" == "${user}:${group}" ]] || {
    echo "Unexpected owner/group on user directory: ${path}" >&2
    exit 1
  }
  runuser -u "${user}" -- chmod "${mode}" "${path}"
}

validate_user_file() {
  local user=$1
  local path=$2
  [[ -f "${path}" && ! -L "${path}" ]] || {
    echo "Unsafe user file: ${path}" >&2
    exit 1
  }
  [[ "$(stat -c '%U' "${path}")" == "${user}" ]] || {
    echo "Unexpected owner on user file: ${path}" >&2
    exit 1
  }
}

write_user_file() {
  local user=$1
  local path=$2
  local mode=$3
  if [[ -e "${path}" || -L "${path}" ]]; then
    validate_user_file "${user}" "${path}"
  fi

  # The single-quoted script is intentionally expanded only by the target user.
  # shellcheck disable=SC2016
  runuser -u "${user}" -- \
    env DESTINATION="${path}" FILE_MODE="${mode}" \
    bash -c '
      set -Eeuo pipefail
      temporary="$(mktemp "${DESTINATION}.XXXXXX")"
      trap '\''rm -f -- "${temporary}"'\'' EXIT
      cat >"${temporary}"
      chmod "${FILE_MODE}" "${temporary}"
      mv -f -- "${temporary}" "${DESTINATION}"
      trap - EXIT
    '
}

ensure_user_line() {
  local user=$1
  local path=$2
  local mode=$3
  local line=$4
  if [[ -e "${path}" || -L "${path}" ]]; then
    validate_user_file "${user}" "${path}"
  fi

  # The single-quoted script is intentionally expanded only by the target user.
  # shellcheck disable=SC2016
  runuser -u "${user}" -- \
    env DESTINATION="${path}" FILE_MODE="${mode}" REQUIRED_LINE="${line}" \
    bash -c '
      set -Eeuo pipefail
      temporary="$(mktemp "${DESTINATION}.XXXXXX")"
      trap '\''rm -f -- "${temporary}"'\'' EXIT
      if [[ -f "${DESTINATION}" ]]; then
        cat "${DESTINATION}" >"${temporary}"
      fi
      if ! grep -qxF -- "${REQUIRED_LINE}" "${temporary}"; then
        [[ ! -s "${temporary}" ]] || printf "\n" >>"${temporary}"
        printf "%s\n" "${REQUIRED_LINE}" >>"${temporary}"
      fi
      chmod "${FILE_MODE}" "${temporary}"
      mv -f -- "${temporary}" "${DESTINATION}"
      trap - EXIT
    '
}

ensure_user_global_include() {
  local user=$1
  local path=$2
  local include_line='Include ~/.ssh/config.d/*'
  if [[ -e "${path}" || -L "${path}" ]]; then
    validate_user_file "${user}" "${path}"
  fi

  # The single-quoted script is intentionally expanded only by the target user.
  # shellcheck disable=SC2016
  runuser -u "${user}" -- \
    env DESTINATION="${path}" REQUIRED_LINE="${include_line}" \
    bash -c '
      set -Eeuo pipefail
      temporary="$(mktemp "${DESTINATION}.XXXXXX")"
      trap '\''rm -f -- "${temporary}"'\'' EXIT
      printf "%s\n" "${REQUIRED_LINE}" >"${temporary}"
      if [[ -f "${DESTINATION}" ]]; then
        grep -vxF -- "${REQUIRED_LINE}" "${DESTINATION}" \
          >>"${temporary}" || true
      fi
      chmod 0600 "${temporary}"
      mv -f -- "${temporary}" "${DESTINATION}"
      trap - EXIT
    '
}

ensure_user_keypair() {
  local user=$1
  local private_key=$2
  local comment=$3

  if [[ -e "${private_key}" || -L "${private_key}" ||
        -e "${private_key}.pub" || -L "${private_key}.pub" ]]; then
    validate_user_file "${user}" "${private_key}"
    validate_user_file "${user}" "${private_key}.pub"
  else
    runuser -u "${user}" -- \
      ssh-keygen -q -t ed25519 -a 64 -N '' \
      -C "${comment}" \
      -f "${private_key}"
  fi
  runuser -u "${user}" -- chmod 0600 "${private_key}"
  runuser -u "${user}" -- chmod 0644 "${private_key}.pub"
}

{
  printf 'header = "Content-Type: application/json"\n'
  printf 'header = "X-Api-Key: %s"\n' "${API_KEY}"
  printf 'header = "X-Api-Secret: %s"\n' "${API_SECRET}"
} >"${KOMODO_CURL_CONFIG}"
chmod 0600 "${KOMODO_CURL_CONFIG}"

download_verified \
  "https://github.com/moghtech/komodo/releases/download/${KOMODO_VERSION}/periphery-x86_64" \
  "${PERIPHERY_SHA256}" \
  "${TEMP_DIR}/periphery"
download_verified \
  "https://github.com/moghtech/komodo/releases/download/${KOMODO_VERSION}/km-x86_64" \
  "${KM_SHA256}" \
  "${TEMP_DIR}/km"

install -o root -g root -m 0755 \
  "${TEMP_DIR}/periphery" /usr/local/bin/periphery
install -o root -g root -m 0755 \
  "${TEMP_DIR}/km" /usr/local/bin/km

install -d -o root -g root -m 0700 /etc/komodo/keys
install -d -o root -g root -m 0755 \
  /etc/komodo/stacks/forge-observability
install -d -o root -g root -m 0555 /var/lib/beszel-root
install -d -o root -g root -m 0700 /var/lib/beszel-agent
[[ -d /workspace && ! -L /workspace ]]
[[ "$(stat -c '%U:%G' /workspace)" == "root:agent-workspace" ]]
chmod 3770 /workspace
if [[ -e /workspace/.system || -L /workspace/.system ]]; then
  [[ -d /workspace/.system && ! -L /workspace/.system ]]
  [[ "$(stat -c '%U:%G' /workspace/.system)" == "root:root" ]]
else
  mkdir -- /workspace/.system
  chown root:root /workspace/.system
fi
setfacl -b -k /workspace/.system
chmod u-s,g-s /workspace/.system
chmod 0700 /workspace/.system
if [[ -e /workspace/.system/beszel ||
      -L /workspace/.system/beszel ]]; then
  [[ -d /workspace/.system/beszel &&
     ! -L /workspace/.system/beszel ]]
  [[ "$(stat -c '%U:%G' /workspace/.system/beszel)" == "root:root" ]]
else
  mkdir -- /workspace/.system/beszel
  chown root:root /workspace/.system/beszel
fi
setfacl -b -k /workspace/.system/beszel
chmod u-s,g-s /workspace/.system/beszel
chmod 0555 /workspace/.system/beszel
install -o root -g root -m 0644 \
  "${STAGE_DIR}/compose.yaml" \
  /etc/komodo/stacks/forge-observability/compose.yaml
install -o root -g root -m 0750 \
  "${STAGE_DIR}/enroll-beszel.py" \
  /usr/local/sbin/enroll-forge-beszel
install -o root -g root -m 0755 \
  "${STAGE_DIR}/stabilize.sh" \
  /usr/local/sbin/forge-stabilize

cat >"${PERIPHERY_CONFIG}" <<EOF
root_directory = "/etc/komodo"
disable_terminals = true
disable_container_terminals = true
include_disk_mounts = ["/", "/workspace"]
private_key = "file:/etc/komodo/keys/periphery.key"
core_address = "${KOMODO_CORE}"
connect_as = "${FORGE_SERVER_NAME}"
onboarding_key = "${ONBOARDING_KEY}"
server_enabled = false
logging.level = "info"
logging.stdio = "standard"
logging.pretty = false
pretty_startup_config = false
EOF
chown root:root "${PERIPHERY_CONFIG}"
chmod 0600 "${PERIPHERY_CONFIG}"
onboarding_embedded=true

cat >/etc/systemd/system/periphery.service <<'EOF'
[Unit]
Description=Komodo Periphery agent
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

CODEX_HOME="$(getent passwd codex | cut -d: -f6)"
CODEX_GROUP="$(id -gn codex)"
[[ -d "${CODEX_HOME}" && ! -L "${CODEX_HOME}" ]]
[[ "$(stat -c '%U:%G' "${CODEX_HOME}")" == "codex:${CODEX_GROUP}" ]]
ensure_user_directory \
  codex "${CODEX_GROUP}" 0700 "${CODEX_HOME}/.config"
ensure_user_directory \
  codex "${CODEX_GROUP}" 0700 "${CODEX_HOME}/.config/komodo"
write_user_file \
  codex "${CODEX_HOME}/.config/komodo/komodo.cli.toml" 0600 <<EOF
default_profile = "Arc"

[[profile]]
name = "Arc"
aliases = ["arc"]
host = "${KOMODO_CORE}"
key = "${API_KEY}"
secret = "${API_SECRET}"
EOF

ADMIN_HOME="$(getent passwd luqmaan | cut -d: -f6)"
ADMIN_GROUP="$(id -gn luqmaan)"
[[ -d "${ADMIN_HOME}" && ! -L "${ADMIN_HOME}" ]]
[[ "$(stat -c '%U:%G' "${ADMIN_HOME}")" == \
  "luqmaan:${ADMIN_GROUP}" ]]
ensure_user_directory \
  luqmaan "${ADMIN_GROUP}" 0700 "${ADMIN_HOME}/.ssh"
ensure_user_directory \
  luqmaan "${ADMIN_GROUP}" 0700 "${ADMIN_HOME}/.ssh/config.d"
ensure_user_keypair \
  luqmaan "${ADMIN_HOME}/.ssh/github_forge_ed25519" forge-github

GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
ensure_user_line \
  luqmaan "${ADMIN_HOME}/.ssh/known_hosts" 0600 "${GITHUB_HOST_KEY}"
write_user_file \
  luqmaan "${ADMIN_HOME}/.ssh/config.d/github" 0600 <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_forge_ed25519
  IdentitiesOnly yes
EOF
ensure_user_global_include luqmaan "${ADMIN_HOME}/.ssh/config"

ensure_user_directory \
  codex "${CODEX_GROUP}" 0700 "${CODEX_HOME}/.ssh"
ensure_user_directory \
  codex "${CODEX_GROUP}" 0700 "${CODEX_HOME}/.ssh/config.d"
ensure_user_keypair \
  codex "${CODEX_HOME}/.ssh/unraid_readonly_ed25519" \
  forge-codex-unraid-readonly

UNRAID_HOST_KEY="$(awk '
  $1 ~ /^ssh-ed25519$/ && $2 ~ /^[A-Za-z0-9+\/=]+$/ {
    print "192.168.50.51,arc.local " $1 " " $2
  }
' "${STAGE_DIR}/unraid-host-ed25519.pub")"
[[ -n "${UNRAID_HOST_KEY}" ]] || {
  echo "The staged Unraid Ed25519 host key is invalid."
  exit 1
}
ensure_user_line \
  codex "${CODEX_HOME}/.ssh/known_hosts" 0600 "${UNRAID_HOST_KEY}"
write_user_file \
  codex "${CODEX_HOME}/.ssh/config.d/unraid" 0600 <<'EOF'
Host unraid arc
  HostName 192.168.50.51
  User root
  IdentityFile ~/.ssh/unraid_readonly_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
EOF
ensure_user_global_include codex "${CODEX_HOME}/.ssh/config"

/usr/local/sbin/forge-stabilize
systemctl daemon-reload
systemctl enable periphery.service
restart_periphery_and_wait
wait_for_forge_core
[[ "$(stat -c '%U:%G %a' /etc/komodo/keys/periphery.key)" == \
  "root:root 600" ]]
remove_onboarding_from_config
restart_periphery_and_wait
wait_for_forge_core
revoke_onboarding_key
onboarding_revoked=true
systemctl restart xrdp.service

ssh-keygen -lf "${ADMIN_HOME}/.ssh/github_forge_ed25519.pub"
ssh-keygen -lf "${CODEX_HOME}/.ssh/unraid_readonly_ed25519.pub"
printf '%s\n' \
  'Forge integrations installed; Core onboarding was verified, removed,' \
  'and revoked. Authorize only the printed codex public-key fingerprint on Arc.'
