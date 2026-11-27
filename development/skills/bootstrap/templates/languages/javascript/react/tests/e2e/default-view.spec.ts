import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";
import {
  WCAG_TAGS,
  describeViolations,
  readA11yMode,
  recordViolations,
  wcagViolations,
} from "../../src/test/a11y-gate";

// Default-view test (#3018): every view opens on a useful default and shows content
// without any interaction. Copy this file once per view and change the route, the
// mocked responses and nothing else. Bootstrap renders it only when it is absent,
// so it is yours to edit.
//
// An a11y value in ui-gates.json other than warn or block fails this file on load.
const mode = readA11yMode();

test("the default view shows content without any interaction", async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  // Where a view's data is mocked: register every response the view fetches BEFORE
  // navigating, so the first render already sees it.
  await page.route("**/api/**", (route) => route.fulfill({ json: { items: [] } }));

  await page.goto("/");

  // No click, key press, hover or scroll: the view must show content as it opens.
  const content = page.locator("#root *").filter({ hasText: /\S/, visible: true });
  await expect(content.first()).toBeVisible();
  expect(pageErrors).toEqual([]);

  const results = await new AxeBuilder({ page }).withTags([...WCAG_TAGS]).analyze();
  const violations = wcagViolations(results.violations);
  recordViolations(violations, "playwright", test.info().file, test.info().title, mode);
  if (mode === "block") {
    expect(violations, describeViolations(violations)).toEqual([]);
  }
});
