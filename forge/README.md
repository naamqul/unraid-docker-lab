# Forge

Forge is the always-on development VM hosted by Arc. It is intentionally
independent from the existing `Kubuntu` graphics-development VM: it has its own
UUID, MAC address, NVRAM, operating-system disk, and workspace disk. Completing
the Panther Lake graphics work and configuring backups are separate follow-up
projects.

## Current VM

| Setting | Value |
| --- | --- |
| Guest | Kubuntu 26.04 / Ubuntu 26.04 LTS base (installation pending) |
| UUID | `1528c7a1-af0a-2d8c-11eb-6c9e2a0faeb0` |
| MAC | `52:54:00:c7:1f:f3` |
| Reserved DHCP address | `192.168.50.179` |
| Compute | 12 vCPU, 24 GiB RAM |
| OS disk | `/mnt/user/domains/Forge/vdisk1.img`, 256 GiB sparse raw |
| Workspace disk | Created and attached after OS installation |
| Workspace mount | `/workspace`, ext4, `noatime` (post-bootstrap) |
| Console | 2D VirtIO plus private Termix/guacd VNC; no GPU passthrough |
| Startup | Disabled until the replacement passes validation |

The ASUS DHCP reservation binds `192.168.50.179` to
`52:54:00:c7:1f:f3`. Use the reserved address for long-lived automation;
`forge.local` remains a convenience name supplied by router DNS.

`Forge-Legacy` retains the previous disks and NVRAM as rollback, but is
headless, non-autostarting, and uses MAC `52:54:00:91:8f:2b`. Never start both
guests with the canonical Forge MAC or VNC port.

Forge does not run its own Tailscale node. Arc is already online as a Tailscale
subnet router for `192.168.50.0/24`, so remote tailnet clients can reach Forge
through that route without a second overlay hop or another device identity.

## Access and trust boundaries

The Windows SSH profile uses a Forge-specific key:

```sshconfig
Host forge
  HostName 192.168.50.179
  User luqmaan
  IdentityFile ~/.ssh/forge_ed25519
  IdentitiesOnly yes
```

After provisioning, SSH is key-only, root login is disabled, and UFW accepts
port 22 only from `192.168.50.0/24`. Arc's routed Tailscale traffic arrives
from the home subnet, so the same rule covers remote access through the
existing subnet router.

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

Generate the replacement Forge GitHub key only after installation. The legacy
VM's key and fingerprint are not identities of the replacement guest.

Komodo Periphery `2.2.0` runs as a root systemd service in outbound mode to
`https://komodo.arc.home.arpa`. It opens no inbound port, trusts only Caddy's
public root CA, and has both general and container terminal APIs disabled.
Komodo stack deployment remains root-equivalent even with those terminal APIs
disabled.

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

- `Forge.xml` is the secret-free replacement definition. During installation
  it includes the Kubuntu ISO but no workspace disk, passthrough device, or
  live VNC secret. After installation, remove the ISO and attach the separately
  prepared workspace disk.
- `legacy/Forge-Legacy.xml` is the headless rollback definition. It uses a
  noncanonical MAC and cannot collide with Forge's private VNC listener.
- `bootstrap.sh` installs the guest baseline and safely initializes an empty
  512 GiB `/dev/vdb` as `/workspace`. It requires an external public key file;
  no key is embedded.
- `stabilize.sh` applies the mandatory Kubuntu 26.04 shadow-stack/fwupd and
  Q35 iTCO containment before the rest of bootstrap work.
- `configure-vnc.sh` creates/verifies the internal Docker bridge, injects the
  root-only VNC password into temporary runtime XML, defines the persistent
  domain, and removes the temporary file. It refuses to run while Forge is
  active.
- `harden-ssh.sh` disables password login only after a second key-based session
  has been tested.
- `unraid-readonly-wrapper.sh` is installed on Arc at the same path as this
  repository copy and is the allowlist behind the Forge-to-Unraid SSH key.
- `stacks/forge-observability` contains the outbound Beszel agent, a
  GET-filtered Docker proxy exposed only as a root-only Unix socket, and the
  hidden-prompt enrollment helper.

Kubuntu's desktop ISO uses Calamares and does not support Ubuntu Server's
Subiquity autoinstall format. Rebuilding therefore has one interactive install
stage followed by the scripted baseline. Start the VM from Unraid, then open
the existing **Forge Desktop (Kubuntu)** connection in Termix; it now reaches
the replacement VM through the private VNC listener.

At the ISO boot menu, edit the `Try or Install Kubuntu` entry and append
`nousershstk` to the Linux kernel line before booting it. Use:

- display name `Luqmaan`, login `luqmaan`;
- hostname `forge`;
- the 256 GiB VirtIO disk as the only installation target;
- no guest full-disk encryption unless manual console unlock after every
  reboot is acceptable;
