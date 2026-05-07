# Two Installers: Coolify and Standalone

Status: approved 2026-05-07
Owner: repo maintainer

## Goal

Ship two installers in this repo that produce the same running stack as
what is currently deployed on this VPS:

1. **`setup-coolify.sh`** — assumes Coolify v4 is already installed on the
   host. Drives Coolify's API to create resources (current behavior).
2. **`setup-standalone.sh`** — assumes a plain Docker host with nothing
   pre-installed. Brings up the full stack via `docker compose`.

Both installers result in the same end-user experience: login at
`{SB_HOST}/auth`, forward-auth on Studio, Google OAuth, SMTP recovery
mail, owner-only user-deletion guard, MinIO-backed Storage, and TLS via
Let's Encrypt.

## Non-goals

- Multi-host / Kubernetes deploys.
- Migrating an existing Coolify-deployed stack to the standalone path
  (no in-place migration; user can teardown + re-up).
- Replacing the bundled Supabase services with a different vendor.

## Repo layout

```
auth-gateway/
├── README.md                            # rewritten — chooses installer based on host
├── .env.example                         # root, single source of env truth
├── setup-coolify.sh                     # root, installer A (Coolify)
├── setup-standalone.sh                  # root, installer B (plain Docker)
├── teardown-coolify.sh                  # root
├── teardown-standalone.sh               # root
├── login/                               # unchanged module
├── validator/                           # unchanged module
├── compose/
│   ├── coolify/                         # fragments uploaded by setup-coolify.sh
│   │   ├── auth-login.compose.yml
│   │   ├── auth-validator.compose.yml
│   │   ├── minio.compose.yml
│   │   └── postgres.compose.yml         # documentation-only today, kept
│   └── standalone/                      # one merged stack
│       ├── docker-compose.yml
│       └── Caddyfile
└── scripts/
    ├── pgsodium_getkey.template.sh
    └── postgres-init/                   # shared by both installers
        ├── _supabase.sql
        ├── jwt.sql
        ├── logs.sql
        ├── pooler.sql
        ├── protect-users.sql
        ├── realtime.sql
        ├── roles.sql
        └── webhooks.sql
```

The five top-level scripts + `.env.example` give the user one place to
look. Modules and shared assets live in subdirectories.

## Installer A: `setup-coolify.sh`

This is `scripts/setup.sh` moved to the repo root with path constants
adjusted to find init SQL at `scripts/postgres-init/` and compose
fragments at `compose/coolify/`. **No behavior change.** It continues to:

1. Create a `supabase-postgres` Coolify database.
2. Bootstrap pgsodium + run init SQL via `docker exec`.
3. Create a `minio` Coolify service from `compose/coolify/minio.compose.yml`.
4. Create the Supabase one-click service, patch its env, strip the
   bundled `supabase-db` / `supabase-minio` / `minio-createbucket`.
5. Build + deploy `auth-validator` from `compose/coolify/auth-validator.compose.yml`.
6. Build + deploy `auth-login` from `compose/coolify/auth-login.compose.yml`.
7. Patch the Coolify DB compose for `supabase-studio` (forward-auth
   labels) and `supabase-auth` (Google OAuth env), then deploy.
8. Apply `protect-users.sql` and mark `OWNER_EMAIL` as protected.
9. Connect networks; restart `coolify-proxy`.

`teardown-coolify.sh` is `scripts/teardown.sh` moved to root.

## Installer B: `setup-standalone.sh`

Idempotent, re-runnable. Reads `.env` at the repo root. Targets a host
that has only Docker (and Docker Compose v2) installed.

### Prerequisites the user must satisfy

- A Docker host with ports 80 and 443 free.
- A wildcard DNS record `*.PARENT_DOMAIN` pointing at the host.
- Filled-in `.env`: `PARENT_DOMAIN`, `SB_HOST`, `API_HOST`,
  `AUTH_VERIFY_HOST`, `S3_HOST`, `MINIO_CONSOLE_HOST`, SMTP creds, Google
  OAuth creds, `OWNER_EMAIL`, `LETSENCRYPT_EMAIL`.

### Steps

