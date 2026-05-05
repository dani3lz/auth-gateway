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
