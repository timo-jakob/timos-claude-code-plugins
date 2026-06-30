# Coverage safety signal redesign — region-scoped coverage gate

**Status:** design / spec (approved in brainstorming 2026-06-29). Anchors a new
family-wide epic that **supersedes #456**.

**Scope:** the maintenance pipeline's test-coverage gate and the
`*-coverage-improver` mechanism, across all three language plugins
(`development-python`, `development-java`, `development-swift`).

---

## Problem

The coverage machinery exists for exactly one purpose: to be a **safety net for
autonomous refactors**. The `*-coverage-improver` is spawned *only* during the
dispatcher's coverage pre-flight, to unblock a coverage-respecting finding
(SonarCloud / semgrep / file-bearing CodeQL) whose code an agent is about to
change. There is no standalone "raise coverage" goal.

Today the gate measures **whole-file** line coverage against a two-tier
**Floor (60%) / Required (80%)** threshold. This signal is too crude:

- A 40%-covered file is blocked from a safe refactor even when the *specific
  function* being changed is thoroughly tested.
- A 95%-covered file is waved through even when the *one function* being changed
  is the untested 5%.
- The Floor/Required split created the **#456 dead-end**: the improver
  bootstraps a from-zero class to the Floor (a whole PR cycle of machine time),
  but the triggering finding needs Required, so it escalates anyway — zero
  user-facing findings advanced.

The whole-file percentage is a poor proxy for the only question that matters:
**if this specific change is wrong, will a test catch it?**

## The model

Replace the whole-file threshold with **region coverage**, and collapse
Floor/Required into a **single Required threshold** (default 80%).

For each coverage-respecting finding, resolve its **enclosing region** — the
innermost *named* function/method whose line range contains the finding's line —
and gate on **that region's** coverage:

- **Region ≥ Required** → the change is protected; proceed straight to the fix.
  Whole-file % is irrelevant.
- **Region < Required** → spawn the improver **scoped to that one function**
  (target = Required), as its own PR; after it merges, the fix proceeds.

Two properties fall out of region-scoping for free:

1. **The Floor tier disappears.** It only existed as partial credit for the
   impossible "bootstrap a whole 0% class to 80% in one pass." A single function
   is small enough to reach 80% in one improver pass, so there is one target
   (Required) and no consolation tier.
2. **The #456 dead-end disappears structurally** — there is no longer a case
   where the improver "succeeds" (Floor) yet the finding still escalates
   (Required), because they are now the same number on the same small region.

**Residual risk (unchanged from today):** line coverage % cannot distinguish
"asserted" from "merely executed." Handled the same way as today — the
improver's existing "verify behaviour, no characterization tests, run the full
suite" contract, plus human / Approver review of its (now much smaller,
function-scoped) PR.

## Components & data flow

The enabling interface is a new **`regions`** array in the coverage payload.
The dispatcher asks it exactly one thing: *given (file, line), return the
enclosing region's pct, or null.* That keeps the dispatcher language-agnostic;
each parser fills `regions` however its tool allows.

```json
"coverage": {
  "by_module": { "Sources/App/FileStore.swift": 42.0 },   // kept — human summary only
  "regions": [
    { "file": "Sources/App/FileStore.swift", "name": "save(_:)",
      "start_line": 78, "end_line": 95, "pct": 40.0 }
  ],
  "measurement": { "reliable": true, "reason": "..." }
}
```

Four components change, per language:

1. **Coverage parsers** — emit `regions`:
   - **Java (`parse-jacoco.py`)** — JaCoCo XML already carries `<method>`
     elements with line numbers and per-method counters. Nearly free.
   - **Swift (`parse-swift-coverage.py`)** — `llvm-cov export` (full, not
     `-summary-only`) and `xccov` both carry per-function regions. Moderate.
   - **Python** — coverage.py reports per-*line* but not per-function; the
     parser maps line → function by reading the source via **AST** (precise
     per-function, not a line-window approximation). The heaviest of the three.
2. **Gather scripts** — call the extended parser; include `coverage.regions`.
3. **Dispatcher pre-flight** — for each coverage-respecting finding: line →
   region, gate region.pct vs Required → proceed or spawn the region-scoped
   improver.
4. **Improver agents** — `modules_to_improve` entries name a *function* + its
   file, target Required; the improver writes tests for that one function. The
   "verify behaviour, no characterization, full suite" contract is unchanged —
   only the scope narrows from file to function.

**Data flow:** `gather (run suite + coverage) → parser emits by_module + regions
→ payload → dispatcher maps finding.line → region → gate vs Required →
(region-scoped improver PR | fix) → planner → fix`.

## Edge cases & error handling

