// Testing-library setup for a React app (development-react #957), registered via
// `setupFiles` in vitest.config.ts. It adds the jest-dom matchers
// (`toBeInTheDocument`, `toHaveTextContent`, …) to Vitest's `expect`, and unmounts
// whatever each test rendered — testing-library only cleans up automatically when
// Vitest `globals` are on, which the family's config leaves off.
//
// It also registers the family-owned `toHaveNoViolations` matcher (#1946), built
// on bare `axe-core` rather than a wrapper package (`vitest-axe`, `jest-axe`):
// `expect(await axe.run(container)).toHaveNoViolations()`. The a11y canary
// (src/test/a11y-canary.test.tsx) proves the matcher is wired.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import type { AxeResults } from "axe-core";
import { afterEach, expect } from "vitest";

afterEach(() => cleanup());

expect.extend({
  toHaveNoViolations(results: AxeResults) {
    const { violations } = results;
    const listed = violations.map((v) => `  ${v.id} (${v.impact ?? "n/a"}): ${v.help} — ${v.nodes.length} node(s)`);
    return {
      pass: violations.length === 0,
      message: () =>
        this.isNot
          ? "expected axe to report at least one violation, but it reported none"
          : `expected no axe violations, got ${violations.length}:\n${listed.join("\n")}`,
    };
  },
});

// Every declaration of Vitest's `Matchers` must repeat its type parameters, so `T`
// (the received value's type) is declared here even though this matcher ignores it.
declare module "vitest" {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  interface Matchers<R, T> {
    toHaveNoViolations: () => R;
  }
}
