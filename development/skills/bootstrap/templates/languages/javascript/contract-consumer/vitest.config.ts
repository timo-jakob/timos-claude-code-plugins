import { defineConfig } from "vitest/config";

// Vitest config — CONTRACT-CONSUMER variant (development-javascript #727). This
// supersedes the base languages/javascript/vitest.config.ts when the repo
// consumes an OpenAPI contract: it is the base config PLUS MSW wired in by
// default via setupFiles, so the whole suite runs with no backend. The
// generated MSW handlers are exempt from coverage (they are generated code).
export default defineConfig({
  test: {
    setupFiles: ["./src/test/msw-setup.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      exclude: ["src/api/generated/**"],
    },
  },
});