1. **Finding does not resolve to a function** (class-/file-level smell,
   import-line finding, `line: 0`, or an AST/parser gap) → **fall back to
   whole-file coverage** for that finding, gated on Required. For a genuinely
   file-level finding the *file* is the correct region. Documented; expected to
   be rare.
2. **Several findings in one under-covered region** → **one improver work-item
   per region**, not per finding. Covering `save(_:)` once unblocks every
   finding inside it.
3. **Coverage unreliable / unmeasured (#258)** → unchanged: withhold →
   escalate. If the measurement is not trustworthy, regions are not either.
4. **Improver cannot reach Required on the region in one pass** (hard-to-reach
   branches, external deps) → **escalate that region to a human; do not loop.**
   Findings in it stay blocked. Rare now that the unit is a single function, and
   there is no dead-end (no Floor consolation to "succeed" at).
5. **Greenfield / no tests anywhere** → every coverage-respecting finding's
   region is 0%, so each spawns a small region-scoped improver PR. Volume is
   bounded by the existing `--batch=N` (#53); each PR is small and meaningful
   (tests for exactly the functions being changed). Accepted.
6. **Function-detection ambiguity** (closures, nested functions, overloads) →
   the region is the **innermost enclosing *named* function** containing the
   line; a closure's lines attribute to its enclosing named function. One
   consistent rule across languages.
7. **The fix agent edits beyond the finding's region** → accepted residual: the
   gate is a pre-flight heuristic; the fix agent's own test run plus human /
   Approver review catch out-of-region damage. The gate does not try to predict
   the full diff (that was the rejected Approach B).

## Testing

The risk concentrates in the parsers' `regions` extraction + line → region
mapping, which is fully hermetic — so that is where the tests go:

- **Parser unit tests (per language)** — feed a canned raw report (JaCoCo XML /
  llvm-cov JSON / xccov JSON / coverage.py JSON) containing several functions →
  assert each `regions[]` entry (`name`, `start_line`, `end_line`, `pct`) **and**
  containment: a line inside `save(_:)` resolves to that region; a line in no
  function → `null` (→ file fallback). No toolchain needed.
- **Python AST mapping** — feed a source file + per-line coverage → assert each
  line maps to its innermost enclosing *named* function (nested funcs / closures
  included). The new-logic hotspot for Python.
- **Reliability (#258)** — extend existing withhold tests so an unreliable
  measurement yields no `regions` either.
- **Dispatcher pre-flight + improver scoping** — these are prompts, not
  unit-testable; verify end-to-end with `/development-claude-plugin:test`,
  checking the four behaviours: region ≥ Required → proceed; region < Required →
  region-scoped improver; no-region → file fallback; multiple findings in a
  region → one improver item.
- **Hermetic discipline preserved** — parser tests feed canned reports; the
  gather's live measurement path stays toolchain-gated (as today), so CI never
  needs the Swift / Java / Python toolchains.

## Rollout & reconciliation

This is family-wide (3 languages × 4 components) — too big for one PR, and not
Swift-specific. Therefore:

- **Its own epic**, anchored by this doc, that **supersedes #456** (the dead-end
  is resolved structurally; #456 closes into this epic). A peer of the language
  epics, not a child of the Swift epic #297 — the `regions` work touches Python
  and Java equally.
- **Sliced by language, each slice a full vertical** (parser `regions` → gather
  → dispatcher pre-flight → improver scoping → **user-facing docs**), in order:
  1. **Swift first** — freshest code, already in flight, proves the pattern
     end-to-end.
  2. **Java** — JaCoCo gives `regions` almost for free.
  3. **Python last** — needs the AST line → function work; do it once the
     pattern is proven.

**User-facing documentation (part of every slice).** The coverage gate is
described in several user-facing places that currently document the whole-file
Floor/Required model; each must be updated to the region-scoped model as part of
the slice that lands the behaviour (never after, never in a trailing PR):

- **`ARCHITECTURE.md`** — the coverage pre-flight / thresholds section and the
  v2 payload schema (the new `coverage.regions` field).
- **`README.md`** — any coverage description in the maintenance entry.
- **The dispatcher `SKILL.md` descriptions** and the `*-coverage-improver`
  agent descriptions (frontmatter + body) for the language the slice touches.
- The `feedback-coverage-human-driven` memory (see below) — internal, but the
  same "keep docs in step with behaviour" rule applies.

Reconciling the three in-flight artifacts:

- **PR #460 (Swift static-analysis triage, open):** **strip the coverage-policy
  change back out of it**, returning #460 to pure static-analysis triage (its
  real scope). The "Floor-only escalate" logic added there was a stop-gap for
  the old model and should not ride along in a triage PR. The new epic's Swift
  slice replaces the whole-file pre-flight properly.
- **The `feedback-coverage-human-driven` memory:** update it to this model as
  the epic's first step — coverage stays human-overseen (the improver's PR is
  reviewed), but the gate is region-scoped-to-Required, not whole-file
  Floor/escalate — so future sessions do not act on the stale rule.
- **Swift epic #297:** untouched — its remaining slices (E bootstrap, F vendor,
  G toolchain, H approver) are coverage-independent. Slice D's whole-file
  pre-flight stays live until the new epic's Swift slice supersedes it.

