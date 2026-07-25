#!/usr/bin/env bash
set -Eeuo pipefail

: "${AGENT_USER:=agent}"
: "${AGENT_GROUP:=agent-workspace}"
: "${AGENT_HOME:=/home/${AGENT_USER}}"
: "${AGENT_UID_RANGE_START:=165536}"
: "${INSTALL_HARNESSES:=true}"
: "${ADMIN_USER:=luqmaan}"

[[ ${EUID} -eq 0 ]] || {
  echo "Run this migration as root on Forge." >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

ensure_subid_range() {
  local file=$1
  local start=$2
  local existing_count

  existing_count="$(
    awk -F: -v user="${AGENT_USER}" '
      $1 == user { total += $3 }
      END { print total + 0 }
    ' "${file}"
  )"
  if (( existing_count < 65536 )); then
    printf '%s:%s:65536\n' \
      "${AGENT_USER}" "${start}" >>"${file}"
  fi
}

ensure_agent_file() {
  local destination=$1
  local mode=$2
  local temporary

  temporary="$(mktemp "${destination}.XXXXXX")"
  trap 'rm -f -- "${temporary}"' RETURN
  cat >"${temporary}"
  chown "${AGENT_USER}:${AGENT_USER}" "${temporary}"
  chmod "${mode}" "${temporary}"
  mv -f -- "${temporary}" "${destination}"
  trap - RETURN
}

ensure_keypair() {
  local private_key=$1
  local comment=$2

  if [[ -e "${private_key}" || -e "${private_key}.pub" ]]; then
    [[ -f "${private_key}" && ! -L "${private_key}" ]]
    [[ -f "${private_key}.pub" && ! -L "${private_key}.pub" ]]
  else
    run_agent ssh-keygen -q -t ed25519 -a 64 -N '' \
      -C "${comment}" -f "${private_key}"
  fi
  chown "${AGENT_USER}:${AGENT_USER}" \
    "${private_key}" "${private_key}.pub"
  chmod 0600 "${private_key}"
  chmod 0644 "${private_key}.pub"
}

append_profile_block() {
  local profile="${AGENT_HOME}/.profile"
  local begin='# BEGIN Forge agent runtime'
  local end='# END Forge agent runtime'
  local temporary

  temporary="$(mktemp "${profile}.XXXXXX")"
  if [[ -f "${profile}" ]]; then
    awk -v begin="${begin}" -v end="${end}" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "${profile}" >"${temporary}"
  fi
  cat >>"${temporary}" <<EOF
${begin}
export PATH="\${HOME}/.local/bin:\${HOME}/bin:\${PATH}"
export DOCKER_HOST="unix:///run/user/${AGENT_UID}/docker.sock"
${end}
EOF
  chown "${AGENT_USER}:${AGENT_USER}" "${temporary}"
  chmod 0644 "${temporary}"
  mv -f -- "${temporary}" "${profile}"
}

install_harness_wrapper() {
  local name=$1
  local executable=$2

  ensure_agent_file "${AGENT_HOME}/bin/${name}" 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/homelab-agent-docs
exec ${executable} "\$@"
EOF
}

install_harnesses() {
  local codex_install='curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'
  local claude_install='curl -fsSL https://claude.ai/install.sh | bash'
  local hermes_install='curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup'

  if ! run_agent bash -lc 'command -v codex >/dev/null'; then
    run_agent bash -lc "${codex_install}"
  fi
  if ! run_agent bash -lc 'command -v claude >/dev/null'; then
    run_agent bash -lc "${claude_install}"
  fi
  if ! run_agent bash -lc 'command -v hermes >/dev/null'; then
    run_agent bash -lc "${hermes_install}"
  fi
}

getent group "${AGENT_GROUP}" >/dev/null ||
  groupadd --system "${AGENT_GROUP}"

if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash "${AGENT_USER}"
fi

[[ "$(getent passwd "${AGENT_USER}" | cut -d: -f6)" == "${AGENT_HOME}" ]]
usermod --shell /bin/bash "${AGENT_USER}"
usermod -aG "${AGENT_GROUP}" "${AGENT_USER}"
usermod -L "${AGENT_USER}"
for forbidden_group in sudo docker; do
  if id -nG "${AGENT_USER}" | tr ' ' '\n' |
    grep -qx "${forbidden_group}"; then
    gpasswd -d "${AGENT_USER}" "${forbidden_group}"
  fi
done

AGENT_UID="$(id -u "${AGENT_USER}")"
AGENT_GID="$(id -g "${AGENT_USER}")"

ensure_subid_range /etc/subuid "${AGENT_UID_RANGE_START}"
ensure_subid_range /etc/subgid "${AGENT_UID_RANGE_START}"

apt-get update
apt-get install -y \
  uidmap \
  slirp4netns \
  fuse-overlayfs \
  dbus-user-session \
  docker-ce-rootless-extras

install -d -o root -g "${AGENT_GROUP}" -m 3770 /workspace
install -d -o "${AGENT_USER}" -g "${AGENT_GROUP}" -m 2770 \
  /workspace/agent \
  /workspace/agent/repos \
  /workspace/agent/state \
  /workspace/agent/state/docker \
  /workspace/agent/cache \
  /workspace/agent/builds

