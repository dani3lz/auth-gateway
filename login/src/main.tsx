import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

// Capture URL state SYNCHRONOUSLY before any module/library can mutate it.
// supabase-js's detectSessionInUrl removes #access_token from the URL after
// parsing, so by the time React mounts the fragment is gone — we want to see
// what was actually delivered.
// eslint-disable-next-line no-console
console.log("[auth-init] href:", window.location.href);
// eslint-disable-next-line no-console
console.log("[auth-init] hash:", window.location.hash || "(empty)");
// eslint-disable-next-line no-console
console.log("[auth-init] search:", window.location.search || "(empty)");

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
