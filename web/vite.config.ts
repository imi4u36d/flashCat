import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 会把 web/dist 当作前端产物；dev 走 1420，与 src-tauri 的 devUrl 对齐。
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { outDir: "dist", target: "safari17" },
});
