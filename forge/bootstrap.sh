#!/usr/bin/env bash
set -Eeuo pipefail

: "${ADMIN_USER:=luqmaan}"
: "${ADMIN_PUBKEY_FILE:=/tmp/forge-admin.pub}"
: "${FORGE_HOSTNAME:=forge}"
: "${LAN_CIDR:=192.168.50.0/24}"
: "${WORKSPACE_DEVICE:=/dev/vdb}"
: "${WORKSPACE_PARTITION:=/dev/vdb1}"
: "${WORKSPACE_BYTES:=274877906944}"
: "${SWAPFILE:=/swapfile}"
: "${SWAP_BYTES:=17179869184}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

[[ ${EUID} -eq 0 ]] || {
  echo "Run this bootstrap as root on Forge." >&2
  exit 1
}

# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID}" == ubuntu && "${VERSION_ID}" == 26.04 ]] || {
  echo "Expected Kubuntu/Ubuntu 26.04; found ${PRETTY_NAME}." >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/stabilize.sh"

id "${ADMIN_USER}" >/dev/null
[[ -r "${ADMIN_PUBKEY_FILE}" ]] || {
  echo "Missing public key: ${ADMIN_PUBKEY_FILE}" >&2
  exit 1
}
[[ "$(grep -cve '^[[:space:]]*$' "${ADMIN_PUBKEY_FILE}")" -eq 1 ]]
ssh-keygen -lf "${ADMIN_PUBKEY_FILE}" >/dev/null

ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
ADMIN_GROUP="$(id -gn "${ADMIN_USER}")"
[[ -d "${ADMIN_HOME}" && ! -L "${ADMIN_HOME}" ]]
hostnamectl set-hostname "${FORGE_HOSTNAME}"

# Refresh package metadata, but do not perform an unsolicited distribution
# upgrade. Forge package and image upgrades are deliberate, approved work.
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update
apt-get install -y \
  qemu-guest-agent spice-vdagent \
  xserver-xorg-core xserver-xorg-input-libinput xcvt \
  plasma-session-x11 kwin-x11 \
  xrdp xorgxrdp dbus-x11 \
  openssh-server ufw sudo \
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

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable --now unattended-upgrades.service 2>/dev/null || true

systemctl enable --now ssh.service
if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
  systemctl enable --now qemu-guest-agent.service
else
  echo "WARNING: QEMU guest-agent channel is not visible." >&2
fi

git lfs install --system
if [[ ! -e /usr/local/bin/fd && -x /usr/bin/fdfind ]]; then
  ln -s /usr/bin/fdfind /usr/local/bin/fd
fi

install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0700 \
  "${ADMIN_HOME}/.ssh"
AUTHORIZED_KEYS="${ADMIN_HOME}/.ssh/authorized_keys"
if [[ ! -e "${AUTHORIZED_KEYS}" ]]; then
  install -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0600 \
    /dev/null "${AUTHORIZED_KEYS}"
fi
ADMIN_PUBKEY="$(tr -d '\r' <"${ADMIN_PUBKEY_FILE}")"
grep -qxF -- "${ADMIN_PUBKEY}" "${AUTHORIZED_KEYS}" ||
  printf '%s\n' "${ADMIN_PUBKEY}" >>"${AUTHORIZED_KEYS}"
chown "${ADMIN_USER}:${ADMIN_GROUP}" "${AUTHORIZED_KEYS}"
chmod 0600 "${AUTHORIZED_KEYS}"

SUDOERS_FILE=/etc/sudoers.d/90-forge-admin
SUDOERS_TEMP="$(mktemp /etc/sudoers.d/.forge-admin.XXXXXX)"
trap 'rm -f -- "${SUDOERS_TEMP}"' EXIT
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" >"${SUDOERS_TEMP}"
chmod 0440 "${SUDOERS_TEMP}"
visudo -cf "${SUDOERS_TEMP}" >/dev/null
mv -f -- "${SUDOERS_TEMP}" "${SUDOERS_FILE}"
trap - EXIT

if [[ ! -e "${ADMIN_HOME}/.xsession" ]]; then
  printf '%s\n' 'exec dbus-run-session startplasma-x11' \
    >"${ADMIN_HOME}/.xsession"
  chown "${ADMIN_USER}:${ADMIN_GROUP}" "${ADMIN_HOME}/.xsession"
  chmod 0600 "${ADMIN_HOME}/.xsession"
fi
adduser xrdp ssl-cert
systemctl enable xrdp.service
systemctl restart xrdp.service

