# Self-hosted Supabase on Coolify (with external Postgres + public MinIO)

This deployment runs in Coolify project `test` on this VPS (`49.13.118.8`).

## Architecture

```
┌─────────────────── Coolify ────────────────────┐
│                                                │
│   Project: test                                │
│                                                │
│  ┌─ supabase-postgres (database resource) ─┐   │
│  │  image: supabase/postgres:15.8.1.060    │   │
│  │  internal host: d0ks0k48o0ggs8ckoo4w80c4│   │
│  │  network: coolify                       │   │
│  └─────────────────────────────────────────┘   │
│                  ▲                             │
│                  │ docker DNS                  │
│  ┌─ supabase (service) ────────────────────┐   │
│  │  Bundled `supabase-db` removed.         │   │
│  │  All services reach above postgres      │   │
│  │  via env POSTGRES_HOSTNAME.             │   │
│  │                                         │   │
│  │  • supabase-kong   → api.sb.soltrix.dev │   │
│  │  • supabase-studio → sb.soltrix.dev     │   │
│  │  • supabase-minio  → s3.soltrix.dev     │   │
│  │                      minio.soltrix.dev  │   │
│  │  • + 11 other supporting services       │   │
│  └─────────────────────────────────────────┘   │
└────────────────────────────────────────────────┘
```

The standalone Postgres lives on the `coolify` docker network. The Supabase service has its own per-service network (`acg480k0ogok4480wgks0k4w`), so the Postgres and the proxy are **manually attached** to that network (see "Network glue" below).

## Public URLs

| URL | What |
|-----|------|
| https://sb.soltrix.dev | Supabase Studio (admin UI) — protected by Authentik forward-auth |
| https://api.sb.soltrix.dev | Kong API gateway: `/auth/v1/*`, `/rest/v1/*`, `/realtime/v1/*`, `/storage/v1/*`, `/graphql/v1` |
| https://auth.sb.soltrix.dev | Authentik login page (SSO for Studio and any future protected app) |
| https://s3.soltrix.dev | MinIO S3-compatible API (port 9000) |
| https://minio.soltrix.dev | MinIO web console (port 9001) |

DNS: wildcard `*.soltrix.dev` already resolves to this VPS.

## Credentials

All credentials are stored in two places:

