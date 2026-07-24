# Forge

Forge is the always-on development VM hosted by Arc. It is intentionally
independent from the existing `Kubuntu` graphics-development VM: it has its own
UUID, MAC address, NVRAM, operating-system disk, and workspace disk. Completing
the Panther Lake graphics work and configuring backups are separate follow-up
projects.

## Current VM

| Setting | Value |
| --- | --- |
| Guest | Kubuntu 26.04 / Ubuntu 26.04 LTS base, provisioned |
| UUID | `1528c7a1-af0a-2d8c-11eb-6c9e2a0faeb0` |
| MAC | `52:54:00:c7:1f:f3` |
| Reserved DHCP address | `192.168.50.179` |
| Compute | 12 vCPU, 8 GiB current / 48 GiB maximum ballooned RAM |
| OS disk | `/mnt/user/domains/Forge/vdisk1.img`, 256 GiB sparse raw |
| Workspace disk | `/mnt/user/domains/Forge/workspace.img`, 256 GiB sparse raw |
| Workspace mount | `/dev/vdb1` at `/workspace`, ext4 label `forge-workspace`, `noatime` |
| Console | xRDP on TCP 3389 for normal use; 2D VirtIO plus stock Unraid VNC for break-glass access |
| Startup | Enabled in libvirt after cold-boot validation |

Final validation on 2026-07-24 detached the installer ISO and exercised a full
power-off/start cycle. QGA, SSH, Docker, xRDP, Periphery, and both Forge
observability containers recovered automatically; `/workspace` and the 16 GiB
swap file were present; RDP was reachable from Windows and Termix's guacd
container; Beszel reported Forge `up`; and `virsh dominfo Forge` reported
`Autostart: enable`.

The ASUS DHCP reservation binds `192.168.50.179` to
`52:54:00:c7:1f:f3`. Use the reserved address for long-lived automation;
`forge.local` remains a convenience name supplied by router DNS.

`Forge-Legacy` retains the previous disks and NVRAM as rollback, but is
headless, non-autostarting, and uses MAC `52:54:00:91:8f:2b`. Never assign it
Forge's canonical MAC while both definitions exist.

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

Ubuntu's normal password and public-key SSH authentication remain available;
the optional key-only hardening workflow was deliberately removed. UFW accepts
SSH and RDP only from `192.168.50.0/24`. Arc's routed Tailscale traffic arrives
from the home subnet, so the same rules cover remote access through the
existing subnet router.

The 8 GiB memory value is the normal balloon target, not a proactive
load-based autoscaler. VirtIO `autodeflate` is enabled so QEMU can return
memory up to the 48 GiB maximum at the last moment before the guest OOM killer
terminates a process. Sustained known-heavy workloads should still have their
target raised deliberately through Unraid or `virsh setmem`; autodeflate is an
emergency safety net rather than capacity planning.

`codex`, `claude`, and `hermes` are locked service identities. They share only
the `agent-workspace` group and are deliberately absent from `sudo` and
`docker`. Docker group membership is root-equivalent and must not be granted
casually.

The `codex` identity has two narrowly scoped integrations:

- Komodo CLI credentials in
  `/home/codex/.config/komodo/komodo.cli.toml`, mode `0600`.
- A forced-command SSH key for Arc. The matching Unraid entry permits only the
  commands defined by `unraid-readonly-wrapper.sh`; it does not provide a
  shell, forwarding, or arbitrary root execution. Its public-key fingerprint
  is `SHA256:KAo11QivnAP/hpB5odluG2bDbAs0QGpXCh7LZRC55O0`.

Forge's replacement GitHub Ed25519 key exists as
`/home/luqmaan/.ssh/github_forge_ed25519`; its fingerprint is
`SHA256:3hvdNG7n6XEwI1ZJLKLatJoNA4Vfoflg361fq0gfZ3A`. Adding the public half to
the GitHub account remains a user-controlled step. The legacy VM's key and
fingerprint are not identities of the replacement guest.

