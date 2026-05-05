#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Auth-Gateway full-stack bootstrap.
#
# Reads .env at the repo root, then via Coolify's API:
#   1. Creates a supabase/postgres database
#   2. Bootstraps Postgres for Supabase (pgsodium key, init SQL scripts)
#   3. Creates a MinIO service
#   4. Creates the Supabase one-click service, wired to the standalone Postgres
#   5. Builds + deploys the auth-validator service (image built locally)
#   6. Builds + deploys the auth-login service (image built locally)
#   7. Adds traefik forward-auth labels to supabase-studio so it sits behind
#      the validator
#
# Idempotent — re-running skips already-existing resources by name.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE — copy .env.example and fill it in"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${COOLIFY_URL:?}" "${COOLIFY_TOKEN:?}" "${PROJECT_UUID:?}" "${SERVER_UUID:?}"
: "${PARENT_DOMAIN:?}" "${SB_HOST:?}" "${API_HOST:?}" "${AUTH_VERIFY_HOST:?}"
# AUTH_HOST is legacy (subdomain mode). Path-based deploys leave it empty.
AUTH_HOST="${AUTH_HOST:-}"
: "${S3_HOST:?}" "${MINIO_CONSOLE_HOST:?}"
: "${SMTP_HOST:?}" "${SMTP_PORT:?}" "${SMTP_USER:?}" "${SMTP_PASS:?}"

API="$COOLIFY_URL/api/v1"
AUTH=(-H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json")

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '   \033[31mERR\033[0m %s\n' "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { err "required: $1"; exit 1; }; }
require curl
require docker
require python3
require openssl
require base64

service_uuid_by_name() {
  curl -s "${AUTH[@]}" "$API/services" \
    | python3 -c "import json,sys; [print(s['uuid']) for s in json.load(sys.stdin) if s.get('name')==sys.argv[1]]" "$1" \
    | head -1
}
db_uuid_by_name() {
  curl -s "${AUTH[@]}" "$API/databases" \
    | python3 -c "import json,sys; [print(d['uuid']) for d in json.load(sys.stdin) if d.get('name')==sys.argv[1]]" "$1" \
    | head -1
}
deploy() { curl -s -X GET "${AUTH[@]}" "$API/deploy?uuid=$1&force=true" >/dev/null; }
patch_env() {
  local svc="$1" key="$2" val="$3"
  curl -s -X PATCH "${AUTH[@]}" "$API/services/$svc/envs" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'key':sys.argv[1],'value':sys.argv[2],'is_preview':False,'is_buildtime':False,'is_literal':False}))" "$key" "$val")" \
    >/dev/null
}
b64() { python3 -c "import sys, base64; print(base64.b64encode(sys.stdin.buffer.read()).decode())"; }

# Render `${VAR}` in a compose file using bash's parameter expansion via envsubst
# (envsubst is in the gettext-base package; if missing, fall back to python).
render() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$1"
  else
    python3 - "$1" <<'PY'
import os, sys, re
src = open(sys.argv[1]).read()
sys.stdout.write(re.sub(r'\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), ''), src))
PY
  fi
}

# Persist generated values back to .env so re-runs reuse them (idempotent).
remember() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# 1. Postgres
# ---------------------------------------------------------------------------
log "Step 1/7: Postgres (image: supabase/postgres)"
PG_UUID="$(db_uuid_by_name supabase-postgres || true)"
if [ -z "$PG_UUID" ]; then
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 24)}"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/databases/postgresql" -d @- <<JSON
{
  "project_uuid": "$PROJECT_UUID",
  "server_uuid": "$SERVER_UUID",
  "environment_name": "production",
  "name": "supabase-postgres",
  "image": "supabase/postgres:15.8.1.060",
  "postgres_user": "supabase_admin",
  "postgres_password": "$POSTGRES_PASSWORD",
  "postgres_db": "postgres",
  "instant_deploy": true
}
JSON
)
  PG_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$PG_UUID" ] || { err "Postgres create failed: $resp"; exit 1; }
  remember POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
  remember POSTGRES_UUID "$PG_UUID"
  ok "Postgres deployed: $PG_UUID"
else
  remember POSTGRES_UUID "$PG_UUID"
  ok "Postgres exists: $PG_UUID"
