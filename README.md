# unraid-docker-lab

Version-controlled Docker Compose and hand-authored configuration for the
Unraid host `Arc`. Mutable application state lives outside this repository in
cache-backed `appdata` directories.

## Layout

```text
forge/                   # Forge VM definition, bootstrap, and access controls
komodo/
├── compose.yaml       # Bootstrap stack owned by Compose Manager Plus
├── .env               # Local secrets; ignored by Git
├── .env.example       # Tracked template
└── stacks/            # Stacks managed by Komodo Periphery
    ├── ai/
    ├── caddy/          # LAN reverse proxy and its Caddyfile
    ├── general/        # Homepage, monitoring, files, search, and downloads
    └── jellyfin/       # Media server; mutable state is kept outside Git
```

Komodo runtime state is stored separately:

```text
/mnt/user/appdata/komodo-state/
├── mongo-data/
├── mongo-config/
├── keys/
└── backups/
```

## Before first startup

Edit `komodo/.env` and replace every value containing `UPDATE_ME`. Use a
different high-entropy value for each password or secret. Do not initialize
Mongo with the placeholders: its root credentials are only created when the
database is empty.

Required values:

- `KOMODO_DATABASE_USERNAME`
- `KOMODO_DATABASE_PASSWORD`
- `KOMODO_INIT_ADMIN_USERNAME`
- `KOMODO_INIT_ADMIN_PASSWORD`
- `KOMODO_WEBHOOK_SECRET`
- `KOMODO_JWT_SECRET`

Validate before deployment:

```bash
cd /mnt/user/appdata/unraid-docker-lab/komodo
grep -n UPDATE_ME .env
docker compose --env-file .env config --quiet
```

The first command must produce no output before deployment.

## Bootstrap with Compose Manager Plus

Create an indirect/external stack with these paths:

```text
Compose: /mnt/user/appdata/unraid-docker-lab/komodo/compose.yaml
Env:     /mnt/user/appdata/unraid-docker-lab/komodo/.env
```

Start it once, verify `http://arc.local:9120`, and then enable autostart. After
Caddy's internal CA is trusted, use `https://komodo.arc.home.arpa` instead.
Compose Manager Plus should continue owning the Komodo bootstrap stack;
Komodo can manage the application stacks below `komodo/stacks/`.

## Persistence and backups

- Compose and hand-authored configuration are versioned here.
- Mongo data and Core/Periphery keys are under
  `/mnt/user/appdata/komodo-state` and must be included in appdata backups.
- Komodo database exports are written to
  `/mnt/user/appdata/komodo-state/backups`.
- Open WebUI data is stored outside the repository at
  `/mnt/user/appdata/open-webui-state/data`.
- The real `.env` is intentionally excluded from Git and must be backed up
  securely through a separate encrypted mechanism.

## Forge development VM

The always-on Forge VM is documented under [`forge/`](forge/README.md).
That directory contains its persistent libvirt definition, secret-free guest
bootstrap and SSH-hardening scripts, and the allowlisted Forge-to-Unraid
diagnostic wrapper. Forge has independent storage and identity from the
existing graphics-development VM; the Panther Lake repository migration and
backup policy are intentionally separate follow-up work.

## Reverse proxy and remote access

Caddy owns `192.168.50.52` on Docker's Unraid-managed `br0` network. It also
joins the external `caddy-backend` bridge, which lets it reach application
containers directly without sending backend traffic through host-published
ports.

The `unraid-webui-bridge` helper is attached only to `caddy-backend`. It exists
because Unraid's macvlan host isolation prevents the main Caddy container on
`br0` from connecting directly to `192.168.50.51`; the helper reaches the host
through Docker's bridge and publishes no port of its own.

Arc advertises `192.168.50.0/24` as a Tailscale subnet route. After approving
that route in the Tailscale admin console, a remote Tailscale client can reach
the same `192.168.50.52` address used on the LAN. Linux clients must also run
`tailscale set --accept-routes=true`; Windows, macOS, iOS, and Android accept
subnet routes by default.

