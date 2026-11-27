// Accessibility report (#3018): turns the axe gate's a11y-report.jsonl into one PR
// annotation per violation and a job-summary table with the violation count.
// The workflows run it after the tests in `test-and-coverage` and `e2e (playwright)`,
// in both modes, even when the tests failed. It only reports: in `block` mode the
// test itself fails on a violation. It exits 0 whatever it finds.
//
// Usage: node scripts/a11y-report.mjs "<label>"
import console from "node:console";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import process from "node:process";

const label = process.argv[2] ?? "axe";
const reportFile = "a11y-report.jsonl";

const readMode = () => {
  try {
    const value = JSON.parse(readFileSync("ui-gates.json", "utf8")).a11y;
    return value === undefined ? "block" : String(value);
  } catch {
    return existsSync("ui-gates.json") ? "unreadable" : "block";
  }
};

// A Playwright retry scans the same page again, so a repeated element is counted once.
// The test file is part of the key: copies of one spec share their test title.
const records = new Map();
let scans = 0;
if (existsSync(reportFile)) {
  for (const line of readFileSync(reportFile, "utf8").split("\n")) {
    if (line.trim() === "") continue;
    try {
      const r = JSON.parse(line);
      if (r.kind === "scan") {
        scans += 1;
        continue;
      }
      records.set([r.source, r.file, r.test, r.rule, r.selector].join("\u0000"), r);
    } catch {
      console.log(`::warning title=a11y report::skipped an unreadable line in ${reportFile}`);
    }
  }
}

const escapeData = (s) => String(s).replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
const escapeProperty = (s) => escapeData(s).replaceAll(":", "%3A").replaceAll(",", "%2C");
const cell = (s) => String(s).replaceAll("|", "\\|").replaceAll("\n", " ");

const mode = readMode();
const rows = [...records.values()];
for (const r of rows) {
  const title = escapeProperty(`axe ${r.rule} (WCAG ${r.criteria})`);
  console.log(`::warning title=${title}::${escapeData(`${r.selector}: ${r.help} [${r.file}: ${r.test}]`)}`);
}

const summary = [
  `### Accessibility (axe, WCAG 2.2 AA): ${label}`,
  "",
  scans === 0 && rows.length === 0
    ? `**No axe scan ran**, mode \`${mode}\` (ui-gates.json).`
    : `**${rows.length} violation(s)**, mode \`${mode}\` (ui-gates.json).`,
  "",
];
if (rows.length > 0) {
  summary.push("| Rule | Selector | WCAG SC | Impact | File | Test |", "| --- | --- | --- | --- | --- | --- |");
  for (const r of rows) {
    const cells = [r.rule, `\`${r.selector}\``, r.criteria, r.impact, r.file, r.test].map(cell);
    summary.push(`| ${cells.join(" | ")} |`);
  }
}
const text = `${summary.join("\n")}\n`;
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, text);
} else {
  console.log(text);
}
