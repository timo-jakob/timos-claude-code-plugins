// Sample test: exercises the ACL client against the generated MSW handlers with
// NO backend process running (MSW is started by src/test/msw-setup.ts via
// vitest `setupFiles`). This is the disjunct-testing guarantee made concrete —
// the frontend suite is green without the backend repo present.
//
// STARTER: after `npm run generate`, this test runs against the mock the spec
// implies. Keep asserting the ACL's domain shape (not the raw generated wire
// type) so the boundary stays under test.
import { expect, test } from "vitest";
import { fetchOrderSummaries } from "./index";

test("fetchOrderSummaries returns the ACL's domain shape (no backend running)", async () => {
  const summaries = await fetchOrderSummaries();
  expect(Array.isArray(summaries)).toBe(true);
  for (const summary of summaries) {
    // The ACL maps the generated wire type to { id: string, total: number };
    // app code depends on this shape, not on the generated schema.
    expect(typeof summary.id).toBe("string");
    expect(typeof summary.total).toBe("number");
  }
});