The configured private names are:

| Name | Backend |
| --- | --- |
| `caddy.arc.home.arpa` | Caddy health response |
| `komodo.arc.home.arpa` | `komodo:9120` |
| `jellyfin.arc.home.arpa` | `jellyfin:8096` |
| `unraid.arc.home.arpa` | Unraid host WebUI through the isolated bridge helper |
| `home.arc.home.arpa` | `homepage:3000` |
| `homepage.arc.home.arpa` | `homepage:3000` |
| `beszel.arc.home.arpa` | `beszel:8090` |
| `termix.arc.home.arpa` | `termix:8080` |
| `jdownloader.arc.home.arpa` | `general-gluetun:5800` |
| `filebrowser.arc.home.arpa` | `filebrowser:80` |
| `searxng.arc.home.arpa` | `general-gluetun:8080` |
| `open-webui.arc.home.arpa` | `gluetun:8080` |
| `hermes.arc.home.arpa` | `gluetun:9119` |
| `hermes-api.arc.home.arpa` | `gluetun:8642` |
| `forge.arc.home.arpa` | Reserved Caddy `503` placeholder until Forge hosts a web service |

`home.arpa` is used deliberately. Do not use subdomains of `arc.local` here:
`.local` is reserved for multicast DNS, and wildcard/unicast records beneath
it are unreliable across operating systems and Tailscale.

### One-time setup

1. Reserve `192.168.50.52` for MAC `02:42:c0:a8:32:34` in ASUS DHCP, or
   exclude the address from the dynamic pool. Compose assigns this address
   statically and does not request a DHCP lease.
   Separately reserve `192.168.50.179` for Forge's MAC
   `52:54:00:c7:1f:f3`; that lease is used for direct SSH and future Caddy
   upstreams.
2. In NextDNS Rewrites (or another DNS server used by both LAN and Tailscale
   clients), point `arc.home.arpa` to `192.168.50.52`. NextDNS applies that
   rewrite to the base name and all subdomains, including future apps.
   Add the more-specific exception `router.arc.home.arpa` →
   `192.168.50.1`; the router uses plain HTTP directly and intentionally
   bypasses Caddy.
3. In the Tailscale admin console, open Arc's route settings and approve
   `192.168.50.0/24`. Advertising a route on Arc does not activate it until it
   is approved, unless an `autoApprovers` policy already covers it.
4. Create the shared backend and isolated Termix control network once:

   ```bash
   docker network create caddy-backend
   docker network create --driver bridge --internal \
     --subnet 172.23.0.0/24 --gateway 172.23.0.1 termix-private
   ```

5. Copy the Caddy environment template and create its state directories:

   ```bash
   cd /mnt/user/appdata/unraid-docker-lab/komodo/stacks/caddy
   cp .env.example .env
   mkdir -p /mnt/user/appdata/caddy-state/data
   mkdir -p /mnt/user/appdata/caddy-state/config
   ```

6. Redeploy the Komodo and AI stacks so `komodo` and `gluetun` join
   `caddy-backend`, then import the running Caddy project into Komodo as a
   Stack. Use these settings:

   ```text
   Name / project name: caddy
   Server:              Arc
   Run directory:       /mnt/user/appdata/unraid-docker-lab/komodo/stacks/caddy
   Compose file:        compose.yaml
   ```

   In the Stack's Environment field, copy the three values from
   `caddy/.env.example`. Komodo writes that field to `.env` and passes it to
   Compose. The project name must remain `caddy` so Komodo imports the running
   project instead of creating a second one. Do not also register Caddy in
   Compose Manager Plus; one stack should have exactly one ongoing owner.

