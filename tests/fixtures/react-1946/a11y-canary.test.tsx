import { render } from "@testing-library/react";
import axe from "axe-core";
import { describe, expect, it } from "vitest";

// The a11y canary (#1946). It proves the axe gate bites without shipping a real
// violation: a known-bad render MUST report at least one violation, so if the
// `toHaveNoViolations` matcher (src/test/setup.ts) is not wired, or axe stops
// seeing the DOM, this file goes red inside test-and-coverage. Copy the second
// case's shape into a component's own test to gate that component.
describe("a11y canary", () => {
  it("reports at least one axe violation for an <img> with no alt text", async () => {
    const { container } = render(<img src="/logo.svg" />);
    const results = await axe.run(container);
    expect(results.violations.length).toBeGreaterThanOrEqual(1);
    expect(results.violations.map((v) => v.id)).toContain("image-alt");
    expect(results).not.toHaveNoViolations();
  });

  it("passes toHaveNoViolations for the same image with alt text", async () => {
    const { container } = render(<img src="/logo.svg" alt="Company logo" />);
    expect(await axe.run(container)).toHaveNoViolations();
  });
});
