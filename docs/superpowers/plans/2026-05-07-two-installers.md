# Two Installers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split this repo into two installers — `setup-coolify.sh` (current behavior, Coolify API) and `setup-standalone.sh` (plain Docker host with Caddy + bundled compose) — both producing the same running stack as this VPS.

**Architecture:** Five top-level scripts at the repo root + `.env.example`. Modules in subdirs. Standalone path uses one merged `docker-compose.yml` derived from this VPS's running Coolify-generated compose, with Caddy as the reverse proxy.

**Tech Stack:** Bash, Docker Compose v2, Caddy v2 (`forward_auth`), Supabase self-host stack, MinIO, supabase/postgres image with pgsodium. JWT generation in pure bash + openssl.

---

## File Structure

**Created:**
- `setup-coolify.sh` — moved from `scripts/setup.sh`, paths updated
- `setup-standalone.sh` — new standalone installer
- `teardown-coolify.sh` — moved from `scripts/teardown.sh`
- `teardown-standalone.sh` — new
- `compose/standalone/docker-compose.yml` — full stack
- `compose/standalone/Caddyfile` — TLS + routing + forward_auth

**Moved:**
- `compose/auth-login.compose.yml` → `compose/coolify/auth-login.compose.yml`
- `compose/auth-validator.compose.yml` → `compose/coolify/auth-validator.compose.yml`
- `compose/minio.compose.yml` → `compose/coolify/minio.compose.yml`
- `compose/postgres.compose.yml` → `compose/coolify/postgres.compose.yml`
- `compose/README.md` → `compose/coolify/README.md` (if it has Coolify-specific content)

**Modified:**
- `.env.example` — add `LETSENCRYPT_EMAIL` and standalone-only secret keys (`STUDIO_USER`, `STUDIO_PASSWORD`, `LOGFLARE_API_KEY`, `LOGFLARE_PRIVATE_ACCESS_TOKEN`, `PG_META_CRYPTO_KEY`)
- `README.md` — top section rewritten to introduce both installers

**Deleted:**
- `scripts/setup.sh` (after move)
- `scripts/teardown.sh` (after move)

---

## Task 1: Restructure existing files (no behavior change)

**Files:**
- Move: `scripts/setup.sh` → `setup-coolify.sh`
- Move: `scripts/teardown.sh` → `teardown-coolify.sh`
- Move: `compose/{auth-login,auth-validator,minio,postgres}.compose.yml` → `compose/coolify/`
- Move: `compose/README.md` → `compose/coolify/README.md` (if exists)
- Modify: `setup-coolify.sh` — update path constants

- [ ] **Step 1: Create the coolify subdir and move files**

```bash
cd /root/projects/auth-gateway
mkdir -p compose/coolify
git mv compose/auth-login.compose.yml compose/coolify/
git mv compose/auth-validator.compose.yml compose/coolify/
git mv compose/minio.compose.yml compose/coolify/
git mv compose/postgres.compose.yml compose/coolify/
[ -f compose/README.md ] && git mv compose/README.md compose/coolify/README.md
git mv scripts/setup.sh setup-coolify.sh
git mv scripts/teardown.sh teardown-coolify.sh
```

- [ ] **Step 2: Fix `REPO_DIR` in both scripts**

The old scripts lived in `scripts/`, so `REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"`. Now that they live at root, `REPO_DIR` must equal `SCRIPT_DIR`.

```bash
sed -i 's|REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"|REPO_DIR="$SCRIPT_DIR"|' \
  /root/projects/auth-gateway/setup-coolify.sh \
  /root/projects/auth-gateway/teardown-coolify.sh
grep -n REPO_DIR /root/projects/auth-gateway/setup-coolify.sh /root/projects/auth-gateway/teardown-coolify.sh | head
```

Expected: both files show `REPO_DIR="$SCRIPT_DIR"`.

- [ ] **Step 3: Update compose path references in `setup-coolify.sh`**

Find every `"$REPO_DIR/compose/<file>.compose.yml"` and rewrite to `"$REPO_DIR/compose/coolify/<file>.compose.yml"`.