- no automatic login.

Before the first installed-system boot, append `nousershstk` to its GRUB entry
once as well. Run `stabilize.sh` immediately after the first login so the
setting, fwupd masks, and iTCO hard block become persistent.

Then run:

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

### Post-bootstrap integrations

The guest bootstrap intentionally does not embed infrastructure credentials.
Rebuilds therefore finish with these explicit steps:

1. On Arc, fully shut Forge down and run
   `/mnt/user/appdata/unraid-docker-lab/forge/configure-vnc.sh`; then start
   Forge again. Do not define the tracked XML directly if a console is wanted.
2. Copy only Caddy's public root certificate into Forge's system trust store.
   Never copy Caddy's private CA key.
3. Install the pinned Periphery version, configure outbound access to
   `https://komodo.arc.home.arpa`, and keep general/container terminal APIs
   disabled. Register Forge and its Files-on-host observability stack in
   Komodo only after TLS validation succeeds.
4. Install `stacks/forge-observability/enroll-beszel.py` as root at
   `/usr/local/sbin/enroll-forge-beszel`, and install its Compose file under
   `/etc/komodo/stacks/forge-observability`. Run enrollment only through its
   hidden prompts.
5. Generate Forge's GitHub Ed25519 key locally as `luqmaan`; add only its
   public half to GitHub and pin GitHub's published host key.
6. Recreate the narrowly scoped Forge-to-Arc diagnostic key and Komodo CLI
   profile without placing either secret in this repository.

After any Unraid reboot, verify that the external `termix-private` Docker
network exists before Forge autostarts. Preserve user-defined Docker networks.
The cold-boot ordering is not yet qualified; if Forge fails to start, recreate
the network, leave Forge shut off, rerun `configure-vnc.sh`, and start it.

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

When intentionally stopping Forge, prefer
`virsh shutdown Forge --mode agent`; that is a shutdown action, not a routine
health check.

Inside Forge:

```bash
systemctl is-active ssh qemu-guest-agent docker containerd
findmnt /workspace
swapon --show
docker version
docker compose version
systemctl is-active periphery
systemctl is-enabled fwupd.service fwupd-refresh.service fwupd-refresh.timer
modprobe -n -v iTCO_wdt
```

The expected results are: core runtime services active, all three fwupd units
`masked`, and the dry-run modprobe ending in `install /bin/false`.

## Platform containment

Forge reproduced the Panther Lake repository's F10 failure even without iGPU
passthrough. An `fwupd-refresh` activation was followed within two seconds by
unrelated processes faulting at the same address with page-fault error
`0x44/0x46`; Linux continued answering ICMP while SSH, QGA, D-Bus, and the
desktop died. This is the documented KVM/CET user-shadow-stack collapse, not a
QXL or VFIO failure.

The required containment is deliberate:

- boot with `nousershstk`;
- keep `fwupd.service`, `fwupd-refresh.service`, and
  `fwupd-refresh.timer` masked;
- hard-block `iTCO_wdt` with `install iTCO_wdt /bin/false` and carry it
  into the initramfs;
- set Q35 `ICH9-LPC.noreboot=on` and the implicit iTCO action to `none`;
- use SDDM's X11 greeter for QXL, disable sleep/hibernate, and retain ACPI
  poweroff handling for clean Unraid shutdowns.

Tradeoffs: Forge gives up the user-space CET shadow-stack mitigation, guest
firmware updates, and the Q35 internal watchdog. Re-enable none of them until
the corresponding platform failure is independently fixed and requalified.

Forge's VNC endpoint is fixed at `172.23.0.1:5909`, password protected, and
bound only to Docker's internal `termix-private` bridge. The tracked XML omits
the entire VNC device so a raw definition fails closed; Arc injects the device
and secret from
`/boot/config/secrets/forge-vnc-password` into root-only runtime libvirt XML.
The `termix-private` network must exist before Forge starts.

The bootstrap explicitly installs Xorg core, the QXL display driver, libinput,
and `xcvt` before relying on SDDM's forced-X11 greeter. A VNC connection that
authenticates but shows a black framebuffer should first be checked with:

```bash
systemctl status sddm
pgrep -a 'Xorg|sddm-greeter'
```

If SDDM reports that `/usr/bin/X` cannot start, repair those four packages
rather than changing the validated QXL VM definition.

The QEMU guest agent is an administrative host-to-guest channel. Do not expose
its socket or libvirt control to agent identities.

`forge.arc.home.arpa` is reserved in Caddy and currently returns an intentional
`503` placeholder because Forge has no web application to proxy yet. Keep
`forge.arc.home.arpa` pointed at Caddy (`192.168.50.52`), not directly at the
VM. When a Forge web service exists, replace the placeholder with a direct
proxy to the DHCP-reserved Forge address and port.
