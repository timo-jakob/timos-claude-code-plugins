// Testing-library setup for a React app (development-react #957), registered via
// `setupFiles` in vitest.config.ts. It adds the jest-dom matchers
// (`toBeInTheDocument`, `toHaveTextContent`, …) to Vitest's `expect`, and unmounts
// whatever each test rendered — testing-library only cleans up automatically when
// Vitest `globals` are on, which the family's config leaves off.
//
// It also registers the family-owned `toHaveNoViolations` matcher (#1946), built
// on bare `axe-core` rather than a wrapper package (`vitest-axe`, `jest-axe`):
// `expect(await axe.run(container)).toHaveNoViolations()`. The a11y canary
// (src/test/a11y-canary.test.tsx) proves the matcher is wired. The matcher counts
// only WCAG 2.2 A/AA violations and follows the repo's mode in ui-gates.json (#3018):
// `block` fails the test, `warn` reports the violation and passes. The tag set, the
// mode and the report live in src/test/a11y-gate.ts.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import type { AxeResults } from "axe-core";
import { afterEach, expect } from "vitest";
import { type A11yGateOptions, describeViolations, readA11yMode, recordViolations, wcagViolations } from "./a11y-gate";

// Read once per test file: an a11y value other than warn or block fails every test file.
const repoMode = readA11yMode();

afterEach(() => cleanup());

expect.extend({
  toHaveNoViolations(results: AxeResults, options: A11yGateOptions = {}) {
    const mode = options.mode ?? repoMode;
    const violations = wcagViolations(results.violations);
    if (options.report !== false) {
      recordViolations(violations, "vitest", this.currentTestName ?? "", mode);
    }
    if (mode === "warn" && violations.length > 0) {
      console.warn(`a11y (warn mode): ${describeViolations(violations)}`);
    }
    return {
      pass: mode === "warn" || violations.length === 0,
      message: () =>
        this.isNot
          ? "expected axe to report at least one WCAG violation, but it reported none"
          : `expected no axe violations, got ${describeViolations(violations)}`,
    };
  },
});

// Every declaration of Vitest's `Matchers` must repeat its type parameters, so `T`
// (the received value's type) is declared here even though this matcher ignores it.
declare module "vitest" {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  interface Matchers<R, T> {
    toHaveNoViolations: (options?: A11yGateOptions) => R;
  }
}
