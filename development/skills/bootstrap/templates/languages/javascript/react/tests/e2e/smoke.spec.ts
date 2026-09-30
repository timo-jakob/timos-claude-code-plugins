import { expect, test } from "@playwright/test";

// Browser smoke test (#1946): the production build's root route loads in a real
// Chromium and React mounts something into #root, with no uncaught page error.
test("the root route renders the app", async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  await page.goto("/");

  await expect(page.locator("#root")).not.toBeEmpty();
  expect(pageErrors).toEqual([]);
});
