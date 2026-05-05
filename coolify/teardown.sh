#!/usr/bin/env bash
# Removes the Coolify resources created by setup.sh. Use with caution.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="${ENV_FILE:-./env/stack.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"
API="$COOLIFY_URL/api/v1"
AUTH=(-H "Authorization: Bearer $COOLIFY_TOKEN")

del_service() {
  local name="$1" uuid
  uuid="$(curl -s "${AUTH[@]}" "$API/services" \
    | python3 -c "import json,sys; [print(s['uuid']) for s in json.load(sys.stdin) if s.get('name')==sys.argv[1]]" "$name" \
    | head -1)"
  [ -n "$uuid" ] && curl -s -X DELETE "${AUTH[@]}" "$API/services/$uuid" >/dev/null && \
    echo "deleted service $name ($uuid)"
}
del_database() {
  local name="$1" uuid
  uuid="$(curl -s "${AUTH[@]}" "$API/databases" \
    | python3 -c "import json,sys; [print(d['uuid']) for d in json.load(sys.stdin) if d.get('name')==sys.argv[1]]" "$name" \
    | head -1)"
  [ -n "$uuid" ] && curl -s -X DELETE "${AUTH[@]}" "$API/databases/$uuid" >/dev/null && \
    echo "deleted database $name ($uuid)"
}

del_service auth-login
del_service auth-validator
del_service supabase
del_service minio
del_database supabase-postgres
echo "Done."
