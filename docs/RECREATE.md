# Recreate the entire stack on a fresh Coolify VPS

This guide assumes:
- A fresh server with Coolify already installed (one-line installer from coolify.io)
- A wildcard DNS record `*.<your-domain>` pointing at the VPS public IP
- A Coolify root API token

## 1. Build & publish the auth-gateway images

You need two images on a registry the VPS can pull from. Easiest is GitHub Container Registry (`ghcr.io`).

```bash
git clone git@github.com:dani3lz/auth-gateway.git
cd auth-gateway

# Build + push validator
docker build -t ghcr.io/dani3lz/auth-gateway-validator:latest validator/
docker push ghcr.io/dani3lz/auth-gateway-validator:latest

# Build + push login (build args bake the public Supabase URL/anon key into the bundle)
docker build \
  --build-arg VITE_SUPABASE_URL=https://api.sb.soltrix.dev \
  --build-arg VITE_SUPABASE_ANON_KEY=<paste anon JWT> \
  --build-arg VITE_COOKIE_DOMAIN=.soltrix.dev \
  --build-arg VITE_DEFAULT_REDIRECT=https://sb.soltrix.dev \
  -t ghcr.io/dani3lz/auth-gateway-login:latest login/
docker push ghcr.io/dani3lz/auth-gateway-login:latest
```

(GHCR image must be public OR Coolify must have docker-credential helpers configured for ghcr.io.)

## 2. Run setup.sh

On the VPS, in the cloned repo:

```bash
cd coolify
cp env/stack.env.example env/stack.env
$EDITOR env/stack.env   # paste COOLIFY_TOKEN, PROJECT_UUID, SERVER_UUID
./setup.sh
```

The script is idempotent — re-running it skips already-existing resources.

## 3. Verify

```bash
curl -skI https://sb.soltrix.dev/        # → 302 to auth.sb.soltrix.dev
curl -skI https://auth.sb.soltrix.dev/   # → 200, login page HTML
curl -skI https://auth-verify.sb.soltrix.dev/healthz  # → 200, "ok"
```

## 4. First user

The login page uses Supabase Auth, so create a user in **Supabase Studio → Authentication → Users → Add user** (or sign up via the form if `ENABLE_EMAIL_SIGNUP=true`).

## 5. Restoring access if locked out

If you ever break the gateway, you can temporarily strip the `auth-gateway` middleware from supabase-studio:

```bash
# Edit /data/coolify/services/<supa_uuid>/docker-compose.yml and remove
# the lines containing 'auth-gateway' from the supabase-studio labels block.
# Then redeploy supabase via Coolify.
```
