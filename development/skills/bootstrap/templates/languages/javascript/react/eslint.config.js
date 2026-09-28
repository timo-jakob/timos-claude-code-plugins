// Flat ESLint config — REACT variant (development-react #957). Supersedes the base
// languages/javascript/eslint.config.js in a React app: the base config PLUS the
// React layers a create-vite react-ts app lints with — the rules of hooks, the
// react-refresh fast-refresh boundary and browser globals. Prettier owns
// formatting (.prettierrc.json); ESLint owns lint. Installed by
// /development:bootstrap (§3k.5).
import js from "@eslint/js";
import globals from "globals";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import tseslint from "typescript-eslint";

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: { ecmaVersion: 2023, sourceType: "module" },
    rules: {
      "no-unused-vars": "off",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      "@typescript-eslint/no-explicit-any": "warn",
    },
  },
  // React layer. The rules of hooks are an error: a conditional or looped hook
  // call is a real bug, not a style choice. A component module should export
  // only components, so Vite's fast refresh can hot-swap it without losing state.
  {
    files: ["**/*.ts", "**/*.tsx"],
    languageOptions: { globals: globals.browser },
    plugins: { "react-hooks": reactHooks, "react-refresh": reactRefresh },
    rules: {
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
      "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
    },
  },
  { ignores: ["dist/", "build/", "coverage/", "node_modules/"] },
);
