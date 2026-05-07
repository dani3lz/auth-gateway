#!/usr/bin/env bash
# Removes the standalone stack and its named volumes (DESTRUCTIVE — wipes
# all data: Postgres, MinIO, Caddy certs, Studio snippets). To keep
# volumes, run `docker compose down` (without -v) manually.
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
