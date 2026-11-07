import { cloudflare } from "@cloudflare/vite-plugin";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig(() => {
  const isTestRun = process.env.VITEST === "true";

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