Komodo Periphery `2.2.0` runs as a root systemd service in outbound mode to
`https://komodo.arc.bonfireboogie.com`. It opens no inbound port, uses a
publicly trusted certificate, and has both general and container terminal APIs
disabled.
Komodo stack deployment remains root-equivalent even with those terminal APIs
disabled.

The Komodo secret, SSH private keys, installer password, Porkbun credentials,
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
edit and build collisions. The mount root is mode `3770`: its sticky bit
prevents an agent from replacing root-owned top-level control entries while
preserving group collaboration. `/workspace/.system/beszel` is a root-only
mount marker used solely to report workspace filesystem metrics.

## Rebuild artifacts

- `Forge.xml` is the secret-free replacement definition. It includes stock
  Unraid VNC and the separately prepared workspace disk, but no passthrough
  device, installer ISO, or VNC secret.
- `legacy/Forge-Legacy.xml` is the headless rollback definition. It uses a
  noncanonical MAC and cannot collide with Forge's reserved DHCP identity.
- `bootstrap.sh` installs the guest baseline and safely initializes an empty
  256 GiB `/dev/vdb` as `/workspace`. It requires an external public key file;
  no key is embedded.
- `stabilize.sh` applies the mandatory Kubuntu 26.04 shadow-stack/fwupd and
  Q35 iTCO containment before the rest of bootstrap work.
- `configure-integrations.sh` installs pinned, checksummed Periphery and `km`
  `2.2.0` binaries; configures outbound-only Periphery and the restricted
  `codex` integrations; stages observability files; and removes one-time
  Komodo credentials after use.
- `unraid-readonly-wrapper.sh` is installed on Arc at the same path as this
  repository copy and is the allowlist behind the Forge-to-Unraid SSH key.
- `authorize-unraid-agent-key.sh` runs on Arc and atomically installs that
  public key with the source-IP, `restrict`, and forced-command controls. It
  refuses a writable wrapper, unsafe input file, or conflicting prior key.
- `stacks/forge-observability` contains the outbound Beszel agent, a
  GET-filtered Docker proxy exposed only as a root-only Unix socket, and the
  hidden-prompt enrollment helper.

Kubuntu's desktop ISO uses Calamares and does not support Ubuntu Server's
Subiquity autoinstall format. Rebuilding therefore has one interactive install
stage followed by the scripted baseline. Start the VM from Unraid and use the
stock Unraid VNC console for installation and break-glass recovery. Termix uses
RDP only after the installed guest has been provisioned for it.

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

# From another terminal, verify key login remains available.
ssh -i ~/.ssh/forge_ed25519 luqmaan@forge.local

sudo reboot
```

Before running `bootstrap.sh`, confirm `/dev/vdb` is the new empty 256 GiB
workspace disk. The script refuses to format a disk with an unexpected size,
partition table, or filesystem signature.

### Post-bootstrap integrations

The guest bootstrap intentionally does not embed infrastructure credentials.
The current guest has completed the following integration pass:

1. Pinned Periphery `2.2.0` connects outbound to
   `https://komodo.arc.bonfireboogie.com`; general and container terminal APIs
   are disabled. The existing Komodo server and Files-on-host observability
   stack are healthy.
2. `enroll-forge-beszel` and the observability Compose file are installed in
   their documented locations. Forge is enrolled, its two-container stack is
   deployed, and the one-time enrollment files were deleted.
3. The `codex` Komodo CLI profile works, and the forced-command Arc key passed
   both its allowlisted `host-summary` test and an arbitrary-command rejection
   test. The one-time Komodo onboarding key was removed and revoked.
4. Forge's GitHub key was generated and GitHub's published Ed25519 host key was
   pinned. Only uploading the public key to the GitHub account remains.
