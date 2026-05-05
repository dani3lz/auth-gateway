#!/usr/bin/env bash
# Removes the resources created by setup.sh from Coolify. Volumes are NOT
# deleted automatically — Coolify keeps them; remove with `docker volume rm`
# if you want a truly fresh slate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"
API="$COOLIFY_URL/api/v1"
AUTH=(-H "Authorization: Bearer $COOLIFY_TOKEN")

del_service() {
  local uuid
  uuid="$(curl -s "${AUTH[@]}" "$API/services" \
    | python3 -c "import json,sys; [print(s['uuid']) for s in json.load(sys.stdin) if s.get('name')==sys.argv[1]]" "$1" \
    | head -1)"
  [ -n "$uuid" ] && curl -s -X DELETE "${AUTH[@]}" "$API/services/$uuid" >/dev/null && \
    echo "deleted service $1 ($uuid)"
}
del_database() {
  local uuid
  uuid="$(curl -s "${AUTH[@]}" "$API/databases" \
    | python3 -c "import json,sys; [print(d['uuid']) for d in json.load(sys.stdin) if d.get('name')==sys.argv[1]]" "$1" \
    | head -1)"
  [ -n "$uuid" ] && curl -s -X DELETE "${AUTH[@]}" "$API/databases/$uuid" >/dev/null && \
    echo "deleted database $1 ($uuid)"
}

del_service auth-login
del_service auth-validator
del_service supabase
del_service minio
del_database supabase-postgres
echo "Done."
