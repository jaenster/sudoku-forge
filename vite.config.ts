import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained index.html: works from any static host, a file:// URL,
// or inside a sandboxed frame.
export default defineConfig({
  root: "web",
  base: "./",
  plugins: [viteSingleFile()],
  build: { outDir: "../dist", emptyOutDir: true },
});
