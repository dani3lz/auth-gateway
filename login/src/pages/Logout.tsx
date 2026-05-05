import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

const DEFAULT_REDIRECT = (import.meta.env.VITE_DEFAULT_REDIRECT as string) || "/";
const COOKIE_DOMAIN = (import.meta.env.VITE_COOKIE_DOMAIN as string) || "";

function getRedirectAfterLogout(): string {
  const params = new URLSearchParams(window.location.search);
  return params.get("rd") || DEFAULT_REDIRECT;
}

/**
 * Clears the Supabase session everywhere we know about it:
 *   1. supabase.auth.signOut() — invalidates the refresh token server-side
 *   2. Manually expire the cookie under the parent-domain scope (the
 *      CookieStorage adapter writes Domain=.<COOKIE_DOMAIN>; supabase-js'
 *      built-in clear path goes through `removeItem` which also expires it,
 *      but we belt-and-braces in case the call fails).
 *   3. Wipe localStorage too — older sessions or accidental fallbacks live
 *      there.
 *
 * Then redirect to the protected app, which will re-trigger the gateway flow.
 */
export function Logout() {
  const [done, setDone] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        await supabase.auth.signOut({ scope: "global" });
      } catch {
        /* ignore — we still want to clear local state */
      }
      // Force-expire the cookie even if the SDK didn't.
      const domains = new Set([COOKIE_DOMAIN, "." + window.location.hostname, ""].filter(Boolean));
      for (const d of domains) {
        const dom = d ? `Domain=${d};` : "";
        document.cookie = `sb-access-token=; ${dom} Path=/; Max-Age=0; SameSite=Lax`;
      }
      try { localStorage.clear(); } catch { /* sandboxed iframe etc */ }
      try { sessionStorage.clear(); } catch { /* same */ }
      setDone(true);
      window.location.replace(getRedirectAfterLogout());
    })();
  }, []);

  return (
    <div className="page">
      <div className="card">
        <h1 className="title">{done ? "Signed out" : "Signing out…"}</h1>
      </div>
    </div>
  );
}
