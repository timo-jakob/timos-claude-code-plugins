import { fileURLToPath } from "node:url";
import { defineConfig, devices } from "@playwright/test";

// Playwright config for the React app's browser smoke gate (#1946), reported by
// the `e2e (playwright)` job of .github/workflows/webui-quality.yml. It serves the
// PRODUCTION build with `vite preview` on port 4173, so run `npm run build` first.
// Run it with `npx playwright test -c tests/e2e/playwright.config.ts`.
//
// This harness lives in tests/e2e/ and never writes into tests/acceptance/web/,
// which is the deployed-UI acceptance spine (#702). Both vitest.config.ts
// variants exclude tests/e2e/**, so test-and-coverage never collects these specs.
const appRoot = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  testDir: ".",
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: "http://localhost:4173",
    trace: "on-first-retry",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command: "npm run preview -- --port 4173 --strictPort",
    cwd: appRoot,
    url: "http://localhost:4173",
    reuseExistingServer: !process.env.CI,
  },
});
