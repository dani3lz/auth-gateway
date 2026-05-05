# Docker artifacts

Files captured from the live deployment as snapshots — useful for replay or restore.

| File | Purpose |
|------|---------|
| `supabase-stack.docker-compose.yml` | Full Supabase service compose (with bundled `supabase-db` already removed and traefik labels added to `supabase-minio`). This is the live, edited version that runs on the VPS. |
| `postgres-init/*.sql` | The 7 init scripts Coolify generates when the Supabase template is parsed. Required to bootstrap an external Postgres so Auth/Storage/Realtime/Analytics/Pooler/Webhooks can connect. |
| `pgsodium_getkey.sh` | The pgsodium server key script. **Replace the key with a fresh `openssl rand -hex 32` if redeploying** — reusing this key on a new deployment doesn't make sense and copying it gives no benefit. |

## Re-running init scripts on a fresh Postgres

Order matters:

1. `_supabase.sql` — creates the `_supabase` database
2. `realtime.sql` — `_realtime` schema in main `postgres` db
3. `pooler.sql` — `_supavisor` schema in `_supabase` db
4. `logs.sql` — `_analytics` schema in `_supabase` db
5. `webhooks.sql` — `pg_net` extension + `supabase_functions` schema (requires `pg_net` in `shared_preload_libraries`)
6. `jwt.sql` — sets `app.settings.jwt_secret` GUC on the database (needs `JWT_SECRET` and `JWT_EXP` env)
7. `roles.sql` — aligns role passwords (needs `POSTGRES_PASSWORD` env)

Each uses psql `\set` to read shell env vars, so pass them via `docker exec -e`:

```bash
docker exec -e JWT_SECRET=... -e JWT_EXP=3600 -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD=... -e POSTGRES_USER=supabase_admin \
  $PG_CONTAINER psql -U supabase_admin -d postgres -f /tmp/sb_init/<file>.sql
```

## pgsodium key rotation

If you ever rotate the pgsodium key, all existing `vault.secrets` rows become unreadable. To rotate safely:

1. Read all secrets out of Vault first (Studio UI or `select * from vault.decrypted_secrets`).
2. Stop Postgres.
3. Replace the key in `/etc/postgresql-custom/pgsodium_getkey.sh`.
4. Truncate `vault.secrets` (the encrypted ciphertext is now garbage).
5. Start Postgres.
6. Re-insert secrets via `vault.create_secret(...)`.

There's no in-place re-encryption tooling in pgsodium for this case.
