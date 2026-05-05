# Auth Gateway

Custom login page (built on Supabase Auth) and forward-auth validator that protects
self-hosted apps behind a single sign-on flow. Replaces Authentik in the Soltrix stack.

## Quickstart

1. `cp .env.example .env` and fill in the values.
2. See `docs/RECREATE.md` for the full bootstrap on a fresh Coolify VPS.
3. Local development:
   - Login: `cd login && bun install && bun run dev` → http://localhost:5173
   - Validator: `cd validator && bun install && bun test`

## Architecture

See `docs/README.md` for the full self-hosted Soltrix stack overview. This repo
contributes the `login/` and `validator/` apps + the Coolify bootstrap (`coolify/setup.sh`).

## License

MIT — see `LICENSE`.
