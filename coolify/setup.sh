#!/usr/bin/env bash
# Idempotent bootstrap of the entire Soltrix self-hosted stack on a fresh Coolify host.
# Order: Postgres -> MinIO -> Supabase -> Validator -> Login -> wire forward-auth onto Studio.
# Re-running is safe: each step checks for an existing resource first.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="${ENV_FILE:-./env/stack.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE (copy stack.env.example and fill it in)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${COOLIFY_URL:?}" "${COOLIFY_TOKEN:?}" "${PROJECT_UUID:?}" "${SERVER_UUID:?}"
: "${PARENT_DOMAIN:?}" "${SB_HOST:?}" "${API_HOST:?}" "${S3_HOST:?}" "${MINIO_CONSOLE_HOST:?}"
: "${AUTH_HOST:?}" "${AUTH_VERIFY_HOST:?}" "${GH_OWNER:?}"

API="$COOLIFY_URL/api/v1"
AUTH=(-H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json")

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }

service_uuid_by_name() {
  local name="$1"
  curl -s "${AUTH[@]}" "$API/services" \
    | python3 -c "import json,sys; [print(s['uuid']) for s in json.load(sys.stdin) if s.get('name')==sys.argv[1]]" "$name" \
    | head -1
}
db_uuid_by_name() {
  local name="$1"
  curl -s "${AUTH[@]}" "$API/databases" \
    | python3 -c "import json,sys; [print(d['uuid']) for d in json.load(sys.stdin) if d.get('name')==sys.argv[1]]" "$name" \
    | head -1
}
deploy_uuid() {
  curl -s -X GET "${AUTH[@]}" "$API/deploy?uuid=$1&force=true" >/dev/null
}
patch_env() {
  local svc_uuid="$1" key="$2" value="$3"
  curl -s -X PATCH "${AUTH[@]}" "$API/services/$svc_uuid/envs" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'key':sys.argv[1],'value':sys.argv[2],'is_preview':False,'is_buildtime':False,'is_literal':False}))" "$key" "$value")" >/dev/null
}

# --- 1. Postgres ---
log "Step 1/6: Postgres (supabase/postgres image)"
PG_UUID="$(db_uuid_by_name supabase-postgres || true)"
if [ -z "$PG_UUID" ]; then
  PG_PASS="$(openssl rand -hex 24)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/databases/postgresql" -d @- <<JSON
{
  "project_uuid": "$PROJECT_UUID",
  "server_uuid": "$SERVER_UUID",
  "environment_name": "production",
  "name": "supabase-postgres",
  "image": "supabase/postgres:15.8.1.060",
  "postgres_user": "supabase_admin",
  "postgres_password": "$PG_PASS",
  "postgres_db": "postgres",
  "instant_deploy": true
}
JSON
)
  PG_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$PG_UUID" ] || { echo "Postgres create failed: $resp"; exit 1; }
  ok "Postgres deployed: $PG_UUID"
  echo "PG_PASS=$PG_PASS" >> "$ENV_FILE"
else
  ok "Postgres already exists: $PG_UUID"
fi

log "Waiting for Postgres ($PG_UUID) to accept connections"
until docker exec "$PG_UUID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
ok "Postgres ready"

log "Step 1.5: bootstrapping Postgres for Supabase (pgsodium + extensions)"
docker exec "$PG_UUID" bash -c "[ -x /etc/postgresql-custom/pgsodium_getkey.sh ]" || {
  KEY="$(openssl rand -hex 32)"
  docker exec "$PG_UUID" bash -c "mkdir -p /etc/postgresql-custom && printf '#!/bin/bash\necho %s\n' '$KEY' > /etc/postgresql-custom/pgsodium_getkey.sh && chmod 700 /etc/postgresql-custom/pgsodium_getkey.sh && chown postgres:postgres /etc/postgresql-custom/pgsodium_getkey.sh"
  docker exec "$PG_UUID" psql -U supabase_admin -d postgres -c "ALTER SYSTEM SET shared_preload_libraries = 'pgsodium,pg_stat_statements,pgaudit,pg_cron,pg_net'; ALTER SYSTEM SET pgsodium.getkey_script = '/etc/postgresql-custom/pgsodium_getkey.sh';" >/dev/null
  docker restart "$PG_UUID" >/dev/null
  until docker exec "$PG_UUID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
  ok "pgsodium configured"
}

