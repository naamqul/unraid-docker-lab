#!/usr/bin/env bash
set -Eeuo pipefail

: "${ADMIN_USER:=luqmaan}"
: "${ADMIN_PUBKEY_FILE:=/tmp/forge-admin.pub}"
: "${FORGE_HOSTNAME:=forge}"
: "${LAN_CIDR:=192.168.50.0/24}"
: "${WORKSPACE_DEVICE:=/dev/vdb}"
: "${WORKSPACE_PARTITION:=/dev/vdb1}"
: "${WORKSPACE_BYTES:=549755813888}"
: "${SWAPFILE:=/swapfile}"
: "${SWAP_BYTES:=17179869184}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

[[ ${EUID} -eq 0 ]] || {
  echo "Run this bootstrap as root."
  exit 1
}

. /etc/os-release
[[ "${ID}" == "ubuntu" && "${VERSION_ID}" == "26.04" ]] || {
  echo "Expected Kubuntu/Ubuntu 26.04; found ${PRETTY_NAME}."
  exit 1
}

id "${ADMIN_USER}" >/dev/null
[[ -r "${ADMIN_PUBKEY_FILE}" ]] || {
  echo "Missing public key: ${ADMIN_PUBKEY_FILE}"
  exit 1
}
[[ "$(grep -cve '^[[:space:]]*$' "${ADMIN_PUBKEY_FILE}")" -eq 1 ]] || {
  echo "The public-key file must contain exactly one key."
  exit 1
}
ssh-keygen -lf "${ADMIN_PUBKEY_FILE}" >/dev/null
hostnamectl set-hostname "${FORGE_HOSTNAME}"

apt-get update
apt-get -y full-upgrade
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update

apt-get install -y \
  qemu-guest-agent spice-vdagent \
  openssh-server unattended-upgrades ufw \
  ca-certificates curl wget gnupg \
  git git-lfs gh \
  jq ripgrep fd-find fzf \
  tmux htop btop tree \
  rsync openssl unzip zip xz-utils zstd cpio \
  dnsutils iproute2 iputils-ping lsof strace \
  acl parted \
  build-essential fakeroot pkg-config ccache sparse \
  bc bison flex \
  libssl-dev libelf-dev libdw-dev libncurses-dev \
  pahole kmod \
  clang llvm lld \
  cmake ninja-build meson \
  python3-full python3-dev python3-venv python3-pip pipx \
  nodejs npm \
  shellcheck

systemctl enable --now ssh.service
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
  systemctl start qemu-guest-agent.service
else
  echo "WARNING: QEMU guest-agent channel is not visible."
fi

git lfs install --system

if [[ ! -e /usr/local/bin/fd && -x /usr/bin/fdfind ]]; then
  ln -s /usr/bin/fdfind /usr/local/bin/fd
fi

getent group sshlogin >/dev/null || groupadd --system sshlogin
getent group agent-workspace >/dev/null || groupadd --system agent-workspace
usermod -aG sudo,sshlogin,agent-workspace "${ADMIN_USER}"

for user in codex claude hermes; do
  if ! id "${user}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "${user}"
  fi

  usermod -aG agent-workspace "${user}"
  usermod -L "${user}"
  chmod 0700 "$(getent passwd "${user}" | cut -d: -f6)"

  for forbidden_group in sudo docker sshlogin; do
    if id -nG "${user}" | tr ' ' '\n' | grep -qx "${forbidden_group}"; then
      gpasswd -d "${user}" "${forbidden_group}"
    fi
  done
done

ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
ADMIN_GROUP="$(id -gn "${ADMIN_USER}")"
AUTHORIZED_KEYS="${ADMIN_HOME}/.ssh/authorized_keys"

install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0700 \
  "${ADMIN_HOME}/.ssh"

if [[ ! -e "${AUTHORIZED_KEYS}" ]]; then
  install -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0600 \
    /dev/null "${AUTHORIZED_KEYS}"
fi

ADMIN_PUBKEY="$(tr -d '\r' <"${ADMIN_PUBKEY_FILE}")"
grep -qxF -- "${ADMIN_PUBKEY}" "${AUTHORIZED_KEYS}" ||
  printf '%s\n' "${ADMIN_PUBKEY}" >>"${AUTHORIZED_KEYS}"

chown "${ADMIN_USER}:${ADMIN_GROUP}" "${AUTHORIZED_KEYS}"
chmod 0600 "${AUTHORIZED_KEYS}"