7. Validate Caddy's configuration on Arc, then test the macvlan address from
   another LAN client. The Unraid host itself cannot directly reach its own
   `br0` macvlan containers by design.

   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   curl http://192.168.50.52
   curl -k --resolve komodo.arc.home.arpa:443:192.168.50.52 \
     https://komodo.arc.home.arpa
   ```

The Caddyfile uses Caddy's internal CA because `home.arpa` cannot receive
publicly trusted certificates. Install the public root certificate from
`/mnt/user/appdata/caddy-state/data/caddy/pki/authorities/local/root.crt` in
each client trust store. Never distribute the adjacent private key. Caddy's
persisted `/data` directory must be backed up; losing it creates a new CA that
clients will not yet trust.

### Add another proxied application manually

For an ordinary container:

1. Declare `caddy-backend` as an external network in that stack and attach the
   web service to it:

   ```yaml
   services:
     example:
       networks:
         - default
         - caddy-backend

   networks:
     caddy-backend:
       name: caddy-backend
       external: true
   ```

2. Add a site to `komodo/stacks/caddy/Caddyfile` using the Compose service
   name and the container's internal port:

   ```caddyfile
   example.arc.home.arpa {
       tls internal
       reverse_proxy example:8080
   }
   ```

3. The existing `arc.home.arpa` wildcard rewrite already covers the new name;
   do not add a redundant per-application rewrite.
4. Redeploy the application, validate the Caddyfile, and gracefully reload it:

   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

For a container using `network_mode: service:gluetun`, do not attach that
container separately. Attach `gluetun` to `caddy-backend`, add the application's
listening port to Gluetun's `FIREWALL_INPUT_PORTS`, and proxy to
`gluetun:<internal-port>` as the existing Open WebUI and Hermes entries do.

Host-published ports on Gluetun are currently retained as a recovery path.
After Open WebUI and Hermes work through Caddy, those `ports:` entries can be
removed to make Caddy the only LAN entry point.

## Komodo stack ownership

Periphery monitoring makes every Docker container visible under Arc, but it
does not automatically create a Komodo Stack resource. A stack only appears in
Komodo's Stacks page after it is registered in Komodo's database.

Compose Manager Plus owns only the `komodo` bootstrap project. Komodo owns the
application projects:

| Stack | Run directory | Compose project |
| --- | --- | --- |
| `ai` | `/mnt/user/appdata/unraid-docker-lab/komodo/stacks/ai` | `ai` |
| `caddy` | `/mnt/user/appdata/unraid-docker-lab/komodo/stacks/caddy` | `caddy` |
| `general` | `/mnt/user/appdata/unraid-docker-lab/komodo/stacks/general` | `general` |
| `jellyfin` | `/mnt/user/appdata/unraid-docker-lab/komodo/stacks/jellyfin` | `jellyfin` |

Each is a **Files on host** stack on server `Arc`, using `compose.yaml`. Keep
the Komodo stack name and Compose project name identical so Komodo adopts the
existing project rather than creating a second one. Once an authenticated
Komodo CLI profile exists, deployments can be run from Core with:

```bash
printf '\n' | docker exec -i komodo km execute deploy-stack ai
printf '\n' | docker exec -i komodo km execute deploy-stack caddy
printf '\n' | docker exec -i komodo km execute deploy-stack general
printf '\n' | docker exec -i komodo km execute deploy-stack jellyfin
```

Forge also has a **Files on host** stack named `forge-observability`, on server
`Forge`, rooted at `/etc/komodo/stacks/forge-observability`. It remains stopped
until its dedicated Beszel key and token have been enrolled.

## General services

The `general` stack contains Homepage, Beszel Hub, FileBrowser Quantum,
JDownloader 2, SearXNG, Termix, guacd, and a restricted Docker socket proxy for
Homepage.
JDownloader and SearXNG share `general-gluetun`'s network namespace, so their
DNS and application traffic leave through that VPN tunnel. Caddy reaches their
web interfaces through ports 5800 and 8080 on `general-gluetun`; neither port
is published directly on the LAN.

Both namespace-sharing services wait for Gluetun's health check during an
ordered Compose `up`, and `restart: true` restarts them when Gluetun is
explicitly restarted through Compose. Still prefer `deploy-stack general`
over `restart-stack general`: a whole-stack restart operates on existing
containers and can briefly stop the network namespace before its dependents.

Persistent state is outside Git:

```text
/mnt/user/appdata/general-gluetun-state
/mnt/user/appdata/jdownloader-state
/mnt/user/appdata/filebrowser
/mnt/user/appdata/searxng-state
/mnt/user/appdata/beszel-state
/mnt/user/appdata/beszel-agent-state
/mnt/user/appdata/termix-state
```

The real `general/.env` contains the VPN credential plus generated SearXNG,
JDownloader, and FileBrowser secrets. Keep it in encrypted backups and do not
commit it. JDownloader writes downloads to `/mnt/user/booty/downloads` as
Unraid's `nobody:users` account (`99:100`). FileBrowser maps the complete
`/mnt/user/booty` share at `/files/stash`, exposes `/files` as its source root,
and also runs as `99:100`. The UI therefore shows `stash` as a folder instead
of opening directly into its contents.

### Shared media permissions

Jellyfin, FileBrowser, and JDownloader all access shared data through GID 100
(`users`); a separate application group is unnecessary. Keep the complete
`/mnt/user/booty` tree group-owned by `users`, group-readable/writable, and set
the setgid bit plus a default ACL on directories so new content inherits that
access:

```bash
chgrp -R users /mnt/user/booty
chmod -R g+rwX /mnt/user/booty
find /mnt/user/booty -xdev -type d -exec chmod g+s -- {} +
find /mnt/user/booty -xdev -type d \
  -exec setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::rx -- {} +
