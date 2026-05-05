import { Auth } from "@supabase/auth-ui-react";
import { ThemeSupa } from "@supabase/auth-ui-shared";
import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

const APP_NAME = (import.meta.env.VITE_APP_NAME as string) || "Auth Gateway";
const DEFAULT_REDIRECT = (import.meta.env.VITE_DEFAULT_REDIRECT as string) || "/";
// Allowed parent for the `?rd=` redirect target. Only used when the auth UI
// lives on a different subdomain than the protected app — for the same-origin
// path-based deployment this should remain empty.
const PARENT_DOMAIN = (import.meta.env.VITE_PARENT_DOMAIN as string) || "";

// Stash rd in sessionStorage when the page first loads so we don't have to
// pass it through the OAuth round-trip. Some Supabase configurations reject
// or strip redirect URLs that have their own query strings.
function stashRd() {
  const rd = new URLSearchParams(window.location.search).get("rd");
  if (rd) {
    try { sessionStorage.setItem("auth-gateway-rd", rd); } catch { /* ignore */ }
  }
}
stashRd();

function getRedirect(): string {
  let rd = new URLSearchParams(window.location.search).get("rd");
  if (!rd) {
    try { rd = sessionStorage.getItem("auth-gateway-rd"); } catch { /* ignore */ }
  }
  if (!rd) return DEFAULT_REDIRECT;
  // Same-origin paths ("/...") are always safe.
  if (rd.startsWith("/") && !rd.startsWith("//")) return rd;
  try {
    const u = new URL(rd, window.location.origin);
    if (u.origin === window.location.origin) return rd;
    if (PARENT_DOMAIN) {
      const dot = `.${PARENT_DOMAIN}`;
      if (u.hostname === PARENT_DOMAIN || u.hostname.endsWith(dot)) return rd;
    }
  } catch {
    /* fall through */
  }
  return DEFAULT_REDIRECT;
}

export function Login() {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let mounted = true;
    // eslint-disable-next-line no-console
    console.log("[auth] mount", { url: window.location.href, hash: window.location.hash, search: window.location.search });
    supabase.auth.getSession().then(({ data: { session }, error }) => {
      // eslint-disable-next-line no-console
      console.log("[auth] getSession result:", { session: !!session, error });
      if (!mounted) return;
      if (session) {
        // eslint-disable-next-line no-console
        console.log("[auth] redirecting to:", getRedirect());
        window.location.replace(getRedirect());
      } else {
        setReady(true);
      }
    });
    const writeCookie = (session: { access_token?: string; expires_at?: number } | null) => {
      if (!session?.access_token) return;
      // Store only the JWT (the validator's only need). The full session is
      // in localStorage via supabase-js. This avoids the 4KB cookie size cap
      // — a Google OAuth session JSON balloons past 4KB once URL-encoded.
      const expires = typeof session.expires_at === "number"
        ? `Expires=${new Date(session.expires_at * 1000).toUTCString()}`
        : "Max-Age=2592000";
      const parts = [
        "sb-access-token=" + encodeURIComponent(session.access_token),
        "Path=/",
        "SameSite=Lax",
        "Secure",
        expires,
      ];
      document.cookie = parts.join("; ");
      // eslint-disable-next-line no-console
      console.log("[auth] cookie written, size:", session.access_token.length, "bytes; ok?", document.cookie.includes("sb-access-token"));
    };

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      // eslint-disable-next-line no-console
      console.log("[auth] onAuthStateChange:", event, "session?", !!session);
      if (event === "SIGNED_IN" || event === "TOKEN_REFRESHED") {
        writeCookie(session);
        if (event === "SIGNED_IN") window.location.replace(getRedirect());
      }
    });
    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  if (!ready) return null;

  return (
    <div className="page">
      <div className="card">
        <h1 className="title">Sign in to {APP_NAME}</h1>
        <Auth
          supabaseClient={supabase}
          appearance={{
            theme: ThemeSupa,
            variables: {
              default: {
                colors: {
                  brand: "#3ECF8E",
                  brandAccent: "#2EB57A",
                  inputBackground: "#1F1F1F",
                  inputBorder: "#2F2F2F",
                  inputText: "#EDEDED",
                  defaultButtonBackground: "#3ECF8E",
                  defaultButtonBackgroundHover: "#66E0AB",
                },
                radii: { borderRadiusButton: "6px", inputBorderRadius: "6px" },
                fonts: { bodyFontFamily: "Inter, sans-serif" },
              },
            },
          }}
          providers={["google"]}
          onlyThirdPartyProviders={true}
          theme="dark"
          showLinks={false}
          redirectTo={
            // Plain origin+path (no query) — Supabase's URI allow-list/glob
            // matching is finicky with query strings. rd is stashed in
            // sessionStorage by stashRd() before this render.
            window.location.origin + window.location.pathname
          }
        />
      </div>
    </div>
  );
}
