import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  // Served from /auth/* on the protected app's origin (e.g. sb.example.com/auth/).
  base: "/auth/",
  plugins: [react()],
  server: { host: "0.0.0.0", port: 5173 },
  test: {
    environment: "happy-dom",
    globals: true,
    setupFiles: ["src/test-setup.ts"],
    environmentOptions: {
      happyDOM: { url: "http://sub.example.com/" },
    },
  },
});
