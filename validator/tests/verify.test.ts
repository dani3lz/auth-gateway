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
      email: "user@example.com",
      role: "authenticated",
    });
    const result = await verifyJwt(token, SECRET);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.sub).toBe("user-1");
      expect(result.claims.email).toBe("user@example.com");
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