5. xRDP is configured and TCP 3389 is reachable end to end. The live Termix
   desktop entry still needs its one-time UI conversion from legacy VNC to RDP;
   leave its username/password blank so xRDP presents the guest login screen,
   and disable Termix session recording.

For a clean rebuild, replay the tracked integration flow as follows:

1. In Komodo, create or reset the existing `Forge` server's one-time onboarding
   key and retain both returned values: its secret and its public key. Prepare a
   scoped Komodo API key/secret that can inspect the server and revoke the
   onboarding key.
2. On Forge, create a root-only staging directory:

   ```bash
   sudo install -d -o root -g root -m 0700 /run/forge-integrations
   ```

   Populate these exact root-owned filenames. Credential files must be mode
   `0600`; all other files must be regular, nonsymlink files with no
   group/other write bit.

   | Staged filename | Source |
   | --- | --- |
   | `onboarding-key` | One-time Komodo onboarding secret |
   | `onboarding-public-key` | Public key returned with that onboarding secret |
   | `api-key` / `api-secret` | Scoped Komodo API credential |
   | `compose.yaml` | `forge/stacks/forge-observability/compose.yaml` |
   | `enroll-beszel.py` | `forge/stacks/forge-observability/enroll-beszel.py` |
   | `stabilize.sh` | `forge/stabilize.sh` |
   | `unraid-host-ed25519.pub` | Arc's `/etc/ssh/ssh_host_ed25519_key.pub` |

3. Install and run the integration helper from a root-owned copy:

   ```bash
   sudo install -o root -g root -m 0750 \
     forge/configure-integrations.sh \
     /usr/local/sbin/configure-forge-integrations
   sudo STAGE_DIR=/run/forge-integrations \
     /usr/local/sbin/configure-forge-integrations
   ```

   The helper verifies Forge becomes healthy in Core, removes the onboarding
   secret from Periphery, reconnects using its persisted identity, revokes the
   Core-side onboarding key, and deletes the staged Komodo credentials. A
   failed run also strips any embedded onboarding secret before exiting. If
   Core revocation cannot be confirmed, it retains the root-only
   `onboarding-public-key` file and prints a warning; revoke that exact key in
   Komodo before retrying.
4. Copy `/home/codex/.ssh/unraid_readonly_ed25519.pub` to a root-owned temporary
   file on Arc, then run:

   ```bash
   # First installation:
   /mnt/user/appdata/unraid-docker-lab/forge/authorize-unraid-agent-key.sh \
     /tmp/forge-codex-unraid-readonly.pub

   # Replacement guest with the prior marked entry still present:
   /mnt/user/appdata/unraid-docker-lab/forge/authorize-unraid-agent-key.sh \
     --rotate /tmp/forge-codex-unraid-readonly.pub
   ```

   On a replacement guest, review the existing marked key and add `--rotate`
   before the public-key path. The helper then atomically replaces only the
   previously restricted `forge-codex-unraid-readonly` entry and prints both
   fingerprints. Remove the temporary public file after authorization and verify
   `sudo -H -u codex ssh unraid host-summary` succeeds while an arbitrary
   command is rejected.
