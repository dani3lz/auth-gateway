import { Hono } from "hono";
import { parseCookies } from "./cookies";
import { verifyJwt } from "./verify";

export const app = new Hono();

app.get("/healthz", (c) => c.text("ok"));

app.all("/verify", async (c) => {
  const SECRET = process.env.SUPABASE_JWT_SECRET || "";
  const LOGIN_URL = process.env.LOGIN_URL || "https://auth.sb.soltrix.dev";
  const COOKIE_NAME = process.env.COOKIE_NAME || "sb-access-token";

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
