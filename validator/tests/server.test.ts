import { beforeAll, describe, expect, test } from "bun:test";
import { SignJWT } from "jose";
import { app } from "../src/server";

const SECRET = "test-secret-min-32-chars-long-aaaaaaaa";

beforeAll(() => {
  process.env.SUPABASE_JWT_SECRET = SECRET;
  process.env.LOGIN_URL = "https://auth.example.com";
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
  test("returns 200 + user headers when cookie has a bare JWT", async () => {
    const token = await makeToken({ sub: "u1", email: "x@y.com", role: "authenticated" });
    const res = await app.request("/verify", {
      headers: { Cookie: `sb-access-token=${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("X-User-Id")).toBe("u1");
    expect(res.headers.get("X-User-Email")).toBe("x@y.com");
  });

  test("returns 200 when cookie is a supabase-js session JSON envelope", async () => {
    const token = await makeToken({ sub: "u2", email: "j@k.com", role: "authenticated" });
    const session = JSON.stringify({ access_token: token, refresh_token: "r", expires_at: 99 });
    const res = await app.request("/verify", {
      headers: { Cookie: `sb-access-token=${encodeURIComponent(session)}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("X-User-Email")).toBe("j@k.com");
  });

  test("returns 302 to LOGIN_URL on a navigation when no cookie is present", async () => {
    const res = await app.request("/verify", {
      headers: {
        "X-Forwarded-Host": "app.example.com",
        "X-Forwarded-Uri": "/",
        "Sec-Fetch-Mode": "navigate",
        "Accept": "text/html",
      },
    });
    expect(res.status).toBe(302);
    const loc = res.headers.get("Location") || "";
    expect(loc.startsWith("https://auth.example.com/?rd=")).toBe(true);
    expect(decodeURIComponent(loc.split("rd=")[1])).toBe("https://app.example.com/");
  });

  test("returns 401 (NOT 302) on an XHR/asset request without a cookie", async () => {
    // This is what prevents the manifest.json/favicon redirect-loop.
    const res = await app.request("/verify", {
      headers: {
        "X-Forwarded-Host": "app.example.com",
        "X-Forwarded-Uri": "/favicon/manifest.json",
        "Sec-Fetch-Mode": "no-cors",
        "Sec-Fetch-Dest": "manifest",
        "Accept": "*/*",
      },
    });
    expect(res.status).toBe(401);
  });

  test("returns 302 when cookie is present but token is invalid (navigation)", async () => {
    const res = await app.request("/verify", {
      headers: {
        Cookie: "sb-access-token=garbage",
        "Sec-Fetch-Mode": "navigate",
        "Accept": "text/html",
      },
    });
    expect(res.status).toBe(302);
  });

  test("does not nest rd when the original URI is already /auth/...", async () => {
    const res = await app.request("/verify", {
      headers: {
        "X-Forwarded-Host": "app.example.com",
        "X-Forwarded-Uri": "/auth/?rd=https%3A%2F%2Fapp.example.com%2F",
        "Sec-Fetch-Mode": "navigate",
        "Accept": "text/html",
      },
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("https://auth.example.com");
  });
});

describe("/healthz", () => {
  test("returns 200 ok", async () => {
    const res = await app.request("/healthz");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});
