import { Auth } from "@supabase/auth-ui-react";
import { ThemeSupa } from "@supabase/auth-ui-shared";
import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

const DEFAULT_REDIRECT =
  (import.meta.env.VITE_DEFAULT_REDIRECT as string) || "https://sb.soltrix.dev";

function getRedirect(): string {
  const params = new URLSearchParams(window.location.search);
  const rd = params.get("rd");
  if (!rd) return DEFAULT_REDIRECT;
  try {
    const u = new URL(rd);
    if (u.hostname.endsWith(".soltrix.dev") || u.hostname === "soltrix.dev") return rd;
  } catch { /* fall through */ }
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
        <h1 className="title">Sign in to Soltrix</h1>
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
          providers={[]}
          theme="dark"
          showLinks={true}
        />
      </div>
    </div>
  );
}