fi

log "Waiting for Postgres to accept connections"
until docker exec "$PG_UUID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
ok "Postgres ready"

# ---------------------------------------------------------------------------
# 1b. Bootstrap Postgres for Supabase
# ---------------------------------------------------------------------------
log "Step 1b/7: Bootstrap Postgres (pgsodium key + extensions + init SQL)"
if ! docker exec "$PG_UUID" test -x /etc/postgresql-custom/pgsodium_getkey.sh 2>/dev/null; then
  PGSODIUM_KEY="$(openssl rand -hex 32)"
  docker exec "$PG_UUID" bash -c "
    mkdir -p /etc/postgresql-custom &&
    printf '#!/bin/bash\necho %s\n' '$PGSODIUM_KEY' > /etc/postgresql-custom/pgsodium_getkey.sh &&
    chmod 700 /etc/postgresql-custom/pgsodium_getkey.sh &&
    chown postgres:postgres /etc/postgresql-custom/pgsodium_getkey.sh"

  docker exec "$PG_UUID" psql -U supabase_admin -d postgres -c "
    ALTER SYSTEM SET shared_preload_libraries = 'pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net';
    ALTER SYSTEM SET pgsodium.getkey_script = '/etc/postgresql-custom/pgsodium_getkey.sh';" >/dev/null
  docker restart "$PG_UUID" >/dev/null
  until docker exec "$PG_UUID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
  remember PGSODIUM_KEY "$PGSODIUM_KEY"
  ok "pgsodium configured"
fi

# Apply init scripts. We run them after Supabase is created so we know the
# JWT secret + role passwords first — see step 4b below.

# ---------------------------------------------------------------------------
# 2. MinIO
# ---------------------------------------------------------------------------
log "Step 2/7: MinIO"
MINIO_UUID="$(service_uuid_by_name minio || true)"
if [ -z "$MINIO_UUID" ]; then
  export MINIO_ROOT_USER="${MINIO_ROOT_USER:-$(openssl rand -hex 8)}"
  export MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -hex 16)}"
  COMPOSE_B64="$(render "$REPO_DIR/compose/minio.compose.yml" | b64)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"minio","docker_compose_raw":"$COMPOSE_B64","instant_deploy":true }
JSON
)
  MINIO_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$MINIO_UUID" ] || { err "MinIO create failed: $resp"; exit 1; }
  remember MINIO_ROOT_USER "$MINIO_ROOT_USER"
  remember MINIO_ROOT_PASSWORD "$MINIO_ROOT_PASSWORD"
  remember MINIO_UUID "$MINIO_UUID"
  ok "MinIO deployed: $MINIO_UUID"
else
  remember MINIO_UUID "$MINIO_UUID"
  ok "MinIO exists: $MINIO_UUID"
fi

# ---------------------------------------------------------------------------
# 3. Supabase (one-click template, then point at standalone Postgres + MinIO)
# ---------------------------------------------------------------------------
log "Step 3/7: Supabase one-click + rewire"
SUPA_UUID="$(service_uuid_by_name supabase || true)"
if [ -z "$SUPA_UUID" ]; then
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "type":"supabase","name":"supabase","project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID",
  "environment_name":"production","instant_deploy":false }
JSON
)
  SUPA_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$SUPA_UUID" ] || { err "Supabase create failed: $resp"; exit 1; }
  remember SUPABASE_UUID "$SUPA_UUID"
  ok "Supabase service shell: $SUPA_UUID"
fi

