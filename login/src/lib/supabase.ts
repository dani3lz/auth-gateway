import { createClient } from "@supabase/supabase-js";
import { CookieStorage } from "./cookie-storage";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
// Optional. Empty/unset → host-only cookie (recommended when the login
// page and the protected app share an origin, e.g. /auth on the same host).
const cookieDomain = (import.meta.env.VITE_COOKIE_DOMAIN as string) || "";

if (!url || !anonKey) {
  throw new Error("VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are required");
}

export const supabase = createClient(url, anonKey, {
  auth: {
    storage: new CookieStorage({ domain: cookieDomain }),
    storageKey: "sb-access-token",
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
    // Implicit flow: Supabase returns the access_token in the URL fragment
    // directly, no code-exchange round-trip. PKCE was failing because the
    // code-verifier cookie set on /auth/* during signInWithOAuth wasn't
    // reliably retrievable on the OAuth callback URL.
    flowType: "implicit",
  },
});
