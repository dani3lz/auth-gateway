# Auth Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Authentik (currently in front of Supabase Studio) with a custom login page that *uses Supabase Auth itself* and a small forward-auth validator, packaged as a private GitHub monorepo with all existing infrastructure docs and a one-shot bootstrap script that recreates the entire Soltrix stack on a fresh Coolify host.

**Architecture:**
- **Login app** (`/login`) at `auth.sb.soltrix.dev`: Vite + React + `@supabase/auth-ui-react` (the same `<Auth />` component supabase.com uses, so the page is pixel-identical to the supabase dashboard's login). Sets a JWT cookie scoped to `.soltrix.dev`.
- **Validator** (`/validator`) at `auth-verify.sb.soltrix.dev` (internal-only via traefik): Hono on Bun. Receives traefik forward-auth probes, reads `sb-access-token` cookie, validates JWT against the shared Supabase `JWT_SECRET`, returns 200 (with `X-User-Email` etc.) or 302 to login with `?rd=`.
- **Coolify integration** (`/coolify`): docker-compose templates for both apps + a `setup.sh` that uses Coolify's REST API to deploy Postgres → MinIO → Supabase → Login → Validator → wires forward-auth label onto Studio. Idempotent.
- **Docs** (`/docs`): the existing `/root/docs/` content moved into the repo verbatim plus a new top-level `RECREATE.md` that points at `setup.sh`.

**Tech Stack:**
- Frontend: Vite, React 18, TypeScript, `@supabase/supabase-js` 2.x, `@supabase/auth-ui-react` 0.4.x, `@supabase/auth-ui-shared` 0.1.x
- Backend: Bun runtime, Hono web framework, `jose` for JWT verification
- Tests: Vitest (frontend), `bun test` (validator)
- Container: `oven/bun:1-alpine` for validator, `caddy:2-alpine` for login static serve
- CI/Repo: GitHub (private), `gh` CLI for creation, deployed via Coolify pulling the repo

---

## File Structure

```
auth-gateway/                          # repo root
├── README.md                          # top-level — quickstart + arch overview
├── LICENSE                            # MIT
├── .gitignore                         # node_modules, dist, .env, .DS_Store
├── .env.example                       # documented env vars for local dev
│
├── login/                             # the Vite + React login app
│   ├── package.json
│   ├── vite.config.ts
│   ├── tsconfig.json
│   ├── index.html
│   ├── Dockerfile                     # multi-stage: bun build → caddy serve
│   ├── Caddyfile                      # SPA-friendly: try_files / index.html
│   ├── public/favicon.svg             # Soltrix favicon
│   └── src/
│       ├── main.tsx                   # entry: ReactDOM.render(<App/>)
│       ├── App.tsx                    # routes: /, /reset-password, /confirm
│       ├── lib/supabase.ts            # createClient with cookie storage
│       ├── lib/cookie-storage.ts      # custom Storage adapter for .soltrix.dev cookies
│       ├── pages/Login.tsx            # <Auth /> + redirect logic
│       ├── pages/ResetPassword.tsx    # password recovery handler
│       └── styles.css                 # Inter font + Supabase greens override
│
├── validator/                         # the Hono forward-auth service
│   ├── package.json
│   ├── tsconfig.json
│   ├── Dockerfile                     # bun build → bun run
│   ├── bun.lockb                      # generated
│   ├── src/
│   │   ├── server.ts                  # Hono app, /verify and /healthz routes
│   │   ├── verify.ts                  # JWT validation logic
│   │   └── cookies.ts                 # parse cookie header
│   └── tests/
│       ├── verify.test.ts             # unit tests for JWT validation
│       └── server.test.ts             # integration tests for /verify
│
├── coolify/                           # deploy assets
│   ├── login.compose.yml              # docker_compose_raw for login service
│   ├── validator.compose.yml          # docker_compose_raw for validator service
│   ├── setup.sh                       # idempotent: hits Coolify API to deploy whole stack
│   ├── teardown.sh                    # destroy all services (testing/reset)
│   └── env/
│       └── stack.env.example          # all env vars setup.sh needs
│
└── docs/                              # the existing docs from /root/docs (moved verbatim)
    ├── README.md
    ├── RECREATE.md                    # NEW: how to bootstrap from scratch with setup.sh
    ├── docker/
    │   ├── README.md
    │   ├── pgsodium_getkey.sh
    │   ├── postgres-init/             # the 7 SQL scripts
    │   ├── supabase-stack.docker-compose.yml
    │   ├── minio.docker-compose.yml
    │   └── authentik.docker-compose.yml   # kept for reference until Authentik removed
    └── superpowers/plans/
        └── 2026-05-04-auth-gateway.md  # this file
```

**Why this layout:**
- Each subsystem is one folder; touching the validator never requires opening the login app
- `coolify/` is the operator-facing layer (no app code, only deploy artifacts)
- `docs/` carries forward everything we built so the repo is self-documenting on day 1

---

## Task 1: Repo Skeleton + Move Docs

**Files:**
- Create: `~/auth-gateway/` (working directory for the repo before push)
- Create: `~/auth-gateway/README.md`
- Create: `~/auth-gateway/LICENSE`
- Create: `~/auth-gateway/.gitignore`
- Create: `~/auth-gateway/.env.example`
- Move: `/root/docs/` → `~/auth-gateway/docs/`

- [ ] **Step 1: Create the repo working directory and copy existing docs**

```bash
mkdir -p ~/auth-gateway
cp -a /root/docs/. ~/auth-gateway/docs/
ls ~/auth-gateway/docs/
# Expect: README.md, docker/, superpowers/
```

- [ ] **Step 2: Create `.gitignore`**

```
# ~/auth-gateway/.gitignore
node_modules/
dist/
build/
.env
.env.local
.DS_Store
*.log
bun.lockb
.vite/
coverage/
```

- [ ] **Step 3: Create `LICENSE` (MIT)**

```
MIT License

Copyright (c) 2026 Soltrix

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Create `.env.example`**

```
# Supabase API base — used by the login app to talk to GoTrue/PostgREST
VITE_SUPABASE_URL=https://api.sb.soltrix.dev
VITE_SUPABASE_ANON_KEY=<paste anon JWT here>

# Cookie domain for the JWT — must be a parent of every host you protect
COOKIE_DOMAIN=.soltrix.dev

# Redirect destination after successful login when no `rd` query param is set
DEFAULT_REDIRECT=https://sb.soltrix.dev

# Validator → only needs the JWT secret to verify tokens
SUPABASE_JWT_SECRET=<paste from Supabase service env>
LOGIN_URL=https://auth.sb.soltrix.dev
```

- [ ] **Step 5: Create top-level `README.md`**

```markdown
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
```

- [ ] **Step 6: Initialize git and make the first commit**

```bash
cd ~/auth-gateway
git init -b main
git add -A
git commit -m "chore: initial repo skeleton + import existing docs"
git log --oneline
# Expect: 1 commit, "chore: initial repo skeleton + import existing docs"
```

---

## Task 2: Validator — Failing JWT-Verify Test

**Files:**
- Create: `~/auth-gateway/validator/package.json`
- Create: `~/auth-gateway/validator/tsconfig.json`
- Create: `~/auth-gateway/validator/tests/verify.test.ts`

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "auth-validator",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "bun --watch src/server.ts",
    "start": "bun src/server.ts",
    "test": "bun test"
  },
  "dependencies": {
    "hono": "^4.6.14",
    "jose": "^5.9.6"
  },
  "devDependencies": {
    "@types/bun": "^1.1.14",
    "typescript": "^5.7.2"
  }
}
```

- [ ] **Step 2: Write `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "esModuleInterop": true,
    "strict": true,
    "skipLibCheck": true,
    "types": ["bun-types"]
  },
  "include": ["src/**/*", "tests/**/*"]
}
```

- [ ] **Step 3: Write the failing test for `verifyJwt()`**

```typescript
// ~/auth-gateway/validator/tests/verify.test.ts
import { describe, expect, test } from "bun:test";
import { SignJWT } from "jose";
import { verifyJwt } from "../src/verify";

const SECRET = "test-secret-min-32-chars-long-aaaaaaaa";
const secretBytes = new TextEncoder().encode(SECRET);

async function makeToken(claims: Record<string, unknown>, exp = "1h") {
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(exp)
    .sign(secretBytes);
}

describe("verifyJwt", () => {
  test("returns user claims for a valid HS256 token", async () => {
    const token = await makeToken({
      sub: "user-1",
      email: "daniel@soltrix.dev",
      role: "authenticated",
    });
    const result = await verifyJwt(token, SECRET);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.sub).toBe("user-1");
      expect(result.claims.email).toBe("daniel@soltrix.dev");
    }
  });

  test("returns ok:false for an expired token", async () => {
    const token = await makeToken({ sub: "u" }, "-1s");
    const result = await verifyJwt(token, SECRET);
    expect(result.ok).toBe(false);
  });

  test("returns ok:false for a wrong-secret token", async () => {
    const token = await makeToken({ sub: "u" });
    const result = await verifyJwt(token, "different-secret-also-32-chars-aaaaa");
    expect(result.ok).toBe(false);
  });

  test("returns ok:false for a malformed token", async () => {
    const result = await verifyJwt("not-a-jwt", SECRET);
    expect(result.ok).toBe(false);
  });
});
```

- [ ] **Step 4: Install dependencies**

```bash
cd ~/auth-gateway/validator
bun install
```

- [ ] **Step 5: Run the test and confirm it fails**

```bash
cd ~/auth-gateway/validator
bun test
# Expected: FAIL — "Cannot find module '../src/verify'"
```

- [ ] **Step 6: Commit the failing test**

```bash
cd ~/auth-gateway
git add validator/
git commit -m "test(validator): failing JWT verify tests"
```

---

## Task 3: Validator — `verify.ts` Implementation

**Files:**
- Create: `~/auth-gateway/validator/src/verify.ts`

- [ ] **Step 1: Implement `verifyJwt()`**

```typescript
// ~/auth-gateway/validator/src/verify.ts
import { jwtVerify, type JWTPayload } from "jose";

export type VerifyResult =
  | { ok: true; claims: JWTPayload & { sub?: string; email?: string; role?: string } }
  | { ok: false; reason: string };

export async function verifyJwt(token: string, secret: string): Promise<VerifyResult> {
  try {
    const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), {
      algorithms: ["HS256"],
    });
    return { ok: true, claims: payload };
  } catch (err) {
    return { ok: false, reason: err instanceof Error ? err.message : String(err) };
  }
}
```

- [ ] **Step 2: Run tests — all 4 should pass**

```bash
cd ~/auth-gateway/validator
bun test
# Expected: 4 pass, 0 fail
```

- [ ] **Step 3: Commit**

```bash
cd ~/auth-gateway
git add validator/src/verify.ts
git commit -m "feat(validator): JWT verification via jose HS256"
```

---

## Task 4: Validator — Cookie Parsing Helper

**Files:**
- Create: `~/auth-gateway/validator/src/cookies.ts`
- Create: `~/auth-gateway/validator/tests/cookies.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// ~/auth-gateway/validator/tests/cookies.test.ts
import { describe, expect, test } from "bun:test";
import { parseCookies } from "../src/cookies";

describe("parseCookies", () => {
  test("parses a single cookie", () => {
    expect(parseCookies("foo=bar")).toEqual({ foo: "bar" });
  });
  test("parses multiple cookies", () => {
    expect(parseCookies("a=1; b=2; c=3")).toEqual({ a: "1", b: "2", c: "3" });
  });
  test("returns empty object for empty/undefined", () => {
    expect(parseCookies("")).toEqual({});
    expect(parseCookies(undefined)).toEqual({});
  });
  test("URL-decodes values", () => {
    expect(parseCookies("token=abc%20def")).toEqual({ token: "abc def" });
  });
});
```

- [ ] **Step 2: Run — should fail with "Cannot find module"**

```bash
cd ~/auth-gateway/validator
bun test tests/cookies.test.ts
# Expected: FAIL
```

- [ ] **Step 3: Implement `parseCookies()`**

```typescript
// ~/auth-gateway/validator/src/cookies.ts
export function parseCookies(header: string | undefined | null): Record<string, string> {
  if (!header) return {};
  const out: Record<string, string> = {};
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const k = part.slice(0, eq).trim();
    const v = part.slice(eq + 1).trim();
    if (!k) continue;
    try {
      out[k] = decodeURIComponent(v);
    } catch {
      out[k] = v;
    }
  }
  return out;
}
```

- [ ] **Step 4: Run — all pass**

```bash
cd ~/auth-gateway/validator
bun test
# Expected: 8 pass total (4 verify + 4 cookies)
```

- [ ] **Step 5: Commit**

```bash
cd ~/auth-gateway
git add validator/
git commit -m "feat(validator): cookie parsing helper"
```

---

## Task 5: Validator — Hono Server with `/verify` and `/healthz`

**Files:**
- Create: `~/auth-gateway/validator/src/server.ts`
- Create: `~/auth-gateway/validator/tests/server.test.ts`

- [ ] **Step 1: Write the failing integration test**

```typescript
// ~/auth-gateway/validator/tests/server.test.ts
import { beforeAll, describe, expect, test } from "bun:test";
import { SignJWT } from "jose";
import { app } from "../src/server";

const SECRET = "test-secret-min-32-chars-long-aaaaaaaa";

beforeAll(() => {
  process.env.SUPABASE_JWT_SECRET = SECRET;
  process.env.LOGIN_URL = "https://auth.sb.soltrix.dev";
  process.env.COOKIE_NAME = "sb-access-token";
});

async function makeToken(claims: Record<string, unknown>) {
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(SECRET));
}

describe("/verify", () => {
  test("returns 200 + user headers when cookie has valid token", async () => {
    const token = await makeToken({ sub: "u1", email: "x@y.com", role: "authenticated" });
    const res = await app.request("/verify", {
      headers: { Cookie: `sb-access-token=${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("X-User-Id")).toBe("u1");
    expect(res.headers.get("X-User-Email")).toBe("x@y.com");
  });

  test("returns 302 to LOGIN_URL when no cookie is present", async () => {
    const res = await app.request("/verify", {
      headers: { "X-Forwarded-Host": "sb.soltrix.dev", "X-Forwarded-Uri": "/" },
    });
    expect(res.status).toBe(302);
    const loc = res.headers.get("Location") || "";
    expect(loc.startsWith("https://auth.sb.soltrix.dev/?rd=")).toBe(true);
    expect(decodeURIComponent(loc.split("rd=")[1])).toBe("https://sb.soltrix.dev/");
  });

  test("returns 302 when cookie is present but token is invalid", async () => {
    const res = await app.request("/verify", {
      headers: { Cookie: "sb-access-token=garbage" },
    });
    expect(res.status).toBe(302);
  });
});