1. **Coolify env vars** (Coolify UI → project `test` → service Environment Variables tab) — operational source of truth.
2. **Supabase Vault** (https://sb.soltrix.dev → Database → Vault) — central lookup for humans. SQL: `select decrypted_secret from vault.decrypted_secrets where name = '<key>'`.

Stored Vault entries (15 total — query with `select name, decrypted_secret from vault.decrypted_secrets`):
- `authentik_admin_user` — Authentik dashboard username (`akadmin`)
- `authentik_secret_key` — `AUTHENTIK_SECRET_KEY` (session encryption)
- `authentik_postgres_user`, `authentik_postgres_password` — credentials for Authentik's internal Postgres
- `supabase_studio_user`, `supabase_studio_password` — internal Studio basic auth (bypassed; Authentik in front)
- `supabase_anon_key`, `supabase_service_role_key`, `supabase_jwt_secret` — API keys
- `supabase_postgres_password` — shared password for all Supabase Postgres roles
- `minio_root_user`, `minio_root_password` — MinIO console login
- `hostinger_smtp_password` — SMTP password for daniel@soltrix.dev

## Components

### Postgres (`supabase-postgres`, UUID `d0ks0k48o0ggs8ckoo4w80c4`)

- Image: `supabase/postgres:15.8.1.060`
- Connection (internal): `postgresql://supabase_admin:<pass>@d0ks0k48o0ggs8ckoo4w80c4:5432/postgres`
- Custom `shared_preload_libraries = 'pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net'` (set via `postgresql.auto.conf`)
- `pgsodium.getkey_script = '/etc/postgresql-custom/pgsodium_getkey.sh'` (required for Vault to work; see `docker/pgsodium_getkey.sh`)
- Bootstrapped with all Supabase schemas, roles, and 7 init scripts (`docker/postgres-init/*.sql`)
- Logical replication on (for Realtime): `wal_level = logical`

### MinIO (standalone Coolify service)

- Service UUID: `rk4cgsggk0kocccsgksgcs48`, container: `minio-rk4cgsggk0kocccsgksgcs48`
- Image: `quay.io/minio/minio:latest`
- Ports: 9000 (S3 API), 9001 (console)
- Public domains: `s3.soltrix.dev` (S3 API), `minio.soltrix.dev` (web console) — both Let's Encrypt
- Internal access from Supabase Storage: `supabase-storage` is connected to MinIO's docker network and `STORAGE_S3_ENDPOINT=http://minio-rk4cgsggk0kocccsgksgcs48:9000`
- Root creds in Vault: `minio_root_user`, `minio_root_password`
- Originally bundled inside the Supabase service — split out so it shows as its own top-level entry in Coolify UI. Bundled `supabase-minio` and `minio-createbucket` were removed from the supabase compose; data was migrated by `cp -a` from `/data/coolify/services/<supabase_uuid>/volumes/storage/.` to `/var/lib/docker/volumes/<minio_uuid>_minio-data/_data/`.

### Supabase service (UUID `acg480k0ogok4480wgks0k4w`)

14 containers (1 supabase-db removed, see the bundled minio + 13 service containers):
`supabase-kong`, `supabase-studio`, `supabase-analytics`, `supabase-vector`, `supabase-rest`, `supabase-auth`, `realtime-dev`, `supabase-minio`, `minio-createbucket`, `supabase-storage`, `imgproxy`, `supabase-meta`, `supabase-edge-functions`, `supabase-supavisor`.

### Authentik (forward-auth in front of Studio)

- Service UUID: `asc44o0ss8kgoo44gso04ggo`
- Containers: `authentik-server`, `authentik-worker`, `postgresql` (Authentik's own Postgres, separate from Supabase's)
- Image: `ghcr.io/goauthentik/server:2025.10.3`
- Public host: `https://auth.sb.soltrix.dev` (modern OAuth-based UI)
- Admin user: `akadmin` (set during initial setup wizard) — **password is NOT in Vault; only the user knows it. Add via `vault.create_secret(...)` if you want a copy.**
- SMTP: configured (`smtp.hostinger.com:587 STARTTLS` via `daniel@soltrix.dev`) — password resets work
- Branding: title = "Soltrix", logo = Supabase's, custom CSS (Inter font, dark `#181818`, `#3ECF8E` accent — supabase-dashboard look). Apply tweaks via Admin → System → Brands.
- Outpost embedded: `authentik_host = https://auth.sb.soltrix.dev` (set via API on the `authentik Embedded Outpost` config).
- **Direct-access guard:** the bare `https://auth.sb.soltrix.dev/` URL redirects to `https://sb.soltrix.dev/` (traefik `redirectregex` middleware on the auth router). All OAuth/flow paths (`/application/o/*`, `/if/flow/*`, `/static/*`, `/outpost.goauthentik.io/*`, `/api/*`, `/-/*`) remain accessible — required for the OAuth flow and for the embedded outpost callbacks.
- Compose snapshot: `docs/docker/authentik.docker-compose.yml`

**Auth flow for Studio:**
- `sb.soltrix.dev` → traefik forwardauth middleware → embedded Outpost on `authentik-server:9000` → if no session, 302 to `auth.sb.soltrix.dev/application/o/authorize/...` (OAuth) → after login, callback to `sb.soltrix.dev/outpost.goauthentik.io/callback` → cookie set → Studio.
- The `/outpost.goauthentik.io/*` path on `sb.soltrix.dev` is routed (by a label on the authentik-server container) back to authentik-server itself — that's the OAuth callback handler.

**To protect another app:**
1. In Authentik admin: **Applications → Create with Provider** → Proxy Provider → "Forward auth (single application)" → External host = `https://yourapp.soltrix.dev`.
2. In **Outposts → authentik Embedded Outpost**, add the new application to its providers list.
3. On the target container, add labels:
   ```yaml
   labels:
     - 'traefik.http.middlewares.authentik.forwardauth.address=http://authentik-server-asc44o0ss8kgoo44gso04ggo:9000/outpost.goauthentik.io/auth/traefik'
     - 'traefik.http.middlewares.authentik.forwardauth.trustForwardHeader=true'
     - 'traefik.http.middlewares.authentik.forwardauth.authResponseHeaders=X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid,X-authentik-jwt,X-authentik-meta-jwks,X-authentik-meta-outpost,X-authentik-meta-provider,X-authentik-meta-app,X-authentik-meta-version'
     - 'traefik.http.routers.https-0-<svc_uuid>-<svc_name>.middlewares=gzip,authentik'
   ```
4. On the **authentik-server** container compose labels, add the OAuth callback PathPrefix router for the new host:
   ```yaml
   - 'traefik.http.routers.outpost-<appname>.rule=Host(`yourapp.soltrix.dev`) && PathPrefix(`/outpost.goauthentik.io/`)'
   - 'traefik.http.routers.outpost-<appname>.entryPoints=https'
   - 'traefik.http.routers.outpost-<appname>.tls=true'
   - 'traefik.http.routers.outpost-<appname>.tls.certresolver=letsencrypt'
   - 'traefik.http.routers.outpost-<appname>.service=https-0-asc44o0ss8kgoo44gso04ggo-authentik-server'
   ```
5. Ensure `coolify-proxy` is connected to both networks: `docker network connect <app_net> coolify-proxy && docker network connect asc44o0ss8kgoo44gso04ggo coolify-proxy`.
6. Restart the proxy: `docker restart coolify-proxy`.

**Login by email instead of username:** Authentik admin → **Flows & Stages → Stages →** `default-authentication-identification` → set "User fields" to include both `Username` and `Email`. Save. Now users can type either at the login prompt.

**Critical Coolify quirk:** for custom-compose services, you MUST use the env var pattern `SERVICE_FQDN_<SERVICENAME>_<PORT>=https://<host>` in the compose's `environment:` for Coolify to wire traefik routing correctly. Without the `_<PORT>` suffix, Coolify generates router labels but no `loadbalancer.server.port`, and traefik returns 503 "no available server".

**Coolify proxy network attachment:** every time a service container is recreated (compose up --force-recreate), the `coolify-proxy` may not auto-rejoin the new network. Symptoms: 503s on a domain that was working. Fix: `docker network connect <service_uuid> coolify-proxy && docker restart coolify-proxy`.

## Setup procedure (replay from scratch)

If you ever need to recreate this (e.g. on another server), the order is:

### 1. Create Postgres database resource in Coolify

```bash
TOKEN=<coolify_root_token>
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  http://localhost:8000/api/v1/databases/postgresql -d '{
    "project_uuid": "<test_project_uuid>",
    "server_uuid": "<server_uuid>",
    "environment_name": "production",
    "name": "supabase-postgres",
    "image": "supabase/postgres:15.8.1.060",
    "postgres_user": "supabase_admin",
    "postgres_password": "<random32hex>",
    "postgres_db": "postgres",
    "instant_deploy": true
  }'
```

Note the returned UUID — that's the postgres container hostname.

### 2. Configure Postgres for Vault + Supabase

```bash
PG=<postgres_uuid>
# Stop, edit conf, restart so shared_preload_libraries take effect
docker stop $PG
VOL=$(docker inspect $PG --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')

cat >> $VOL/postgresql.auto.conf <<EOF
shared_preload_libraries = 'pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net'
pgsodium.getkey_script = '/etc/postgresql-custom/pgsodium_getkey.sh'
EOF

docker start $PG
# create the getkey script (see docker/pgsodium_getkey.sh — generate fresh, don't reuse)
KEY=$(openssl rand -hex 32)
docker exec $PG bash -c "mkdir -p /etc/postgresql-custom && echo -e '#!/bin/bash\necho $KEY' > /etc/postgresql-custom/pgsodium_getkey.sh && chmod 700 /etc/postgresql-custom/pgsodium_getkey.sh && chown postgres:postgres /etc/postgresql-custom/pgsodium_getkey.sh"
docker restart $PG
```

### 3. Create Supabase service

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  http://localhost:8000/api/v1/services -d '{
    "type": "supabase",
    "name": "supabase",
    "project_uuid": "<test_project_uuid>",
    "server_uuid": "<server_uuid>",
    "environment_name": "production",
    "instant_deploy": false
  }'
