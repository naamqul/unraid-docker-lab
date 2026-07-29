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

`agent` is the single locked service identity shared by Codex, Claude Code, and
Hermes. It uses a system UID, a locked password, and a shell reachable only
through an authorized local transition such as `sudo -iu agent`; it does not
appear in SDDM and is deliberately absent from `sudo` and the rootful `docker`
group. The earlier `codex`, `claude`, and `hermes` accounts remain locked only
as rollback identities until their retained configuration has been retired.

The shared identity has narrowly scoped integrations:

- Komodo CLI credentials in
  `/home/agent/.config/komodo/komodo.cli.toml`, mode `0600`.
- A forced-command SSH key for Arc. The matching Unraid entry permits only the
  commands defined by `unraid-readonly-wrapper.sh`; it does not provide a
  shell, forwarding, or arbitrary root execution.
- A separate, normally unauthorized root key. Arc can grant it only from
  Forge's reserved address with an OpenSSH `expiry-time`, and the grant helper
  records the task, reason, fingerprint, expiry, and revocation.
- A repository-scoped GitHub deploy key for `homelab-agent-docs`.

The `agent` identity runs its own rootless Docker daemon and data root under
`/workspace/agent/state/docker`. Rootful Docker remains available only to root
for Periphery-managed system services.

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
├── agent/
│   ├── repos/              # Shared harness repositories
│   ├── state/              # Runtime and rootless Docker state
│   ├── cache/              # Shared harness caches
│   └── builds/             # Shared build outputs
├── repos/                  # Canonical working repositories
├── shared/                 # Shared artifacts
├── inbox/                  # Staging/import area
├── worktrees/agent/
├── builds/agent/
└── cache/agent/
```

Directories are setgid and have default ACLs so new files remain writable by
`agent-workspace`. Harnesses use separate Git worktrees when concurrent edits
would collide, while credentials and runtime state share the one Unix
principal. The mount root is mode `3770`: its sticky bit
prevents an agent from replacing root-owned top-level control entries while
preserving group collaboration. `/workspace/.system/beszel` is a root-only
mount marker used solely to report workspace filesystem metrics.

## Arc agent access tooling

The Git checkout under `/mnt/user/appdata` is a development source, not a
trusted root execution path. Its `/mnt/user` and `/mnt/user/appdata`
ancestors are mode `0777`, so a root SSH forced command must never execute
repository bytes there.

Reviewed sources are snapshotted once, checked against an independently
supplied manifest digest, and atomically installed under the dedicated
root-controlled directory `/boot/config/custom/forge-agent-access`:

| Tracked source | Protected Arc path | Role |
| --- | --- | --- |
| `forge/unraid-readonly-wrapper.sh` | `/boot/config/custom/forge-agent-access/forge/unraid-readonly-wrapper.sh` | Standing forced-command diagnostic allowlist. |
| `forge/authorize-unraid-agent-key.sh` | `/boot/config/custom/forge-agent-access/forge/authorize-unraid-agent-key.sh` | Installs or rotates only the source-restricted read-only key. |
| `forge/manage-unraid-agent-root.sh` | `/boot/config/custom/forge-agent-access/forge/manage-unraid-agent-root.sh` | Grants, reports, or revokes the separate expiring root key. |

The machine-readable copy of this mapping is
`forge/unraid-agent-access.map`; the map itself is included in
`forge/unraid-agent-access.sha256`. Protected scripts are regular,
root-owned, mode-`0500` files. The verifier rejects symlinks, non-root
ownership, group/world-writable ancestry, missing manifest pins, and byte
drift.

For CI or a non-Arc checkout:

```bash
forge/verify-unraid-agent-access.sh --source-only
```

After a protected bundle has been installed, run the non-mutating live
verifier only from that bundle:

```bash
/boot/config/custom/forge-agent-access/forge/verify-unraid-agent-access.sh \
  --live
```

The live check shares the updater lock and validates protected ancestry,
manifest pins, the map, exact forced-command path, temporary-root expiry, and
audit-log permissions. It never invokes the access managers, changes
`authorized_keys`, or prints key bodies.

### Protected update trust flow

`forge/update-unraid-agent-access.sh` must not be executed from the repository.
For initial bootstrap, an administrator copies it once to a root-only
temporary path, verifies that snapshot against a SHA-256 value obtained from
the reviewed GitHub commit rather than from Arc's checkout, and invokes the
verified snapshot with:

```bash
FORGE_AGENT_ACCESS_BOOTSTRAP=1 /root/update-unraid-agent-access.verified \
  update /mnt/user/appdata/unraid-docker-lab \
  FULL_REVIEWED_COMMIT_ID INDEPENDENT_MANIFEST_SHA256