1. **Generate-and-remember secrets** (idempotent — only generated if
   missing in `.env`):
   - `POSTGRES_PASSWORD` (24 hex bytes)
   - `MINIO_ROOT_USER` (8 hex), `MINIO_ROOT_PASSWORD` (16 hex)
   - `PGSODIUM_KEY` (32 hex bytes)
   - `SUPABASE_JWT_SECRET` (40-char alphanum)
   - `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` — HS256 JWTs signed
     with `SUPABASE_JWT_SECRET`, payloads `{role:"anon"/"service_role",
     iat, exp:+10y, iss:"supabase"}`. Generated in pure bash + openssl
     (no Node dependency on the host).
   - `SUPABASE_INTERNAL_PG_PASS` (24 hex) — assigned to all
     `supabase_*` Postgres roles, same as the Coolify path.
   - `STUDIO_USER` (literal `supabase`), `STUDIO_PASSWORD` (24 hex) —
     Kong basic-auth dashboard pair.

2. **Build images locally**:
   - `auth-gateway-validator:local` from `validator/`.
   - `auth-gateway-login:local` from `login/`, with the same six
     `--build-arg`s as today (`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`,
     `VITE_COOKIE_DOMAIN`, `VITE_DEFAULT_REDIRECT`, `VITE_PARENT_DOMAIN`,
     `VITE_APP_NAME`).

3. **Postgres-only up**:
   `docker compose -f compose/standalone/docker-compose.yml up -d postgres`.
   Wait for `pg_isready`.

4. **Bootstrap Postgres** (only on first run — guarded by checking for
   the `_supabase` database):
   - Write `pgsodium_getkey.sh` containing `PGSODIUM_KEY` into the
     `pgsodium-config` named volume; restart Postgres.
   - Align all `supabase_*` role passwords to `SUPABASE_INTERNAL_PG_PASS`.
   - Copy `scripts/postgres-init/` into the container; run
     `_supabase`, `realtime`, `pooler`, `logs`, `webhooks`, `jwt`
     (with `JWT_SECRET`, `JWT_EXP=3600`, `POSTGRES_DB=postgres` env),
     `roles` (with `POSTGRES_PASSWORD=$SUPABASE_INTERNAL_PG_PASS`).
   - Same SQL files, same env, same order as the Coolify path.

5. **Full stack up**:
   `docker compose -f compose/standalone/docker-compose.yml up -d`.
   Brings up: caddy, minio, supabase-{kong, auth, rest, studio, realtime,
   storage, edge-functions, meta, analytics, vector, supavisor},
   imgproxy, validator, login.

6. **Apply protect-users trigger**: poll until `auth.users` exists
   (gotrue creates the schema on first boot), then run
   `protect-users.sql`. If `OWNER_EMAIL` is set, mark that user's
   `raw_app_meta_data.is_protected = true`.

7. **Print verify URLs** and the bootstrap-user `curl` snippet from the
   README.

### `teardown-standalone.sh`

```
docker compose -f compose/standalone/docker-compose.yml down -v
```

Same caveat as the Coolify teardown: by default the named volumes are
removed (`-v`), giving a clean slate. Document that explicitly so users
who want to keep data can run `down` without `-v`.

## `compose/standalone/docker-compose.yml`

### Construction

Source: the 1015-line compose Coolify generated on this VPS at
`/data/coolify/services/<supa_uuid>/docker-compose.yml` (the running
stack). One-time transforms applied by hand and committed:

- **Remove** services: `supabase-db`, `supabase-minio`,
  `minio-createbucket` (the three the Coolify installer also strips).
- **Rename Coolify magic vars** to our `.env` names:
  - `${SERVICE_PASSWORD_JWT}` → `${SUPABASE_JWT_SECRET}`
  - `${SERVICE_SUPABASEANON_KEY}` → `${SUPABASE_ANON_KEY}`
  - `${SERVICE_SUPABASESERVICE_KEY}` → `${SUPABASE_SERVICE_ROLE_KEY}`
  - `${SERVICE_PASSWORD_POSTGRES}` → `${SUPABASE_INTERNAL_PG_PASS}`
  - `${SERVICE_USER_ADMIN}` / `${SERVICE_PASSWORD_ADMIN}` →
    `${STUDIO_USER}` / `${STUDIO_PASSWORD}`
  - `${SERVICE_FQDN_SUPABASEKONG_8000}` → `https://${API_HOST}`
  - `${SERVICE_FQDN_SUPABASESTUDIO_3000}` → `https://${SB_HOST}`
