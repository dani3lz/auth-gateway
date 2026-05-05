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
├── .env.example                  # all variables setup.sh needs
├── login/                        # Vite + React login page (built into a Caddy image)
│   ├── Dockerfile
│   ├── Caddyfile
│   ├── package.json
│   └── src/
├── validator/                    # Hono on Bun forward-auth verifier
│   ├── Dockerfile
│   ├── package.json
│   ├── src/
│   └── tests/
├── compose/                      # docker-compose templates used by setup.sh
│   ├── postgres.compose.yml
│   ├── minio.compose.yml
│   ├── auth-validator.compose.yml
│   └── auth-login.compose.yml
└── scripts/
    ├── setup.sh                  # one-shot deploy to Coolify
    ├── teardown.sh               # destroy
    ├── pgsodium_getkey.template.sh
    └── postgres-init/            # Supabase bootstrap SQL
        ├── _supabase.sql
        ├── jwt.sql
        ├── logs.sql
        ├── pooler.sql
        ├── realtime.sql
        ├── roles.sql
        └── webhooks.sql
```

## Prerequisites

- A VPS with **Coolify v4** already installed
  (`curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`).
- A domain you control with a wildcard A record (`*.example.com`) pointing at
  the VPS public IP. Coolify's bundled traefik will issue Let's Encrypt certs
  automatically.
- An SMTP mailbox for confirmation/recovery emails. Provider note: many
  providers require the From address to match the SMTP auth user — set
  `SMTP_USER` and `SMTP_ADMIN_EMAIL` to the same mailbox.
- The Coolify root API token (Coolify → Keys & Tokens → Create New Token).
- The target Coolify project UUID and server UUID. Find them with:
  ```
  curl -H "Authorization: Bearer $TOKEN" $COOLIFY_URL/api/v1/projects
  curl -H "Authorization: Bearer $TOKEN" $COOLIFY_URL/api/v1/servers
  ```
- `bash`, `curl`, `python3`, `docker`, `openssl` on the host. (All present
  by default on a Coolify host.)

## Deploy

```bash
# On the Coolify host
git clone https://github.com/<you>/auth-gateway.git
cd auth-gateway

cp .env.example .env
$EDITOR .env                 # fill in COOLIFY_TOKEN, PROJECT_UUID, SERVER_UUID,
                             # PARENT_DOMAIN, the *_HOST values, and SMTP creds

./scripts/setup.sh
```

`setup.sh` is idempotent — re-running it skips already-existing resources.
It will:

1. Create a `supabase-postgres` database resource (Coolify-managed, with
   backups). Generates a fresh password.
2. Configure pgsodium for Supabase Vault and run the seven init SQL files
   that bootstrap Supabase's roles and schemas.
3. Create a `minio` service with public S3 + console domains. Generates a
   fresh root user/password.
4. Create the Supabase one-click service and re-wire its env vars to point
   at the standalone Postgres + MinIO. Strip the bundled `supabase-db`,
   `supabase-minio`, and `minio-createbucket` from the generated compose.
5. Build `auth-gateway-validator:local` from `validator/`, deploy as a
   Coolify service.
6. Build `auth-gateway-login:local` from `login/` (with the Supabase URL
   and anon key baked in as build args), deploy as a Coolify service.
7. Add a traefik forward-auth middleware label to `supabase-studio` so
   every request to `sb.example.com` is authenticated by the validator.
8. Reload traefik.

All the values it generates (passwords, UUIDs, JWT secret, anon/service-role
keys) are written back to `.env` so subsequent runs reuse them.

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
./scripts/setup.sh    # idempotent — picks up code changes, rebuilds images
```

The setup script rebuilds the validator and login images every run if you've
removed them with `docker rmi`. To force a rebuild without touching anything
else:

```bash
docker rmi auth-gateway-validator:local auth-gateway-login:local
./scripts/setup.sh
```

## Teardown

```bash
./scripts/teardown.sh    # removes Coolify services + the database
docker volume ls | grep -E 'minio|postgres'   # remove if you want a clean slate
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

## License

MIT — see `LICENSE`.
