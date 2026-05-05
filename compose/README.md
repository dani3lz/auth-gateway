# compose/

Each file here is a docker-compose YAML used by `scripts/setup.sh` as the
`docker_compose_raw` payload to Coolify's API. Variable interpolation
(e.g. `${SB_HOST}`) is done by the script before the compose is sent —
Coolify itself doesn't substitute these.

| File | What it deploys |
|------|-----------------|
| `postgres.compose.yml` | Reference only — Postgres is created via Coolify's `databases/postgresql` API, not this compose. Useful if you want to run it standalone. |
| `minio.compose.yml` | MinIO with public S3 + console domains. |
| `auth-validator.compose.yml` | Forward-auth validator (Hono + Bun). |
| `auth-login.compose.yml` | Login page (Vite + React static, Caddy-served). |

The Supabase service itself doesn't get a compose file in this repo — it's
deployed via Coolify's built-in `type: supabase` one-click template. Setup.sh
calls that endpoint and then wires its env vars to point at the standalone
Postgres and MinIO created above.
