import { createClient } from "@supabase/supabase-js";
import { CookieStorage } from "./cookie-storage";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
const cookieDomain = import.meta.env.VITE_COOKIE_DOMAIN as string;

if (!url || !anonKey || !cookieDomain) {
  throw new Error(
    "VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY and VITE_COOKIE_DOMAIN are required",
  );
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
