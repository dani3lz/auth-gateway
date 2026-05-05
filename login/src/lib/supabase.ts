import { createClient } from "@supabase/supabase-js";
import { CookieStorage } from "./cookie-storage";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
const cookieDomain = (import.meta.env.VITE_COOKIE_DOMAIN as string) || ".soltrix.dev";

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
  },
});
