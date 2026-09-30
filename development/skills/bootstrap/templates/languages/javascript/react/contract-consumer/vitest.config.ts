import { configDefaults, defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

// Vitest config — CONTRACT-CONSUMER + REACT variant (development-react #957).
// Supersedes the contract-consumer vitest.config.ts in a React app that consumes
// an OpenAPI contract: every consumer layer is kept (MSW started first via
// setupFiles, so the whole suite runs with no backend, and the generated client
// excluded from coverage), PLUS a jsdom environment and the testing-library setup
// module. It merges OVER the app's own vite.config.ts because Vitest gives
// vitest.config.ts priority over vite.config.ts — without the merge,
// @vitejs/plugin-react would not apply under test. Installed by
// /development:bootstrap (§3k.5).
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: "jsdom",
      // tests/e2e/ holds the Playwright smoke specs (#1946), which Playwright runs in a real
      // browser — never Vitest, whose default include would otherwise collect *.spec.ts.
      exclude: [...configDefaults.exclude, "tests/e2e/**"],
      setupFiles: ["./src/test/msw-setup.ts", "./src/test/setup.ts"],
      coverage: {
        provider: "v8",
        reporter: ["text", "lcov"],
        exclude: ["src/api/generated/**"],
      },
    },
  }),
);
