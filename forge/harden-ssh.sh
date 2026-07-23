#!/usr/bin/env bash
set -Eeuo pipefail

: "${ADMIN_USER:=luqmaan}"
: "${CONFIRM_KEY_LOGIN:=}"

[[ ${EUID} -eq 0 ]] || {
  echo "Run this hardening stage as root."
  exit 1
}

[[ "${CONFIRM_KEY_LOGIN}" == "yes" ]] || {
  echo "Set CONFIRM_KEY_LOGIN=yes only after testing a second key-based SSH session."
  exit 1
}

id -nG "${ADMIN_USER}" | tr ' ' '\n' | grep -qx sshlogin

TARGET="/etc/ssh/sshd_config.d/00-forge-hardening.conf"
CANDIDATE="$(mktemp)"
BACKUP="$(mktemp)"
trap 'rm -f "${CANDIDATE}" "${BACKUP}"' EXIT

cat >"${CANDIDATE}" <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

AllowGroups sshlogin

AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no

MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

HAD_OLD=0
if [[ -e "${TARGET}" ]]; then
  cp --preserve=all "${TARGET}" "${BACKUP}"
  HAD_OLD=1
fi

install -o root -g root -m 0644 "${CANDIDATE}" "${TARGET}"

if ! sshd -t; then
  if ((HAD_OLD)); then
    cp --preserve=all "${BACKUP}" "${TARGET}"
  else
    rm -f "${TARGET}"
  fi
  echo "Invalid SSH configuration; previous state restored."
  exit 1
fi

systemctl reload ssh.service
echo "SSH hardening applied. Test another new session before closing this one."