5. Enroll Beszel only after the preceding trust paths pass. A normal Beszel
   user automatically owns the new record. When authenticating as a Beszel
   superuser, also provide the intended 15-character normal-user record ID at
   the hidden prompt, or through a root-owned mode-`0600` file referenced by
   `BESZEL_OWNER_USER_ID_FILE`; the helper never guesses ownership from a
   system name.

   ```bash
   # On Forge:
   sudo /usr/local/sbin/enroll-forge-beszel

   # On Arc, after enrollment succeeds:
   printf '\n' |
     docker exec -i komodo km execute deploy-stack forge-observability
   docker exec komodo km list stacks \
     --all --format json --name forge-observability
   ```

   Finish by confirming both containers are running, the agent log reports a
   WebSocket connection to `beszel.arc.bonfireboogie.com`, and the Beszel Hub
   reports Forge `up`.

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
systemctl is-active ssh qemu-guest-agent docker containerd xrdp periphery
findmnt /workspace
swapon --show
docker version
docker compose version
sudo -H -u codex km core-info
sudo -H -u codex ssh unraid host-summary
systemctl is-enabled fwupd.service fwupd-refresh.service fwupd-refresh.timer
modprobe -n -v iTCO_wdt
```

The expected results are: core runtime services active; Komodo Core metadata
returned; the restricted Arc summary returned without a shell; all three fwupd
units `masked`; and the dry-run modprobe ending in `install /bin/false`.
`virsh dominfo Forge` on Arc should report `Autostart: enable`.

## Platform containment

Forge previously reproduced the Panther Lake repository's F10 failure even
without iGPU passthrough. An `fwupd-refresh` activation was followed within two
seconds by unrelated processes faulting at the same address with page-fault
error `0x44/0x46`; Linux continued answering ICMP while SSH, QGA, D-Bus, and
the desktop died. That incident is the documented KVM/CET user-shadow-stack
collapse, not a VFIO failure.

The separate freeze on 2026-07-23 had a different signature: `fwupd` never
activated, one guest vCPU remained pinned at a fixed kernel instruction, and
the recovered journal contained repeated QXL/Mesa display errors. No kernel
trace identified the initiating driver, so QXL cannot be proven as the cause,
but the display path was the strongest correlate. Forge was recovered by
switching QXL to plain 2D VirtIO; two clean boots and a soak beyond the original
failure window passed.

The required containment is deliberate:

- boot with `nousershstk`;
- keep `fwupd.service`, `fwupd-refresh.service`, and
  `fwupd-refresh.timer` masked;
- hard-block `iTCO_wdt` with `install iTCO_wdt /bin/false` and carry it
  into the initramfs;
- set Q35 `ICH9-LPC.noreboot=on` and the implicit iTCO action to `none`;
- retain Kubuntu's supported Wayland default with 2D VirtIO, disable
  sleep/hibernate, and let logind handle the ACPI power key even when KDE's
  PowerDevil holds its normal desktop inhibitor, so Unraid can shut Forge down
  cleanly.

Tradeoffs: Forge gives up the user-space CET shadow-stack mitigation, guest
firmware updates, and the Q35 internal watchdog. Re-enable none of them until
the corresponding platform failure is independently fixed and requalified.

Forge uses xRDP as its normal remote desktop path and retains Unraid's stock
auto-assigned VNC console for trusted-LAN break-glass access. The tracked XML
contains no secret; set a VNC password through Unraid/libvirt at runtime if the
console must remain available. Until then, never port-forward the raw VNC
listener or expose it to an untrusted network. The XML listens on `0.0.0.0`,
so this trust boundary is operational rather than interface-enforced: routed
tailnet clients can also reach it through Arc's subnet route. Configure a
runtime VNC password or a management-network ACL if every LAN/tailnet device is
not trusted.

The bootstrap installs the Xorg core and input packages as a fallback while
leaving Kubuntu's supported Wayland greeter/session default intact. If Unraid
VNC shows a black framebuffer, first check:

```bash
systemctl status sddm
pgrep -a 'Xorg|sddm-greeter'
```

Inspect `journalctl -b` for display-manager, VirtIO DRM, or Mesa errors before
changing the validated VirtIO VM definition.

The QEMU guest agent is an administrative host-to-guest channel. Do not expose
its socket or libvirt control to agent identities.

`forge.arc.bonfireboogie.com` is reserved in Caddy and currently returns an intentional
`503` placeholder because Forge has no web application to proxy yet. Keep
`forge.arc.bonfireboogie.com` pointed at Caddy (`192.168.50.52`), not directly at the
VM. When a Forge web service exists, replace the placeholder with a direct
proxy to the DHCP-reserved Forge address and port.