```

This generates the SQL init scripts at `/data/coolify/services/<uuid>/volumes/db/`.

### 4. Bootstrap external Postgres

Sync the auto-generated `SERVICE_PASSWORD_POSTGRES` and `SERVICE_PASSWORD_JWT` from the supabase service env vars, then run the 7 init scripts against the standalone postgres.

```bash
PG=<postgres_uuid>
SUPA=<supabase_service_uuid>
TARGET_PASS=<SERVICE_PASSWORD_POSTGRES from supabase env>
JWT_SECRET=<SERVICE_PASSWORD_JWT from supabase env>

# Align role passwords
docker exec $PG psql -U supabase_admin -d postgres -c "
  ALTER USER supabase_admin WITH PASSWORD '$TARGET_PASS';
  ALTER USER postgres WITH PASSWORD '$TARGET_PASS';
  ALTER USER authenticator WITH PASSWORD '$TARGET_PASS';
  ALTER USER pgbouncer WITH PASSWORD '$TARGET_PASS';
  ALTER USER supabase_auth_admin WITH PASSWORD '$TARGET_PASS';
  ALTER USER supabase_storage_admin WITH PASSWORD '$TARGET_PASS';
  ALTER USER supabase_replication_admin WITH PASSWORD '$TARGET_PASS';
  ALTER USER supabase_read_only_user WITH PASSWORD '$TARGET_PASS';
  CREATE ROLE supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD '$TARGET_PASS';"

