# Region-Scoped Coverage Signal — Swift Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `development-swift`'s whole-file coverage gate with a region-scoped
(enclosing-function) gate against a single Required threshold, per the approved spec.

**Architecture:** Extend `parse-swift-coverage.py` to emit a `regions[]` array (per-function
line coverage with line ranges) alongside the existing `by_module`. The gather includes
`coverage.regions` in the payload. The dispatcher's pre-flight resolves each
coverage-respecting finding to its enclosing region and gates on that region's pct (single
Required, fallback to whole-file when a finding maps to no function). The improver becomes
function-scoped. Documentation is updated in the same slice.

**Tech Stack:** Python 3 (stdlib only) for the parser; bash for the gather; markdown for the
dispatcher SKILL / agents / docs; bats for tests; `xccov` (Xcode, first-class — the test-bed
is an Xcode app) and `llvm-cov export` (SwiftPM) as the coverage sources.

## Global Constraints

- Coverage threshold: **Required = 80%** (single threshold; Floor tier removed). Copy
  verbatim into the dispatcher.
- A coverage figure (and now a region pct) is **trustworthy-or-withheld** (#258): unreliable
  measurement → no `regions`, withhold → escalate.
- Parser is **stdlib-only** Python 3 (runs anywhere `python3` does).
- Tests stay **hermetic**: parser tests feed *captured real* coverage JSON fixtures; the
  gather's live-measurement path stays toolchain-gated.
- Pre-commit must pass: `shellcheck` + `shfmt` (bash), `markdownlint` (120-col,
  fenced-code-exempt) on every changed file. **Never `--no-verify`.**
- Plugin content changes bump that plugin's `plugin.json` **and** its
  `.claude-plugin/marketplace.json` entry, kept in sync (`check-marketplace-sync.bats`).
  `development` (scripts) and `development-swift` (skill/agents) are separate plugins.
- PRs are **bot-authored** via `/development:open-pr`; this is a **human-merge** repo →
  **one PR per slice**, resolve each off fresh `origin/main`, verify the branch before
  committing.
- The `regions` interface (parser → dispatcher), used by Tasks 4–7:

  ```json
  "coverage": {
    "by_module": { "Sources/App/FileStore.swift": 42.0 },
    "regions": [
      { "file": "Sources/App/FileStore.swift", "name": "save(_:)",
        "start_line": 78, "end_line": 95, "pct": 40.0 }
    ],
    "measurement": { "reliable": true, "reason": "..." }
  }
  ```

  Containment rule (consumed by the dispatcher): for a finding at `(file, line)`, its region
  is the `regions[]` entry with matching `file` and `start_line <= line <= end_line`; on
  overlap (nested funcs) pick the **smallest span** (innermost); if none → `null` →
  whole-file fallback.

## PR / ordering map

This plan spans **four independent landings**, in order (human merges between):

- **Landing 0 — issues (no PR):** Task 0 creates `$EPIC` + `$SLICE`.
- **Landing 1 — prep (no repo PR):** Task 1 (memory update — the memory lives under
  `~/.claude/...`, not the repo).
- **Landing 2 — strip #460 (existing open PR):** Task 2, pushed to the
  `feat/443-swift-static-analysis-triage` branch; human merges #460.
- **Landing 3 — the Swift slice (one new bot PR):** Tasks 3–9, branched off fresh
  `origin/main` **after #460 merges** (it touches the same two plugins + the
  dispatcher/improver files).

---

## Task 0: Create the epic + Swift-slice issues (prep)

**Files:** none (GitHub issues).

**Interfaces:**

