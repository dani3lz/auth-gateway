import { Login } from "./pages/Login";
import { Logout } from "./pages/Logout";

/**
 * Tiny path-based router — no need for react-router for two routes.
 *   /logout  → clear session, redirect to ?rd= or default
 *   anything else → login form (cleared by gateway redirects with ?rd=)
 */
export function App() {
  if (typeof window !== "undefined" && window.location.pathname === "/logout") {
    return <Logout />;
  }
  return <Login />;
}
