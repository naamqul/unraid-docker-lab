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
    ├── caddy/
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