## Per-language playbook — adding region coverage to a new language

The family will gain more languages (Go, TypeScript, Rust, …). Each is the
**same vertical**; only the parser's data source differs. Swift is the worked
reference (`docs/superpowers/plans/2026-06-29-coverage-region-signal-swift-slice.md`).
To add language `L`:

1. **Extend `parse-<L>-coverage` to emit `regions[]`.** The contract is fixed —
   each entry is exactly `{file, name, start_line, end_line, pct}`, `file`
   repo-relative, `pct` a number `0–100`. Do **not** rename keys; the gather,
   dispatcher, and improver all depend on this shape.
2. **Gather includes `coverage.regions`** in the payload (empty `[]` when
   coverage is withheld/unreliable — #258 discipline carries over).
3. **Dispatcher pre-flight uses region containment** (this prose is identical
   across languages — copy the Swift dispatcher's Coverage pre-flight section):
   resolve each coverage-respecting finding's enclosing region
   (`start_line ≤ finding.line ≤ end_line`, innermost on overlap), gate vs the
   **single Required threshold (80%)**, whole-file fallback when no region
   matches, dedupe one improver work-item per region.
4. **The `<L>-coverage-improver` is function-scoped** — `modules_to_improve`
   names a function (`{file, function, start_line, end_line, current, target}`),
   target = Required.
5. **Update the user-facing docs** in the same slice (the `<L>` dispatcher
   `SKILL.md`, the improver agent, and any `<L>`-specific coverage wording).

### Where per-function data comes from (per coverage tool)

The only language-specific work is computing per-function line coverage. Known
sources:

| Tool (language) | Per-function data | Effort |
| --- | --- | --- |
| **JaCoCo** (Java) | `<method name= line=>` elements with per-method `LINE` counters | trivial — names + spans + pct directly |
| **xccov** (Swift / Xcode) | `functions[].{name, lineNumber, executableLines, coveredLines}` | easy — `end_line` = next function's start − 1 |
| **llvm-cov export** (Swift / SwiftPM, also C/C++/Rust) | `functions[].regions[]` (line spans) + `files[].segments[]` (per-line exec) | medium — span from regions, coverage from covered segments in span |
| **coverage.py** (Python) | per-**line** only (`executed_lines`/`missing_lines`) — **no** per-function | heaviest — map line→function via the stdlib `ast` module (innermost enclosing `def`) |

**For a tool not in this table:** if it reports per-function/per-method data,
use it directly (JaCoCo/xccov pattern). If it reports only per-line, map lines
to functions by parsing the source (the coverage.py/AST pattern). Either way the
output is the same `regions[]` contract.

### Discipline that carries over to every language

- **Capture real fixtures.** Don't hand-write the tool's JSON/XML — run the real
  tool on a tiny throwaway project and commit the trimmed output as the test
  fixture, so the parser is written against the true shape. Tests stay hermetic
  (load the fixture; no toolchain in CI).
- **Trustworthy-or-withheld (#258).** No `regions` when the measurement is
  unreliable; the dispatcher then halts/escalates rather than gating on a bad
  number.
- **The contract is the boundary.** Steps 2–4 are nearly copy-paste across
  languages because the parser absorbs all the per-tool variation behind
  `regions[]`. If you find yourself changing the dispatcher's containment logic
  per language, the parser isn't doing its job.

## Rejected alternatives

- **Approach B — diff coverage (gate after the fix):** measure coverage of the
  lines the fix agent actually changed. Truest safety signal, but a heavier
  re-architecture (fix-before-gate re-orders the PR cycle, and a fix that breaks
  the build cannot be coverage-measured). Set aside in favour of the lighter
  pre-flight region signal.
- **Approach C — any-real-test + change-risk class (drop %):** cheapest (no
  per-line coverage), but coarse — treats a barely-tested unit the same as a
  thoroughly-tested one, and the change-risk classification is itself an
  error-prone judgment.
- **Never generate tests (protected-or-escalate):** considered; rejected because
  region-scoping makes the improver's output small and meaningful (a test for
  the exact function being changed), which the owner accepts under review.

## Out of scope

- Standalone "improve coverage" runs unconnected to a finding (still not a
  pipeline goal).
- Distinguishing "asserted" from "executed" mechanically (handled by the
  improver contract + review, as today).
- Predicting the fix agent's full diff (that was Approach B).
