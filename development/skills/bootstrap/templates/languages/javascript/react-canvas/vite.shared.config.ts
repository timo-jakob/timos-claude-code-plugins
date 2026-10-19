import { defineConfig } from "vite";

// The shared-dependency build (#1939). Concurrently mounted widgets import react,
// react/jsx-runtime, react-dom and react-dom/client as bare specifiers; the inline
// import map in index.html resolves each to /shared/<name>.js, built here into
// public/shared/ so the dev server and the production build serve the same paths.
// One multi-entry build shares a single React chunk, so every widget runs on the
// one React instance the shell's own image pins. public/shared/ is gitignored.
export default defineConfig({
  publicDir: false,
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    outDir: "public/shared",
    emptyOutDir: true,
    lib: {
      entry: {
        react: "src/canvas/shared/react.ts",
        "react-jsx-runtime": "src/canvas/shared/react-jsx-runtime.ts",
        "react-dom": "src/canvas/shared/react-dom.ts",
        "react-dom-client": "src/canvas/shared/react-dom-client.ts",
      },
      formats: ["es"],
      fileName: (_format, name) => `${name}.js`,
    },
  },
});