# Create the dedicated workspace filesystem only when vdb is exactly the new,
# empty 512 GiB virtual disk prepared for Forge.
if [[ ! -b "${WORKSPACE_PARTITION}" ]]; then
  [[ -b "${WORKSPACE_DEVICE}" ]] || {
    echo "Workspace device ${WORKSPACE_DEVICE} is missing."
    exit 1
  }

  [[ "$(blockdev --getsize64 "${WORKSPACE_DEVICE}")" == "${WORKSPACE_BYTES}" ]] || {
    echo "Refusing to format ${WORKSPACE_DEVICE}: unexpected size."
    exit 1
  }

  [[ "$(lsblk -nrpo NAME "${WORKSPACE_DEVICE}" | wc -l)" -eq 1 ]] || {
    echo "Refusing to format ${WORKSPACE_DEVICE}: partitions already exist."
    exit 1
  }

  if blkid "${WORKSPACE_DEVICE}" >/dev/null 2>&1; then
    echo "Refusing to format ${WORKSPACE_DEVICE}: a filesystem signature exists."
    exit 1
  fi

  parted -s "${WORKSPACE_DEVICE}" mklabel gpt
  parted -s "${WORKSPACE_DEVICE}" mkpart primary ext4 1MiB 100%
  partprobe "${WORKSPACE_DEVICE}"
  udevadm settle
  mkfs.ext4 -L forge-workspace "${WORKSPACE_PARTITION}"
fi

WORKSPACE_UUID="$(blkid -s UUID -o value "${WORKSPACE_PARTITION}")"
install -d -o root -g agent-workspace -m 2770 /workspace

if ! grep -Eq "^[[:space:]]*UUID=${WORKSPACE_UUID}[[:space:]]+/workspace[[:space:]]" /etc/fstab; then
  printf 'UUID=%s /workspace ext4 defaults,noatime 0 2\n' \
    "${WORKSPACE_UUID}" >>/etc/fstab
fi

mountpoint -q /workspace || mount /workspace
chown root:agent-workspace /workspace
chmod 2770 /workspace

install -d -o root -g agent-workspace -m 2770 \
  /workspace/repos \
  /workspace/shared \
  /workspace/inbox \
  /workspace/worktrees \
  /workspace/builds \
  /workspace/cache

for user in codex claude hermes; do
  install -d -o "${user}" -g agent-workspace -m 2770 \
    "/workspace/worktrees/${user}" \
    "/workspace/builds/${user}" \
    "/workspace/cache/${user}"
done

while IFS= read -r directory; do
  setfacl -m u::rwx,g::rwx,m::rwx,o::--- "${directory}"
  setfacl -d -m u::rwx,g::rwx,m::rwx,o::--- "${directory}"
done < <(find /workspace -type d -print)

ufw default deny incoming
ufw default allow outgoing
ufw allow from "${LAN_CIDR}" to any port 22 proto tcp \
  comment "Forge SSH from home LAN"
ufw --force enable

for package in \
  docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc
do
  if dpkg-query -W -f='${db:Status-Abbrev}\n' "${package}" \
    2>/dev/null | grep -q '^ii '; then
    apt-get remove -y "${package}"
  fi
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DOCKER_SUITE="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
DOCKER_ARCH="$(dpkg --print-architecture)"

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${DOCKER_SUITE}
Components: stable
Architectures: ${DOCKER_ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable --now containerd.service docker.service

# Docker access remains deliberately root-only. Membership in the docker group
# is equivalent to root and is not granted to human or agent identities.

if [[ -e "${SWAPFILE}" ]]; then
  [[ "$(blkid -p -s TYPE -o value "${SWAPFILE}" 2>/dev/null || true)" == "swap" ]] || {
    echo "Refusing to modify existing non-swap file: ${SWAPFILE}"
    exit 1
  }
fi

if [[ ! -e "${SWAPFILE}" || "$(stat -c %s "${SWAPFILE}")" != "${SWAP_BYTES}" ]]; then
  if swapon --show=NAME --noheadings |
    sed 's/^[[:space:]]*//' |
    grep -qx "${SWAPFILE}"; then
    swapoff "${SWAPFILE}"
  fi

  truncate -s 0 "${SWAPFILE}"
  chmod 0600 "${SWAPFILE}"
  fallocate -l 16G "${SWAPFILE}"
  chmod 0600 "${SWAPFILE}"
  mkswap "${SWAPFILE}"
fi

grep -Eq "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab ||
  printf '%s none swap sw 0 0\n' "${SWAPFILE}" >>/etc/fstab

swapon --show=NAME --noheadings |
  sed 's/^[[:space:]]*//' |
  grep -qx "${SWAPFILE}" || swapon "${SWAPFILE}"

cat >/etc/sysctl.d/99-forge-vm.conf <<'EOF'
vm.swappiness = 10
EOF
sysctl --system >/dev/null

echo
echo "Forge base bootstrap complete."
echo "Test SSH key login before applying the separate hardening stage."
[[ -e /var/run/reboot-required ]] && echo "A reboot is required."