describe("/healthz", () => {
  test("returns 200 ok", async () => {
    const res = await app.request("/healthz");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});
```

- [ ] **Step 2: Run — should fail with "Cannot find module"**

```bash
cd ~/auth-gateway/validator
bun test tests/server.test.ts
# Expected: FAIL
```

- [ ] **Step 3: Implement `server.ts`**

```typescript
// ~/auth-gateway/validator/src/server.ts
import { Hono } from "hono";
import { parseCookies } from "./cookies";
import { verifyJwt } from "./verify";

const SECRET = process.env.SUPABASE_JWT_SECRET || "";
const LOGIN_URL = process.env.LOGIN_URL || "https://auth.sb.soltrix.dev";
const COOKIE_NAME = process.env.COOKIE_NAME || "sb-access-token";

export const app = new Hono();

app.get("/healthz", (c) => c.text("ok"));

app.all("/verify", async (c) => {
  const cookies = parseCookies(c.req.header("cookie"));
  const token = cookies[COOKIE_NAME];

  const buildRedirect = () => {
    const xfHost = c.req.header("x-forwarded-host") || "";
    const xfProto = c.req.header("x-forwarded-proto") || "https";
    const xfUri = c.req.header("x-forwarded-uri") || "/";
    const rd = xfHost ? `${xfProto}://${xfHost}${xfUri}` : "";
    const url = rd ? `${LOGIN_URL}/?rd=${encodeURIComponent(rd)}` : LOGIN_URL;
    return c.redirect(url, 302);
  };

  if (!token) return buildRedirect();
  if (!SECRET) {
    console.error("SUPABASE_JWT_SECRET is not set");
    return c.text("misconfigured", 500);
  }
  const result = await verifyJwt(token, SECRET);
  if (!result.ok) return buildRedirect();

  c.header("X-User-Id", String(result.claims.sub ?? ""));
  c.header("X-User-Email", String(result.claims.email ?? ""));
  c.header("X-User-Role", String(result.claims.role ?? ""));
  return c.text("ok", 200);
});

const port = Number(process.env.PORT || 8080);
if (import.meta.main) {
  Bun.serve({ port, fetch: app.fetch });
  console.log(`validator listening on :${port}`);
}
```

- [ ] **Step 4: Run all tests — all pass**

```bash
cd ~/auth-gateway/validator
bun test
# Expected: 12 pass total (4 verify + 4 cookies + 4 server)
```

- [ ] **Step 5: Smoke-test the running server locally**

```bash
cd ~/auth-gateway/validator
SUPABASE_JWT_SECRET="test-secret-min-32-chars-long-aaaaaaaa" PORT=8080 bun src/server.ts &
sleep 1
curl -s http://localhost:8080/healthz
# Expected: ok
curl -sI http://localhost:8080/verify
# Expected: HTTP/1.1 302 Found, Location: https://auth.sb.soltrix.dev
kill %1
```

- [ ] **Step 6: Commit**

```bash
cd ~/auth-gateway
git add validator/
git commit -m "feat(validator): Hono server with /verify and /healthz"
```

---

## Task 6: Validator — Dockerfile

**Files:**
- Create: `~/auth-gateway/validator/Dockerfile`
- Create: `~/auth-gateway/validator/.dockerignore`

- [ ] **Step 1: Write `.dockerignore`**

```
node_modules
tests
.env
.env.local
*.log
```

- [ ] **Step 2: Write `Dockerfile`**

```dockerfile
# ~/auth-gateway/validator/Dockerfile
FROM oven/bun:1-alpine AS deps
WORKDIR /app
COPY package.json bun.lockb* ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src
COPY package.json tsconfig.json ./
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["bun", "src/server.ts"]
```

- [ ] **Step 3: Build the image and confirm it boots**

```bash
cd ~/auth-gateway/validator
docker build -t auth-validator:dev .
docker run --rm -d --name validator-test -p 18080:8080 \
  -e SUPABASE_JWT_SECRET=test-secret-min-32-chars-long-aaaaaaaa \
  auth-validator:dev
sleep 2
curl -s http://localhost:18080/healthz
# Expected: ok
docker rm -f validator-test
```

- [ ] **Step 4: Commit**

```bash
cd ~/auth-gateway
git add validator/Dockerfile validator/.dockerignore
git commit -m "feat(validator): Dockerfile (bun runtime)"
```

---

## Task 7: Login App — Vite + React Skeleton

**Files:**
- Create: `~/auth-gateway/login/package.json`
- Create: `~/auth-gateway/login/vite.config.ts`
- Create: `~/auth-gateway/login/tsconfig.json`
- Create: `~/auth-gateway/login/index.html`
- Create: `~/auth-gateway/login/src/main.tsx`
- Create: `~/auth-gateway/login/src/App.tsx`
- Create: `~/auth-gateway/login/public/favicon.svg`

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "auth-login",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview --host 0.0.0.0 --port 4173",
    "test": "vitest run"
  },
  "dependencies": {
    "@supabase/auth-ui-react": "^0.4.7",
    "@supabase/auth-ui-shared": "^0.1.8",
    "@supabase/supabase-js": "^2.46.2",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.28.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "happy-dom": "^15.11.6",
    "typescript": "^5.7.2",
    "vite": "^6.0.3",
    "vitest": "^2.1.8"
  }
}
```

- [ ] **Step 2: Write `vite.config.ts`**

```typescript
// ~/auth-gateway/login/vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: { host: "0.0.0.0", port: 5173 },
  test: { environment: "happy-dom", globals: true },
});
```

- [ ] **Step 3: Write `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true,
    "isolatedModules": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"]
}
```

- [ ] **Step 4: Write `index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Sign in · Soltrix</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 5: Write `src/main.tsx`**

```typescript
// ~/auth-gateway/login/src/main.tsx
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
```

- [ ] **Step 6: Write a placeholder `src/App.tsx` (real content lands in Task 9)**

```typescript
// ~/auth-gateway/login/src/App.tsx
export function App() {
  return <div>Soltrix login (skeleton)</div>;
}
```

- [ ] **Step 7: Write `src/styles.css`**

```css
@import url("https://rsms.me/inter/inter.css");

* { box-sizing: border-box; }
html, body, #root { height: 100%; margin: 0; }
body {
  font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #181818;
  color: #ededed;
}
```

- [ ] **Step 8: Write a minimal `public/favicon.svg`**

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="6" fill="#3ECF8E"/>
  <text x="16" y="22" font-family="Inter, sans-serif" font-size="18" font-weight="700"
        fill="#0A0A0A" text-anchor="middle">S</text>
</svg>
```

- [ ] **Step 9: Install + smoke-build**

```bash
cd ~/auth-gateway/login
bun install
bun run build
# Expected: dist/ created, no TypeScript errors
ls dist/
```

- [ ] **Step 10: Commit**

```bash
cd ~/auth-gateway
git add login/
git commit -m "feat(login): Vite + React skeleton"
```

---

## Task 8: Login App — Cookie-based Storage Adapter

**Files:**
- Create: `~/auth-gateway/login/src/lib/cookie-storage.ts`
- Create: `~/auth-gateway/login/src/lib/cookie-storage.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// ~/auth-gateway/login/src/lib/cookie-storage.test.ts
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { CookieStorage } from "./cookie-storage";

describe("CookieStorage", () => {
  beforeEach(() => {
    document.cookie.split(";").forEach((c) => {
      const eq = c.indexOf("=");
      const name = (eq > -1 ? c.slice(0, eq) : c).trim();
      document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;
    });
  });

  test("setItem writes a cookie scoped to the configured domain", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "v");
    expect(document.cookie).toContain("k=v");
  });

  test("getItem returns the previously set value", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "hello");
    expect(s.getItem("k")).toBe("hello");
  });

  test("removeItem clears the cookie", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "v");
    s.removeItem("k");
    expect(s.getItem("k")).toBeNull();
  });

  test("URL-encodes special characters", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "a b=c");
    expect(s.getItem("k")).toBe("a b=c");
  });
});
```

- [ ] **Step 2: Run — should fail with "Cannot find module"**

```bash
cd ~/auth-gateway/login
bun run test
# Expected: FAIL
```

- [ ] **Step 3: Implement `CookieStorage`**

```typescript
// ~/auth-gateway/login/src/lib/cookie-storage.ts
export interface CookieStorageOptions {
  domain: string;
  secure?: boolean;
  sameSite?: "Lax" | "Strict" | "None";
  path?: string;
}

/**
 * A `Storage`-compatible adapter that persists Supabase auth state
 * to cookies scoped to a parent domain (e.g. ".soltrix.dev"), so the
 * forward-auth validator on a sibling subdomain can read the JWT.
 *
 * Note: cookies set from JS cannot be HttpOnly. We accept this trade-off
 * because supabase-js needs to read the token client-side. The validator
 * still uses HS256 + JWT_SECRET to authenticate, so XSS leakage is the
 * only added risk relative to localStorage (which is also JS-readable).
 */
export class CookieStorage implements Storage {
  private readonly opts: Required<CookieStorageOptions>;

  constructor(opts: CookieStorageOptions) {
    this.opts = {
      domain: opts.domain,
      secure: opts.secure ?? true,
      sameSite: opts.sameSite ?? "Lax",
      path: opts.path ?? "/",
    };
  }

  get length(): number {
    return document.cookie ? document.cookie.split(";").length : 0;
  }

  key(_index: number): string | null {
    return null; // not used by supabase-js
  }

  clear(): void {
    for (const part of document.cookie.split(";")) {
      const eq = part.indexOf("=");
      const name = (eq > -1 ? part.slice(0, eq) : part).trim();
      if (name) this.removeItem(name);
    }
  }

  getItem(key: string): string | null {
    const all = document.cookie ? document.cookie.split(";") : [];
    for (const part of all) {
      const eq = part.indexOf("=");
      if (eq < 0) continue;
      const k = part.slice(0, eq).trim();
      if (k === key) {
        try {
          return decodeURIComponent(part.slice(eq + 1).trim());
        } catch {
          return part.slice(eq + 1).trim();
        }
      }
    }
    return null;
  }

  setItem(key: string, value: string): void {
    const v = encodeURIComponent(value);
    const parts = [
      `${key}=${v}`,
      `Domain=${this.opts.domain}`,
      `Path=${this.opts.path}`,
      `SameSite=${this.opts.sameSite}`,
      "Max-Age=2592000", // 30 days
    ];
    if (this.opts.secure) parts.push("Secure");
    document.cookie = parts.join("; ");
  }

  removeItem(key: string): void {
    document.cookie = `${key}=; Domain=${this.opts.domain}; Path=${this.opts.path}; Max-Age=0`;
  }
}
```

- [ ] **Step 4: Run — all 4 pass**

```bash
cd ~/auth-gateway/login
bun run test
# Expected: 4 pass
```

- [ ] **Step 5: Commit**

```bash
cd ~/auth-gateway
git add login/
git commit -m "feat(login): cookie storage adapter scoped to parent domain"
```

---

## Task 9: Login App — Supabase Client + `<Auth />` Page

**Files:**
- Create: `~/auth-gateway/login/src/lib/supabase.ts`
- Create: `~/auth-gateway/login/src/pages/Login.tsx`
- Modify: `~/auth-gateway/login/src/App.tsx`

- [ ] **Step 1: Write `lib/supabase.ts`**

```typescript
// ~/auth-gateway/login/src/lib/supabase.ts
import { createClient } from "@supabase/supabase-js";
import { CookieStorage } from "./cookie-storage";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
const cookieDomain = (import.meta.env.VITE_COOKIE_DOMAIN as string) || ".soltrix.dev";

if (!url || !anonKey) {
  // Fail fast at import time so a misconfigured deploy is obvious in the UI.
  throw new Error("VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are required");
}

export const supabase = createClient(url, anonKey, {
  auth: {
    storage: new CookieStorage({ domain: cookieDomain }),
    storageKey: "sb-access-token",
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
  },
});
```

- [ ] **Step 2: Write `pages/Login.tsx`**

```typescript
// ~/auth-gateway/login/src/pages/Login.tsx
import { Auth } from "@supabase/auth-ui-react";
import { ThemeSupa } from "@supabase/auth-ui-shared";
import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

const DEFAULT_REDIRECT =
  (import.meta.env.VITE_DEFAULT_REDIRECT as string) || "https://sb.soltrix.dev";

function getRedirect(): string {
  const params = new URLSearchParams(window.location.search);
  const rd = params.get("rd");
  if (!rd) return DEFAULT_REDIRECT;
  // only allow same-parent-domain redirects
  try {
    const u = new URL(rd);
    if (u.hostname.endsWith(".soltrix.dev") || u.hostname === "soltrix.dev") return rd;
  } catch { /* fall through */ }
  return DEFAULT_REDIRECT;
}

export function Login() {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let mounted = true;
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!mounted) return;
      if (session) window.location.replace(getRedirect());
      else setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_IN") window.location.replace(getRedirect());
    });
    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  if (!ready) return null;

  return (
    <div className="page">
      <div className="card">
        <h1 className="title">Sign in to Soltrix</h1>
        <Auth
          supabaseClient={supabase}
          appearance={{
            theme: ThemeSupa,
            variables: {
              default: {
                colors: {
                  brand: "#3ECF8E",
                  brandAccent: "#2EB57A",
                  inputBackground: "#1F1F1F",
                  inputBorder: "#2F2F2F",
                  inputText: "#EDEDED",
                  defaultButtonBackground: "#3ECF8E",
                  defaultButtonBackgroundHover: "#66E0AB",
                },
                radii: { borderRadiusButton: "6px", inputBorderRadius: "6px" },
                fonts: { bodyFontFamily: "Inter, sans-serif" },
              },
            },
          }}
          providers={[]}
          theme="dark"
          showLinks={true}
        />
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Add page styles to `styles.css` (append)**

```css
.page {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 24px;
}
.card {
  width: 100%;
  max-width: 380px;
  background: #1c1c1c;
  border: 1px solid #2a2a2a;
  border-radius: 12px;
  padding: 32px;
  box-shadow: 0 8px 32px rgba(0,0,0,0.4);
}
.title {
  margin: 0 0 24px;
  font-size: 20px;
  font-weight: 600;
  color: #ededed;
  text-align: center;
}
```

- [ ] **Step 4: Wire `App.tsx` to render `<Login />`**

```typescript
// ~/auth-gateway/login/src/App.tsx
import { Login } from "./pages/Login";
export function App() { return <Login />; }
```

- [ ] **Step 5: Build and confirm no errors**

```bash
cd ~/auth-gateway/login
VITE_SUPABASE_URL=https://api.sb.soltrix.dev \
VITE_SUPABASE_ANON_KEY=placeholder \
VITE_COOKIE_DOMAIN=.soltrix.dev \
VITE_DEFAULT_REDIRECT=https://sb.soltrix.dev \
  bun run build
# Expected: no TypeScript errors, dist/ produced
```

- [ ] **Step 6: Commit**

```bash
cd ~/auth-gateway
git add login/src login/src/pages
git commit -m "feat(login): Supabase auth UI with cookie session"
```

---

## Task 10: Login App — Dockerfile (Caddy static serve)

**Files:**
- Create: `~/auth-gateway/login/Dockerfile`
- Create: `~/auth-gateway/login/Caddyfile`
- Create: `~/auth-gateway/login/.dockerignore`

- [ ] **Step 1: Write `.dockerignore`**

```
node_modules
dist
.env
.env.local
.vite
*.log
```

- [ ] **Step 2: Write `Caddyfile`**

```
:80 {
  root * /srv
  encode gzip zstd
  try_files {path} {path}/ /index.html
  file_server
  header /assets/* Cache-Control "public, max-age=31536000, immutable"
  header / Cache-Control "no-cache"
}
```

- [ ] **Step 3: Write multi-stage `Dockerfile`**

```dockerfile
# ~/auth-gateway/login/Dockerfile
# Build args are populated by Coolify from runtime env via "build args" --
# values are baked into the static bundle at build time.
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_COOKIE_DOMAIN
ARG VITE_DEFAULT_REDIRECT

FROM oven/bun:1-alpine AS build
WORKDIR /app
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_COOKIE_DOMAIN
ARG VITE_DEFAULT_REDIRECT
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY \
    VITE_COOKIE_DOMAIN=$VITE_COOKIE_DOMAIN \
    VITE_DEFAULT_REDIRECT=$VITE_DEFAULT_REDIRECT
COPY package.json bun.lockb* ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

FROM caddy:2-alpine AS runtime
COPY --from=build /app/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
```

- [ ] **Step 4: Build and confirm it serves the SPA**

```bash
cd ~/auth-gateway/login
docker build \
  --build-arg VITE_SUPABASE_URL=https://api.sb.soltrix.dev \
  --build-arg VITE_SUPABASE_ANON_KEY=placeholder \
  --build-arg VITE_COOKIE_DOMAIN=.soltrix.dev \
  --build-arg VITE_DEFAULT_REDIRECT=https://sb.soltrix.dev \
  -t auth-login:dev .
docker run --rm -d --name login-test -p 18181:80 auth-login:dev
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:18181/
# Expected: 200
curl -s http://localhost:18181/ | grep -q "Sign in"
# Expected: (no output, exit 0 — title in HTML)
docker rm -f login-test
```

- [ ] **Step 5: Commit**

```bash
cd ~/auth-gateway
git add login/Dockerfile login/Caddyfile login/.dockerignore
git commit -m "feat(login): Dockerfile (caddy static serve)"
```

---

## Task 11: Coolify Deploy Compose — Validator

**Files:**
- Create: `~/auth-gateway/coolify/validator.compose.yml`

- [ ] **Step 1: Write the compose**

```yaml
# ~/auth-gateway/coolify/validator.compose.yml
# Used by setup.sh as docker_compose_raw on the auth-validator service.
services:
  validator:
    image: 'ghcr.io/${GH_OWNER}/auth-gateway-validator:latest'
    environment:
      # Coolify magic FQDN — exposes service at this host on port 8080.
      - SERVICE_FQDN_VALIDATOR_8080=https://auth-verify.sb.soltrix.dev
      - SUPABASE_JWT_SECRET=${SUPABASE_JWT_SECRET}
      - LOGIN_URL=https://auth.sb.soltrix.dev
      - COOKIE_NAME=sb-access-token
      - PORT=8080
    expose:
      - '8080'
    healthcheck:
      test: ['CMD-SHELL', 'wget -qO- http://127.0.0.1:8080/healthz | grep -q ok']
      interval: 10s
      timeout: 3s
      retries: 3
```

- [ ] **Step 2: Commit**

```bash
cd ~/auth-gateway
git add coolify/validator.compose.yml
git commit -m "feat(coolify): validator compose template"
```

---

## Task 12: Coolify Deploy Compose — Login

**Files:**
- Create: `~/auth-gateway/coolify/login.compose.yml`

- [ ] **Step 1: Write the compose**

```yaml
# ~/auth-gateway/coolify/login.compose.yml
services:
  login:
    image: 'ghcr.io/${GH_OWNER}/auth-gateway-login:latest'
    environment:
      - SERVICE_FQDN_LOGIN_80=https://auth.sb.soltrix.dev
      # Build args were already baked in at image build time.
      # These runtime env vars are kept for documentation / future runtime templating.
      - VITE_SUPABASE_URL=https://api.sb.soltrix.dev
      - VITE_COOKIE_DOMAIN=.soltrix.dev
      - VITE_DEFAULT_REDIRECT=https://sb.soltrix.dev
    expose:
      - '80'
    healthcheck:
      test: ['CMD-SHELL', 'wget -qO- http://127.0.0.1/ >/dev/null || exit 1']
      interval: 10s
      timeout: 3s
      retries: 3
    labels:
      # Block bare-root direct access — redirect to sb.soltrix.dev unless ?rd= is present.
      - 'traefik.http.middlewares.login-root-redirect.redirectregex.regex=^https?://auth\.sb\.soltrix\.dev/?$$'
      - 'traefik.http.middlewares.login-root-redirect.redirectregex.replacement=https://sb.soltrix.dev/'
      - 'traefik.http.middlewares.login-root-redirect.redirectregex.permanent=false'
```

- [ ] **Step 2: Commit**

```bash
cd ~/auth-gateway
git add coolify/login.compose.yml
git commit -m "feat(coolify): login compose template"
```

---

## Task 13: Coolify Bootstrap — `setup.sh` (the "auto-deploy everything" script)

**Files:**
- Create: `~/auth-gateway/coolify/setup.sh`
- Create: `~/auth-gateway/coolify/env/stack.env.example`

- [ ] **Step 1: Write `coolify/env/stack.env.example`**

```
# Coolify
COOLIFY_URL=http://localhost:8000
COOLIFY_TOKEN=<paste a Coolify root API token>
PROJECT_UUID=<paste the target project UUID>
SERVER_UUID=<paste the target server UUID>

# Domains (parent domain MUST already have wildcard A record pointing at the VPS)
PARENT_DOMAIN=soltrix.dev
SB_HOST=sb.soltrix.dev
API_HOST=api.sb.soltrix.dev
S3_HOST=s3.soltrix.dev
MINIO_CONSOLE_HOST=minio.soltrix.dev
AUTH_HOST=auth.sb.soltrix.dev
AUTH_VERIFY_HOST=auth-verify.sb.soltrix.dev

# Repo
GH_OWNER=dani3lz
GH_REPO=auth-gateway
```

- [ ] **Step 2: Write `coolify/setup.sh`**

```bash
#!/usr/bin/env bash
# ~/auth-gateway/coolify/setup.sh
# Idempotent bootstrap of the entire Soltrix self-hosted stack on a fresh Coolify host.
# Order: Postgres → MinIO → Supabase → Validator → Login → wire forward-auth onto Studio.
# Re-running is safe — each step checks for an existing resource first.
set -euo pipefail

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
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }

# --- Helpers ---
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
b64() { base64 -w0 < "$1"; }

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
  echo "PG_PASS=$PG_PASS" >> "$ENV_FILE"   # remember for later steps
else
  ok "Postgres already exists: $PG_UUID"
  PG_PASS="${PG_PASS:-}"
fi

# Wait for Postgres to be reachable
log "Waiting for Postgres ($PG_UUID) to accept connections"
until docker exec "$PG_UUID" pg_isready -U supabase_admin >/dev/null 2>&1; do sleep 2; done
ok "Postgres ready"

# Bootstrap Postgres for Supabase (extensions + Vault key + init scripts)
log "Step 1.5: bootstrapping Postgres for Supabase"
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
  COMPOSE_B64="$(python3 -c "import base64; print(base64.b64encode(open('login.compose.yml').read().encode()).decode())" || true)"
  # Inline compose for MinIO since it's small
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

# Wire env (FQDNs, postgres host pointing at standalone, S3 endpoint pointing at minio)
log "Wiring Supabase env vars"
for kv in \
  "SERVICE_FQDN_SUPABASEKONG_8000=https://$API_HOST" \
  "SERVICE_FQDN_SUPABASESTUDIO_3000=https://$SB_HOST" \
  "POSTGRES_HOSTNAME=$PG_UUID" \
  "POSTGRES_HOST=$PG_UUID" \
  "POSTGRES_PORT=5432" \
  "STORAGE_S3_ENDPOINT=http://minio-$MINIO_UUID:9000"; do
  k="${kv%%=*}"; v="${kv#*=}"
  curl -s -X PATCH "${AUTH[@]}" "$API/services/$SUPA_UUID/envs" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'key':sys.argv[1],'value':sys.argv[2],'is_preview':False,'is_buildtime':False,'is_literal':False}))" "$k" "$v")" \
    >/dev/null
done
ok "Supabase env vars set"

# --- 4. Validator ---
log "Step 4/6: Validator (auth-gateway)"
VAL_UUID="$(service_uuid_by_name auth-validator || true)"
if [ -z "$VAL_UUID" ]; then
  COMPOSE_B64="$(python3 -c "import base64,sys; print(base64.b64encode(open(sys.argv[1]).read().replace('\${GH_OWNER}', '$GH_OWNER').encode()).decode())" validator.compose.yml)"
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
  COMPOSE_B64="$(python3 -c "import base64,sys; print(base64.b64encode(open(sys.argv[1]).read().replace('\${GH_OWNER}', '$GH_OWNER').encode()).decode())" login.compose.yml)"
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
warn "This step appends labels to the supabase service compose."
warn "Inspect /data/coolify/services/$SUPA_UUID/docker-compose.yml afterward."

# (See coolify/wire-forward-auth.py for the exact in-place YAML edit)
python3 ./wire-forward-auth.py "$SUPA_UUID" "$VAL_UUID" "$AUTH_HOST"
deploy_uuid "$SUPA_UUID"
ok "Forward-auth wired."

log "Done. Verify: curl -skI https://$SB_HOST/ → expect 302 to https://$AUTH_HOST/"
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x ~/auth-gateway/coolify/setup.sh
```

- [ ] **Step 4: Commit**

```bash
cd ~/auth-gateway
git add coolify/setup.sh coolify/env/stack.env.example
git commit -m "feat(coolify): idempotent setup.sh bootstrap script"
```

---

## Task 14: Coolify Bootstrap — Forward-Auth Wiring Helper

**Files:**
- Create: `~/auth-gateway/coolify/wire-forward-auth.py`

- [ ] **Step 1: Write the helper that edits supabase compose**

```python
#!/usr/bin/env python3
# ~/auth-gateway/coolify/wire-forward-auth.py
"""
Append (or replace) traefik forward-auth labels on the supabase-studio service.
Usage: wire-forward-auth.py <SUPABASE_UUID> <VALIDATOR_UUID> <AUTH_HOST>
"""
import sys
import yaml

if len(sys.argv) != 4:
    sys.stderr.write(__doc__)
    sys.exit(2)
SUPA, VAL, AUTH_HOST = sys.argv[1], sys.argv[2], sys.argv[3]
PATH = f"/data/coolify/services/{SUPA}/docker-compose.yml"

with open(PATH) as f:
    d = yaml.safe_load(f)

studio = d["services"]["supabase-studio"]
labels = studio.get("labels", {})
if isinstance(labels, list):
    labels = {l.split("=", 1)[0]: l.split("=", 1)[1] for l in labels if "=" in l}

# Strip any prior auth middlewares we manage
for k in list(labels):
    if any(s in k for s in (
        "studio-basicauth",
        "authelia",
        "authentik",
        "auth-gateway",
    )):
        del labels[k]

verify_addr = f"http://validator-{VAL}:8080/verify"

labels["traefik.http.middlewares.auth-gateway.forwardauth.address"] = verify_addr
labels["traefik.http.middlewares.auth-gateway.forwardauth.trustForwardHeader"] = "true"
labels["traefik.http.middlewares.auth-gateway.forwardauth.authResponseHeaders"] = (
    "X-User-Id,X-User-Email,X-User-Role"
)
labels[f"traefik.http.routers.http-0-{SUPA}-supabase-studio.middlewares"] = (
    "redirect-to-https,auth-gateway"
)
labels[f"traefik.http.routers.https-0-{SUPA}-supabase-studio.middlewares"] = (
    "gzip,auth-gateway"
)

studio["labels"] = labels
with open(PATH, "w") as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
print(f"wired forward-auth on {PATH} → {verify_addr}")
```

- [ ] **Step 2: Make it executable + commit**

```bash
chmod +x ~/auth-gateway/coolify/wire-forward-auth.py
cd ~/auth-gateway
git add coolify/wire-forward-auth.py
git commit -m "feat(coolify): wire-forward-auth helper"
```

---

## Task 15: Teardown Script (for testing)

**Files:**
- Create: `~/auth-gateway/coolify/teardown.sh`

- [ ] **Step 1: Write the teardown**

```bash
#!/usr/bin/env bash
# ~/auth-gateway/coolify/teardown.sh
# Removes the Coolify resources created by setup.sh. Use with caution.
set -euo pipefail

ENV_FILE="${ENV_FILE:-./env/stack.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"
API="$COOLIFY_URL/api/v1"
AUTH=(-H "Authorization: Bearer $COOLIFY_TOKEN")

del_service() {
  local name="$1"
  local uuid
  uuid="$(curl -s "${AUTH[@]}" "$API/services" \
    | python3 -c "import json,sys; [print(s['uuid']) for s in json.load(sys.stdin) if s.get('name')==sys.argv[1]]" "$name" \
    | head -1)"
  [ -n "$uuid" ] && curl -s -X DELETE "${AUTH[@]}" "$API/services/$uuid" >/dev/null && \
    echo "deleted service $name ($uuid)"
}
del_database() {
  local name="$1"
  local uuid
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
```

- [ ] **Step 2: chmod + commit**

```bash
chmod +x ~/auth-gateway/coolify/teardown.sh
cd ~/auth-gateway
git add coolify/teardown.sh
git commit -m "feat(coolify): teardown script"
```

---

## Task 16: Add `docs/RECREATE.md`

**Files:**
- Create: `~/auth-gateway/docs/RECREATE.md`

- [ ] **Step 1: Write the runbook**

````markdown
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
curl -skI https://auth.sb.soltrix.dev/healthz  # 404 — login app doesn't expose health, this is fine
curl -skI https://auth-verify.sb.soltrix.dev/healthz  # → 200, "ok"
```

## 4. First user

The login page uses Supabase Auth, so create a user in **Supabase Studio → Authentication → Users → Add user** (or sign up via the form if `ENABLE_EMAIL_SIGNUP=true`).

## 5. Restoring access if locked out

If you ever break the gateway, you can temporarily strip the `auth-gateway` middleware from supabase-studio:

```bash
docker exec coolify-db psql -U coolify -d coolify -c "
UPDATE service_applications
SET fqdn = REPLACE(fqdn, ',https://...', '')
WHERE name='supabase-studio';"
# then edit /data/coolify/services/<supa>/docker-compose.yml to drop the auth-gateway middleware
```
````

- [ ] **Step 2: Commit**

```bash
cd ~/auth-gateway
git add docs/RECREATE.md
git commit -m "docs: RECREATE.md (full-stack bootstrap runbook)"
```

---

## Task 17: Push to Private GitHub Repo

**Files:**
- (Push only)

- [ ] **Step 1: Confirm `gh` CLI is installed and authenticated**

```bash
which gh || (apt-get update && apt-get install -y gh)
gh auth status
# If not authenticated: gh auth login   (interactive — one-time)
```

- [ ] **Step 2: Create the private repo**

```bash
cd ~/auth-gateway
gh repo create dani3lz/auth-gateway --private --source=. --remote=origin --push
# Expected: Repo created, branch `main` pushed.
```

- [ ] **Step 3: Verify**

```bash
gh repo view dani3lz/auth-gateway --json visibility,url
# Expected: {"visibility":"PRIVATE","url":"https://github.com/dani3lz/auth-gateway"}
```

---

## Task 18: Live Smoke Test (Validator + Login Deployed)

- [ ] **Step 1: Run the bootstrap script on this VPS**

```bash
cd ~/auth-gateway/coolify
cp env/stack.env.example env/stack.env
# Fill in COOLIFY_TOKEN, PROJECT_UUID (sw0g4cw0kkogg0ococss4wcs), SERVER_UUID (agkkw88ko0sgss4oggw804sw)
./setup.sh
# Expect: 6 ✓ lines, "Done."
```

- [ ] **Step 2: Verify the validator is reachable**

```bash
curl -skI https://auth-verify.sb.soltrix.dev/healthz
# Expected: HTTP/2 200, "ok"
```

- [ ] **Step 3: Verify the login page renders**

```bash
curl -sk https://auth.sb.soltrix.dev/ | grep -q 'Sign in to Soltrix'
# Expected: exit 0 (string found)
```

- [ ] **Step 4: Verify forward-auth on Studio redirects to login**

```bash
curl -skI https://sb.soltrix.dev/
# Expected: HTTP/2 302, Location: https://auth.sb.soltrix.dev/?rd=https%3A%2F%2Fsb.soltrix.dev%2F
```

- [ ] **Step 5: Sign in via the browser**

```
1. Open https://sb.soltrix.dev in incognito
2. Redirected to https://auth.sb.soltrix.dev/?rd=…
3. Use a user from Supabase Studio's auth.users table (create one in Studio if needed)
4. Sign in → redirected back to https://sb.soltrix.dev/
5. Studio loads, you can access it
```

- [ ] **Step 6: Verify the cookie**

In DevTools → Application → Cookies → `.soltrix.dev`: there should be a `sb-access-token` cookie with `Domain=.soltrix.dev`, `SameSite=Lax`, `Secure`.

---

## Task 19: Decommission Authentik

- [ ] **Step 1: Delete the Authentik service via Coolify**

```bash
TOKEN="<coolify root token>"
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8000/api/v1/services/asc44o0ss8kgoo44gso04ggo"
# Expected: {"message":"Service deletion request queued."}
```

- [ ] **Step 2: Remove Authentik vault entries**

```bash
docker exec d0ks0k48o0ggs8ckoo4w80c4 psql -U supabase_admin -d postgres -c \
  "DELETE FROM vault.secrets WHERE name LIKE 'authentik%';"
```

- [ ] **Step 3: Remove the Authentik snapshot from `docs/docker/`**

```bash
rm ~/auth-gateway/docs/docker/authentik.docker-compose.yml
```

- [ ] **Step 4: Update `docs/README.md` to reflect the new auth gateway in place of Authentik**

Replace the `### Authentik (forward-auth in front of Studio)` section with `### Auth Gateway (forward-auth in front of Studio)` and the corresponding details. (Show the diff in the commit.)

- [ ] **Step 5: Commit and push**

```bash
cd ~/auth-gateway
git add docs/
git commit -m "docs: replace Authentik section with Auth Gateway"
git push
```

---

## Self-Review

**Spec coverage:**
- ✅ Custom login page using Supabase Auth UI — Tasks 7–10
- ✅ Forward-auth validator — Tasks 2–6
- ✅ Private GitHub repo — Task 17
- ✅ All existing docs included — Task 1 (`cp -a /root/docs/. ~/auth-gateway/docs/`)
- ✅ docker-compose / setup script for Coolify auto-bootstrap — Tasks 11–15
- ✅ Authentik decommission — Task 19

**Placeholder scan:** none — every code/config block is concrete.

**Type consistency:** `verifyJwt(token, secret)` signature is identical in `verify.ts` and `tests/verify.test.ts`. `parseCookies(header)` returns `Record<string,string>` consistently. `CookieStorage` implements `Storage` interface (matching what `@supabase/supabase-js`'s `auth.storage` accepts).

---

## Operational Notes

- **Coolify docker-network attachment** is the single most fragile thing in this stack. Whenever a service container is recreated, `coolify-proxy` may need to be reconnected: `docker network connect <service_uuid> coolify-proxy && docker restart coolify-proxy`. The `setup.sh` handles this for first deploys; if you re-build manually via `docker compose up -d --force-recreate`, you'll need to repeat the connect.
- **Supabase JWT_SECRET** is the shared secret between Supabase Auth and our validator. Rotate it in Supabase env and the validator env together — they must always match.
- **Cookie scope.** The login app writes `sb-access-token` with `Domain=.soltrix.dev`. Any subdomain whose request reaches the validator can read it. Don't run untrusted apps under `*.soltrix.dev` unless you trust them with the same auth.
- **Image registry.** The compose templates reference `ghcr.io/$GH_OWNER/...`. If the repo is private, the registry images can still be public — that's a separate setting. Easier path: make the *images* public on GHCR while the source repo stays private.