```

When copying as `root` with rsync, prevent archive mode from restoring the
source's owner, group, and permissions over this policy:

```bash
rsync -a --no-owner --no-group --no-perms SOURCE/ root@arc:/mnt/user/booty/
```

With a modern rsync on both ends, an explicit alternative is
`--chown=nobody:users --chmod=D2775,F0664`.

### Complete Beszel enrollment

The Hub starts immediately, while its local agent is intentionally behind the
`beszel-agent` Compose profile because the Hub generates the required key and
token during enrollment:

1. Open `https://beszel.arc.home.arpa` and create the first account.
2. Add a system named `Arc` using the Unix socket
   `/beszel_socket/beszel.sock`. Use that system's individual enrollment
   instructions rather than a universal token.
3. Put the displayed Hub public key and per-system token in `general/.env` as
   `BESZEL_AGENT_KEY` and `BESZEL_AGENT_TOKEN`.
4. Add `COMPOSE_PROFILES=beszel-agent`, redeploy `general`, and use
   `/beszel_socket/beszel.sock` for the system's Host/IP.

Arc and Forge agents use pinned Beszel `0.18.7` images. Each agent receives a
filtered, GET-only Docker view through a root-only Unix socket; the agent
itself never mounts the raw Docker socket, and no Docker API TCP port is
published.

Forge uses a separate outbound-only agent and Unix-socket proxy. Its tracked
Compose file and enrollment helper are in
`forge/stacks/forge-observability`. To finish enrollment without copying a
credential into shell history:

```bash
ssh forge
sudo /usr/local/sbin/enroll-forge-beszel
```

Enter the existing Beszel login only at the hidden prompts, then deploy the
already-registered `forge-observability` stack from Komodo. No port is opened
in Forge's firewall: the agent initiates its authenticated WebSocket to
`https://beszel.arc.home.arpa`. The agent mounts Forge's public system CA
bundle read-only so it can validate Caddy's private CA; no Caddy private key is
present in the container.

### Termix and the Forge console

Termix is available at `https://termix.arc.home.arpa`. It publishes no host
port. Termix reaches `termix-guacd` only across the internal `termix-private`
control bridge; guacd has a separate unprivileged egress bridge for outbound
remote-desktop connections. Neither service publishes guacd to the LAN.

