import { cloudflare } from "@cloudflare/vite-plugin";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { validateProductionAuthUrl } from "./scripts/production-auth-url.ts";

export default defineConfig(() => {
  const isTestRun = process.env.VITEST === "true";
  if (!isTestRun && process.env.CLOUDFLARE_ENV === "production") {
    validateProductionAuthUrl(process.env.VITE_NEON_AUTH_URL);
  }

  return {
    plugins: isTestRun
      ? [react()]
      : [react(), cloudflare({ viteEnvironment: { name: "worker" } })],
    test: {
      environment: "jsdom",
      globals: true,
      setupFiles: ["./tests/setup.ts"]
    }
  };
});
