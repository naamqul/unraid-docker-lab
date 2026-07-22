# unraid-docker-lab

Version-controlled Docker Compose and hand-authored configuration for the
Unraid host `Arc`. Mutable application state lives outside this repository in
cache-backed `appdata` directories.

## Layout

```text
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
| `jdownloader.arc.home.arpa` | `general-gluetun:5800` |
| `filebrowser.arc.home.arpa` | `filebrowser:80` |
| `searxng.arc.home.arpa` | `general-gluetun:8080` |
| `open-webui.arc.home.arpa` | `gluetun:8080` |
| `hermes.arc.home.arpa` | `gluetun:9119` |
| `hermes-api.arc.home.arpa` | `gluetun:8642` |

`home.arpa` is used deliberately. Do not use subdomains of `arc.local` here:
`.local` is reserved for multicast DNS, and wildcard/unicast records beneath
it are unreliable across operating systems and Tailscale.

### One-time setup

1. Reserve `192.168.50.52` for MAC `02:42:c0:a8:32:34` in ASUS DHCP, or
   exclude the address from the dynamic pool. Compose assigns this address
   statically and does not request a DHCP lease.
2. In NextDNS Rewrites (or another DNS server used by both LAN and Tailscale
   clients), point `arc.home.arpa` to `192.168.50.52`. NextDNS applies that
   rewrite to the base name and all subdomains, including future apps.
3. In the Tailscale admin console, open Arc's route settings and approve
   `192.168.50.0/24`. Advertising a route on Arc does not activate it until it
   is approved, unless an `autoApprovers` policy already covers it.
4. Create the shared backend network once:

   ```bash
   docker network create caddy-backend
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

3. Add a DNS rewrite from `example.arc.home.arpa` to `192.168.50.52`.
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
docker exec komodo km execute -y deploy-stack ai
docker exec komodo km execute -y deploy-stack caddy
docker exec komodo km execute -y deploy-stack general
docker exec komodo km execute -y deploy-stack jellyfin
```

## General services

The `general` stack contains Homepage, Beszel Hub, FileBrowser Quantum,
JDownloader 2, SearXNG, and a restricted Docker socket proxy for Homepage.
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
2. Add a system named `Arc` and create/select a universal token.
3. Put the generated values in `general/.env` as `BESZEL_AGENT_KEY` and
   `BESZEL_AGENT_TOKEN`.
4. Add `COMPOSE_PROFILES=beszel-agent`, redeploy `general`, and use
   `/beszel_socket/beszel.sock` for the system's Host/IP.

Homepage is available at `https://home.arc.home.arpa`. Its hand-authored
dashboard files live under `general/homepage`. It reads container status
through `homepage-dockerproxy`, which permits Docker GET operations for
container metadata while explicitly rejecting POST requests.

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
