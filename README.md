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
    └── general/
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

Start it once, verify `http://arc.local:9120`, and then enable autostart.
Compose Manager Plus should continue owning the Komodo bootstrap stack;
Komodo can manage the application stacks below `komodo/stacks/`.

## Persistence and backups

- Compose and hand-authored configuration are versioned here.
- Mongo data and Core/Periphery keys are under
  `/mnt/user/appdata/komodo-state` and must be included in appdata backups.
- Komodo database exports are written to
  `/mnt/user/appdata/komodo-state/backups`.
- The real `.env` is intentionally excluded from Git and must be backed up
  securely through a separate encrypted mechanism.

## Reverse proxy and remote access

Caddy owns `192.168.50.52` on Docker's Unraid-managed `br0` network. It also
joins the external `caddy-backend` bridge, which lets it reach application
containers directly without sending backend traffic through host-published
ports.

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
   clients), point every name in the table above to `192.168.50.52`.
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
   curl -H 'Host: komodo.arc.home.arpa' http://192.168.50.52
   ```

The Caddyfile currently uses private HTTP. Tailscale encrypts traffic between
the remote client and Arc, but LAN traffic and Arc's final hop to Caddy remain
plain HTTP. For end-to-end HTTPS, either use a real domain with publicly
trusted certificates or add `tls internal` to each site and install Caddy's
root CA on every client. A Dockerized Caddy cannot install its CA into client
trust stores automatically.

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
   http://example.arc.home.arpa {
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
