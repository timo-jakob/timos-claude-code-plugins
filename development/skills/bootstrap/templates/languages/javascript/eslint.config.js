// Flat ESLint config (ESLint 9+/10) — the blessed JS/TS lint layer, replacing
// the legacy .eslintrc.json. Prettier owns formatting (see .prettierrc.json);
// ESLint owns lint. Installed by /development:bootstrap (#729).
import js from "@eslint/js";
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
  { ignores: ["dist/", "build/", "coverage/", "node_modules/"] },
);