- **Static service names** in env:
  - `POSTGRES_HOSTNAME` / `POSTGRES_HOST` → `postgres`
  - `STORAGE_S3_ENDPOINT` → `http://minio:9000`
- **Strip all `traefik.*` labels** — Caddy routes by service name.
- **Add Google OAuth env to `supabase-auth`**:
  - `GOTRUE_EXTERNAL_GOOGLE_ENABLED=true`
  - `GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}`
  - `GOTRUE_EXTERNAL_GOOGLE_SECRET=${GOOGLE_CLIENT_SECRET}`
  - `GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI}`
- **Set `GOTRUE_SITE_URL=https://${SB_HOST}/auth/`** so invite/recovery
  emails land at the login page (matches the Coolify installer).
- **Set `GOTRUE_DISABLE_SIGNUP=true`** and
  `GOTRUE_EXTERNAL_EMAIL_ENABLED=false` (matches the Coolify installer's
  `DISABLE_SIGNUP=true` / `ENABLE_EMAIL_SIGNUP=false`).

### Appended services

```yaml
postgres:
  image: supabase/postgres:15.8.1.060
  environment:
    POSTGRES_USER: supabase_admin
    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    POSTGRES_DB: postgres
  volumes:
    - postgres-data:/var/lib/postgresql/data
    - pgsodium-config:/etc/postgresql-custom
  command:
    - postgres
    - -c
    - shared_preload_libraries=pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net
    - -c
    - pgsodium.getkey_script=/etc/postgresql-custom/pgsodium_getkey.sh
    - -c
    - wal_level=logical
  healthcheck:
    test: [CMD-SHELL, pg_isready -U supabase_admin]
    interval: 10s

minio:
  image: quay.io/minio/minio:latest
  command: server /data --console-address ":9001"
  environment:
    MINIO_ROOT_USER: ${MINIO_ROOT_USER}
    MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    MINIO_SERVER_URL: https://${S3_HOST}
    MINIO_BROWSER_REDIRECT_URL: https://${MINIO_CONSOLE_HOST}
  volumes:
    - minio-data:/data
  healthcheck:
    test: [CMD-SHELL, "mc ready local || curl -f http://127.0.0.1:9000/minio/health/live"]

validator:
  image: auth-gateway-validator:local
  environment:
    SUPABASE_JWT_SECRET: ${SUPABASE_JWT_SECRET}
    LOGIN_URL: https://${SB_HOST}/auth
    COOKIE_NAME: sb-access-token
    PORT: "8080"
    OWNER_EMAIL: ${OWNER_EMAIL}
  healthcheck:
    test: [CMD-SHELL, "wget -qO- http://127.0.0.1:8080/healthz | grep -q ok"]

login:
  image: auth-gateway-login:local
  environment:
    COOKIE_DOMAIN: .${PARENT_DOMAIN}
    LOGOUT_REDIRECT: https://${SB_HOST}/
  healthcheck:
    test: [CMD-SHELL, "wget -qO- http://127.0.0.1/auth/ >/dev/null || exit 1"]

caddy:
  image: caddy:2-alpine
  ports: ["80:80", "443:443"]
  volumes:
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy-data:/data
    - caddy-config:/config
  environment:
    SB_HOST: ${SB_HOST}
    API_HOST: ${API_HOST}
    AUTH_VERIFY_HOST: ${AUTH_VERIFY_HOST}
    S3_HOST: ${S3_HOST}
    MINIO_CONSOLE_HOST: ${MINIO_CONSOLE_HOST}
    LETSENCRYPT_EMAIL: ${LETSENCRYPT_EMAIL}
```

All services attached to a single bridge network `auth-gateway`. Named
volumes: `postgres-data`, `minio-data`, `pgsodium-config`,
`caddy-data`, `caddy-config`, plus whatever the Supabase compose
declares (kept verbatim — `supabase-storage`, `supabase-functions`,
etc.).

