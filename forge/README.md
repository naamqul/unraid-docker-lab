# Forge

Forge is the always-on Kubuntu development VM. Interactive Codex, Claude, and
Hermes sessions run directly as `luqmaan`.

The private
[`homelab-agent-docs`](https://github.com/naamqul/homelab-agent-docs)
repository defines the architecture, access model, approval rules, and current
project handoffs. This directory contains the deployable Forge assets.

## Desired state

- Kubuntu/Ubuntu 26.04 guest named `forge`
- `luqmaan` has passwordless sudo and rootful Docker access
- `/workspace` is the dedicated 256 GiB ext4 disk
- `/workspace/{repos,builds,tmp}` belongs to `luqmaan`
- `~/developer` points to `/workspace/repos`
- SSH and RDP accept only the home LAN
- Ubuntu refreshes apt metadata but does not install unattended upgrades
- Komodo Periphery runs as root so Komodo can manage the Forge Docker daemon
- Beszel observes `/` and `/workspace`
- `codex`, `claude`, and `hermes` are direct commands for `luqmaan`
- Termix continues to connect as `luqmaan`; passwordless sudo needs no Termix
  credential or host change

## Files

| File | Purpose |
| --- | --- |
| `Forge.xml` | Current Unraid VM definition |
| `legacy/Forge-Legacy.xml` | Preserved legacy VM definition |
| `bootstrap.sh` | Base OS, workspace, sudo, Docker, SSH, RDP, and build tools |
| `install-harnesses.sh` | Official latest Codex, Claude, and Hermes installers |
| `install-onepassword-cli.sh` | Official 1Password CLI repository installer |
| `configure-integrations.sh` | Komodo Periphery, Beszel, direct Komodo CLI, and Arc SSH key |
| `authorize-forge-admin-key.sh` | Arc-side authorization for the dedicated Forge admin key |
| `stabilize.sh` | Existing Forge display/session recovery settings |
| `restart-unraid-docker-clean-env.sh` | Existing Arc Docker clean-environment recovery helper |
| `stacks/forge-observability/` | Beszel Agent Compose file and enrollment helper |

## Base bootstrap

Copy this directory to Forge, stage the existing `luqmaan` public key at
`/tmp/forge-admin.pub`, review the script, then run:

```bash
sudo /path/to/forge/bootstrap.sh
```

The script formats `/dev/vdb` only when it is the expected blank 256 GiB
workspace disk. It refuses an unexpected size, signature, partition layout,
filesystem, mount source, conflicting fstab entry, or existing
`~/developer` path.

It does not run `full-upgrade`. Package and image updates are separate,
user-approved tasks.

## Harnesses

After reviewing the current official upstream installers:

```bash
sudo /path/to/forge/install-harnesses.sh
```

The script installs the latest releases directly for `luqmaan` from:

- `https://chatgpt.com/codex/install.sh`
- `https://claude.ai/install.sh`
- `https://hermes-agent.nousresearch.com/install.sh`

It does not authenticate any harness or configure harness permission modes.
All Claude update paths are disabled. For an approved Claude update, temporarily
remove `DISABLE_AUTOUPDATER` and `DISABLE_UPDATES` from
`~/.claude/settings.json`, run `claude update`, and restore both values.
Rerunning the installer is an explicit harness update and requires user
approval. Hermes setup and its optional browser download are skipped.

Run `codex`, `claude`, or `hermes` from any normal `luqmaan` login: local
desktop, SSH, Termix, or a tmux session. Tmux is optional and provides session
persistence, not a separate identity.

## Integrations

`configure-integrations.sh` expects `/tmp/forge-integrations` to be owned by
root, mode `0700`, and to contain:

- `onboarding-key` and `onboarding-public-key`
- `api-key` and `api-secret`
- `unraid-host-ed25519.pub`
- `compose.yaml` from `stacks/forge-observability/`
- `enroll-beszel.py` from `stacks/forge-observability/`
- `stabilize.sh`

The four credential files must be mode `0600`; no staged file may be writable
by group or other. Then run:

```bash
sudo /path/to/forge/configure-integrations.sh
```

The script:

1. Installs checksum-pinned Komodo Periphery and `km`.
2. enrolls Periphery, verifies the connection, removes the one-time onboarding
   key, and asks Komodo to revoke it;
3. writes the Arc Komodo CLI profile to
   `~/.config/komodo/komodo.cli.toml` for `luqmaan`;
4. creates `~/.ssh/arc_admin_ed25519` with comment `forge-admin@forge`;
5. records the staged Arc host key and configures the `arc` and `unraid` SSH
   aliases.

The script restarts Periphery and XRDP. Treat running it as disruptive work and
obtain the approval required by the homelab operations policy first.

Copy only the generated public key to Arc and authorize it there:

```bash
/mnt/user/appdata/unraid-docker-lab/forge/authorize-forge-admin-key.sh \
  /tmp/arc_admin_ed25519.pub
```

The Arc helper atomically preserves unrelated root keys, replaces only entries
carrying the current `forge-admin@forge` marker, and installs one Ed25519 key
restricted to Forge's LAN IP. It does not use a forced command. Termix's
existing Arc key is unrelated and remains untouched. Before replacement, the
helper writes a timestamped, mode-`0600` backup beside `authorized_keys`.

## 1Password

Stage the Homelab-vault service-account token at
`/tmp/forge-op-service-account-token` with mode `0600`, then run:

```bash
sudo /path/to/forge/install-onepassword-cli.sh
```

The script installs the official 1Password CLI, moves the token to
`~/.config/1password/service-account-token` with mode `0600`, removes the
staged copy, and installs `~/.local/bin/op`. That small launcher exposes the
token only to `/usr/bin/op`; it is not exported into every Forge shell.

## Operating rules

- Use Komodo for Arc container deployment and lifecycle management.
- Direct `docker exec`, `docker inspect`, and log inspection are normal
  diagnostics; use direct lifecycle commands only for recovery, debugging, or
  bootstrapping when Komodo is unsuitable.
- Explain privileged or disruptive work in the plan and get approval before
  executing it.
- Prepare and validate everything possible before downtime, then give a
  just-in-time heads-up or go/no-go prompt appropriate to the impact.
- Never restart or shut down Forge, the Arc Docker daemon, or Arc without a
  final explicit go-ahead.
- Keep secrets and mutable application state out of Git.
- Reconcile exploratory live changes back into the repository before calling
  the task complete.
- Update `homelab-agent-docs` when nodes, services, dependencies, networking,
  access, operations, or pending work materially change.

## Recovery assets

`stabilize.sh`, `restart-unraid-docker-clean-env.sh`, both VM XML definitions,
and `stacks/forge-observability/` are retained as operational/recovery assets.
Do not run a restart helper merely to inspect or validate it.