# Copy and run init scripts (generated by Coolify when supabase service was created)
docker cp /data/coolify/services/$SUPA/volumes/db/. $PG:/tmp/sb_init/

docker exec -e POSTGRES_USER=supabase_admin $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/_supabase.sql
docker exec -e POSTGRES_USER=supabase_admin $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/realtime.sql
docker exec -e POSTGRES_USER=supabase_admin $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/pooler.sql
docker exec -e POSTGRES_USER=supabase_admin $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/logs.sql
docker exec $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/webhooks.sql
docker exec -e JWT_SECRET=$JWT_SECRET -e JWT_EXP=3600 -e POSTGRES_DB=postgres $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/jwt.sql
docker exec -e POSTGRES_PASSWORD=$TARGET_PASS $PG psql -U supabase_admin -d postgres -f /tmp/sb_init/roles.sql
```

The init scripts are saved in `docker/postgres-init/` for reference.

### 5. Edit Supabase compose to remove bundled supabase-db

Strip the `supabase-db:` service block from the supabase docker compose, and remove every `depends_on: supabase-db` reference.

```python
# helper script — see this README's git history for full Python edit
import yaml
with open('/data/coolify/services/<supa_uuid>/docker-compose.yml') as f:
    d = yaml.safe_load(f)
del d['services']['supabase-db']
for svc in d['services'].values():
    if 'depends_on' in svc and 'supabase-db' in svc['depends_on']:
        del svc['depends_on']['supabase-db']
        if not svc['depends_on']:
            del svc['depends_on']
with open('/data/coolify/services/<supa_uuid>/docker-compose.yml','w') as f:
    yaml.safe_dump(d, f, sort_keys=False, default_flow_style=False)
```

Push the modified compose back to Coolify via PATCH `/api/v1/services/<uuid>` with body `{"docker_compose_raw": "<base64-encoded yaml>"}`.

### 6. Set Supabase service env vars

```bash
# Postgres pointers
POSTGRES_HOSTNAME=<standalone postgres uuid>
POSTGRES_HOST=<standalone postgres uuid>
POSTGRES_PORT=5432

# Public URLs
API_EXTERNAL_URL=https://api.sb.soltrix.dev
SUPABASE_PUBLIC_URL=https://api.sb.soltrix.dev
STORAGE_PUBLIC_URL=https://api.sb.soltrix.dev
NEXT_PUBLIC_SUPABASE_URL=https://api.sb.soltrix.dev
GOTRUE_SITE_URL=https://sb.soltrix.dev