## `compose/standalone/Caddyfile`

```
{
  email {$LETSENCRYPT_EMAIL}
}

# sb.<domain> — Studio gated by forward_auth, with login UI on /auth
(login_routes) {
  handle /auth* {
    reverse_proxy login:80
  }
  handle /logout {
    reverse_proxy login:80
  }
  handle /favicon/manifest.json {
    reverse_proxy login:80
  }
  handle /api/platform/notifications* {
    reverse_proxy login:80
  }
}

{$SB_HOST} {
  import login_routes

  handle {
    forward_auth validator:8080 {
      uri /verify
      copy_headers X-User-Id X-User-Email X-User-Role
    }
    reverse_proxy supabase-studio:3000
  }
}

{$AUTH_VERIFY_HOST} {
  reverse_proxy validator:8080
}

{$API_HOST} {
  reverse_proxy supabase-kong:8000
}

{$S3_HOST} {
  reverse_proxy minio:9000
}

{$MINIO_CONSOLE_HOST} {
  reverse_proxy minio:9001
}
```

Caddy v2's built-in `forward_auth` directive is functionally equivalent
to traefik's forwardauth middleware: it issues a subrequest, forwards
the original cookies, and on a 2xx response copies the listed headers
into the upstream request before proxying to Studio. On a 3xx response
Caddy returns the redirect to the browser unmodified — same flow the
validator emits today.

`{$VAR}` is Caddy's env-var substitution syntax; values are passed in
via the `caddy` service's `environment:` block in the compose.

## Validator and login: no code changes

Both apps work behind Caddy without modification. The validator only
reads the `Cookie` header and X-Forwarded-Uri (Caddy sets the same
forward-auth headers traefik does); the login app only needs the
cookie to be writable on `.PARENT_DOMAIN` and the API host reachable.

## `.env.example` additions

Add to the existing file:

```
# --------------------------------------------------------------------------
# Standalone installer only (setup-standalone.sh)
# --------------------------------------------------------------------------
# Email Caddy uses to register Let's Encrypt certificates.
LETSENCRYPT_EMAIL=admin@example.com
```

Keep all existing keys unchanged. The Coolify installer ignores
`LETSENCRYPT_EMAIL`.

## README rewrite

Rewrite the top of the README to present the choice up front:

```
## Pick your installer

- On a host that already has Coolify v4: ./setup-coolify.sh
- On a plain Docker host (Docker + Compose v2 only): ./setup-standalone.sh

Both produce the same running stack. Pick by what's already on your VPS.
```

Existing sections (How it works, Bootstrap user, Protect another app,
Caveats) apply to both installers and stay as-is, with small notes where
behavior diverges (e.g. the "Coolify proxy network attachments" caveat
becomes "Coolify only").

## Testing

- **Coolify path regression**: re-run `setup-coolify.sh` on this VPS
  after the rename. It must remain idempotent (no resources
  duplicated, no errors).
- **Standalone path smoke test**: provision a clean Docker VM, point a
  test domain at it, run `setup-standalone.sh`. Verify:
  - `curl -kI https://$AUTH_VERIFY_HOST/healthz` → 200
  - `curl -kI https://$SB_HOST/` → 302 to `/auth/?rd=...`
  - Login flow works end-to-end (create user via service-role admin
    API, sign in via UI, land on Studio).
  - Google OAuth round-trip works.
  - SMTP recovery email sends.
  - `OWNER_EMAIL`-only delete restriction enforced.

## Risk and rollback

- **Risk**: hand-translating the 1015-line Coolify compose is the
  largest single source of drift. Mitigation: diff the rendered
  `docker compose config` output against the running stack on this VPS
  service-by-service before committing.
- **Risk**: Caddy's `forward_auth` may differ subtly from traefik's
  forwardauth (header forwarding rules). Mitigation: integration-test
  the login-then-Studio flow on the standalone VM before declaring
  done.
- **Rollback**: the Coolify installer is unchanged code-path-wise; if
  the standalone path is broken, users on Coolify hosts are unaffected.
