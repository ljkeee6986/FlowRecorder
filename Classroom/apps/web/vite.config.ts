import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  publicDir: "../../../AppIcon.iconset",
  server: {
    proxy: {
      "/api": "http://localhost:4100",
      "/socket.io": {
        target: "http://localhost:4100",
        ws: true
      }
    }
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.ts"
  }
});
