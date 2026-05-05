import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!url || !anonKey) {
  throw new Error("VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are required");
}

export const supabase = createClient(url, anonKey, {
  auth: {
    // Use the default localStorage adapter — the full session JSON (with user
    // metadata + provider tokens) can exceed 4KB and would be rejected if
    // crammed into a cookie. The JWT-only cookie that the forward-auth
    // validator reads is written separately by Login.tsx on SIGNED_IN.
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
    flowType: "implicit",
  },
});
