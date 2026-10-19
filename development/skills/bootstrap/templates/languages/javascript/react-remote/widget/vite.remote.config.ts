import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The remote build (#1125). src/remote/entry.tsx becomes dist/remote.js, the
// stable, unhashed entry path the gateway serves; every other chunk and asset
// lands under dist/assets/ with a content hash in its name, so it can be cached
// forever. A widget shares the shell's React: the four specifiers below stay bare
// imports, which the canvas's import map resolves to /shared/<name>.js (#1939).
// vite.config.ts stays the app's own, so the remote still runs as a dev app.
export default defineConfig({
  plugins: [react()],
  publicDir: false,
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    lib: {
      entry: "src/remote/entry.tsx",
      formats: ["es"],
      fileName: () => "remote.js",
    },
    rollupOptions: {
      external: ["react", "react/jsx-runtime", "react-dom", "react-dom/client"],
      output: {
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
});