```

The updater snapshots each listed source into a root-only staging directory,
then validates the independently pinned manifest and all seven content hashes
before any protected file changes. It uses a root-only exclusive lock and
atomic per-file replacement; the updater and manifest are replaced last.
It also records the reviewed commit and independent manifest digest in the
root-only `source.pin`; the live verifier recomputes and compares that pin.
Later updates run only the already protected updater:

```bash
/boot/config/custom/forge-agent-access/forge/update-unraid-agent-access.sh \
  update /mnt/user/appdata/unraid-docker-lab \
  FULL_REVIEWED_COMMIT_ID INDEPENDENT_MANIFEST_SHA256
```

The commit check records provenance, while the independently obtained
manifest digest is the integrity pin: the Git metadata and files beneath
`/mnt/user` are not trusted. `/boot` is a ZFS mount and `/boot` plus
`/boot/config` are root-owned mode `0700`; the dedicated bundle is also
`0700`. The cold backup already archives `/boot/config` with ownership and
xattrs and runs weekly restore tests. That backup is same-host and unencrypted,
however, and is a recovery copy rather than an independent integrity anchor.
Neither this boundary nor its hashes defend against Arc root, root-equivalent
Komodo/Docker control, physical/offline modification, or compromise of the
independent review channel.

Current Arc state (audited 2026-07-29) is **not live-verified** and must not be
described as such. The standing entry still executes the wrapper through the
replaceable `/mnt/user/appdata` path, the protected bundle/cutover has not been
installed, and an unmanaged `forge-codex-readonly` legacy entry remains.
This source-only work intentionally does not remove, rewrite, or add any live
authorization. An administrator must install and verify the protected bundle,
remove the unmanaged legacy entry explicitly, rotate the marked entry through
the protected authorizer, and rerun `--live`.

The normal state is one standing read-only key and no
`forge-agent-unraid-root` entry. The separate root private key may remain
staged on Forge, but it has no authority until an explicitly approved,
source-restricted, expiring public-key entry is installed by
the protected `manage-unraid-agent-root.sh`. Never replace that lifecycle with an
unrestricted or permanent entry. Standing agent access does not expose QEMU
Guest Agent execution, arbitrary `virsh`, an interactive root shell, or an
equivalent host-control path; those remain behind a separately approved,
time-bounded root grant.

### Clean Docker restart environment

Do not restart Unraid Docker directly from an arbitrary SSH login environment.
A prior SSH-initiated restart passed
`XDG_RUNTIME_DIR=/run/user/0` and `DBUS_SESSION_BUS_ADDRESS` into `dockerd` and
`containerd`. When that login runtime disappeared, health checks and
`docker exec` failed even though the daemons were still present.

The protected root-only helper runs Arc's stock restart script with those two
variables removed:

```bash
/boot/config/custom/forge-agent-access/forge/restart-unraid-docker-clean-env.sh \
  restart all-containers-will-restart
```

This is disruptive: every container stops and restarts. Schedule downtime,
capture `docker ps` first, and confirm the VPN-dependent workloads can wait for
Gluetun to become healthy. The helper executes the equivalent of:

```bash
/usr/bin/env \
  -u XDG_RUNTIME_DIR \
  -u DBUS_SESSION_BUS_ADDRESS \
  /etc/rc.d/rc.docker restart
