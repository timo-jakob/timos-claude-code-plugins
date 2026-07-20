// Flat ESLint config — CONTRACT-CONSUMER variant (development-javascript #727).
// This supersedes the base languages/javascript/eslint.config.js when the repo
// consumes an OpenAPI contract: it is the base config PLUS the anti-corruption
// boundary rule. Prettier owns formatting (.prettierrc.json); ESLint owns lint.
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
  // ACL boundary: nothing may import the generated client except the two layers
  // that legitimately must — the hand-written ACL (src/api/**) and the MSW test
  // harness (src/test/**), which wires up the generated mock handlers and has no
  // ACL wrapper to route through. Everywhere else, a violation is an error, so
  // it fails CI, not just the editor.
  {
    files: ["**/*.ts", "**/*.tsx", "**/*.js", "**/*.jsx"],
    ignores: ["src/api/**", "src/test/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: ["**/api/generated", "**/api/generated/**"],
              message:
                "Import from the anti-corruption layer (src/api) instead of the generated client (src/api/generated).",
            },
          ],
        },
      ],
    },
  },
  { ignores: ["dist/", "build/", "coverage/", "node_modules/", "src/api/generated/"] },
);