log "Wiring Supabase env vars"
patch_env "$SUPA_UUID" SERVICE_FQDN_SUPABASEKONG_8000   "https://$API_HOST"
patch_env "$SUPA_UUID" SERVICE_FQDN_SUPABASESTUDIO_3000 "https://$SB_HOST"
patch_env "$SUPA_UUID" POSTGRES_HOSTNAME                "$PG_UUID"
patch_env "$SUPA_UUID" POSTGRES_HOST                    "$PG_UUID"
patch_env "$SUPA_UUID" POSTGRES_PORT                    "5432"
patch_env "$SUPA_UUID" STORAGE_S3_ENDPOINT              "http://minio-$MINIO_UUID:9000"
patch_env "$SUPA_UUID" API_EXTERNAL_URL                 "https://$API_HOST"
patch_env "$SUPA_UUID" SUPABASE_PUBLIC_URL              "https://$API_HOST"
# Path-based deployment: invite/recovery emails should redirect to /auth/
# (the login page) which knows how to parse the auth fragment. Setting
# this to the bare host triggers the forward-auth bounce, which strips the
# fragment and breaks the invite click-through flow.
patch_env "$SUPA_UUID" GOTRUE_SITE_URL                  "https://$SB_HOST/auth/"
patch_env "$SUPA_UUID" DISABLE_SIGNUP                   "true"
patch_env "$SUPA_UUID" ENABLE_EMAIL_SIGNUP              "false"
patch_env "$SUPA_UUID" SMTP_HOST                        "$SMTP_HOST"
patch_env "$SUPA_UUID" SMTP_PORT                        "$SMTP_PORT"
patch_env "$SUPA_UUID" SMTP_USER                        "$SMTP_USER"
patch_env "$SUPA_UUID" SMTP_PASS                        "$SMTP_PASS"
patch_env "$SUPA_UUID" SMTP_ADMIN_EMAIL                 "${SMTP_ADMIN_EMAIL:-$SMTP_USER}"
patch_env "$SUPA_UUID" SMTP_SENDER_NAME                 "${SMTP_SENDER_NAME:-Auth}"
ok "env wired"

# Capture the auto-generated SUPABASE secrets before first deploy
JWT_SECRET="$(curl -s "${AUTH[@]}" "$API/services/$SUPA_UUID/envs" | python3 -c "
import json,sys
for e in json.load(sys.stdin):
  if e['key']=='SERVICE_PASSWORD_JWT': print(e['real_value']); break")"
ANON_KEY="$(curl -s "${AUTH[@]}" "$API/services/$SUPA_UUID/envs" | python3 -c "
import json,sys
for e in json.load(sys.stdin):
  if e['key']=='SERVICE_SUPABASEANON_KEY': print(e['real_value']); break")"
SVC_KEY="$(curl -s "${AUTH[@]}" "$API/services/$SUPA_UUID/envs" | python3 -c "
import json,sys
for e in json.load(sys.stdin):
  if e['key']=='SERVICE_SUPABASESERVICE_KEY': print(e['real_value']); break")"
SUPA_PG_PASS="$(curl -s "${AUTH[@]}" "$API/services/$SUPA_UUID/envs" | python3 -c "
import json,sys
for e in json.load(sys.stdin):
  if e['key']=='SERVICE_PASSWORD_POSTGRES': print(e['real_value']); break")"
remember SUPABASE_JWT_SECRET "$JWT_SECRET"
remember SUPABASE_ANON_KEY   "$ANON_KEY"
remember SUPABASE_SERVICE_ROLE_KEY "$SVC_KEY"
remember SUPABASE_INTERNAL_PG_PASS "$SUPA_PG_PASS"

# ---------------------------------------------------------------------------
# 3b. Apply Supabase init scripts to the standalone Postgres
# ---------------------------------------------------------------------------
log "Step 3b/7: Run Supabase init SQL against standalone Postgres"
docker exec "$PG_UUID" psql -U supabase_admin -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='_supabase'" | grep -q 1 || {
  # Align Supabase role passwords to SUPABASE_INTERNAL_PG_PASS so the supabase services can connect.
  docker exec "$PG_UUID" psql -U supabase_admin -d postgres -c "
    ALTER USER supabase_admin WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER postgres WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER authenticator WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER pgbouncer WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER supabase_auth_admin WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER supabase_storage_admin WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER supabase_replication_admin WITH PASSWORD '$SUPA_PG_PASS';
    ALTER USER supabase_read_only_user WITH PASSWORD '$SUPA_PG_PASS';" >/dev/null
  docker exec "$PG_UUID" psql -U supabase_admin -d postgres -c "
    CREATE ROLE supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION PASSWORD '$SUPA_PG_PASS';" 2>/dev/null || true

  # Copy init scripts into the container then run in order.
  docker cp "$REPO_DIR/scripts/postgres-init/." "$PG_UUID:/tmp/sb_init/"

  for script in _supabase realtime pooler logs webhooks; do
    docker exec -e POSTGRES_USER=supabase_admin "$PG_UUID" \
      psql -U supabase_admin -d postgres -f "/tmp/sb_init/${script}.sql" >/dev/null 2>&1 || \
        warn "${script}.sql had errors (often benign on re-run)"
  done
  docker exec -e JWT_SECRET="$JWT_SECRET" -e JWT_EXP=3600 -e POSTGRES_DB=postgres "$PG_UUID" \
    psql -U supabase_admin -d postgres -f /tmp/sb_init/jwt.sql >/dev/null
  docker exec -e POSTGRES_PASSWORD="$SUPA_PG_PASS" "$PG_UUID" \
    psql -U supabase_admin -d postgres -f /tmp/sb_init/roles.sql >/dev/null
  ok "Postgres bootstrapped"
}