# Initialize only the dedicated, exactly sized blank workspace disk. Reruns
# accept only the ext4 filesystem previously created by this script.
[[ -b "${WORKSPACE_DEVICE}" ]] || {
  echo "Workspace device ${WORKSPACE_DEVICE} is missing." >&2
  exit 1
}
[[ "$(blockdev --getsize64 "${WORKSPACE_DEVICE}")" == "${WORKSPACE_BYTES}" ]] || {
  echo "Refusing workspace setup: unexpected device size." >&2
  exit 1
}

if [[ ! -b "${WORKSPACE_PARTITION}" ]]; then
  [[ "$(lsblk -nrpo NAME "${WORKSPACE_DEVICE}" | wc -l)" -eq 1 ]]
  if blkid "${WORKSPACE_DEVICE}" >/dev/null 2>&1; then
    echo "Refusing to format a workspace device with a signature." >&2
    exit 1
  fi
  parted -s "${WORKSPACE_DEVICE}" mklabel gpt
  parted -s "${WORKSPACE_DEVICE}" mkpart primary ext4 1MiB 100%
  partprobe "${WORKSPACE_DEVICE}"
  udevadm settle
  mkfs.ext4 -L forge-workspace "${WORKSPACE_PARTITION}"
fi

mapfile -t WORKSPACE_NODES < <(lsblk -nrpo NAME "${WORKSPACE_DEVICE}")
[[ "${#WORKSPACE_NODES[@]}" -eq 2 &&
   "${WORKSPACE_NODES[0]}" == "${WORKSPACE_DEVICE}" &&
   "${WORKSPACE_NODES[1]}" == "${WORKSPACE_PARTITION}" ]]
[[ "$(blkid -s TYPE -o value "${WORKSPACE_PARTITION}")" == ext4 ]]
[[ "$(blkid -s LABEL -o value "${WORKSPACE_PARTITION}")" == forge-workspace ]]
WORKSPACE_UUID="$(blkid -s UUID -o value "${WORKSPACE_PARTITION}")"
[[ -n "${WORKSPACE_UUID}" ]]

install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0750 /workspace
mapfile -t WORKSPACE_FSTAB_SOURCES < <(
  awk '$1 !~ /^#/ && $2 == "/workspace" { print $1 }' /etc/fstab
)
if [[ "${#WORKSPACE_FSTAB_SOURCES[@]}" -eq 0 ]]; then
  printf 'UUID=%s /workspace ext4 defaults,noatime 0 2\n' \
    "${WORKSPACE_UUID}" >>/etc/fstab
elif [[ "${#WORKSPACE_FSTAB_SOURCES[@]}" -ne 1 ||
        "${WORKSPACE_FSTAB_SOURCES[0]}" != "UUID=${WORKSPACE_UUID}" ]]; then
  echo "Refusing workspace setup: conflicting fstab entry." >&2
  exit 1
fi
mountpoint -q /workspace || mount /workspace
[[ "$(readlink -f "$(findmnt -nro SOURCE --target /workspace)")" == \
   "$(readlink -f "${WORKSPACE_PARTITION}")" ]]
[[ "$(findmnt -nro FSTYPE --target /workspace)" == ext4 ]]

chown "${ADMIN_USER}:${ADMIN_GROUP}" /workspace
chmod 0750 /workspace
install -d -o "${ADMIN_USER}" -g "${ADMIN_GROUP}" -m 0750 \
  /workspace/repos \
  /workspace/builds \
  /workspace/tmp

DEVELOPER_LINK="${ADMIN_HOME}/developer"
if [[ -L "${DEVELOPER_LINK}" ]]; then
  [[ "$(readlink -f "${DEVELOPER_LINK}")" == /workspace/repos ]] || {
    echo "${DEVELOPER_LINK} points somewhere other than /workspace/repos." >&2
    exit 1
  }
elif [[ -e "${DEVELOPER_LINK}" ]]; then
  echo "Refusing to replace existing ${DEVELOPER_LINK}." >&2
  exit 1
else
  runuser -u "${ADMIN_USER}" -- \
    ln -s /workspace/repos "${DEVELOPER_LINK}"
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow from "${LAN_CIDR}" to any port 22 proto tcp \
  comment "Forge SSH from home LAN"
ufw allow from "${LAN_CIDR}" to any port 3389 proto tcp \
  comment "Forge RDP from home LAN and Arc Termix"
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
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now containerd.service docker.service
usermod -aG docker "${ADMIN_USER}"

if [[ -e "${SWAPFILE}" ]]; then
  [[ "$(blkid -p -s TYPE -o value "${SWAPFILE}" 2>/dev/null || true)" == swap ]] || {
    echo "Refusing to modify existing non-swap file: ${SWAPFILE}" >&2
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

printf '%s\n' \
  "Forge bootstrap complete for ${ADMIN_USER}." \
  "Open a new login session before using Docker group access."
[[ -e /var/run/reboot-required ]] &&
  echo "Installed packages report that a reboot is required."
