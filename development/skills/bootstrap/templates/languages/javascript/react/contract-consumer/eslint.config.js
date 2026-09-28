// Flat ESLint config — CONTRACT-CONSUMER + REACT variant (development-react #957).
// Supersedes the contract-consumer eslint.config.js in a React app that consumes
// an OpenAPI contract: every consumer layer is kept (the anti-corruption boundary
// rule and the consumer deprecation surface, #727/#707), PLUS the React layers a
// create-vite react-ts app lints with — the rules of hooks, the react-refresh
// fast-refresh boundary and browser globals. Prettier owns formatting
// (.prettierrc.json); ESLint owns lint. Installed by /development:bootstrap (§3k.5).
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
  // Consumer deprecation surface (#707), SCOPED to application source. Typed
  // linting is REQUIRED by @typescript-eslint/no-deprecated (it reads the
  // @deprecated JSDoc the generated client carries), but it is deliberately NOT
  // applied to the root config files (eslint.config.js / vitest.config.ts /
  // orval.config.ts): the base tsconfig's `include: ["src/**/*"]` doesn't cover
  // them, so a repo-wide `projectService` would error "file not found by the
  // project service" on this very file. All call sites of the generated client
  // live under src/, so scoping here loses no coverage.
  {
    files: ["src/**/*.ts", "src/**/*.tsx"],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // Warn at every call site of a deprecated operation. NOTE: the bootstrapped
      // pre-commit eslint hook runs `--max-warnings=0`, so this gates commits
      // touching a deprecated call site — deliberate migration pressure the moment
      // a Renovate spec bump lands (same as `no-explicit-any: "warn"` in this
      // stack). A team wanting it advisory-only relaxes the hook's max-warnings.
      "@typescript-eslint/no-deprecated": "warn",
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
  { ignores: ["dist/", "build/", "coverage/", "node_modules/", "src/api/generated/"] },
);
