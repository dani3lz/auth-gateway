# Auth Gateway

A self-hosted authentication gateway for protecting any web app behind a
Supabase-style login. Replaces heavier IdPs (Authelia / Authentik / Keycloak)
with a small custom login page + a tiny forward-auth verifier, both built on
top of Supabase Auth.

## What you get

- **`sb.example.com`** — Supabase Studio (or any other app) sitting behind a
  forward-auth check.
- **`auth.example.com`** — Login page using Supabase's actual
  `@supabase/auth-ui-react` component (pixel-identical to the
  supabase.com dashboard login). Email + password, password reset.
- **`auth-verify.example.com`** — Small Hono service that traefik calls on
  every request to a protected app. Reads the JWT cookie, verifies the
  signature against the shared Supabase `JWT_SECRET`, returns 200 or 302.
- **Full Supabase stack** — standalone Postgres (Supabase-flavored), MinIO
  for Storage, Kong for API, Studio, GoTrue, PostgREST, Realtime, Edge
  Functions, etc. Deployed via Coolify.

The gateway uses Supabase Auth itself as the user store — no second user
database to manage. Anyone you create in Studio's "Authentication → Users"
can sign in to any app behind the gateway.

## Repo layout

```
auth-gateway/
├── README.md
├── .env.example                  # all variables both installers need
├── setup-coolify.sh              # installer for Coolify hosts
├── setup-standalone.sh           # installer for plain Docker hosts
├── teardown-coolify.sh
├── teardown-standalone.sh
├── login/                        # Vite + React login page (built into a Caddy image)
├── validator/                    # Hono on Bun forward-auth verifier
├── compose/
│   ├── coolify/                  # fragments setup-coolify.sh uploads via the API
│   │   ├── auth-login.compose.yml
│   │   ├── auth-validator.compose.yml
│   │   ├── minio.compose.yml
│   │   └── postgres.compose.yml
│   └── standalone/               # one merged stack setup-standalone.sh brings up
│       ├── docker-compose.yml
│       ├── Caddyfile
│       └── volumes/              # vendored config (kong.yml, vector.yml, …)
└── scripts/
    ├── pgsodium_getkey.template.sh
    └── postgres-init/            # Supabase bootstrap SQL (shared by both installers)
        ├── _supabase.sql
        ├── jwt.sql
        ├── logs.sql
        ├── pooler.sql
        ├── protect-users.sql
        ├── realtime.sql
        ├── roles.sql
        └── webhooks.sql
```

## Pick your installer

Two installers in this repo, both produce the same running stack:

- **`./setup-coolify.sh`** — for hosts that already have **Coolify v4**.
  Drives Coolify's API to create the Postgres DB, MinIO, Supabase, and the
  validator + login services, then patches Coolify's compose to add the
  traefik forward-auth label and Google OAuth env. Reuses Coolify's
  bundled traefik (`coolify-proxy`) for TLS.
- **`./setup-standalone.sh`** — for plain **Docker hosts** (Docker +
  Compose v2 only). Brings up the full stack via one
  `compose/standalone/docker-compose.yml`, with **Caddy** as the reverse
  proxy (auto-HTTPS via Let's Encrypt, built-in `forward_auth`).

Pick by what's already on your VPS.

### Common prerequisites

- A domain you control with a wildcard A record (`*.example.com`) pointing
  at the VPS public IP. The installer's reverse proxy (Coolify's traefik
  or the standalone Caddy) negotiates Let's Encrypt certs on first request.
- An SMTP mailbox for confirmation/recovery emails (port 587 / STARTTLS;
  most clouds block 25/465). Many providers require the From address to
  match the SMTP auth user — keep `SMTP_USER` and `SMTP_ADMIN_EMAIL` the
  same.
- `bash`, `curl`, `docker`, `openssl`, `python3` on the host.

### Coolify-specific prerequisites

- Coolify v4 already installed
  (`curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`).
- The Coolify root API token (Coolify → Keys & Tokens → Create New Token).
- The target Coolify project + server UUIDs. Find them with:
  ```
  curl -H "Authorization: Bearer $TOKEN" $COOLIFY_URL/api/v1/projects
  curl -H "Authorization: Bearer $TOKEN" $COOLIFY_URL/api/v1/servers
  ```

### Standalone-specific prerequisites

- Docker Compose v2.
- Ports 80 and 443 free on the host (Caddy binds them).
- `LETSENCRYPT_EMAIL` set in `.env`.

## Deploy

```bash
git clone https://github.com/<you>/auth-gateway.git
cd auth-gateway
cp .env.example .env
$EDITOR .env       # fill in PARENT_DOMAIN, *_HOST values, SMTP creds, OAuth creds
                   # (Coolify only: COOLIFY_TOKEN, PROJECT_UUID, SERVER_UUID)
                   # (standalone only: LETSENCRYPT_EMAIL)

# On a Coolify host:
./setup-coolify.sh

# On a plain Docker host:
./setup-standalone.sh
```

Both installers are idempotent — re-running picks up code changes and
skips already-existing resources. Generated secrets (Postgres password,
JWT secret, anon/service-role keys, MinIO creds, etc.) are written back
to `.env` so subsequent runs reuse them.

## Teardown

```bash
./teardown-coolify.sh                  # removes Coolify resources, keeps volumes
./teardown-standalone.sh --yes         # docker compose down -v (DESTRUCTIVE)
```

## Verify

```bash
curl -skI https://auth-verify.example.com/healthz
# → HTTP/2 200, "ok"

curl -skI https://sb.example.com/
# → HTTP/2 302
# Location: https://auth.example.com/?rd=https%3A%2F%2Fsb.example.com%2F

curl -sk "https://auth.example.com/?rd=https%3A%2F%2Fsb.example.com%2F" | grep -q 'Sign in'
# → exit 0
```

