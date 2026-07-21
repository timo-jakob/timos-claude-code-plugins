// Flat ESLint config — CONTRACT-CONSUMER variant (development-javascript
// #727/#707). Supersedes the base languages/javascript/eslint.config.js when the
// repo consumes an OpenAPI contract: base config PLUS the anti-corruption
// boundary rule AND the consumer deprecation surface (#707). Prettier owns
// formatting (.prettierrc.json); ESLint owns lint.
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
  { ignores: ["dist/", "build/", "coverage/", "node_modules/", "src/api/generated/"] },
);