```

It then requires `dockerd`, `containerd`, and every
`containerd-shim-runc-v2` process to omit those variables, because the shims
directly invoke `runc`. It also checks that `docker info` and `docker ps`
succeed. It does not patch `/etc/rc.d/rc.docker`, install an environment file,
or change boot configuration.

After the daemon-level check, perform dependency-aware recovery validation:

1. wait for Gluetun to report healthy before judging SearXNG, jDownloader,
   Neko, or other namespace-sharing dependents;
2. confirm the registered Komodo stacks and expected containers are running;
3. check Caddy and the externally used service URLs;
4. check Beszel telemetry and a representative Jellyfin playback probe;
5. inspect `docker ps` for unhealthy or restart-looping containers.

Rollback is operational rather than file-based because the helper persists no
daemon configuration. If recovery fails, use the Unraid console to inspect
Docker logs and run the same stock restart from a clean root environment, or
reboot Arc during the approved outage. Reverting this helper removes only the
guarded launcher; never modify the stock `rc.docker` script to compensate.

## Rebuild artifacts

- `Forge.xml` is the secret-free replacement definition. It includes stock
  Unraid VNC and the separately prepared workspace disk, but no passthrough
  device, installer ISO, or VNC secret.
- `legacy/Forge-Legacy.xml` is the headless rollback definition. It uses a
  noncanonical MAC and cannot collide with Forge's reserved DHCP identity.
- `bootstrap.sh` installs the guest baseline and safely initializes an empty
  256 GiB `/dev/vdb` as `/workspace`. It requires an external public key file;
  no key is embedded.
- `migrate-shared-agent.sh` creates or reconciles the locked `agent` principal,
  rootless Docker, scoped keys, workspace state, and all three CLI harnesses.
- `install-onepassword-cli.sh` verifies 1Password's published repository-key
  fingerprint and installs the official CLI without configuring an account,
  vault, item, or token. Credential provisioning follows the canonical
  `homelab-agent-docs/runbooks/provision-agent-1password.md` runbook.
- `stabilize.sh` applies the mandatory Kubuntu 26.04 shadow-stack/fwupd and
  Q35 iTCO containment before the rest of bootstrap work.
- `configure-integrations.sh` installs pinned, checksummed Periphery and `km`
  `2.2.0` binaries; configures outbound-only Periphery and the restricted
  shared-agent integrations; stages observability files; and removes one-time
  Komodo credentials after use.
- `unraid-readonly-wrapper.sh` is installed only in Arc's protected
  `/boot/config/custom/forge-agent-access` bundle and is the allowlist behind
  the Forge-to-Unraid SSH key.
- `update-unraid-agent-access.sh`, its SHA-256 manifest, and the access map
  provide the independently pinned source-to-protected update flow.
- The protected `authorize-unraid-agent-key.sh` atomically installs that
  public key with the source-IP, `restrict`, and forced-command controls. It
  snapshots its root-owned input key once and refuses a writable wrapper,
  unsafe ancestry, unmanaged legacy entry, or conflicting/duplicate key.
- The protected `manage-unraid-agent-root.sh` grants, reports, and revokes the separate
  source-restricted root key with a maximum eight-hour OpenSSH expiry and a
  persistent root-only audit log. Both authorization helpers share an
  exclusive lock around `authorized_keys`.
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
3. The shared `agent` Komodo CLI profile works, and the forced-command Arc key passed
   both its allowlisted `host-summary` test and an arbitrary-command rejection
   test. The one-time Komodo onboarding key was removed and revoked.
4. Forge's repository-scoped GitHub key was generated, authorized as a deploy
   key, and GitHub's published Ed25519 host key was pinned.
5. xRDP is configured and TCP 3389 is reachable end to end. The live Termix
   desktop entry uses RDP at `192.168.50.179:3389`, reaches the xRDP login
   screen, stores no guest username or password, and has session recording
   disabled. Stock Termix 2.5.1 resizes the live session to its browser canvas,
   regardless of the profile's saved initial dimensions, so the desktop is
   viewport-responsive rather than fixed at 3840x2160. KDE scaling is a
   separate guest setting; use a native RDP client later if fixed 4K at 150%
   scaling is required. Closing an unrecorded session may emit a benign
   `guac_recording_missing` warning in Termix 2.5.1 even though no recording is
   enabled or created.

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
4. Copy `/home/agent/.ssh/unraid_readonly_ed25519.pub` to a root-owned temporary
   file on Arc, then run:

   ```bash
    # First installation:
    /boot/config/custom/forge-agent-access/forge/authorize-unraid-agent-key.sh \
      /tmp/forge-agent-unraid-readonly.pub

    # Replacement guest with the prior marked entry still present:
    /boot/config/custom/forge-agent-access/forge/authorize-unraid-agent-key.sh \
      --rotate /tmp/forge-agent-unraid-readonly.pub
   ```

   On a replacement guest, review the existing marked key and add `--rotate`
   before the public-key path. The helper then atomically replaces only the
   previously restricted Forge read-only entry and prints both
   fingerprints. Remove the temporary public file after authorization and verify
   `sudo -H -u agent ssh unraid host-summary` succeeds while an arbitrary
   command is rejected.
   For exceptional maintenance, stage
   `/home/agent/.ssh/unraid_root_ed25519.pub` on Arc and use the separate
   audited helper:

   ```bash
   /boot/config/custom/forge-agent-access/forge/manage-unraid-agent-root.sh grant \
     /tmp/forge-agent-unraid-root.pub 60 issue-123 \
     "Exact approved maintenance reason"
   /boot/config/custom/forge-agent-access/forge/manage-unraid-agent-root.sh status
   /boot/config/custom/forge-agent-access/forge/manage-unraid-agent-root.sh revoke \
     issue-123 "Maintenance complete"
   ```

   Never substitute this temporary key for the standing forced-command key.
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
sudo docker version
sudo docker compose version
sudo -iu agent docker info
sudo -iu agent km core-info
sudo -iu agent ssh unraid host-summary
op --version
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
