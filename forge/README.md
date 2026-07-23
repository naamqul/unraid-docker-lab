# Forge

Forge is the always-on development VM hosted by Arc. It is intentionally
independent from the existing `Kubuntu` graphics-development VM: it has its own
UUID, MAC address, NVRAM, operating-system disk, and workspace disk. Completing
the Panther Lake graphics work and configuring backups are separate follow-up
projects.

## Current VM

| Setting | Value |
| --- | --- |
| Guest | Kubuntu 26.04 / Ubuntu 26.04 LTS base |
| UUID | `2aa8ec75-6629-466d-a029-3c5b9e3865a4` |
| MAC | `52:54:00:c7:1f:f3` |
| Current DHCP address | `192.168.50.179` |
| Compute | 12 vCPU, 24 GiB RAM |
| OS disk | `/mnt/user/domains/Forge/vdisk1.img`, 256 GiB sparse raw |
| Workspace disk | `/mnt/user/domains/Forge/workspace.img`, 512 GiB sparse raw |
| Workspace mount | `/workspace`, ext4, `noatime` |
| Console | QXL plus Unraid VNC; no physical GPU passthrough |
| Startup | Unraid autostart enabled |

Reserve `192.168.50.179` for `52:54:00:c7:1f:f3` in the ASUS DHCP table before
putting an IP address in a long-lived proxy or automation. `forge.local`
currently follows the router's DHCP hostname registration and is the direct
LAN SSH name.

Forge does not run its own Tailscale node. Arc is already online as a Tailscale
subnet router for `192.168.50.0/24`, so remote tailnet clients can reach Forge
through that route without a second overlay hop or another device identity.

## Access and trust boundaries

The Windows SSH profile uses a Forge-specific key:

```sshconfig
Host forge
  HostName forge.local
  User luqmaan
  IdentityFile ~/.ssh/forge_ed25519
  IdentitiesOnly yes
```

SSH is key-only, root login is disabled, and UFW accepts port 22 only from
`192.168.50.0/24`. Arc's routed Tailscale traffic arrives from the home subnet,
so the same rule covers remote access through the existing subnet router.

`codex`, `claude`, and `hermes` are locked service identities. They share only
the `agent-workspace` group and are deliberately absent from `sudo`, `docker`,
and `sshlogin`. Docker group membership is root-equivalent and must not be
granted casually.

The `codex` identity has two narrowly scoped integrations:

- Komodo CLI credentials in
  `/home/codex/.config/komodo/komodo.cli.toml`, mode `0600`.
- A forced-command SSH key for Arc. The matching Unraid entry permits only the
  commands defined by `unraid-readonly-wrapper.sh`; it does not provide a
  shell, forwarding, or arbitrary root execution.

The Komodo secret, SSH private keys, installer password, Caddy private CA key,
and agent-service credentials must never be committed here.

## Workspace layout

```text
/workspace/
├── repos/                 # Canonical working repositories
├── shared/                # Cross-agent artifacts
├── inbox/                 # Staging/import area
├── worktrees/
│   ├── codex/
│   ├── claude/
│   └── hermes/
├── builds/
│   ├── codex/
│   ├── claude/
│   └── hermes/
└── cache/
    ├── codex/
    ├── claude/
    └── hermes/
```

Directories are setgid and have default ACLs so new files remain writable by
`agent-workspace`. Per-agent worktrees and build directories reduce concurrent
edit and build collisions.

## Rebuild artifacts

- `Forge.xml` is the persistent libvirt definition captured after installation.
  It contains no installer ISO, temporary bootstrap share, or passthrough
  device.
- `bootstrap.sh` installs the guest baseline and safely initializes an empty
  512 GiB `/dev/vdb` as `/workspace`. It requires an external public key file;
  no key is embedded.
- `harden-ssh.sh` disables password login only after a second key-based session
  has been tested.
- `unraid-readonly-wrapper.sh` is installed on Arc at the same path as this
  repository copy and is the allowlist behind the Forge-to-Unraid SSH key.

Kubuntu's desktop ISO uses Calamares and does not support Ubuntu Server's
Subiquity autoinstall format. Rebuilding therefore has one interactive install
stage through Unraid VNC, followed by the scripted baseline:

```bash
sudo ADMIN_PUBKEY_FILE=/tmp/forge-admin.pub ./bootstrap.sh

# From another terminal, prove key login works before continuing.
ssh -i ~/.ssh/forge_ed25519 luqmaan@forge.local

sudo CONFIRM_KEY_LOGIN=yes ./harden-ssh.sh
sudo reboot
```

Before running `bootstrap.sh`, confirm `/dev/vdb` is the new empty 512 GiB
workspace disk. The script refuses to format a disk with an unexpected size,
partition table, or filesystem signature.

## Operational checks

From a normal client:

```bash
ssh forge
```

From Arc:

```bash
virsh dominfo Forge
virsh domifaddr Forge --source agent
virsh qemu-agent-command Forge '{"execute":"guest-ping"}'
```

Inside Forge:

```bash
systemctl is-active ssh qemu-guest-agent docker containerd
findmnt /workspace
swapon --show
docker version
docker compose version
```

The QEMU guest agent is an administrative host-to-guest channel. Do not expose
its socket or libvirt control to agent identities.

`forge.arc.home.arpa` is reserved in Caddy and currently returns an intentional
`503` placeholder because Forge has no web application to proxy yet. Keep
`forge.arc.home.arpa` pointed at Caddy (`192.168.50.52`), not directly at the
VM. When a Forge web service exists, replace the placeholder with a direct
proxy to the DHCP-reserved Forge address and port.
