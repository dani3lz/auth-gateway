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
