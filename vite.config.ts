import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// Each page is built into one self-contained HTML file: it works from any
// static host, a file:// URL, or inside a sandboxed frame. PAGE=classic builds
// the earlier generator and play page next to the designer.
const classic = process.env.PAGE === "classic";
export default defineConfig({
  root: "web",
  base: "./",
  plugins: [viteSingleFile()],
  build: {
    outDir: "../dist",
    emptyOutDir: !classic,
    rollupOptions: { input: classic ? "web/classic.html" : "web/index.html" },
  },
});