Forge installation and break-glass access use the stock Unraid VNC console,
not Termix. After the guest is provisioned, Termix should use RDP directly to
Forge's reserved address.

The first administrator and a passkey are enrolled. Registration is disabled
both in Termix's persisted settings and with
`ALLOW_REGISTRATION: "false"` in `general/compose.yaml`; session recording is
not configured. The managed connections are:

| Termix entry | Protocol | Target | Account |
| --- | --- | --- | --- |
| `Arc / Unraid` | SSH | `192.168.50.51:22` | `root` |
| `Forge` | SSH | `192.168.50.179:22` | `luqmaan` |
| `Forge Desktop (Kubuntu)` | RDP | `192.168.50.179:3389` | `luqmaan` |

Arc and Forge use separate Termix-generated Ed25519 credentials; neither
reuses the Windows administrative key or Forge's GitHub key. Their authorized
key entries disable agent forwarding, port forwarding, X11 forwarding, and
user RC files while preserving the PTY, SFTP, and command execution required
by Termix. The Arc entry remains root-equivalent, including its Docker view.
The Forge entry has terminal, file-manager, Docker, and system-stat access.
Verify each server's host-key fingerprint when Termix first presents it.

Termix stores private SSH keys and remote-desktop credentials in its encrypted
database. The one-time API key used for provisioning was revoked and its
handoff file deleted immediately after end-to-end SSH authentication tests
passed. Never export the Termix hosts or credentials into an unencrypted file.

Stock Unraid VNC is unauthenticated unless a runtime password is configured.
Never port-forward its raw listener; use it only from a trusted management
network and disable it once the Termix RDP path is proven. Do not publish
guacd.
The separate powered-down VFIO VM named `Kubuntu` intentionally has no
libvirt VNC device: adding an emulated display alongside its passed-through
iGPU previously stalled Plasma. `Forge Desktop (Kubuntu)` is the supported
browser-accessible Kubuntu environment.
Back up all of `/mnt/user/appdata/termix-state` as encrypted data. Its hidden
`.env` contains the generated encryption keys required to restore and decrypt
the Termix database.

Homepage is available at `https://home.arc.home.arpa`. Its hand-authored
dashboard files live under `general/homepage`. It reads container status
through `homepage-dockerproxy`, which permits Docker GET operations for
container metadata while explicitly rejecting POST requests. The proxy shares
an internal network only with Homepage; unrelated application containers
cannot reach it. Dashboard links open in new tabs, and the Beszel card is
configured to use a dedicated dashboard account to show Arc's CPU, memory,
disk, and network metrics. Store that account only as
`HOMEPAGE_BESZEL_USERNAME` and `HOMEPAGE_BESZEL_PASSWORD` in the ignored
`general/.env`; Homepage receives them through `HOMEPAGE_VAR_*` substitutions.

## Jellyfin

Jellyfin runs as Unraid's `nobody:users` account (`99:100`). Its database,
plugins, logs, and cache are deliberately outside the Git repository:

```text
/mnt/user/appdata/jellyfin-state/config
/mnt/user/appdata/jellyfin-state/cache
```

The media share `/mnt/user/booty` is mounted read-only at `/media`. Port 8096
remains published as a direct recovery path, while normal browser access uses
`https://jellyfin.arc.home.arpa` through Caddy. UDP 7359 remains published for
LAN client discovery. DLNA is not enabled by this bridge-network setup because
it requires host networking; prefer native Jellyfin apps or add DLNA later as
a deliberate tradeoff.

The host currently has no `/dev/dri`, so hardware-accelerated transcoding is
not configured. If a supported GPU later exposes `/dev/dri`, follow Jellyfin's
vendor-specific hardware acceleration guide before adding the device mapping.

After Jellyfin's first start, open **Dashboard > Networking > Known Proxies**
and add Caddy's address on `caddy-backend`. This lets Jellyfin trust Caddy's
forwarded client headers and apply local/remote access policy correctly.
