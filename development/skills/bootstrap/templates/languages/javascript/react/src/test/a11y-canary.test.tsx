import { render } from "@testing-library/react";
import axe from "axe-core";
import { describe, expect, it } from "vitest";

// The a11y canary (#1946). It proves the axe gate bites without shipping a real
// violation: a known-bad render MUST report at least one violation, so if the
// `toHaveNoViolations` matcher (src/test/setup.ts) is not wired, or axe stops
// seeing the DOM, this file goes red inside test-and-coverage. Copy the second
// case's shape into a component's own test to gate that component.
//
// The first case does not follow ui-gates.json (#3018): it forces `block`, so it
// stays red-on-unwired in `warn` too, and it never reports, so its deliberate
// violation is never annotated or counted. The second case is the shape to copy: it
// follows the repo's mode.
describe("a11y canary", () => {
  it("reports at least one axe violation for an <img> with no alt text", async () => {
    const { container } = render(<img src="/logo.svg" />);
    const results = await axe.run(container);
    expect(results.violations.length).toBeGreaterThanOrEqual(1);
    expect(results.violations.map((v) => v.id)).toContain("image-alt");
    expect(results).not.toHaveNoViolations({ mode: "block", report: false });
  });

  it("passes toHaveNoViolations for the same image with alt text", async () => {
    const { container } = render(<img src="/logo.svg" alt="Company logo" />);
    expect(await axe.run(container)).toHaveNoViolations();
  });
});