install -d -o "${AGENT_USER}" -g "${AGENT_USER}" -m 0700 \
  "${AGENT_HOME}/.config" \
  "${AGENT_HOME}/.config/docker" \
  "${AGENT_HOME}/.config/systemd" \
  "${AGENT_HOME}/.config/systemd/user" \
  "${AGENT_HOME}/bin" \
  "${AGENT_HOME}/.ssh" \
  "${AGENT_HOME}/.ssh/config.d"

ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -d "${ADMIN_HOME}" && ! -L "${ADMIN_HOME}" ]]
[[ "$(stat -c '%U' "${ADMIN_HOME}")" == "${ADMIN_USER}" ]]
chmod 0700 "${ADMIN_HOME}"

run_agent() {
  runuser -u "${AGENT_USER}" -- \
    env \
      HOME="${AGENT_HOME}" \
      USER="${AGENT_USER}" \
      LOGNAME="${AGENT_USER}" \
      XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${AGENT_UID}/bus" \
      PATH="${AGENT_HOME}/.local/bin:${AGENT_HOME}/bin:/usr/local/bin:/usr/bin:/bin" \
      "$@"
}

ensure_agent_file "${AGENT_HOME}/.config/docker/daemon.json" 0600 <<EOF
{
  "data-root": "/workspace/agent/state/docker"
}
EOF

loginctl enable-linger "${AGENT_USER}"
systemctl start "user@${AGENT_UID}.service"

if [[ ! -f "${AGENT_HOME}/.config/systemd/user/docker.service" ]]; then
  run_agent dockerd-rootless-setuptool.sh install --force
fi
run_agent systemctl --user daemon-reload
run_agent systemctl --user enable --now docker.service

for _ in $(seq 1 30); do
  if run_agent docker info --format '{{json .SecurityOptions}}' \
    2>/dev/null | grep -q rootless; then
    break
  fi
  sleep 1
done
run_agent docker info --format '{{json .SecurityOptions}}' |
  grep -q rootless

append_profile_block

ensure_keypair \
  "${AGENT_HOME}/.ssh/github_docs_ed25519" \
  forge-agent-github-docs
ensure_keypair \
  "${AGENT_HOME}/.ssh/unraid_readonly_ed25519" \
  forge-agent-unraid-readonly
ensure_keypair \
  "${AGENT_HOME}/.ssh/unraid_root_ed25519" \
  forge-agent-unraid-root

ensure_agent_file "${AGENT_HOME}/.ssh/config.d/github" 0600 <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_docs_ed25519
  IdentitiesOnly yes
EOF

ensure_agent_file "${AGENT_HOME}/.ssh/config.d/unraid" 0600 <<'EOF'
Host unraid arc
  HostName 192.168.50.51
  User root
  IdentityFile ~/.ssh/unraid_readonly_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts

Host unraid-root arc-root
  HostName 192.168.50.51
  User root
  IdentityFile ~/.ssh/unraid_root_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
EOF

ensure_agent_file "${AGENT_HOME}/.ssh/config" 0600 <<'EOF'
Include ~/.ssh/config.d/*
EOF

github_host_key='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
known_hosts="${AGENT_HOME}/.ssh/known_hosts"
if [[ ! -f "${known_hosts}" ]]; then
  install -o "${AGENT_USER}" -g "${AGENT_USER}" -m 0600 \
    /dev/null "${known_hosts}"
fi
grep -qxF -- "${github_host_key}" "${known_hosts}" ||
  printf '%s\n' "${github_host_key}" >>"${known_hosts}"

legacy_known_hosts=/home/codex/.ssh/known_hosts
if [[ -f "${legacy_known_hosts}" ]]; then
  while IFS= read -r host_line; do
    [[ -n "${host_line}" ]] || continue
    grep -qxF -- "${host_line}" "${known_hosts}" ||
      printf '%s\n' "${host_line}" >>"${known_hosts}"
  done < <(
    grep -E '^(192\.168\.50\.51|192\.168\.50\.51,arc\.local) ' \
      "${legacy_known_hosts}" || true
  )
fi
chown "${AGENT_USER}:${AGENT_USER}" "${known_hosts}"
chmod 0600 "${known_hosts}"

legacy_komodo=/home/codex/.config/komodo/komodo.cli.toml
agent_komodo="${AGENT_HOME}/.config/komodo/komodo.cli.toml"
if [[ -f "${legacy_komodo}" && ! -e "${agent_komodo}" ]]; then
  install -d -o "${AGENT_USER}" -g "${AGENT_USER}" -m 0700 \
    "${AGENT_HOME}/.config/komodo"
  install -o "${AGENT_USER}" -g "${AGENT_USER}" -m 0600 \
    "${legacy_komodo}" "${agent_komodo}"
fi

if [[ "${INSTALL_HARNESSES}" == true ]]; then
  install_harnesses
fi

if [[ -d /workspace/homelab-agent-docs &&
      ! -L /workspace/homelab-agent-docs ]]; then
  if [[ ! -e /workspace/agent/repos/homelab-agent-docs &&
        ! -L /workspace/agent/repos/homelab-agent-docs ]]; then
    run_agent ln -s /workspace/homelab-agent-docs \
      /workspace/agent/repos/homelab-agent-docs
  fi
  install_harness_wrapper codex-homelab codex
  install_harness_wrapper claude-homelab claude
  install_harness_wrapper hermes-homelab hermes
fi

printf '%s\n' \
  "Shared Forge agent runtime prepared for ${AGENT_USER}." \
  "Legacy harness accounts were retained as locked rollback identities." \
  "Authorize the printed public keys through their scoped control planes:"
ssh-keygen -lf "${AGENT_HOME}/.ssh/github_docs_ed25519.pub"
ssh-keygen -lf "${AGENT_HOME}/.ssh/unraid_readonly_ed25519.pub"
ssh-keygen -lf "${AGENT_HOME}/.ssh/unraid_root_ed25519.pub"