# Strip the bundled supabase-db + supabase-minio + minio-createbucket from the
# Supabase compose so the stack uses our standalone Postgres + MinIO.
log "Stripping bundled supabase-db, supabase-minio, minio-createbucket"
COMPOSE_PATH="/data/coolify/services/$SUPA_UUID/docker-compose.yml"
if [ -f "$COMPOSE_PATH" ]; then
  python3 - "$COMPOSE_PATH" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f: d = yaml.safe_load(f)
for k in ('supabase-db', 'supabase-minio', 'minio-createbucket'):
    d['services'].pop(k, None)
for svc in d['services'].values():
    deps = svc.get('depends_on')
    if isinstance(deps, dict):
        for k in ('supabase-db', 'supabase-minio', 'minio-createbucket'):
            deps.pop(k, None)
        if not deps: svc.pop('depends_on', None)
with open(path, 'w') as f: yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
PY
fi
deploy "$SUPA_UUID"

# Connect supabase-storage to MinIO network so STORAGE_S3_ENDPOINT resolves
sleep 5
until docker ps --filter "name=supabase-storage-$SUPA_UUID" --format '{{.Names}}' | grep -q .; do sleep 3; done
docker network connect "$MINIO_UUID" "supabase-storage-$SUPA_UUID" 2>/dev/null || true
docker network connect "$PG_UUID" "$SUPA_UUID" 2>/dev/null || true   # standalone PG → supabase service network
ok "Supabase deployed"

# ---------------------------------------------------------------------------
# 4. Validator
# ---------------------------------------------------------------------------
log "Step 4/7: Build + deploy auth-validator"
if ! docker image inspect auth-gateway-validator:local >/dev/null 2>&1; then
  docker build -t auth-gateway-validator:local "$REPO_DIR/validator/" >/dev/null
fi
ok "validator image ready"

VAL_UUID="$(service_uuid_by_name auth-validator || true)"
if [ -z "$VAL_UUID" ]; then
  export AUTH_VERIFY_HOST SB_HOST SUPABASE_JWT_SECRET="$JWT_SECRET"
  COMPOSE_B64="$(render "$REPO_DIR/compose/auth-validator.compose.yml" | b64)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"auth-validator","docker_compose_raw":"$COMPOSE_B64","instant_deploy":true }
JSON
)
  VAL_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$VAL_UUID" ] || { err "Validator create failed: $resp"; exit 1; }
  remember VALIDATOR_UUID "$VAL_UUID"
  ok "Validator deployed: $VAL_UUID"
else
  remember VALIDATOR_UUID "$VAL_UUID"
  ok "Validator exists: $VAL_UUID"
fi

# ---------------------------------------------------------------------------
# 5. Login
# ---------------------------------------------------------------------------
log "Step 5/7: Build + deploy auth-login"
if ! docker image inspect auth-gateway-login:local >/dev/null 2>&1; then
  docker build \
    --build-arg "VITE_SUPABASE_URL=https://$API_HOST" \
    --build-arg "VITE_SUPABASE_ANON_KEY=$ANON_KEY" \
    --build-arg "VITE_COOKIE_DOMAIN=" \
    --build-arg "VITE_DEFAULT_REDIRECT=/" \
    --build-arg "VITE_PARENT_DOMAIN=" \
    --build-arg "VITE_APP_NAME=${APP_NAME:-Auth Gateway}" \
    -t auth-gateway-login:local "$REPO_DIR/login/" >/dev/null
