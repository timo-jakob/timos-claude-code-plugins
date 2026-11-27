/// <reference types="node" />
// The axe gate's shared rules (#3018), read by the `toHaveNoViolations` matcher in
// src/test/setup.ts and by the Playwright scan in tests/e2e/default-view.spec.ts:
//
// - the tag set: only violations of rules tagged WCAG 2.0/2.1/2.2 A or AA count,
//   so axe's best-practice rules are not part of the gate;
// - the mode, read from the repo's committed ui-gates.json (`"a11y": "warn" | "block"`).
//   A missing file or key means `block`; any other value fails the run;
// - the report: every counted violation is appended to a11y-report.jsonl, which
//   scripts/a11y-report.mjs turns into PR annotations and the job summary's count.
//
// Change the mode with a one-line edit to ui-gates.json, never here.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export const WCAG_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"] as const;

export type A11yMode = "warn" | "block";

export interface A11yGateOptions {
  // Force a mode instead of the repo's: the a11y canary forces `block`.
  mode?: A11yMode;
  // `false` keeps the scan out of the report: the canary's deliberate violation is never counted.
  report?: boolean;
}

// The parts of an axe violation the gate reads, so both axe-core and @axe-core/playwright results fit.
export interface GateViolation {
  id: string;
  impact?: string | null;
  help: string;
  helpUrl?: string;
  tags: string[];
  nodes: { target: unknown[] }[];
}

// Vitest and Playwright both run from the app root, where ui-gates.json lives. (Under
// jsdom, import.meta.url is not a file URL, so the module cannot locate the root itself.)
const gatesFile = resolve(process.cwd(), "ui-gates.json");
const reportFile = resolve(process.cwd(), "a11y-report.jsonl");

export function readA11yMode(): A11yMode {
  if (!existsSync(gatesFile)) return "block";
  const allowed = 'the "a11y" key in ui-gates.json must be "warn" or "block"';
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(gatesFile, "utf8"));
  } catch {
    throw new Error(`ui-gates.json is not valid JSON: ${allowed}`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`ui-gates.json must hold a JSON object: ${allowed}`);
  }
  const value = (parsed as Record<string, unknown>).a11y;
  if (value === undefined) return "block";
  if (value === "warn" || value === "block") return value;
  throw new Error(`${allowed}, got ${JSON.stringify(value)}`);
}

export function wcagViolations<V extends GateViolation>(violations: V[]): V[] {
  return violations.filter((v) => v.tags.some((tag) => (WCAG_TAGS as readonly string[]).includes(tag)));
}

// axe tags each rule with its success criteria as `wcag<digits>`: wcag412 is 4.1.2, wcag1410 is 1.4.10.
export function successCriteria(tags: string[]): string {
  const criteria = tags.flatMap((tag) => {
    const m = /^wcag(\d)(\d)(\d+)$/.exec(tag);
    return m ? [`${m[1]}.${m[2]}.${m[3]}`] : [];
  });
  return criteria.length > 0 ? criteria.join(", ") : "n/a";
}

export function selectorOf(node: { target: unknown[] }): string {
  return node.target.map((part) => (Array.isArray(part) ? part.join(" >>> ") : String(part))).join(" ");
}

export function describeViolations(violations: GateViolation[]): string {
  const lines = violations.flatMap((v) =>
    v.nodes.map((n) => `  ${v.id} (WCAG ${successCriteria(v.tags)}): ${v.help} — ${selectorOf(n)}`),
  );
  return `${violations.length} WCAG violation(s):\n${lines.join("\n")}`;
}

// One JSON line per violating element. Test workers append concurrently, one write per line.
export function recordViolations(violations: GateViolation[], source: string, test: string, mode: A11yMode): void {
  for (const v of violations) {
    for (const node of v.nodes) {
      const record = {
        source,
        test,
        mode,
        rule: v.id,
        selector: selectorOf(node),
        criteria: successCriteria(v.tags),
        impact: v.impact ?? "n/a",
        help: v.help,
        helpUrl: v.helpUrl ?? "",
      };
      appendFileSync(reportFile, `${JSON.stringify(record)}\n`);
    }
  }
}