# --- 2. MinIO ---
log "Step 2/6: MinIO"
MINIO_UUID="$(service_uuid_by_name minio || true)"
if [ -z "$MINIO_UUID" ]; then
  MINIO_USER="$(openssl rand -hex 8)"
  MINIO_PASS="$(openssl rand -hex 16)"
  MINIO_COMPOSE=$(cat <<YAML
services:
  minio:
    image: quay.io/minio/minio:latest
    command: 'server /data --console-address ":9001"'
    environment:
      - SERVICE_FQDN_MINIO_9000=https://$S3_HOST
      - SERVICE_FQDN_MINIO_9001=https://$MINIO_CONSOLE_HOST
      - MINIO_SERVER_URL=https://$S3_HOST
      - MINIO_BROWSER_REDIRECT_URL=https://$MINIO_CONSOLE_HOST
      - MINIO_ROOT_USER=$MINIO_USER
      - MINIO_ROOT_PASSWORD=$MINIO_PASS
    volumes:
      - minio-data:/data
    healthcheck:
      test: ['CMD-SHELL', 'mc ready local || curl -f http://127.0.0.1:9000/minio/health/live']
      interval: 10s
      timeout: 10s
      retries: 5
YAML
)
  MINIO_B64="$(printf %s "$MINIO_COMPOSE" | base64 -w0)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"minio","docker_compose_raw":"$MINIO_B64","instant_deploy":true }
JSON
)
  MINIO_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$MINIO_UUID" ] || { echo "MinIO create failed: $resp"; exit 1; }
  ok "MinIO deployed: $MINIO_UUID"
  echo "MINIO_USER=$MINIO_USER" >> "$ENV_FILE"
  echo "MINIO_PASS=$MINIO_PASS" >> "$ENV_FILE"
else
  ok "MinIO exists: $MINIO_UUID"
fi

# --- 3. Supabase ---
log "Step 3/6: Supabase"
SUPA_UUID="$(service_uuid_by_name supabase || true)"
if [ -z "$SUPA_UUID" ]; then
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "type":"supabase","name":"supabase","project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID",
  "environment_name":"production","instant_deploy":false }
JSON
)
  SUPA_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  [ -n "$SUPA_UUID" ] || { echo "Supabase create failed: $resp"; exit 1; }
  ok "Supabase service shell created: $SUPA_UUID"
fi

log "Wiring Supabase env vars"
patch_env "$SUPA_UUID" SERVICE_FQDN_SUPABASEKONG_8000  "https://$API_HOST"
patch_env "$SUPA_UUID" SERVICE_FQDN_SUPABASESTUDIO_3000 "https://$SB_HOST"
patch_env "$SUPA_UUID" POSTGRES_HOSTNAME               "$PG_UUID"
patch_env "$SUPA_UUID" POSTGRES_HOST                   "$PG_UUID"
patch_env "$SUPA_UUID" POSTGRES_PORT                   "5432"
patch_env "$SUPA_UUID" STORAGE_S3_ENDPOINT             "http://minio-$MINIO_UUID:9000"
ok "Supabase env vars set"

# --- 4. Validator ---
log "Step 4/6: Validator (auth-gateway)"
VAL_UUID="$(service_uuid_by_name auth-validator || true)"
if [ -z "$VAL_UUID" ]; then
  COMPOSE_B64="$(python3 -c "import base64,sys,os; t=open(sys.argv[1]).read().replace('\${GH_OWNER}', os.environ['GH_OWNER']); print(base64.b64encode(t.encode()).decode())" validator.compose.yml)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"auth-validator","docker_compose_raw":"$COMPOSE_B64","instant_deploy":false }
JSON
)
  VAL_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  ok "Validator created: $VAL_UUID"
fi

# --- 5. Login ---
log "Step 5/6: Login app"
LOGIN_UUID="$(service_uuid_by_name auth-login || true)"
if [ -z "$LOGIN_UUID" ]; then
  COMPOSE_B64="$(python3 -c "import base64,sys,os; t=open(sys.argv[1]).read().replace('\${GH_OWNER}', os.environ['GH_OWNER']); print(base64.b64encode(t.encode()).decode())" login.compose.yml)"
  resp=$(curl -s -X POST "${AUTH[@]}" "$API/services" -d @- <<JSON
{ "project_uuid":"$PROJECT_UUID","server_uuid":"$SERVER_UUID","environment_name":"production",
  "name":"auth-login","docker_compose_raw":"$COMPOSE_B64","instant_deploy":false }
JSON
)
  LOGIN_UUID="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uuid',''))")"
  ok "Login created: $LOGIN_UUID"
fi

# --- 6. Wire forward-auth onto supabase-studio ---
log "Step 6/6: Wiring forward-auth onto Supabase Studio"
warn "Edits /data/coolify/services/$SUPA_UUID/docker-compose.yml directly."
python3 ./wire-forward-auth.py "$SUPA_UUID" "$VAL_UUID" "$AUTH_HOST"
deploy_uuid "$SUPA_UUID"
ok "Forward-auth wired."

log "Done. Verify: curl -skI https://$SB_HOST/  ->  expect 302 to https://$AUTH_HOST/"
