export interface CookieStorageOptions {
  /** Cookie Domain attribute. Empty string → host-only cookie (recommended
   *  when login + protected app share an origin). */
  domain?: string;
  secure?: boolean;
  sameSite?: "Lax" | "Strict" | "None";
  path?: string;
}

/**
 * A `Storage`-compatible adapter that persists Supabase auth state
 * to cookies. Use a parent-domain `domain` when login and protected
 * apps live on different subdomains; pass `""` for host-only when
 * they share an origin.
 *
 * Note: cookies set from JS cannot be HttpOnly. We accept this trade-off
 * because supabase-js needs to read the token client-side. The validator
 * still uses HS256 + JWT_SECRET to authenticate, so XSS leakage is the
 * only added risk relative to localStorage (which is also JS-readable).
 */
export class CookieStorage implements Storage {
  private readonly opts: Required<CookieStorageOptions>;

  constructor(opts: CookieStorageOptions = {}) {
    this.opts = {
      domain: opts.domain ?? "",
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
    const parts = [`${key}=${v}`, `Path=${this.opts.path}`, `SameSite=${this.opts.sameSite}`, "Max-Age=2592000"];
    if (this.opts.domain) parts.push(`Domain=${this.opts.domain}`);
    if (this.opts.secure) parts.push("Secure");
    document.cookie = parts.join("; ");
  }

  removeItem(key: string): void {
    const parts = [`${key}=`, `Path=${this.opts.path}`, "Max-Age=0"];
    if (this.opts.domain) parts.push(`Domain=${this.opts.domain}`);
    document.cookie = parts.join("; ");
  }
}