fi
ok "login image ready"

LOGIN_UUID="$(service_uuid_by_name auth-login || true)"
if [ -z "$LOGIN_UUID" ]; then
  export AUTH_HOST SB_HOST
  AUTH_HOST_REGEX="$(printf '%s' "$AUTH_HOST" | sed 's/\./\\\\./g')"
  export AUTH_HOST_REGEX
  COMPOSE_B64="$(render "$REPO_DIR/compose/auth-login.compose.yml" | b64)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"auth-login","docker_compose_raw":"$COMPOSE_B64","instant_deploy":true }
JSON
)
  LOGIN_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$LOGIN_UUID" ] || { err "Login create failed: $resp"; exit 1; }
  remember LOGIN_UUID "$LOGIN_UUID"
  ok "Login deployed: $LOGIN_UUID"
else
  remember LOGIN_UUID "$LOGIN_UUID"
  ok "Login exists: $LOGIN_UUID"
fi

# ---------------------------------------------------------------------------
# 6. Wire forward-auth onto supabase-studio
# ---------------------------------------------------------------------------
log "Step 6/7: Wire forward-auth onto supabase-studio"
python3 - "$SUPA_UUID" "$VAL_UUID" <<'PY'
import sys, yaml
SUPA, VAL = sys.argv[1], sys.argv[2]
path = f"/data/coolify/services/{SUPA}/docker-compose.yml"
with open(path) as f: d = yaml.safe_load(f)
studio = d['services']['supabase-studio']
labels = studio.get('labels', {})
if isinstance(labels, list):
    labels = {l.split('=',1)[0]: l.split('=',1)[1] for l in labels if '=' in l}
for k in list(labels):
    if 'auth-gateway' in k or 'authentik' in k or 'authelia' in k or 'studio-basicauth' in k:
        del labels[k]
verify = f"http://validator-{VAL}:8080/verify"
labels['traefik.http.middlewares.auth-gateway.forwardauth.address'] = verify
labels['traefik.http.middlewares.auth-gateway.forwardauth.trustForwardHeader'] = 'true'
labels['traefik.http.middlewares.auth-gateway.forwardauth.authResponseHeaders'] = 'X-User-Id,X-User-Email,X-User-Role'
labels[f'traefik.http.routers.http-0-{SUPA}-supabase-studio.middlewares']  = 'redirect-to-https,auth-gateway'
labels[f'traefik.http.routers.https-0-{SUPA}-supabase-studio.middlewares'] = 'gzip,auth-gateway'
studio['labels'] = labels
with open(path, 'w') as f: yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
PY
deploy "$SUPA_UUID"
ok "Forward-auth wired"

# ---------------------------------------------------------------------------
# 7. Reload traefik so it picks up the new networks/labels
# ---------------------------------------------------------------------------
log "Step 7/7: Reload traefik (coolify-proxy)"
docker network connect "$VAL_UUID" coolify-proxy 2>/dev/null || true
docker network connect "$LOGIN_UUID" coolify-proxy 2>/dev/null || true
docker network connect "$MINIO_UUID" coolify-proxy 2>/dev/null || true
docker network connect "$SUPA_UUID" coolify-proxy 2>/dev/null || true
docker restart coolify-proxy >/dev/null
ok "Traefik reloaded"

cat <<EOF

==> Done.
   Verify:
     curl -skI https://$AUTH_VERIFY_HOST/healthz   # 200, "ok"
     curl -skI https://$SB_HOST/                   # 302 to https://$AUTH_HOST/?rd=...
     curl -skI 'https://$AUTH_HOST/?rd=https://$SB_HOST/'   # 200 (login HTML)

   Generated values written back to $ENV_FILE:
     POSTGRES_PASSWORD, POSTGRES_UUID
     MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, MINIO_UUID
     SUPABASE_UUID, SUPABASE_JWT_SECRET, SUPABASE_ANON_KEY,
     SUPABASE_SERVICE_ROLE_KEY, SUPABASE_INTERNAL_PG_PASS
     VALIDATOR_UUID, LOGIN_UUID, PGSODIUM_KEY

   Add a user in Supabase Studio (sb.$PARENT_DOMAIN) -> Authentication -> Users
   to be able to sign in to the gateway.
EOF