Then in a browser:

1. Open `https://sb.example.com/` (incognito).
2. You're redirected to the login page.
3. The first time, you have no account. Add one in **Supabase Studio →
   Authentication → Users → Add user** (Studio is reachable directly via
   `https://sb.example.com/` once you sign in — chicken-and-egg, see
   "Bootstrap user" below).
4. Sign in. The cookie `sb-access-token` is set with `Domain=.example.com`
   so the validator can read it on any subdomain.
5. You're redirected back to Studio.

### Bootstrap user

To create the very first user (before any sign-in is possible), use the
service-role key against Supabase Auth's admin API:

```bash
SVC_KEY="$(grep ^SUPABASE_SERVICE_ROLE_KEY .env | cut -d= -f2)"
curl -sk -X POST "https://api.example.com/auth/v1/admin/users" \
  -H "apikey: $SVC_KEY" \
  -H "Authorization: Bearer $SVC_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com","password":"changeme","email_confirm":true}'
```

Now sign in to Studio and create more users from the UI.

## Protect another app

For any other Coolify service, add these labels to its compose
(`traefik.docker.network` should be set if your service uses multiple networks):

```yaml
labels:
  - 'traefik.http.middlewares.auth-gateway.forwardauth.address=http://validator-<VALIDATOR_UUID>:8080/verify'
  - 'traefik.http.middlewares.auth-gateway.forwardauth.trustForwardHeader=true'
  - 'traefik.http.middlewares.auth-gateway.forwardauth.authResponseHeaders=X-User-Id,X-User-Email,X-User-Role'
  - 'traefik.http.routers.https-0-<SVC_UUID>-<SVC_NAME>.middlewares=gzip,auth-gateway'
```

Then attach the validator's network and reload traefik:

```bash
docker network connect <VALIDATOR_UUID> coolify-proxy
docker network connect <SVC_UUID> coolify-proxy
docker restart coolify-proxy
```

Your app's request handler can read the authenticated user from
`X-User-Email` (or `X-User-Id`).

## How the auth flow works

```
1. Browser GET https://sb.example.com/
2. traefik calls validator → no cookie → 302
   Location: https://auth.example.com/?rd=https://sb.example.com/

3. Browser GET https://auth.example.com/?rd=...
4. Login page reads ?rd=, presents <Auth /> form

5. User submits → supabase-js POSTs https://api.example.com/auth/v1/token
6. Supabase Auth issues JWT
7. Custom CookieStorage writes the JWT into a cookie:
     Domain=.example.com, Path=/, SameSite=Lax, Secure
8. onAuthStateChange("SIGNED_IN") → window.location.replace(rd)

9. Browser GET https://sb.example.com/ (with cookie)
10. traefik calls validator → cookie present → JWT verifies → 200
    + sets X-User-Id / X-User-Email / X-User-Role
11. Studio loads, your app sees the user via headers.
```

## Logout

`https://auth.example.com/logout` clears the cookie and redirects to
`https://sb.example.com/` (which re-triggers the auth flow).

Or, programmatically: any app on a `*.example.com` subdomain can
`document.cookie = "sb-access-token=; Max-Age=0; Domain=.example.com; Path=/"`
to log the user out from everywhere.

## Updating

```bash
git pull
./setup-coolify.sh        # or ./setup-standalone.sh
```

Both installers are idempotent and pick up code changes. Validator and
login images are rebuilt the next run if you've removed them with
`docker rmi`. To force a rebuild without touching anything else:

```bash
docker rmi auth-gateway-validator:local auth-gateway-login:local
./setup-coolify.sh        # or ./setup-standalone.sh
```

## Caveats

- **Cookie scope.** The JWT is in a JS-readable cookie (`HttpOnly` is not
  possible because supabase-js needs to read it client-side). The
  signature-based validator means leakage is needed *and* exploitable, but
  any subdomain you control with the same `*.example.com` parent can read it
  — only run apps you trust under that parent.
- **Coolify proxy network attachments.** Whenever a service container is
  recreated, you may need to reattach `coolify-proxy` to the service's
  docker network (`docker network connect <uuid> coolify-proxy && docker
  restart coolify-proxy`). Setup.sh handles this for first deploys.
- **Hetzner / DigitalOcean / many cloud providers block outbound TCP 25 and
  often 465.** Use SMTP port 587 (STARTTLS).
- **`SMTP_USER` must equal `SMTP_ADMIN_EMAIL`.** Many providers (Hostinger,
  Gmail SMTP, etc.) silently hold the connection open if the From address
  doesn't match the auth user. Symptom is a 504 timeout from `/auth/v1/signup`.
- **Multi-port custom-compose services.** Coolify's auto-generated traefik
  labels skip `loadbalancer.server.port` for some custom-compose deploys.
  If a service returns 503 with the message "no available server", the fix
  is usually to add `traefik.http.services.<router>.loadbalancer.server.port=<port>`
  to the labels manually. The script does this for the validator and login.
- **Studio's Authentication → Sign In / Providers, OAuth Apps, and API Keys
  tabs spin forever on self-host.** Studio's frontend renders them but the
  `/api/platform/projects/[ref]/config/auth` (and sibling) Next.js routes
  ship Cloud-only — they 404 in self-host. Configure providers via the
  `GOTRUE_EXTERNAL_*` env vars in `.env` (the script wires Google by
  default); the **Authentication → Users** tab still works because it
  talks to gotrue's admin API through Kong, not through `/api/platform`.

## License

MIT — see `LICENSE`.
