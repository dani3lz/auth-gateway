#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Standalone installer — for hosts without Coolify.
#
# Reads .env at the repo root, generates any missing secrets, then brings
# up the full stack via docker compose. Idempotent — re-running picks up
# changes (rebuilds images on `docker rmi`, re-applies the protect-users
# trigger).
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
: "${LETSENCRYPT_EMAIL:?Set LETSENCRYPT_EMAIL in .env (Caddy needs it for Lets Encrypt)}"
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

remember() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  export "$key"="$val"
}

# HS256 JWT, payload {role, iss:"supabase", iat, exp:+10y}. Pure bash + openssl.
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

dc() { docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" --env-file "$ENV_FILE" "$@"; }

# ---------------------------------------------------------------------------
# 1. Generate secrets (idempotent)
# ---------------------------------------------------------------------------
log "Step 1/6: Generate / load secrets"
[ -n "${POSTGRES_PASSWORD:-}" ]              || remember POSTGRES_PASSWORD "$(openssl rand -hex 24)"
[ -n "${MINIO_ROOT_USER:-}" ]                || remember MINIO_ROOT_USER "$(openssl rand -hex 8)"
[ -n "${MINIO_ROOT_PASSWORD:-}" ]            || remember MINIO_ROOT_PASSWORD "$(openssl rand -hex 16)"
[ -n "${PGSODIUM_KEY:-}" ]                   || remember PGSODIUM_KEY "$(openssl rand -hex 32)"
[ -n "${SUPABASE_JWT_SECRET:-}" ]            || remember SUPABASE_JWT_SECRET "$(openssl rand -hex 20)"
[ -n "${SUPABASE_INTERNAL_PG_PASS:-}" ]      || remember SUPABASE_INTERNAL_PG_PASS "$(openssl rand -hex 24)"
[ -n "${STUDIO_USER:-}" ]                    || remember STUDIO_USER "supabase"
[ -n "${STUDIO_PASSWORD:-}" ]                || remember STUDIO_PASSWORD "$(openssl rand -hex 16)"
[ -n "${LOGFLARE_API_KEY:-}" ]               || remember LOGFLARE_API_KEY "$(openssl rand -hex 32)"
[ -n "${LOGFLARE_PRIVATE_ACCESS_TOKEN:-}" ]  || remember LOGFLARE_PRIVATE_ACCESS_TOKEN "$(openssl rand -hex 32)"
[ -n "${PG_META_CRYPTO_KEY:-}" ]             || remember PG_META_CRYPTO_KEY "$(openssl rand -hex 32)"
[ -n "${SUPAVISOR_SECRET_KEY_BASE:-}" ]      || remember SUPAVISOR_SECRET_KEY_BASE "$(openssl rand -hex 32)"
[ -n "${SUPAVISOR_VAULT_ENC_KEY:-}" ]        || remember SUPAVISOR_VAULT_ENC_KEY "$(openssl rand -hex 16)"
[ -n "${SUPABASE_ANON_KEY:-}" ]              || remember SUPABASE_ANON_KEY         "$(make_jwt anon         "$SUPABASE_JWT_SECRET")"
[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]      || remember SUPABASE_SERVICE_ROLE_KEY "$(make_jwt service_role "$SUPABASE_JWT_SECRET")"
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
dc up -d postgres
PG_CID="$(dc ps -q postgres)"
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

# Init SQL (only on first run — guarded by _supabase database existence)
if ! docker exec "$PG_CID" psql -U supabase_admin -d postgres -tc \
       "SELECT 1 FROM pg_database WHERE datname='_supabase'" | grep -q 1; then
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    ALTER USER supabase_admin            WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER postgres                  WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER authenticator             WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER pgbouncer                 WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_auth_admin       WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_storage_admin    WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_replication_admin WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';
    ALTER USER supabase_read_only_user   WITH PASSWORD '$SUPABASE_INTERNAL_PG_PASS';" >/dev/null
  docker exec "$PG_CID" psql -U supabase_admin -d postgres -c "
    CREATE ROLE supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD '$SUPABASE_INTERNAL_PG_PASS';" 2>/dev/null || true

  docker cp "$REPO_DIR/scripts/postgres-init/." "$PG_CID:/tmp/sb_init/"
  for script in _supabase realtime pooler logs webhooks; do
    docker exec "$PG_CID" psql -U supabase_admin -d postgres -f "/tmp/sb_init/${script}.sql" >/dev/null 2>&1 || warn "${script}.sql had errors"
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
dc up -d
ok "All services up"

# ---------------------------------------------------------------------------
# 5. Apply protect-users trigger (after gotrue creates auth.users)
# ---------------------------------------------------------------------------
log "Step 5/6: Install auth.users protection trigger"
until docker exec "$PG_CID" psql -U supabase_admin -d postgres -tc "SELECT 1 FROM information_schema.tables WHERE table_schema='auth' AND table_name='users'" | grep -q 1; do sleep 2; done
docker cp "$REPO_DIR/scripts/postgres-init/protect-users.sql" "$PG_CID:/tmp/protect-users.sql"
docker exec "$PG_CID" psql -U supabase_admin -d postgres -f /tmp/protect-users.sql >/dev/null
if [ -n "$OWNER_EMAIL" ]; then
  docker exec -i "$PG_CID" psql -U supabase_admin -d postgres -v owner="$OWNER_EMAIL" -v ON_ERROR_STOP=1 >/dev/null <<SQL
UPDATE auth.users
SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('is_protected', true)
WHERE email = :'owner';
SQL
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

   Bootstrap user (run once):
     SVC_KEY="\$(grep ^SUPABASE_SERVICE_ROLE_KEY $ENV_FILE | cut -d= -f2)"
     curl -k -X POST "https://$API_HOST/auth/v1/admin/users" \\
       -H "apikey: \$SVC_KEY" -H "Authorization: Bearer \$SVC_KEY" \\
       -H "Content-Type: application/json" \\
       -d '{"email":"you@example.com","password":"changeme","email_confirm":true}'

EOF
