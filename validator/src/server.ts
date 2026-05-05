import { Hono } from "hono";
import { parseCookies } from "./cookies";
import { verifyJwt } from "./verify";

export const app = new Hono();

app.get("/healthz", (c) => c.text("ok"));

app.all("/verify", async (c) => {
  const SECRET = process.env.SUPABASE_JWT_SECRET || "";
  const LOGIN_URL = process.env.LOGIN_URL || "";
  const COOKIE_NAME = process.env.COOKIE_NAME || "sb-access-token";
  const OWNER_EMAIL = (process.env.OWNER_EMAIL || "").toLowerCase();

  const cookies = parseCookies(c.req.header("cookie"));
  // supabase-js stores the entire session as a JSON object under the cookie:
  //   {"access_token":"eyJ...","refresh_token":"...","expires_at":..., "user":{...}}
  // For a "raw token" mode we also accept a bare JWT (starts with "eyJ").
  const raw = cookies[COOKIE_NAME];
  let token = "";
  if (raw) {
    if (raw.startsWith("{")) {
      try {
        const parsed = JSON.parse(raw);
        token = typeof parsed.access_token === "string" ? parsed.access_token : "";
      } catch {
        token = "";
      }
    } else {
      token = raw;
    }
  }

  // Decide if the request is a top-level page navigation (browser will
  // follow our 302 to the login page) vs an XHR/asset fetch (where a 302
  // chain would loop and the browser will explode with ERR_TOO_MANY_REDIRECTS).
  // Heuristic: only navigations have Sec-Fetch-Mode=navigate AND request
  // text/html. Anything else gets a clean 401.
  const isNavigation = (() => {
    const mode = c.req.header("sec-fetch-mode") || "";
    if (mode === "navigate") return true;
    const accept = c.req.header("accept") || "";
    const dest = c.req.header("sec-fetch-dest") || "";
    return accept.includes("text/html") && (dest === "document" || dest === "");
  })();

  const buildResponse = () => {
    if (!isNavigation) return c.text("unauthorized", 401);
    const xfHost = c.req.header("x-forwarded-host") || "";
    const xfProto = c.req.header("x-forwarded-proto") || "https";
    const xfUri = c.req.header("x-forwarded-uri") || "/";
    // If the original URI is already pointing at the login page, don't wrap
    // it again — that's the loop the user just hit. Send to LOGIN_URL bare.
    const isLoginPath = xfUri.startsWith("/auth") || xfUri.startsWith("/logout");
    if (isLoginPath) return c.redirect(LOGIN_URL, 302);
    const rd = xfHost ? `${xfProto}://${xfHost}${xfUri}` : "";
    const url = rd ? `${LOGIN_URL}/?rd=${encodeURIComponent(rd)}` : LOGIN_URL;
    return c.redirect(url, 302);
  };

  if (!LOGIN_URL || !SECRET) {
    console.error("LOGIN_URL and SUPABASE_JWT_SECRET must both be set");
    return c.text("misconfigured", 500);
  }
  if (!token) return buildResponse();
  const result = await verifyJwt(token, SECRET);
  if (!result.ok) return buildResponse();

  const email = String(result.claims.email ?? "").toLowerCase();

  // Owner-only guard for Studio's per-user write actions in the
  // Authentication > Users tab — delete, ban, unban, edit, etc. They all
  // go through /api/platform/auth/[ref]/users/[id]... with a mutating verb
  // (DELETE / PATCH / PUT / POST). Block them for everyone except
  // OWNER_EMAIL so invited teammates can't lock each other (or the owner)
  // out through the UI. Reads (GET) and the collection-level POST that
  // Studio uses to invite new users are still allowed.
  // NB: this is a UI-button guard, not a security boundary — Studio's
  // SQL editor runs as superuser and can still mutate auth.users directly.
  if (OWNER_EMAIL) {
    const method = (c.req.header("x-forwarded-method") || "").toUpperCase();
    const path = (c.req.header("x-forwarded-uri") || "").split("?")[0];
    const isPerUserMutation =
      ["DELETE", "PATCH", "PUT", "POST"].includes(method) &&
      /^\/api\/platform\/auth\/[^/]+\/users\/[^/]+/.test(path);
    if (isPerUserMutation && email !== OWNER_EMAIL) {
      return c.text("Only the workspace owner may modify users.", 403);
    }
  }

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