# SMTP (Hostinger). NOTE: use port 587 STARTTLS — Hetzner blocks outbound 465.
# SMTP_ADMIN_EMAIL MUST equal SMTP_USER — Hostinger hangs the connection if From doesn't match auth user.
SMTP_HOST=smtp.hostinger.com
SMTP_PORT=587
SMTP_USER=daniel@soltrix.dev
SMTP_PASS=<pass>
SMTP_ADMIN_EMAIL=daniel@soltrix.dev
SMTP_SENDER_NAME=Soltrix
```

### 7. Set FQDNs on service applications

```sql
-- run against coolify-db
UPDATE service_applications SET fqdn='https://api.sb.soltrix.dev' WHERE name='supabase-kong'    AND service_id=(SELECT id FROM services WHERE uuid='<supa>');
UPDATE service_applications SET fqdn='https://sb.soltrix.dev'     WHERE name='supabase-studio'  AND service_id=(SELECT id FROM services WHERE uuid='<supa>');
UPDATE service_applications SET fqdn='https://s3.soltrix.dev,https://minio.soltrix.dev:9001' WHERE name='supabase-minio' AND service_id=(SELECT id FROM services WHERE uuid='<supa>');
```

### 8. Network glue (CRITICAL — easy to miss)

The Supabase service runs on its own per-service docker network. The standalone Postgres and the Coolify proxy are NOT on it by default — Supabase services can't reach Postgres, and Traefik can't reach Supabase containers.

After first deploy:

```bash
SUPA_NET=acg480k0ogok4480wgks0k4w   # supabase service uuid IS the network name
docker network connect $SUPA_NET <postgres_uuid>
docker network connect $SUPA_NET coolify-proxy
```

These connections persist across container restarts but **NOT across `docker network prune` or service deletion**. If you redeploy the supabase service from scratch, redo them.

### 9. Add public traefik labels to bundled MinIO

Coolify's auto-generated traefik labels don't cover the bundled `supabase-minio` container. Edit `/data/coolify/services/<supa_uuid>/docker-compose.yml` and add the labels manually under `services.supabase-minio.labels` (see `docker/supabase-stack.docker-compose.yml` for the full label block — look for `traefik.http.routers.*-supabase-minio.*`). Then:

```bash
cd /data/coolify/services/<supa_uuid>
docker compose -p <supa_uuid> up -d --force-recreate --no-deps supabase-minio
```

### 10. Initial deploy + smoke tests

```bash
curl -X GET -H "Authorization: Bearer $TOKEN" "http://localhost:8000/api/v1/deploy?uuid=<supa_uuid>&force=true"

# After all containers are healthy:
curl -sk https://api.sb.soltrix.dev/auth/v1/health
# → {"version":"...","name":"GoTrue",...}

curl -sk -H "apikey: <ANON_KEY>" https://api.sb.soltrix.dev/rest/v1/
# → {"swagger":"2.0",...}

curl -skI https://sb.soltrix.dev      # → 307 to /project/default
curl -skI https://minio.soltrix.dev   # → 200
curl -sk  https://s3.soltrix.dev/minio/health/live  # → 200 OK
```

## Adding new app secrets to Vault

Studio UI: https://sb.soltrix.dev → **Database** → **Vault** → **+ Add new secret**.

Or SQL:
```sql
select vault.create_secret('the-secret-value', 'unique_name', 'optional description');
```

Read back:
```sql
select decrypted_secret from vault.decrypted_secrets where name = 'unique_name';
```

For app-runtime usage from another service in `test` project, expose a SECURITY DEFINER function in `public`:
```sql
create or replace function public.get_secret(secret_name text)
returns text language sql security definer
as $$
  select decrypted_secret from vault.decrypted_secrets where name = secret_name;
$$;
revoke execute on function public.get_secret(text) from anon, authenticated;
grant execute on function public.get_secret(text) to service_role;
```

Then call from your app via PostgREST RPC using the service-role key.

## Known issues / follow-ups

- **Hetzner blocks outbound TCP 465**. Use port 587 (already configured).
- **`SMTP_ADMIN_EMAIL` must equal `SMTP_USER`** (i.e. the From address must match the SMTP auth mailbox). When they differ — e.g. authenticating as `daniel@soltrix.dev` but sending From `noreply@soltrix.dev` (an alias) — Hostinger silently holds the connection open and GoTrue's send hits its 10s deadline with no error logged. Symptom is a 504 from `/signup` and `auth.users` rows getting rolled back. **Fix:** set both to the same real mailbox, OR create a separate `noreply@` *mailbox* (not alias) with its own credentials.
- **Network attachments are manual**: every redeploy of the supabase service from scratch needs the two `docker network connect` commands re-run (step 8).
- **TLS certs**: Traefik issues Let's Encrypt certs automatically on first request. Initial requests can return 504 for ~30s while a cert is being negotiated.

## Cleanup commands (if you need to nuke and start over)

```bash
TOKEN=...
SUPA_UUID=...
PG_UUID=...

# Stop + delete supabase service
curl -X DELETE -H "Authorization: Bearer $TOKEN" "http://localhost:8000/api/v1/services/$SUPA_UUID"

# Delete postgres database resource
curl -X DELETE -H "Authorization: Bearer $TOKEN" "http://localhost:8000/api/v1/databases/$PG_UUID"

# Coolify removes containers but NOT volumes by default. To wipe volumes:
docker volume ls | grep -E "$SUPA_UUID|$PG_UUID|postgres-data-$PG_UUID" | awk '{print $2}' | xargs -r docker volume rm
```
