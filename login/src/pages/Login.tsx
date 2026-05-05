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

function getRedirect(): string {
  const params = new URLSearchParams(window.location.search);
  const rd = params.get("rd");
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
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!mounted) return;
      if (session) window.location.replace(getRedirect());
      else setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_IN") window.location.replace(getRedirect());
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
            // After Google OAuth, return to the same /auth/ page (with rd preserved
            // if present) so onAuthStateChange("SIGNED_IN") fires and we redirect
            // to the protected app.
            window.location.origin + window.location.pathname + window.location.search
          }
        />
      </div>
    </div>
  );
}