```bash
sed -i 's|compose/\(minio\|auth-validator\|auth-login\)\.compose\.yml|compose/coolify/\1.compose.yml|g' \
  /root/projects/auth-gateway/setup-coolify.sh
grep -nE 'compose/[a-z-]+/[a-z-]+\.compose\.yml|compose/[a-z-]+\.compose\.yml' /root/projects/auth-gateway/setup-coolify.sh
```

Expected: 3 lines, all under `compose/coolify/`.

- [ ] **Step 4: Verify the relocated scripts still parse**

```bash
bash -n /root/projects/auth-gateway/setup-coolify.sh
bash -n /root/projects/auth-gateway/teardown-coolify.sh
```

Expected: no output (both scripts have valid syntax).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move installers to repo root, group Coolify compose fragments

setup.sh -> setup-coolify.sh (root)
teardown.sh -> teardown-coolify.sh (root)
compose/*.compose.yml -> compose/coolify/

No behavior change — paths inside setup-coolify.sh updated to match.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add standalone-only env keys to `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Append a standalone section**

Add to the bottom of `.env.example`:

```
# --------------------------------------------------------------------------
# Standalone installer only (setup-standalone.sh)
#
# These keys are generated automatically on first run if left blank.
# The Coolify installer ignores them (Coolify generates its own equivalents).
# --------------------------------------------------------------------------

# Email Caddy uses to register Let's Encrypt certificates.
LETSENCRYPT_EMAIL=

# Studio basic-auth (Kong protects Studio with these). Auto-generated if blank.
STUDIO_USER=
STUDIO_PASSWORD=

# Logflare (analytics) API tokens. Auto-generated if blank.
LOGFLARE_API_KEY=
LOGFLARE_PRIVATE_ACCESS_TOKEN=

# pg-meta encryption key. Auto-generated if blank.
PG_META_CRYPTO_KEY=
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "feat(env): add standalone-only keys to .env.example

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Create `compose/standalone/docker-compose.yml`

**Files:**
- Create: `compose/standalone/docker-compose.yml`

Source: `/data/coolify/services/<supa_uuid>/docker-compose.yml` on this VPS (the running Coolify-generated Supabase compose). Apply documented transforms.

- [ ] **Step 1: Find the running Coolify-Supabase compose path on this VPS**

```bash
SUPA_UUID="$(grep ^SUPABASE_UUID /root/projects/auth-gateway/.env | cut -d= -f2)"
ls "/data/coolify/services/$SUPA_UUID/docker-compose.yml"
```

Expected: file exists, ~1015 lines.

- [ ] **Step 2: Copy the compose into `compose/standalone/` as a starting point**

```bash
mkdir -p /root/projects/auth-gateway/compose/standalone
cp "/data/coolify/services/$SUPA_UUID/docker-compose.yml" /root/projects/auth-gateway/compose/standalone/docker-compose.yml
```

- [ ] **Step 3: Apply var-name substitutions**

```bash
F=/root/projects/auth-gateway/compose/standalone/docker-compose.yml

# Coolify magic vars -> .env names
sed -i \
  -e 's|\${SERVICE_PASSWORD_JWT}|${SUPABASE_JWT_SECRET}|g' \
  -e 's|\${SERVICE_SUPABASEANON_KEY}|${SUPABASE_ANON_KEY}|g' \
  -e 's|\${SERVICE_SUPABASESERVICE_KEY}|${SUPABASE_SERVICE_ROLE_KEY}|g' \
  -e 's|\${SERVICE_PASSWORD_POSTGRES}|${SUPABASE_INTERNAL_PG_PASS}|g' \
  -e 's|\${SERVICE_USER_ADMIN}|${STUDIO_USER}|g' \
  -e 's|\${SERVICE_PASSWORD_ADMIN}|${STUDIO_PASSWORD}|g' \
  -e 's|\${SERVICE_PASSWORD_PGMETACRYPTO}|${PG_META_CRYPTO_KEY}|g' \
  -e 's|\${SERVICE_PASSWORD_LOGFLARE}|${LOGFLARE_API_KEY}|g' \
  -e 's|\${SERVICE_PASSWORD_LOGFLAREPRIVATE}|${LOGFLARE_PRIVATE_ACCESS_TOKEN}|g' \
  -e 's|\${SERVICE_USER_MINIO}|${MINIO_ROOT_USER}|g' \
  -e 's|\${SERVICE_PASSWORD_MINIO}|${MINIO_ROOT_PASSWORD}|g' \
  -e 's|\${SERVICE_URL_SUPABASEKONG}|https://${API_HOST}|g' \
  -e 's|\${SERVICE_URL_SUPABASEKONG_8000}|https://${API_HOST}|g' \
  -e 's|\${SERVICE_FQDN_SUPABASEKONG_8000}|https://${API_HOST}|g' \
  -e 's|\${SERVICE_FQDN_SUPABASESTUDIO_3000}|https://${SB_HOST}|g' \
  "$F"

# Hard-code service-name overrides where Coolify injected the postgres UUID
sed -i \
  -e 's|\${POSTGRES_HOSTNAME:-supabase-db}|postgres|g' \
  -e 's|\${POSTGRES_HOST}|postgres|g' \
  -e 's|\${POSTGRES_HOSTNAME}|postgres|g' \
  "$F"

# MinIO endpoint
sed -i 's|http://supabase-minio:9000|http://minio:9000|g' "$F"
sed -i 's|http://${MINIO_HOST:-supabase-minio}:9000|http://minio:9000|g' "$F"
```

- [ ] **Step 4: Strip the bundled `supabase-db`, `supabase-minio`, `minio-createbucket` services and their `depends_on` references**

```bash
python3 - "$F" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f: d = yaml.safe_load(f)
for k in ('supabase-db', 'supabase-minio', 'minio-createbucket'):
    d.get('services', {}).pop(k, None)
for svc in d.get('services', {}).values():
    deps = svc.get('depends_on')
    if isinstance(deps, dict):
        for k in ('supabase-db', 'supabase-minio', 'minio-createbucket'):
            deps.pop(k, None)
        if not deps: svc.pop('depends_on', None)
    elif isinstance(deps, list):
        deps[:] = [x for x in deps if x not in ('supabase-db', 'supabase-minio', 'minio-createbucket')]
        if not deps: svc.pop('depends_on', None)
    # Strip all traefik labels — Caddy handles routing
    labels = svc.get('labels')
    if isinstance(labels, dict):
        for k in list(labels):
            if k.startswith('traefik.') or k == 'traefik.enable':
                del labels[k]
        if not labels: svc.pop('labels', None)
    elif isinstance(labels, list):
        labels[:] = [l for l in labels if not (isinstance(l, str) and l.startswith('traefik.'))]
        if not labels: svc.pop('labels', None)
with open(path, 'w') as f: yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
PY
```

- [ ] **Step 5: Append our own service blocks (postgres, minio, validator, login, caddy) and standalone-specific overrides**

Append the following YAML to `$F` (use `cat >>` to preserve the existing services):

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
      test: [CMD-SHELL, "pg_isready -U supabase_admin"]
      interval: 10s
      timeout: 5s
      retries: 10

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
      interval: 10s
      timeout: 5s
      retries: 5

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
      interval: 10s
      timeout: 3s
      retries: 3

  login:
    image: auth-gateway-login:local
    environment:
      COOKIE_DOMAIN: .${PARENT_DOMAIN}
      LOGOUT_REDIRECT: https://${SB_HOST}/
    healthcheck:
      test: [CMD-SHELL, "wget -qO- http://127.0.0.1/auth/ >/dev/null || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3

  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "443:443"
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
    depends_on:
      - validator
      - login
      - supabase-kong
      - supabase-studio
      - minio

volumes:
  postgres-data:
  minio-data:
  pgsodium-config:
  caddy-data:
  caddy-config:
```

If the imported compose already declares a top-level `volumes:` key, merge into it; otherwise the appended block creates one. Use `python3 -c "import yaml; d=yaml.safe_load(open('$F')); print(list(d.keys()))"` to check, and merge by editing.

- [ ] **Step 6: Add Google OAuth + GOTRUE_SITE_URL + DISABLE_SIGNUP env on `supabase-auth`**

```bash
python3 - "$F" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f: d = yaml.safe_load(f)
auth = d['services']['supabase-auth']
env = auth.get('environment', {})
if isinstance(env, list):
    env = {l.split('=',1)[0]: l.split('=',1)[1] for l in env if '=' in l}
env['GOTRUE_EXTERNAL_GOOGLE_ENABLED'] = 'true'
env['GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID'] = '${GOOGLE_CLIENT_ID}'
env['GOTRUE_EXTERNAL_GOOGLE_SECRET'] = '${GOOGLE_CLIENT_SECRET}'
env['GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI'] = '${GOOGLE_REDIRECT_URI}'
env['GOTRUE_SITE_URL'] = 'https://${SB_HOST}/auth/'
env['GOTRUE_DISABLE_SIGNUP'] = 'true'
env['GOTRUE_EXTERNAL_EMAIL_ENABLED'] = 'false'
auth['environment'] = env
with open(path, 'w') as f: yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
PY
```

- [ ] **Step 7: Validate the compose file**

```bash
cd /root/projects/auth-gateway/compose/standalone
docker compose --env-file=/dev/null config --quiet 2>&1 | head -20
```

Expected: zero output (= valid YAML and references resolve to placeholders). Some `WARN ... variable is not set` lines for env vars are fine — those resolve at runtime. Hard errors on YAML structure must be fixed.

- [ ] **Step 8: Commit**

```bash
git add compose/standalone/docker-compose.yml
git commit -m "feat(standalone): add docker-compose.yml derived from running stack

Source: this VPS's Coolify-generated Supabase compose, with magic vars
remapped to .env names, traefik labels stripped, supabase-db/minio/
minio-createbucket removed, and our postgres + minio + validator + login
+ caddy services appended.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Create `compose/standalone/Caddyfile`

**Files:**
- Create: `compose/standalone/Caddyfile`

- [ ] **Step 1: Write the Caddyfile**

```
{
	email {$LETSENCRYPT_EMAIL}
}

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

- [ ] **Step 2: Validate the Caddyfile**

```bash
docker run --rm -v /root/projects/auth-gateway/compose/standalone/Caddyfile:/etc/caddy/Caddyfile:ro \
  -e SB_HOST=sb.example.com \
  -e API_HOST=api.example.com \
  -e AUTH_VERIFY_HOST=auth-verify.example.com \
  -e S3_HOST=s3.example.com \
  -e MINIO_CONSOLE_HOST=minio.example.com \
  -e LETSENCRYPT_EMAIL=admin@example.com \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

Expected: `Valid configuration`.

- [ ] **Step 3: Commit**

```bash
git add compose/standalone/Caddyfile
git commit -m "feat(standalone): Caddyfile with TLS, routing, forward_auth on Studio

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Create `setup-standalone.sh`

**Files:**
- Create: `setup-standalone.sh`

- [ ] **Step 1: Write the script**

The script's structure mirrors `setup-coolify.sh` but talks to `docker compose` directly. Save to `/root/projects/auth-gateway/setup-standalone.sh`:

```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Standalone installer — for hosts without Coolify.
#
# Reads .env at the repo root, generates any missing secrets, then brings
# up the full stack via docker compose. Idempotent — re-running picks up
# changes (rebuilds images, re-applies the protect-users trigger).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
COMPOSE_DIR="$REPO_DIR/compose/standalone"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE — copy .env.example and fill it in"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${PARENT_DOMAIN:?}" "${SB_HOST:?}" "${API_HOST:?}" "${AUTH_VERIFY_HOST:?}"
: "${S3_HOST:?}" "${MINIO_CONSOLE_HOST:?}"
: "${SMTP_HOST:?}" "${SMTP_PORT:?}" "${SMTP_USER:?}" "${SMTP_PASS:?}"
: "${GOOGLE_CLIENT_ID:?}" "${GOOGLE_CLIENT_SECRET:?}"
: "${LETSENCRYPT_EMAIL:?Set LETSENCRYPT_EMAIL in .env (Caddy needs it for Let's Encrypt)}"
GOOGLE_REDIRECT_URI="${GOOGLE_REDIRECT_URI:-https://$API_HOST/auth/v1/callback}"
SMTP_ADMIN_EMAIL="${SMTP_ADMIN_EMAIL:-$SMTP_USER}"
SMTP_SENDER_NAME="${SMTP_SENDER_NAME:-Auth}"
APP_NAME="${APP_NAME:-Auth Gateway}"
OWNER_EMAIL="${OWNER_EMAIL:-}"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '   \033[31mERR\033[0m %s\n' "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { err "required: $1"; exit 1; }; }
require docker
require openssl
require python3

# Persist generated values back to .env so re-runs reuse them.
remember() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  export "$key"="$val"
}

# JWT helper: HS256-signed, payload `{role:..., iss:"supabase", iat, exp:+10y}`.
# Pure bash + openssl — no Node dependency on the host.
make_jwt() {
  local role="$1" secret="$2"
  local now exp header payload h_b64 p_b64 sig
  now=$(date +%s); exp=$((now + 3600 * 24 * 365 * 10))
  header='{"alg":"HS256","typ":"JWT"}'
  payload="{\"role\":\"$role\",\"iss\":\"supabase\",\"iat\":$now,\"exp\":$exp}"
  h_b64=$(printf '%s' "$header" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  p_b64=$(printf '%s' "$payload" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  sig=$(printf '%s' "$h_b64.$p_b64" | openssl dgst -sha256 -hmac "$secret" -binary \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  printf '%s.%s.%s' "$h_b64" "$p_b64" "$sig"
}

# ---------------------------------------------------------------------------
# 1. Generate secrets (idempotent)
# ---------------------------------------------------------------------------
log "Step 1/6: Generate / load secrets"
[ -n "${POSTGRES_PASSWORD:-}" ] || remember POSTGRES_PASSWORD "$(openssl rand -hex 24)"
[ -n "${MINIO_ROOT_USER:-}" ]   || remember MINIO_ROOT_USER "$(openssl rand -hex 8)"
[ -n "${MINIO_ROOT_PASSWORD:-}" ] || remember MINIO_ROOT_PASSWORD "$(openssl rand -hex 16)"
[ -n "${PGSODIUM_KEY:-}" ]      || remember PGSODIUM_KEY "$(openssl rand -hex 32)"
[ -n "${SUPABASE_JWT_SECRET:-}" ] || remember SUPABASE_JWT_SECRET "$(openssl rand -hex 20)"
[ -n "${SUPABASE_INTERNAL_PG_PASS:-}" ] || remember SUPABASE_INTERNAL_PG_PASS "$(openssl rand -hex 24)"
[ -n "${STUDIO_USER:-}" ]       || remember STUDIO_USER "supabase"
[ -n "${STUDIO_PASSWORD:-}" ]   || remember STUDIO_PASSWORD "$(openssl rand -hex 16)"
[ -n "${LOGFLARE_API_KEY:-}" ]  || remember LOGFLARE_API_KEY "$(openssl rand -hex 32)"
[ -n "${LOGFLARE_PRIVATE_ACCESS_TOKEN:-}" ] || remember LOGFLARE_PRIVATE_ACCESS_TOKEN "$(openssl rand -hex 32)"
[ -n "${PG_META_CRYPTO_KEY:-}" ] || remember PG_META_CRYPTO_KEY "$(openssl rand -hex 32)"
[ -n "${SUPABASE_ANON_KEY:-}" ]         || remember SUPABASE_ANON_KEY         "$(make_jwt anon         "$SUPABASE_JWT_SECRET")"
[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] || remember SUPABASE_SERVICE_ROLE_KEY "$(make_jwt service_role "$SUPABASE_JWT_SECRET")"
ok "Secrets ready"

# ---------------------------------------------------------------------------
# 2. Build images
# ---------------------------------------------------------------------------
log "Step 2/6: Build validator + login images"
if ! docker image inspect auth-gateway-validator:local >/dev/null 2>&1; then
  docker build -t auth-gateway-validator:local "$REPO_DIR/validator/" >/dev/null
fi
ok "validator image"
if ! docker image inspect auth-gateway-login:local >/dev/null 2>&1; then
  docker build \
    --build-arg "VITE_SUPABASE_URL=https://$API_HOST" \
    --build-arg "VITE_SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY" \
    --build-arg "VITE_COOKIE_DOMAIN=" \
    --build-arg "VITE_DEFAULT_REDIRECT=/" \
    --build-arg "VITE_PARENT_DOMAIN=" \
    --build-arg "VITE_APP_NAME=$APP_NAME" \
    -t auth-gateway-login:local "$REPO_DIR/login/" >/dev/null
fi
ok "login image"

# ---------------------------------------------------------------------------
# 3. Bring up Postgres alone, then bootstrap
# ---------------------------------------------------------------------------
log "Step 3/6: Postgres + bootstrap"
docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" up -d postgres
PG_CID="$(docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" ps -q postgres)"
[ -n "$PG_CID" ] || { err "postgres container not found"; exit 1; }
until docker exec "$PG_CID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
ok "postgres up"

# pgsodium key + extensions (only on first run)
if ! docker exec "$PG_CID" test -x /etc/postgresql-custom/pgsodium_getkey.sh 2>/dev/null; then
  docker exec "$PG_CID" bash -c "
    mkdir -p /etc/postgresql-custom &&
    printf '#!/bin/bash\necho %s\n' '$PGSODIUM_KEY' > /etc/postgresql-custom/pgsodium_getkey.sh &&
    chmod 700 /etc/postgresql-custom/pgsodium_getkey.sh &&
    chown postgres:postgres /etc/postgresql-custom/pgsodium_getkey.sh"
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    ALTER SYSTEM SET shared_preload_libraries = 'pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net';
    ALTER SYSTEM SET pgsodium.getkey_script = '/etc/postgresql-custom/pgsodium_getkey.sh';" >/dev/null
  docker restart "$PG_CID" >/dev/null
  until docker exec "$PG_CID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
  ok "pgsodium configured"
fi

# Init SQL — only if _supabase database doesn't yet exist
if ! docker exec "$PG_CID" psql -U supabase_admin -d postgres -tc \
       "SELECT 1 FROM pg_database WHERE datname='_supabase'" | grep -q 1; then
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    ALTER USER supabase_admin WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER postgres WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER authenticator WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER pgbouncer WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_auth_admin WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_storage_admin WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_replication_admin WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_read_only_user WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';" >/dev/null
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    CREATE ROLE supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD '$SUPABASE_INTERNAL_PG_PASS';" 2>/dev/null || true

  docker cp "$REPO_DIR/scripts/postgres-init/." "$PG_CID:/tmp/sb_init/"
  for script in _supabase realtime pooler logs webhooks; do
    docker exec "$PG_CID" psql -U supabase_admin -d postgres -f "/tmp/sb_init/${script}.sql" >/dev/null 2>&1 || \
      warn "${script}.sql had errors (often benign on re-run)"
  done
  docker exec -e JWT_SECRET="$SUPABASE_JWT_SECRET" -e JWT_EXP=3600 -e POSTGRES_DB=postgres "$PG_CID" \
    psql -U supabase_admin -d postgres -f /tmp/sb_init/jwt.sql >/dev/null
  docker exec -e POSTGRES_PASSWORD="$SUPABASE_INTERNAL_PG_PASS" "$PG_CID" \
    psql -U supabase_admin -d postgres -f /tmp/sb_init/roles.sql >/dev/null
  ok "Postgres bootstrapped"
else
  ok "Postgres already bootstrapped"
fi

# ---------------------------------------------------------------------------
# 4. Bring up the full stack
# ---------------------------------------------------------------------------
log "Step 4/6: Bring up the full stack"
docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" up -d
ok "All services up"

# ---------------------------------------------------------------------------
# 5. Apply protect-users trigger (after gotrue creates auth.users)
# ---------------------------------------------------------------------------
log "Step 5/6: Install auth.users protection trigger"
until docker exec "$PG_CID" psql -U supabase_admin -d postgres -tc \
  "SELECT 1 FROM information_schema.tables WHERE table_schema='auth' AND table_name='users'" \
  | grep -q 1; do sleep 2; done
docker cp "$REPO_DIR/scripts/postgres-init/protect-users.sql" "$PG_CID:/tmp/protect-users.sql"
docker exec "$PG_CID" psql -U supabase_admin -d postgres -f /tmp/protect-users.sql >/dev/null
if [ -n "$OWNER_EMAIL" ]; then
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    UPDATE auth.users
    SET raw_app_meta_data = COALESCE(raw_app_meta_data,'{}'::jsonb) || '{\"is_protected\":true}'::jsonb
    WHERE email = '$OWNER_EMAIL';" >/dev/null
fi
ok "protect-users trigger installed"

# ---------------------------------------------------------------------------
# 6. Done
# ---------------------------------------------------------------------------
log "Step 6/6: Verify"
cat <<EOF

==> Done. Caddy will negotiate Let's Encrypt certs on first request to each host.

   Verify:
     curl -kI https://$AUTH_VERIFY_HOST/healthz   # 200, "ok"
     curl -kI https://$SB_HOST/                   # 302 to /auth/?rd=...
     curl -k  "https://$SB_HOST/auth/?rd=https://$SB_HOST/" | grep -q 'Sign in'

   Bootstrap user (run once):
     SVC_KEY="\$(grep ^SUPABASE_SERVICE_ROLE_KEY $ENV_FILE | cut -d= -f2)"
     curl -k -X POST "https://$API_HOST/auth/v1/admin/users" \\
       -H "apikey: \$SVC_KEY" -H "Authorization: Bearer \$SVC_KEY" \\
       -H "Content-Type: application/json" \\
       -d '{"email":"you@example.com","password":"changeme","email_confirm":true}'

EOF
```

- [ ] **Step 2: Make executable + lint**

```bash
chmod +x /root/projects/auth-gateway/setup-standalone.sh
bash -n /root/projects/auth-gateway/setup-standalone.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add setup-standalone.sh
git commit -m "feat(standalone): setup-standalone.sh — Docker-only installer

Generates secrets idempotently, builds images, bootstraps Postgres with
the same init SQL the Coolify path uses, brings up the stack via
docker compose, applies the protect-users trigger.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Create `teardown-standalone.sh`

**Files:**
- Create: `teardown-standalone.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Removes the standalone stack and its named volumes (DESTRUCTIVE — wipes
# all data). To keep volumes, run `docker compose down` without -v
# manually.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/compose/standalone"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

if [ "${1:-}" != "--yes" ]; then
  echo "This will remove all containers AND volumes (Postgres data, MinIO data, Caddy certs)."
  echo "Re-run with --yes to confirm."
  exit 1
fi

docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" down -v
echo "Done."
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x /root/projects/auth-gateway/teardown-standalone.sh
bash -n /root/projects/auth-gateway/teardown-standalone.sh
git add teardown-standalone.sh
git commit -m "feat(standalone): teardown-standalone.sh (requires --yes)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Rewrite README header to introduce both installers

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "Prerequisites" + "Deploy" sections with a two-installer intro**

Read the existing README and replace the section between `## What you get` and `## How the auth flow works` with:

```markdown
## Pick your installer

Two installers, both produce the same running stack:

- **`./setup-coolify.sh`** — for hosts that already have Coolify v4. Drives
  Coolify's API (creates DB + services, edits Coolify's compose).
- **`./setup-standalone.sh`** — for plain Docker hosts. Brings up the full
  stack (Caddy + Postgres + MinIO + Supabase + auth) via `docker compose`.

Pick by what's already on your VPS.

### Common prerequisites

- A domain you control with a wildcard A record (`*.example.com`) pointing
  at the VPS public IP. The installer's reverse proxy (Coolify's traefik
  or the standalone Caddy) negotiates Let's Encrypt certs on first request.
- An SMTP mailbox for confirmation/recovery emails (port 587 / STARTTLS;
  most clouds block 25/465). `SMTP_USER` and `SMTP_ADMIN_EMAIL` should be
  the same address.
- `bash`, `curl`, `docker`, `openssl`, `python3` on the host.

### Coolify-specific prerequisites

- Coolify v4 already installed (`curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`).
- The Coolify root API token (Coolify → Keys & Tokens → Create New Token).
- The target Coolify project + server UUIDs (`/api/v1/projects`, `/api/v1/servers`).

### Standalone-specific prerequisites

- Docker Compose v2.
- Ports 80 and 443 free on the host.
- `LETSENCRYPT_EMAIL` set in `.env`.

## Deploy

```bash
git clone https://github.com/<you>/auth-gateway.git
cd auth-gateway
cp .env.example .env
$EDITOR .env

# On a Coolify host:
./setup-coolify.sh

# On a plain Docker host:
./setup-standalone.sh
```

Both installers are idempotent — re-running picks up code changes and
skips already-existing resources.

## Teardown

```bash
./teardown-coolify.sh                  # Coolify resources (volumes kept)
./teardown-standalone.sh --yes         # docker compose down -v (DESTRUCTIVE)
```
```

The "How the auth flow works", "Logout", "Protect another app", and "Caveats" sections stay.

- [ ] **Step 2: Apply the rewrite via Edit tool**

Read `README.md`, identify the exact span to replace, edit.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): introduce two installers (Coolify and standalone)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Smoke-test the Coolify installer is unbroken on this VPS

**Files:** none modified.

- [ ] **Step 1: Run `setup-coolify.sh` against this VPS**

```bash
cd /root/projects/auth-gateway
./setup-coolify.sh 2>&1 | tee /tmp/setup-coolify.log
```

Expected: idempotent run completes without errors. All "exists" / "OK" markers, no "ERR".

- [ ] **Step 2: Verify endpoints still work**

```bash
AUTH_VERIFY_HOST=$(grep ^AUTH_VERIFY_HOST .env | cut -d= -f2)
SB_HOST=$(grep ^SB_HOST .env | cut -d= -f2)

curl -skI "https://$AUTH_VERIFY_HOST/healthz" | head -1   # HTTP/2 200
curl -skI "https://$SB_HOST/" | head -1                   # HTTP/2 302
```

Expected: 200 and 302 respectively.

- [ ] **Step 3: If any failures, investigate and fix path references**

Most likely cause is a missed `compose/coolify/` path update. `grep -rn 'compose/[a-z-]\+\.compose\.yml' setup-coolify.sh` should return only the three rewritten lines.

---

## Task 9: Validate the standalone compose renders against a sample env

**Files:** none modified — verification only.

- [ ] **Step 1: Render with sample env to catch missing references**

```bash
cd /root/projects/auth-gateway/compose/standalone
docker compose --env-file=<(cat <<EOF
PARENT_DOMAIN=example.com
SB_HOST=sb.example.com
API_HOST=api.example.com
AUTH_VERIFY_HOST=auth-verify.example.com
S3_HOST=s3.example.com
MINIO_CONSOLE_HOST=minio.example.com
LETSENCRYPT_EMAIL=admin@example.com
POSTGRES_PASSWORD=pgpass
SUPABASE_JWT_SECRET=secret
SUPABASE_ANON_KEY=anon
SUPABASE_SERVICE_ROLE_KEY=svc
SUPABASE_INTERNAL_PG_PASS=intpg
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=minio12345678
STUDIO_USER=supabase
STUDIO_PASSWORD=studio
LOGFLARE_API_KEY=lf
LOGFLARE_PRIVATE_ACCESS_TOKEN=lfp
PG_META_CRYPTO_KEY=pgmeta
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=https://api.example.com/auth/v1/callback
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=admin@example.com
SMTP_PASS=
SMTP_ADMIN_EMAIL=admin@example.com
SMTP_SENDER_NAME=Auth
APP_NAME=Auth Gateway
OWNER_EMAIL=
EOF
) config 2>&1 | tail -20
```

Expected: full rendered YAML, no `WARN ... is not set` lines for the vars above. Any remaining `${SERVICE_*}` references are bugs — fix in the compose.

---

## Task 10: Final commit + summary

- [ ] **Step 1: Verify clean tree**

```bash
cd /root/projects/auth-gateway
git status
```

Expected: clean.

- [ ] **Step 2: Print the new top-level layout**

```bash
ls -la /root/projects/auth-gateway/ | grep -E 'setup|teardown|env|README'
```

Expected: `setup-coolify.sh`, `setup-standalone.sh`, `teardown-coolify.sh`, `teardown-standalone.sh`, `.env.example`, `README.md`.