- Produces: `$EPIC` (the region-coverage epic issue number) and `$SLICE` (the Swift-slice
  issue number) — referenced by Task 2 (#460 body), Task 3 (branch name), and Task 9
  (`Closes`). Record both numbers before proceeding.

- [ ] **Step 1: Create the epic issue** (peer of the language epics, supersedes #456):

  ```bash
  gh issue create --repo timo-jakob/timos-claude-code-plugins --label enhancement \
    --title "epic: region-scoped coverage safety signal (supersedes #456)" \
    --body "Anchored by docs/superpowers/specs/2026-06-29-coverage-safety-signal-design.md. Replaces the whole-file Floor/Required coverage gate with an enclosing-function gate against a single Required threshold, family-wide (Swift -> Java -> Python). Supersedes #456. Children: Swift, Java, Python slices."
  ```

  Record the number as `$EPIC`.

- [ ] **Step 2: Create the Swift-slice issue** (child of `$EPIC`):

  ```bash
  gh issue create --repo timo-jakob/timos-claude-code-plugins --label enhancement \
    --title "region-coverage epic — Swift slice: per-function regions + region-scoped pre-flight + improver" \
    --body "Part of #\$EPIC. The Swift vertical: parse-swift-coverage.py regions, gather coverage.regions, region-scoped dispatcher pre-flight (single Required, file fallback, dedupe-per-region), function-scoped swift-coverage-improver, and docs. See docs/superpowers/plans/2026-06-29-coverage-region-signal-swift-slice.md."
  ```

  Record the number as `$SLICE`.

- [ ] **Step 3: Cross-link #456** — comment that it is superseded by `$EPIC` (do **not** close
  it until the epic's first slice merges):

  ```bash
  gh issue comment 456 --repo timo-jakob/timos-claude-code-plugins \
    --body "Superseded by the region-scoped coverage epic #\$EPIC — the Floor/Required dead-end is resolved structurally there. Closing into that epic once its first slice lands."
  ```

---

## Task 1: Update the coverage-policy memory (prep)

**Files:**

- Modify:
  `~/.claude/projects/-Users-timo-repositories-timos-claude-code-plugins/memory/feedback-coverage-human-driven.md`

**Interfaces:** none (internal memory; no code consumes it).

- [ ] **Step 1: Rewrite the "How to apply" paragraph** to the region-scoped model. Replace
  the Floor-only-bootstrap wording with: the gate is scoped to the **enclosing function** of
  each finding against a single **Required (80%)** threshold; ≥ Required → fix proceeds; below
  → a **function-scoped** improver writes tests for that one function (its own reviewed PR),
  target Required. Coverage stays human-overseen (the improver PR is reviewed); auto-generated
  tests are acceptable *because* they are scoped to the exact function being changed, not
  padding a whole-file number. Supersedes the Floor-only rule; resolves #456 structurally.
  Anchored by `docs/superpowers/specs/2026-06-29-coverage-safety-signal-design.md`.

- [ ] **Step 2: Verify the file still parses** (intact frontmatter):

  Run: `head -8 ~/.claude/projects/-Users-timo-repositories-timos-claude-code-plugins/memory/feedback-coverage-human-driven.md`

  Expected: intact `---` frontmatter with `name:` / `metadata:`.

- [ ] **Step 3: No commit** — memory files are not in the repo. Note completion.

---

## Task 2: Strip the coverage-policy change out of PR #460 (prep)

**Context:** #460 (open, branch `feat/443-swift-static-analysis-triage`) bundles the real
Slice-C triage work **and** a stop-gap coverage-policy change. Remove the latter so #460 is
pure triage; the Swift slice installs the region model properly.

**Files** (revert to their Slice-D state on the #460 branch; keep all triage edits):

- Modify: `development-swift/skills/maintenance/SKILL.md` — revert the coverage pre-flight
  section to its pre-#460 (whole-file Floor/Required) content; **keep** the tool-universe /
  dispatch_filter / missing_tooling triage additions.
- Modify: `development-swift/agents/swift-coverage-improver.md` — revert the Floor-only edits
  to the pre-#460 content (this file had only coverage edits in #460 → full restore is
  correct).
- Leave `swift-sonar-triage.md`, `swift-code-scanning-triage.md`, the gather sonar/codeql
  blocks, and `swift-maintenance-planner.md` routing **unchanged**.

- [ ] **Step 1: Check out the #460 branch and view its edits to those two files**

  ```bash
  cd <repo>
  git fetch origin -q
  git switch feat/443-swift-static-analysis-triage
  git diff origin/main -- development-swift/skills/maintenance/SKILL.md \
    development-swift/agents/swift-coverage-improver.md
  ```

  Expected: the coverage-pre-flight + improver-Floor edits are visible.

- [ ] **Step 2: Restore the improver fully; restore the SKILL then re-apply only triage edits**

  ```bash
  git checkout origin/main -- development-swift/agents/swift-coverage-improver.md
  ```

  For `SKILL.md`, restore to `origin/main`, then re-apply by hand only the non-coverage
  additions from Step 1's diff (tool universe, dispatch_filter list, missing_tooling for
  sonar/codeql/semgrep, routing notes). Do **not** re-add the coverage pre-flight rewrite.

- [ ] **Step 3: Verify the strip**

  Run: `grep -n 'Floor\|region' development-swift/skills/maintenance/SKILL.md | head`

  Expected: whole-file Floor/Required wording present; no region wording.

  Run: `grep -n 'sonarcloud\|code_scanning' development-swift/skills/maintenance/SKILL.md | head`

  Expected: triage tool-universe still present.

- [ ] **Step 4: Run the gate**

  Run: `bats tests/gather-swift.bats && pre-commit run --files
  development-swift/skills/maintenance/SKILL.md development-swift/agents/swift-coverage-improver.md`

  Expected: all green.

- [ ] **Step 5: Commit + push to the #460 branch as the bot, then wait for merge**

  ```bash
  git commit -am "refactor(swift): drop the stop-gap coverage-policy change from Slice C (#443)"
  TOKEN=$(development/skills/maintenance/scripts/mint-maintenance-token.zsh)
  git push "https://x-access-token:${TOKEN}@github.com/timo-jakob/timos-claude-code-plugins.git" \
    HEAD:feat/443-swift-static-analysis-triage --force-with-lease
  ```

  Update #460's body to drop the coverage bullet. **Stop — wait for the human to merge #460**
  before Task 3.

---

## Task 3: Capture real coverage fixtures (Swift slice begins)

**Context:** Don't hand-write llvm-cov / xccov JSON — capture it from a real run so the parser
is written against the true shape. Branch off fresh `origin/main` (post-#460-merge):
`git switch -c feat/$SLICE-swift-region-coverage origin/main` (using `$SLICE` from Task 0).

**Files:**

- Create: `tests/fixtures/coverage/swiftpm-llvmcov.json` (real `llvm-cov export`, trimmed to
  1 source file / 2 functions)
- Create: `tests/fixtures/coverage/xcode-xccov.json` (real `xccov view --report --json`,
  trimmed similarly)
- Create: `tests/fixtures/coverage/README.md` (how they were captured, so they're regenerable)

**Interfaces:**

- Produces: two committed JSON fixtures whose exact field shape Task 4 parses.

- [ ] **Step 1: Build a throwaway SwiftPM package with two functions, one tested**

  ```bash
  TMP=$(mktemp -d); cd "$TMP"
  swift package init --type library --name Demo
  cat > Sources/Demo/Demo.swift <<'SWIFT'
  public struct Demo {
      public func covered(_ x: Int) -> Int { x > 0 ? x : -x }
      public func uncovered(_ x: Int) -> Int { x * 2 }
  }
  SWIFT
  cat > Tests/DemoTests/DemoTests.swift <<'SWIFT'
  import XCTest; @testable import Demo
  final class DemoTests: XCTestCase {
      func testCovered() { XCTAssertEqual(Demo().covered(-3), 3) }
  }
  SWIFT
  swift test --enable-code-coverage
  ```

  Expected: tests pass; only `covered(_:)` is exercised.

- [ ] **Step 2: Export the llvm-cov JSON and inspect the per-function shape**

  ```bash
  BIN=$(swift build --show-bin-path)
  PROF="$BIN/codecov/default.profdata"
  XCTEST=$(find "$BIN" -name '*.xctest' -print -quit)
  xcrun llvm-cov export -instr-profile "$PROF" "$XCTEST/Contents/MacOS/"* \
    2>/dev/null | python3 -m json.tool | head -60
  ```

  Expected: a `data[].functions[]` array with `name`, `regions`, `filenames`, and
  `data[].files[]` with `segments`. **Record the exact keys** — Task 4 parses them.

- [ ] **Step 3: Save the trimmed llvm-cov fixture into the repo**

  Copy the export to `tests/fixtures/coverage/swiftpm-llvmcov.json`, trimming
  `data[0].functions` to the two Demo functions and `data[0].files` to the one Demo source.
  Keep it valid JSON (`python3 -m json.tool < file`).

- [ ] **Step 4: Capture an xccov fixture (Xcode path — first-class)**

  If an Xcode `.xcresult` is reachable, run
  `xcrun xccov view --report --json <Result.xcresult> > /tmp/xccov.json` and inspect
  `targets[].files[].functions[]` (keys: `name`, `lineNumber`, `executableLines`,
  `coveredLines`). Trim to one file / two functions into
  `tests/fixtures/coverage/xcode-xccov.json`. If no `.xcresult` is reachable here, hand-author
  a **minimal** xccov fixture matching the documented shape and note it as synthetic in the
  fixtures README.

- [ ] **Step 5: Commit the fixtures**

  ```bash
  cd <repo>
  git add tests/fixtures/coverage/
  git commit -m "test(coverage): capture real llvm-cov + xccov fixtures for region parsing"
  ```

---

## Task 4: `parse-swift-coverage.py` emits `regions`

**Files:**

- Modify: `development/skills/maintenance/scripts/parse-swift-coverage.py`
- Modify: `tests/gather-swift.bats`

**Interfaces:**

- Consumes: the fixtures from Task 3.
- Produces: parser stdout gains `"regions": [{file, name, start_line, end_line, pct}]`;
  `overall` / `by_module` unchanged. Helpers `regions_from_xccov(doc, root)` and
  `regions_from_llvm(doc, root)` returning `list[dict]`, plus `_region_linespan` for
  end_line derivation (xccov: next-function-start − 1; llvm: min/max region line).

- [ ] **Step 1: Write the failing test (xccov regions)** in `tests/gather-swift.bats`:

  ```bash
  @test "parse-swift-coverage: xccov -> per-function regions with line spans" {
    PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
    out=$(cd "$REPO_ROOT" && python3 "$PARSE" tests/fixtures/coverage/xcode-xccov.json)
    [ "$(jq '.regions | length >= 2' <<<"$out")" = "true" ]
    [ "$(jq '[.regions[] | select(.name | test("covered"))][0].pct >= 99' <<<"$out")" = "true" ]
    [ "$(jq '[.regions[] | select(.name | test("uncovered"))][0].pct == 0' <<<"$out")" = "true" ]
    [ "$(jq '.regions[0] | has("start_line") and has("end_line")' <<<"$out")" = "true" ]
  }
  ```

- [ ] **Step 2: Run it to verify it fails**

  Run: `bats tests/gather-swift.bats -f 'per-function regions'`

  Expected: FAIL (`.regions` is null / absent).

- [ ] **Step 3: Implement `regions` extraction** in `parse-swift-coverage.py` — add
  `regions_from_xccov` and `regions_from_llvm` per the keys recorded in Task 3. xccov:
  `functions[].{name,lineNumber,executableLines,coveredLines}`, `end_line` = next function's
  `lineNumber − 1` within the file (last = `lineNumber + max(executableLines−1, 0)`),
  `pct = coveredLines/executableLines`. llvm: per-function line set from `regions[]` line
  ranges intersected with the file's covered segments, `pct = covered_lines/total_lines`.
  Relativize `file` via the existing `relativize()`. Add `"regions": regions` to the printed
  dict. Stdlib-only.

- [ ] **Step 4: Run the xccov test to verify it passes**

  Run: `bats tests/gather-swift.bats -f 'per-function regions'`

  Expected: PASS.

- [ ] **Step 5: Add + run the llvm-cov region test** (same shape, loading
  `swiftpm-llvmcov.json`; assert `covered`/`uncovered` pcts and line spans). Iterate
  `regions_from_llvm` against the real fixture until green.

- [ ] **Step 6: Add a containment-edge test** — a line inside `covered(_:)` resolves to that
  region; a line above the first function is in no region (the dispatcher's fallback case).

- [ ] **Step 7: Lint + full parser test run**

  Run: `python3 -m py_compile development/skills/maintenance/scripts/parse-swift-coverage.py &&
  bats tests/gather-swift.bats`

  Expected: all green.

- [ ] **Step 8: Commit**

  ```bash
  git add development/skills/maintenance/scripts/parse-swift-coverage.py tests/gather-swift.bats
  git commit -m "feat(coverage): parse-swift-coverage emits per-function regions"
  ```

---

## Task 5: `gather-swift-findings.sh` includes `coverage.regions`

**Files:**

- Modify: `development/skills/maintenance/scripts/gather-swift-findings.sh`
- Modify: `tests/gather-swift.bats`

**Interfaces:**

- Consumes: the parser's `regions` (Task 4).
- Produces: the gather's `coverage` object gains a `regions` array (empty `[]` when
  withheld/unmeasured).

- [ ] **Step 1: Write the failing contract test** — bare project (no tests) →
  `coverage.regions` is present and `[]`:

  ```bash
  @test "gather-swift: coverage carries a regions array (empty when withheld)" {
    printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
    run bash "$GATHER" "$WORK"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
    [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  }
  ```

- [ ] **Step 2: Run it to verify it fails**

  Run: `bats tests/gather-swift.bats -f 'regions array'`

  Expected: FAIL (`.coverage.regions` absent).

- [ ] **Step 3: Implement** — capture the parser's `.regions` into `coverage_regions`
  (default `[]`); on a successful parse set `coverage_regions="$(jq '.regions // []' <<<"$parsed")"`.
  Add `--argjson coverage_regions "$coverage_regions"` and `regions: $coverage_regions` to the
  emit `jq`.

- [ ] **Step 4: Run to verify pass + shellcheck/shfmt**

  Run: `bats tests/gather-swift.bats -f 'regions array' &&
  shellcheck development/skills/maintenance/scripts/gather-swift-findings.sh &&
  shfmt -d development/skills/maintenance/scripts/gather-swift-findings.sh`

  Expected: PASS + clean.

- [ ] **Step 5: Commit**

  ```bash
  git add development/skills/maintenance/scripts/gather-swift-findings.sh tests/gather-swift.bats
  git commit -m "feat(coverage): gather-swift includes coverage.regions"
  ```

---

## Task 6: Dispatcher pre-flight — region-scoped gate

**Files:**

- Modify: `development-swift/skills/maintenance/SKILL.md` (the Coverage pre-flight section +
  schema example + scope notes)

**Interfaces:**

- Consumes: `coverage.regions` (Task 5) and the containment rule (Global Constraints).
- Produces: the region-scoped pre-flight prose the orchestrator executes.

- [ ] **Step 1: Rewrite the Coverage pre-flight section** to carry every spec edge case:
  (a) resolve each coverage-respecting finding's enclosing region via containment (innermost
  named function on overlap); (b) gate `region.pct` vs **Required (80%)** — ≥ proceed,
  < spawn the **function-scoped** improver (target Required); (c) **fallback to whole-file**
  coverage when no region contains the line; (d) **dedupe** to one improver work-item per
  region; (e) keep #258 withhold→escalate on unreliable measurement; (f) if the improver
  can't reach Required on a region in one pass, escalate that region to a human (don't loop);
  (g) greenfield (no tests) is normal — each region is 0% and gets a small improver PR,
  bounded by `--batch=N`; (h) note the out-of-region residual (the gate is a pre-flight
  heuristic; the fix agent's test run + review catch out-of-region damage). Remove all Floor /
  two-tier wording.

- [ ] **Step 2: Update the v2 schema example** in the SKILL to show `coverage.regions`.

- [ ] **Step 3: Update the scope/decisions notes** — coverage gate is region-scoped-to-Required;
  reference the spec.

- [ ] **Step 4: Lint**

  Run: `pre-commit run markdownlint --files development-swift/skills/maintenance/SKILL.md`

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add development-swift/skills/maintenance/SKILL.md
  git commit -m "feat(swift): region-scoped coverage pre-flight (single Required)"
  ```

---

## Task 7: `swift-coverage-improver` — function-scoped

**Files:**

- Modify: `development-swift/agents/swift-coverage-improver.md`

**Interfaces:**

- Consumes: the dispatcher's region-scoped spawn (Task 6) — `modules_to_improve[]` entries
  carry `{file, function, current_pct, target: Required}`.

- [ ] **Step 1: Update the frontmatter description + intro** — the improver raises coverage on
  a **named function** to Required (single threshold); drop Floor/bootstrap-vs-topup framing.

- [ ] **Step 2: Update Inputs + Procedure** — `modules_to_improve` names a function; the
  improver writes tests for *that function's* behaviour; verify the function's region reaches
  Required.

- [ ] **Step 3: Lint**

  Run: `pre-commit run markdownlint --files development-swift/agents/swift-coverage-improver.md`

  Expected: PASS.

- [ ] **Step 4: Commit**

  ```bash
  git add development-swift/agents/swift-coverage-improver.md
  git commit -m "feat(swift): function-scoped coverage improver (target Required)"
  ```

---

## Task 8: User-facing documentation

**Files:**

- Modify: `ARCHITECTURE.md` (coverage pre-flight / thresholds section + the v2
  `coverage.regions` schema field)
- Modify: `README.md` (only if it describes the coverage gate)

- [ ] **Step 1: Find the coverage docs**

  Run: `grep -n 'coverage\|Floor\|Required\|by_module' ARCHITECTURE.md README.md`

  Expected: the sections to update.

- [ ] **Step 2: Update `ARCHITECTURE.md`** — describe the region-scoped gate (enclosing
  function, single Required, file fallback) and add `coverage.regions` to the v2 schema
  description. Note this is the Swift realization; Java/Python follow in later slices.

- [ ] **Step 3: Update `README.md`** if it mentions whole-file coverage gating; otherwise leave
  it.

- [ ] **Step 4: Lint**

  Run: `pre-commit run markdownlint --files ARCHITECTURE.md README.md`

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add ARCHITECTURE.md README.md
  git commit -m "docs: region-scoped coverage gate (Swift)"
  ```

---

## Task 9: Version bumps + open the bot PR

**Files:**

- Modify: `development/.claude-plugin/plugin.json`, `development-swift/.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump both plugins** (patch) + their marketplace entries, kept in sync:
  `development` (parser + gather changed) and `development-swift` (skill + improver changed).

- [ ] **Step 2: Verify sync + full gate**

  Run: `bats tests/ && pre-commit run --files <all changed files>`

  Expected: full suite green, 0 failing; `check-marketplace-sync.bats` green.

- [ ] **Step 3: Commit the bumps**

  ```bash
  git add -A && git commit -m "chore: bump development + development-swift for region coverage"
  ```

- [ ] **Step 4: Open the bot PR** via `/development:open-pr` — mint the token, push as the bot,
  open with a template body (Type / Summary / Risk / Test plan + `Closes #$SLICE`), arm squash
  auto-merge. **Stop — human approves/merges.** After it merges, comment on `$EPIC` checking
  off the Swift slice, and close #456 (the first slice has landed).

---

## Notes for the engineer

- This is **Swift only**. Java (`parse-jacoco.py` — `<method>` elements, nearly free) and
  Python (`coverage.py` + AST line→function mapping) are **separate later plans**, same shape.
- The `regions` interface and containment rule (Global Constraints) are the contract every
  later language slice reuses — don't change them per-language.
- If the llvm-cov per-function line% proves intractable from the captured fixture in Task 4,
  ship xccov regions (Xcode test-bed, first-class) and have the SwiftPM/llvm-cov path emit
  file-level regions as the documented fallback, with a follow-up issue — do **not** block the
  slice on it.
