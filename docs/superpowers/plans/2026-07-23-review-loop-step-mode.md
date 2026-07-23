# Review-Loop Step Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pre-push review loop transparent: one loop invocation per round
(`--findings-file` step mode, new `AWAITING_FIX` status), a tail-able
`progress.md`, and a SKILL.md §3.5 rewrite that mandates in-session review
agents and bans headless `claude`.

**Architecture:** `resolve-story-loop.zsh` gains a step mode alongside the
existing hook mode (which stays byte-compatible as the bats seam). A new pure
renderer script (`render-progress-block.zsh`) turns a changelist JSON into one
progress.md block so the rendering is unit-testable. SKILL.md and
`docs/explanation/review-loop.md` are rewritten to mandate the transparent
wiring.

**Tech Stack:** zsh, jq, bats, markdown (markdownlint + mkdocs strict).

**Spec:** `docs/superpowers/specs/2026-07-23-review-loop-step-mode-design.md`
(read it before starting). Tracking issue: #971.

## Global Constraints

- Branch: `feat/971-review-loop-step-mode` off **fresh** `origin/main` (never stack on the spec branch).
- New shell scripts are **zsh** (`#!/usr/bin/env zsh`, `emulate -L zsh`, `setopt nounset pipefail`), per
  ARCHITECTURE.md "Scripting conventions".
- Existing hook-mode behaviour and all existing tests in `tests/resolve-story-loop.bats` must pass **unmodified**
  at every task boundary.
- Exit-code map after this change: 0 CONVERGED/SKIPPED · 20 AWAITING_FIX (new, non-terminal) · 10/11/12
  ESCALATE_* · 13 BUDGET_EXHAUSTED · 2 usage · 1 operational.
- Telemetry: one JSONL record per loop, appended **only on terminal statuses** (never `AWAITING_FIX`); wall
  clock from `$work_dir/.t0`.
- progress.md writes are **never fatal** (`|| true`), same policy as telemetry.
- No headless `claude` anywhere; no long-lived background task spanning rounds (this applies to the docs you
  write, too).
- Line length 120; markdown must pass markdownlint (pre-commit runs it); a line must never *start* with
  `#<digits>` (MD018 false positive — rewrap so issue refs sit mid-line).
- Run bats via `bats tests/<file>.bats` and read bats' real exit code — never pipe through `tail`.
- Finish: bump `development` plugin version **minor** in BOTH `development/.claude-plugin/plugin.json` and
  `.claude-plugin/marketplace.json` (read the current value first — it was 1.130.0 when this plan was written;
  if main has moved, bump from whatever is current), PR body per template with `Closes #971`.

---

### Task 1: `render-progress-block.zsh` — the pure progress renderer

**Files:**

- Create: `development/skills/resolve-issue/scripts/render-progress-block.zsh`
- Test: `tests/render-progress-block.bats`

**Interfaces:**

- Produces: `render-progress-block.zsh --changelist FILE --round N --verdict TEXT`
  → markdown block on stdout, exit 0; exit 2 on missing args / unknown flag;
  exit 1 on missing/empty/invalid changelist. Task 4 calls it from the loop.
- The new/carried split renders **only** when every `.blocking[]` item has the
  `non_converging` key (the #913 stamp); otherwise totals only.

- [ ] **Step 1: Write the failing tests**

Create `tests/render-progress-block.bats`:

```bash
#!/usr/bin/env bats
#
# Tests for render-progress-block.zsh (#971): changelist JSON in, one
# human-readable progress.md block on stdout. The new/carried split must render
# ONLY when every blocker carries the #913 non_converging stamp — a stamp-less
# or mixed changelist gets totals only (no label rather than a confident wrong
# one).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/render-progress-block.zsh"
  CL="$BATS_TEST_TMPDIR/changelist.json"
}

@test "stamped blockers render the new/carried split and per-dimension counts" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":1,"low":1,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"tests","title":"y","non_converging":false}],
 "suggestions":[{}],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 2 — blockers remain'
  echo "$output" | grep -q -- '- blockers: 2 (new: 1, carried: 1), conflicts: 0, suggestions: 1'
  echo "$output" | grep -q -- '- by dimension: bugs 1, tests 1'
  echo "$output" | grep -q -- '- awaiting fix'
}

@test "a stamp-less changelist degrades to totals only (no new/carried label)" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x"},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "budget exhausted"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- blockers: 2, conflicts: 0, suggestions: 0'
  run ! grep -q 'new:' <<< "$output"
}

@test "a MIXED changelist (one stamped, one not) also degrades to totals only" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "v"
  [ "$status" -eq 0 ]
  run ! grep -q 'new:' <<< "$output"
}

@test "a converged round renders 'no blockers' and omits the dimension line" {
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":0,"low":2,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[{},{}],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "converged"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 3 — no blockers'
  echo "$output" | grep -q -- '- blockers: 0, conflicts: 0, suggestions: 2'
  run ! grep -q 'by dimension' <<< "$output"
  echo "$output" | grep -q -- '- converged'
}

@test "missing required args is a usage error (exit 2)" {
  run zsh "$S" --changelist "$CL" --round 1
  [ "$status" -eq 2 ]
}

@test "a missing changelist file is an internal error (exit 1)" {
  run zsh "$S" --changelist "$BATS_TEST_TMPDIR/nope.json" --round 1 --verdict v
  [ "$status" -eq 1 ]
}

@test "invalid changelist JSON is an internal error (exit 1)" {
  printf 'not json' > "$CL"
  run zsh "$S" --changelist "$CL" --round 1 --verdict v
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/render-progress-block.bats`
Expected: 7 failures ("No such file or directory" for the script).

- [ ] **Step 3: Write the renderer**

Create `development/skills/resolve-issue/scripts/render-progress-block.zsh`
(then `chmod +x` it):

```zsh
#!/usr/bin/env zsh
# render-progress-block.zsh — render one review-loop round as a human-readable
# markdown block for the loop's tail-able progress.md (#971). Pure function:
# changelist JSON (consolidate-findings.zsh output) in, markdown on stdout.
#
# The new/carried split is rendered ONLY when every blocker carries the #913
# per-item non_converging stamp; a stamp-less (pre-#913) or mixed producer gets
# totals only — no label rather than a confident wrong one.
#
# Usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT
# Exit: 0 ok · 2 usage · 1 missing/empty/invalid changelist

emulate -L zsh
setopt nounset pipefail

local changelist="" round="" verdict=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --changelist) changelist="$2"; shift 2 ;;
  --round) round="$2"; shift 2 ;;
  --verdict) verdict="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$changelist" && -n "$round" && -n "$verdict" ]] || {
  print -u2 -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT"; exit 2 }
[[ -s "$changelist" ]] || {
  print -u2 -- "render-progress-block: changelist missing or empty: $changelist"; exit 1 }

jq -r --arg ts "$(date +%H:%M:%S)" --argjson r "$round" --arg v "$verdict" '
  (.blocking // []) as $blk
  | ((($blk | length) > 0) and ([ $blk[] | has("non_converging") ] | all)) as $stamped
  | (if $stamped then ($blk | map(select(.non_converging)) | length) else null end) as $carried
  | "## Round \($r) — \(if (.summary.blocking // 0) == 0 then "no blockers" else "blockers remain" end) (\($ts))",
    ("- blockers: \(.summary.blocking // 0)"
     + (if $carried != null then " (new: \((.summary.blocking // 0) - $carried), carried: \($carried))" else "" end)
     + ", conflicts: \(.summary.conflicts // 0), suggestions: \(.summary.low // 0)"),
    (if ($blk | length) > 0 then
       "- by dimension: " + ($blk | group_by(.dimension // "") | map("\(.[0].dimension // "?") \(length)") | join(", "))
     else empty end),
    "- \($v)",
    ""
' "$changelist" || { print -u2 -- "render-progress-block: invalid changelist JSON"; exit 1 }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/render-progress-block.bats`
Expected: 7 passing. Also run `shellcheck` is N/A for zsh; instead:
`zsh -n development/skills/resolve-issue/scripts/render-progress-block.zsh` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/render-progress-block.zsh tests/render-progress-block.bats
git commit -m "feat(resolve-issue): progress-block renderer for the review loop (#971)"
```

---

### Task 2: Step mode — flag, validation, findings consumption, `AWAITING_FIX`

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`
- Test: `tests/resolve-story-loop-step.bats` (new)

**Interfaces:**

- Consumes: nothing from Task 1 yet (progress wiring is Task 4).
- Produces: `--findings-file PATH` flag; `step_mode` local (0/1); the decide
  chain restructured to set `loop_status` + `verdict` (Task 4 appends the
  progress call between them); status `AWAITING_FIX`, exit 20. Tasks 3–5 build
  on exactly these names.

- [ ] **Step 1: Write the failing tests**

Create `tests/resolve-story-loop-step.bats`:

```bash
#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh STEP MODE (#971): one invocation
# per round, findings supplied via --findings-file, fixes applied in-session
# between invocations (so the loop exits AWAITING_FIX instead of running a fix
# hook). Detection is stubbed via DETECT_STACK_BIN; git runs for real.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"

  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"   # the story's diff (in-scope file)

  WD="$BATS_TEST_TMPDIR/wd"
  F="$BATS_TEST_TMPDIR/findings.json"
  CRIT='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]'
}

# one step-mode invocation against the python repo
step() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" "$@"
}

# seed a work-dir one AWAITING_FIX round deep (round 1, one CRITICAL blocker)
seed_awaiting() {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
}

@test "usage: --findings-file with --review-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --review-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "usage: --findings-file with --fix-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "blockers with budget left exit AWAITING_FIX (20), accumulators populated" {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 1 ]
  # stdout stays exactly the one-line status JSON
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "clean findings converge in round 1 (exit 0)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
}

@test "a missing findings file is treated as no findings (CONVERGED)" {
  rm -f "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "a findings file that is not a JSON array is an internal error (exit 1)" {
  printf 'not json' > "$F"
  step
  [ "$status" -eq 1 ]
}

@test "blockers on the last budget round exit BUDGET_EXHAUSTED (13), not AWAITING_FIX" {
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
}

@test "a surviving conflict exits ESCALATE_CONFLICT (11) in step mode too" {
  printf '%s' '[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]' > "$F"
  step
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bats tests/resolve-story-loop-step.bats`
Expected: the two usage tests pass spuriously (an unknown `--findings-file`
flag also exits 2 today); every other test FAILS with "unknown flag:
--findings-file". That is the failing baseline — proceed.

- [ ] **Step 3: Implement**

Four edits to `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`.

**3a — arg declaration and parsing.** In the locals (currently
`local repo="" base="origin/main" review_cmd="" fix_cmd="" test_cmd=""`), add
`findings_file=""`:

```zsh
local repo="" base="origin/main" review_cmd="" fix_cmd="" test_cmd="" findings_file=""
```

In the `while [[ $# -gt 0 ]]` case list, after the `--test-cmd` case add:

```zsh
  --findings-file) findings_file="$2"; shift 2 ;;
```

And update the `--help` line to:

```zsh
  -h|--help) print -r -- "usage: resolve-story-loop.zsh --repo PATH (--findings-file FILE | --review-cmd CMD --fix-cmd CMD) [--test-cmd CMD] [--base REF] [--max-rounds N] [--resume] [--issue N] [--telemetry-file PATH] [--no-review]"; exit 0 ;;
```

**3b — validation.** Replace these two lines (after the `--repo` checks):

```zsh
[[ -n "$review_cmd" ]] || { print -u2 -- "resolve-story-loop: --review-cmd is required (or use --no-review)"; exit 2 }
[[ -n "$fix_cmd" ]] || { print -u2 -- "resolve-story-loop: --fix-cmd is required (or use --no-review)"; exit 2 }
```

with:

```zsh
# Step mode (#971): --findings-file replaces BOTH model-driven hooks — the
# driving session runs the panel and the fix pass in-session, one round per
# invocation. Mixing the two wirings is a contradiction, not a fallback.
local step_mode=0
[[ -n "$findings_file" ]] && step_mode=1
if (( step_mode )) && [[ -n "$review_cmd" || -n "$fix_cmd" ]]; then
  print -u2 -- "resolve-story-loop: --findings-file is mutually exclusive with --review-cmd/--fix-cmd"; exit 2
fi
if (( ! step_mode )); then
  [[ -n "$review_cmd" ]] || { print -u2 -- "resolve-story-loop: --review-cmd is required (or use --findings-file / --no-review)"; exit 2 }
  [[ -n "$fix_cmd" ]] || { print -u2 -- "resolve-story-loop: --fix-cmd is required (or use --findings-file / --no-review)"; exit 2 }
fi
```

**3c — findings consumption.** Replace the review-hook step (the block starting
`# 1. run the review panel (hook) — it writes findings_path` through its
`[[ -s "$findings_path" ]] || print -r -- '[]' > "$findings_path"` line) with:

```zsh
  # 1. obtain this round's findings: step mode consumes --findings-file (the
  # session already ran the panel in-session, #971); hook mode runs the
  # injected panel command
  if (( step_mode )); then
    if [[ -s "$findings_file" ]]; then
      jq -e 'type=="array"' "$findings_file" >/dev/null 2>&1 || {
        print -u2 -- "resolve-story-loop: --findings-file is not a JSON array: $findings_file"; exit 1 }
      cp "$findings_file" "$findings_path" || {
        print -u2 -- "resolve-story-loop: could not copy --findings-file"; exit 1 }
    fi
  else
    ( export REVIEW_ROUND="$round" REVIEW_FINDINGS="$findings_path" \
             REVIEW_SKILL="$review_skill" REVIEW_SCOPE_FILE="$scope_file" \
             REVIEW_REPO="$repo"; eval "$review_cmd" ) || {
      print -u2 -- "resolve-story-loop: --review-cmd failed at round $round"; exit 1 }
  fi
  [[ -s "$findings_path" ]] || print -r -- '[]' > "$findings_path"
```

**3d — the decide chain.** Add `verdict` to the once-declared loop locals
(`local blocking conflict nonconv nconf` → `local blocking conflict nonconv nconf verdict`),
then replace:

```zsh
  # 4. decide the round's fate
  if (( blocking == 0 )); then loop_status="CONVERGED"; break; fi
  if (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"; break; fi
  if (( nonconv == 1 )); then loop_status="ESCALATE_NO_CONVERGENCE"; break; fi
  if (( round == max_rounds )); then loop_status="BUDGET_EXHAUSTED"; break; fi
```

with:

```zsh
  # 4. decide the round's fate. In step mode a survivable round (blockers,
  # budget left) exits AWAITING_FIX (20): the fix pass is the driving session's
  # job, in-session, before it re-invokes with --resume (#971).
  if (( blocking == 0 )); then loop_status="CONVERGED"
  elif (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"
  elif (( nonconv == 1 )); then loop_status="ESCALATE_NO_CONVERGENCE"
  elif (( round == max_rounds )); then loop_status="BUDGET_EXHAUSTED"
  elif (( step_mode )); then loop_status="AWAITING_FIX"
  fi
  case "$loop_status" in
    CONVERGED) verdict="converged" ;;
    ESCALATE_CONFLICT) verdict="escalating (unresolved conflict)" ;;
    ESCALATE_NO_CONVERGENCE) verdict="escalating (non-converging blocker)" ;;
    BUDGET_EXHAUSTED) verdict="budget exhausted" ;;
    AWAITING_FIX) verdict="awaiting fix — apply blockers in-session, then --resume" ;;
    *) verdict="fix pass (in-loop), continuing" ;;
  esac
  if [[ -n "$loop_status" ]]; then break; fi
```

(`verdict` is consumed in Task 4; setting it now keeps this edit single-shot.)

**3e — exit-code map.** In the final `case "$loop_status" in` add, after the
`CONVERGED) code=0 ;;` line:

```zsh
  AWAITING_FIX) code=20 ;;
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/resolve-story-loop-step.bats` → 8 passing.
Run: `bats tests/resolve-story-loop.bats` → all existing tests still pass.
Run: `zsh -n development/skills/resolve-issue/scripts/resolve-story-loop.zsh` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh tests/resolve-story-loop-step.bats
git commit -m "feat(resolve-issue): review-loop step mode — --findings-file + AWAITING_FIX (#971)"
```

---

### Task 3: Step-mode resume + `--test-cmd` gating the prior fix

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`
- Test: `tests/resolve-story-loop-step.bats` (append)

**Interfaces:**

- Consumes: `step_mode`, `resume`, `resume_round`, `resume_prev` (all existing
  or from Task 2).
- Produces: on a step-mode `--resume` invocation, `--test-cmd` runs FIRST; red
  → status `ERROR`, exit 1. No new names.

- [ ] **Step 1: Append the failing tests**

Append to `tests/resolve-story-loop-step.bats`:

```bash
@test "resume with clean findings converges at round 2; accumulators span invocations" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
}

@test "resume with the SAME blocker trips ESCALATE_NO_CONVERGENCE against the carried prior round" {
  seed_awaiting
  printf '%s' "$CRIT" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "a fresh step-mode run does NOT execute --test-cmd (step 3's gate already ran)" {
  printf '%s' "$CRIT" > "$F"
  step --test-cmd 'false'
  # if --test-cmd ran, this would be exit 1; the round must proceed to AWAITING_FIX
  [ "$status" -eq 20 ]
}

@test "--test-cmd red at the start of a step-mode resume is ERROR (exit 1) — the prior fix broke the gate" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false'
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "--test-cmd green at the start of a step-mode resume lets the round proceed" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}
```

- [ ] **Step 2: Run to verify the test-cmd tests fail**

Run: `bats tests/resolve-story-loop-step.bats`
Expected: the two resume-happy-path tests may already pass (resume machinery is
reused); "fresh run does NOT execute --test-cmd" passes; the red-on-resume test
FAILS (today nothing runs `--test-cmd` in step mode, so it converges with
exit 0 instead of ERROR).

- [ ] **Step 3: Implement**

In `resolve-story-loop.zsh`, directly after the `--resume` validation `if`/`else`
block ends (after the `fi` that follows the fresh-run
`: > "$changelists_file"` branch) and **before** the
`# --- dispatch: which panel, on what scope` section, insert:

```zsh
# Step mode gates the PREVIOUS round's in-session fix here (#971): the fix ran
# between invocations, so the "red after a fix aborts" check runs at resume
# start — deterministically, before any new round work.
if (( step_mode && resume )) && [[ -n "$test_cmd" ]]; then
  ( cd "$repo" && eval "$test_cmd" ) || {
    print -u2 -- "resolve-story-loop: --test-cmd red on --resume (prior round's fix broke the gate)"
    emit_and_exit "ERROR" "$resume_round" 1 "" "" "$resume_prev" "$history_file" "$changelists_file" }
fi
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/resolve-story-loop-step.bats` → 13 passing.
Run: `bats tests/resolve-story-loop.bats` → all existing tests still pass
(hook mode never sets `step_mode`, so the new block is inert there).

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh tests/resolve-story-loop-step.bats
git commit -m "feat(resolve-issue): step-mode resume gates the prior in-session fix via --test-cmd (#971)"
```

---

### Task 4: progress.md — per-round blocks + terminal line

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`
- Test: `tests/resolve-story-loop-step.bats` (append)

**Interfaces:**

- Consumes: `render-progress-block.zsh` (Task 1), `verdict` (Task 2).
- Produces: `append_progress_round CHANGELIST ROUND VERDICT` helper;
  `$work_dir/progress.md` appended per round in BOTH modes plus one
  `**Final:** <status>` line on every terminal emit. All writes non-fatal.

- [ ] **Step 1: Append the failing tests**

Append to `tests/resolve-story-loop-step.bats`:

```bash
@test "progress.md gets a per-round block with the new/carried split (step mode)" {
  seed_awaiting
  grep -q '^## Round 1 — blockers remain' "$WD/progress.md"
  grep -q -- '- blockers: 1 (new: 1, carried: 0), conflicts: 0, suggestions: 0' "$WD/progress.md"
  grep -q -- '- by dimension: bugs 1' "$WD/progress.md"
  printf '%s' "$CRIT" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  grep -q '^## Round 2 — blockers remain' "$WD/progress.md"
  grep -q -- 'new: 0, carried: 1' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* ESCALATE_NO_CONVERGENCE' "$WD/progress.md"
}

@test "progress.md ends with a Final line naming the terminal status (converged run)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — no blockers' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$WD/progress.md"
}

@test "AWAITING_FIX writes its round block but NO Final line (non-terminal)" {
  seed_awaiting
  run ! grep -q '^\*\*Final:' "$WD/progress.md"
}

@test "hook mode also writes progress.md (both wirings are observable)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-hook" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — blockers remain' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q -- '- fix pass (in-loop), continuing' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^## Round 2 — no blockers' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
}

@test "an unwritable progress.md never aborts the run (transparency is non-fatal)" {
  mkdir -p "$WD/progress.md"   # a DIRECTORY at the target path defeats appends
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/resolve-story-loop-step.bats`
Expected: the four progress-content tests FAIL (no progress.md written); the
non-fatal test passes vacuously — keep it anyway, it pins the policy.

- [ ] **Step 3: Implement**

Three edits to `resolve-story-loop.zsh`.

**3a — renderer path + helper.** Next to the existing
`local CONSOLIDATE="${self_dir}/consolidate-findings.zsh"` add:

```zsh
local RENDER_PROGRESS="${self_dir}/render-progress-block.zsh"
```

After the `emit_ambiguous()` function definition add:

```zsh
# append one per-round block to the tail-able progress file (#971). Rendering
# is render-progress-block.zsh (a testable pure function); transparency must
# never abort a run, so every failure here is swallowed.
append_progress_round() {
  local cl="$1" r="$2" v="$3"
  [[ -n "$work_dir" ]] || return 0
  "$RENDER_PROGRESS" --changelist "$cl" --round "$r" --verdict "$v" \
    >> "$work_dir/progress.md" 2>/dev/null || true
}
```

**3b — per-round call.** In the decide chain from Task 2, insert the call
between the `esac` and the `if [[ -n "$loop_status" ]]; then break; fi` line:

```zsh
  append_progress_round "$changelist" "$round" "$verdict"
```

**3c — terminal line.** In `emit_and_exit()`, immediately before the
telemetry block (`local tfile="$telemetry_file"`), insert:

```zsh
  # progress.md terminal line (#971) — non-fatal; AWAITING_FIX is not terminal
  if [[ -n "$work_dir" && -d "$work_dir" && "$st" != "AWAITING_FIX" ]]; then
    local reasons=""
    [[ -n "$esc" && "$esc" != "[]" ]] && reasons=" — $(print -r -- "$esc" | jq -r 'join(", ")' 2>/dev/null)"
    print -r -- "**Final:** ${st}${reasons} ($(date +%H:%M:%S))" >> "$work_dir/progress.md" 2>/dev/null || true
  fi
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/resolve-story-loop-step.bats` → 18 passing.
Run: `bats tests/resolve-story-loop.bats` → all existing tests still pass
(the clean-path stdout contract is untouched: progress writes go to a file,
`2>/dev/null` keeps stderr quiet).

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh tests/resolve-story-loop-step.bats
git commit -m "feat(resolve-issue): tail-able progress.md for the review loop (#971)"
```

---

### Task 5: Telemetry — terminal-only, whole-loop wall clock via `.t0`

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`
- Test: `tests/resolve-story-loop-step.bats` (append)

**Interfaces:**

- Consumes: `emit_and_exit`, `t0`, `work_dir`.
- Produces: `$work_dir/.t0` (epoch seconds, written on every fresh run, both
  modes); telemetry records skipped when status is `AWAITING_FIX`; `--ts` /
  `--wall-s` computed from `.t0` when present and numeric.

- [ ] **Step 1: Append the failing tests**

Append to `tests/resolve-story-loop-step.bats`:

```bash
@test "no telemetry record on AWAITING_FIX; exactly one on the terminal invocation" {
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  printf '%s' "$CRIT" > "$F"
  step --telemetry-file "$T"
  [ "$status" -eq 20 ]
  [ ! -s "$T" ]
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
}

@test "terminal telemetry reports whole-loop wall clock from .t0, not the last round's" {
  T="$BATS_TEST_TMPDIR/telemetry-wall.jsonl"
  seed_awaiting
  # back-date the loop's logical start by 100s; the terminal record must span it
  echo "$(( $(date +%s) - 100 ))" > "$WD/.t0"
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.wall_s >= 100' "$T")" = "true" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/resolve-story-loop-step.bats`
Expected: both FAIL — today a record is appended on every emit (including
AWAITING_FIX), and `.t0` does not exist.

- [ ] **Step 3: Implement**

Two edits to `resolve-story-loop.zsh`.

**3a — write `.t0` on fresh runs.** In the fresh-run `else` branch of the
resume handling (the one containing the two truncations), extend to:

```zsh
else
  : > "$history_file"
  : > "$changelists_file"
  # the loop's logical start — a step-mode run spans several invocations, and
  # the terminal telemetry must report whole-loop wall clock, not the last
  # round's (#971)
  print -r -- "$t0" > "$work_dir/.t0"
fi
```

**3b — gate + rebase the telemetry block.** In `emit_and_exit()`, replace the
telemetry section (from `local tfile="$telemetry_file"` through `rm -f
"$tmp_status"` and its closing `fi`) with:

```zsh
  # telemetry (#566): append exactly one JSONL record per LOOP — terminal
  # statuses only, never the non-terminal AWAITING_FIX (#971) — to the explicit
  # --telemetry-file or the git-ignored default under the repo. Never fatal.
  local tfile="$telemetry_file"
  [[ -z "$tfile" && -n "$repo" ]] && tfile="${repo%/}/.claude/telemetry/review-loop.jsonl"
  if [[ -n "$tfile" && "$st" != "AWAITING_FIX" ]]; then
    local t_begin="$t0"
    if [[ -n "$work_dir" && -s "$work_dir/.t0" ]]; then
      t_begin=$(<"$work_dir/.t0")
      [[ "$t_begin" == <-> ]] || t_begin="$t0"
    fi
    local tmp_status; tmp_status=$(mktemp)
    print -r -- "$out" > "$tmp_status"
    mkdir -p "${tfile:h}"
    local -a issue_arg; [[ -n "$issue" ]] && issue_arg=(--issue "$issue")
    "${self_dir}/build-telemetry-record.zsh" --status "$tmp_status" \
      "${issue_arg[@]}" --ts "$t_begin" --wall-s "$(( $(date +%s) - t_begin ))" >> "$tfile" || true
    rm -f "$tmp_status"
  fi
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/resolve-story-loop-step.bats` → 20 passing.
Run: `bats tests/resolve-story-loop.bats` and `bats tests/build-telemetry-record.bats`
→ all pass (hook mode: fresh run writes `.t0` equal to `t0`, so records are
unchanged; a hook-mode `--resume` now correctly spans the whole loop).

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh tests/resolve-story-loop-step.bats
git commit -m "feat(resolve-issue): terminal-only review-loop telemetry with whole-loop wall clock (#971)"
```

---

### Task 6: Rewrite the script header + SKILL.md §3.5

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh` (comment only)
- Modify: `development/skills/resolve-issue/SKILL.md` (§3.5 + interactive extension)

No bats here — verification is `zsh -n`, `pre-commit run --files <the two files>`
(markdownlint), and grep assertions listed in Step 4.

- [ ] **Step 1: Rewrite the script header comment**

Replace the header paragraph

```text
# The agentic steps — running the review panel and applying the implementor's
# fix pass — are model-driven, so they are injected as HOOK COMMANDS. This keeps
# the deterministic state machine (rounds, budget, consolidation, exit-state)
# testable, and lets /development:resolve-issue wire the real panel/fix/test
# commands (or a headless `claude -p`) behind the same seam.
```

with:

```text
# The agentic steps — running the review panel and applying the implementor's
# fix pass — are model-driven. The canonical wiring is STEP MODE (#971): the
# driving session runs the panel in-session (visible review agents), passes the
# aggregate findings via --findings-file, and this script processes exactly ONE
# round per invocation — exiting AWAITING_FIX (20) when blockers remain with
# budget left, so the session applies the fixes in-session (visible edits) and
# re-invokes with --resume. HOOK MODE (--review-cmd/--fix-cmd) remains as the
# deterministic seam the bats suite drives the state machine through; wiring a
# headless `claude -p` behind it is NOT a supported pattern — it hides the
# whole loop from the user behind one opaque background task.
```

Update the per-round flow block's last two arrows to:

```text
#     -> last round + blockers  => BUDGET_EXHAUSTED
#     -> else: step mode        => AWAITING_FIX (fix in-session, --resume)
#              hook mode        => fix pass -> re-run tests -> next round
```

After that block add:

```text
#
# Every round also appends a human-readable block to $work_dir/progress.md
# (#971) — the user tails it to watch a long run; writes are never fatal.
#
# Step mode:
#   --findings-file  this round's aggregate findings JSON (issue #558 schema,
#                    a flat array). Missing/empty file = "no findings". On
#                    --resume, --test-cmd (when given) runs FIRST — it gates
#                    the previous round's in-session fix; red exits ERROR (1).
```

Update the `--test-cmd` hook doc line to:

```text
#   --test-cmd    the repo gate. Hook mode: re-run after each fix. Step mode:
#                 run at --resume start (see above). Nonzero aborts the loop as
#                 an operational error (exit 1), never a verdict.
```

Update the Usage block to:

```text
# Usage:
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --findings-file FILE [--test-cmd CMD] [--resume] \
#       [--max-rounds N] [--status-file PATH] [--work-dir DIR]    # step mode
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] ...       # hook mode
#   resolve-story-loop.zsh --no-review   # skip the loop entirely (fast path)
```

And add to the exit-codes block, directly under the `0 CONVERGED` line:

```text
#   20  AWAITING_FIX              (step mode only: blockers remain, budget
#                                  left — fix in-session, then --resume)
```

- [ ] **Step 2: Rewrite SKILL.md §3.5's wiring section**

In `development/skills/resolve-issue/SKILL.md`, replace the block from
"Drive `development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — the
state machine (constants ..." through the end of the `--test-cmd` bullet
(ending "...must fail here, not at CI (#604).") with:

````markdown
Drive `development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — the
state machine (constants `MAX_REVIEW_ROUNDS=3`, `BLOCKING_SEVERITIES=(CRITICAL
WARNING)`) — in **step mode** (#971): one invocation per round, with every
model-driven step done **in-session, where the user can watch it**. Two hard
rules: **never** shell out to a headless `claude` (`claude -p` / `--print`)
for any model-driven step, and **never** run the loop as a long-lived
background task spanning rounds. The user must be able to see rounds happen:
visible review agents, visible fix edits, a narrated summary per round.

**At loop start, tell the user where to watch:** the loop appends one block per
round to `<work-dir>/progress.md` — say so once, e.g. "follow along with
`tail -f <work-dir>/progress.md`".

Each round:

1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh
   plan`, §#560) and spawn the reviewers of the skill it names in
   `review_skill` via the **Agent tool** (one agent per dimension, visible to
   the user), scoped to the plan's `changed_files`. Aggregate their findings
   into one #558-schema JSON array file — the round's findings file.
2. **One loop invocation.**

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <work-dir> --status-file <status.json> --issue <N> \
     --findings-file <findings-round-R.json> \
     --test-cmd '<full gate>' [--resume]
   ```

   `--resume` from round 2 on. On a `--resume` invocation the loop runs
   `--test-cmd` — the **full** suite (unit **and** integration), never a
   subset (#604) — FIRST, deterministically gating the previous round's
   in-session fix: red exits `ERROR` (1), the same "red after a fix aborts"
   rule as ever.
3. **On `AWAITING_FIX` (exit 20)** — blockers remain and budget is left:
   **narrate the round in the conversation** (round number; blockers found,
   new vs carried; the dimensions they came from; what you fix next — the
   same block the loop just appended to progress.md), then implement the
   blockers from the status JSON's `final_changelist.blocking` exactly as
   step 2 implements — Low suggestions never loop — re-run the full gate, and
   go to 1 for the next round's panel.
4. **On a terminal status**, take its branch below (`CONVERGED` → step 4;
   escalations → *Escalation*).

(Hook mode — `--review-cmd`/`--fix-cmd` — still exists as the bats test seam
only. Never wire it to a headless `claude`.)
````

Then, in the exit-status list below (the `CONVERGED` / `ESCALATE_*` bullets),
add a bullet directly after the `CONVERGED` one:

```markdown
- **`AWAITING_FIX` (20)** → not a verdict — the step-mode "narrate, fix
  in-session, `--resume`" turn of the round protocol above. Never build an
  escalation comment from it.
```

- [ ] **Step 3: Touch up the interactive extension**

Three surgical replacements in the same file.

Replace:

```markdown
   Then resume (step 5) with a `--fix-cmd` that **re-reads the issue's
   comments** as fix context (the readiness gate and escalation already read
   comments — reuse that, do not invent an env side-channel).
```

with:

```markdown
   Then resume (step 5): re-read the issue's comments during the pre-resume
   in-session fix pass so the guidance becomes fix context (the readiness gate
   and escalation already read comments — reuse that, do not invent an env
   side-channel).
```

Replace:

```markdown
   and implement the fixes exactly as step 2 implements, re-run the step-3 gate
   — resume only once it is green; red follows §3's rule (fix it, or abandon and
   report) — then resume the loop — same `--work-dir`, `--resume`, ceiling
   raised by 2 — and increment `grants`:
```

with:

```markdown
   and implement the fixes exactly as step 2 implements, re-run the step-3 gate
   — resume only once it is green; red follows §3's rule (fix it, or abandon and
   report) — run the next round's panel in-session (round protocol step 1) to
   produce its findings file, then resume the loop — same `--work-dir`,
   `--resume`, ceiling raised by 2 — and increment `grants`:
```

Replace:

```markdown
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <same-work-dir> --resume --max-rounds <prev_max + 2> \
     --review-cmd <cmd> --fix-cmd <guidance-aware cmd> --test-cmd <cmd> \
     --issue <N> --status-file <status.json>
```

with:

```markdown
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <same-work-dir> --resume --max-rounds <prev_max + 2> \
     --findings-file <findings-round-R.json> --test-cmd '<full gate>' \
     --issue <N> --status-file <status.json>
```

- [ ] **Step 4: Verify**

```bash
zsh -n development/skills/resolve-issue/scripts/resolve-story-loop.zsh
# the old blessing must be gone everywhere:
! grep -n "or a headless" development/skills/resolve-issue/scripts/resolve-story-loop.zsh
! grep -n "you provide three hooks" development/skills/resolve-issue/SKILL.md
! grep -n -- "--review-cmd <cmd>" development/skills/resolve-issue/SKILL.md
grep -n "AWAITING_FIX" development/skills/resolve-issue/SKILL.md
pre-commit run --files development/skills/resolve-issue/SKILL.md development/skills/resolve-issue/scripts/resolve-story-loop.zsh
bats tests/resolve-story-loop.bats tests/resolve-story-loop-step.bats
```

All green; both greps for removed text return nothing (exit 1 under `!`).

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh development/skills/resolve-issue/SKILL.md
git commit -m "docs(resolve-issue): mandate step-mode wiring, ban headless claude in the review loop (#971)"
```

---

### Task 7: `docs/explanation/review-loop.md` — "Watching it run"

**Files:**

- Modify: `docs/explanation/review-loop.md`

- [ ] **Step 1: Edit the page**

Insert a new section between "What one round does" and "The round budget and
how it can end":

```markdown
## Watching it run

The loop is transparent by construction. Earlier versions allowed the
model-driven steps to run inside headless `claude -p` hooks, which put a whole
multi-round loop behind a single opaque background task — you saw nothing
until it exited. The loop now runs in **step mode**: the driving session
processes one round per loop invocation, so everything model-driven happens in
the session where you can see it.

- **Review agents are visible** — each round's panel is spawned in-session,
  one named agent per review dimension, so the terminal shows who is
  reviewing what.
- **A narrated summary per round** — after each round the session reports the
  blockers found (new vs carried), the dimensions they came from, and what it
  fixes next.
- **A tail-able progress file** — the loop appends the same summary to a
  `progress.md` in its work directory (the run tells you the exact path when
  the loop starts); `tail -f` it from another terminal to follow a long run.
  The file survives the session.
```

In "What one round does", extend list item 1 by one sentence so it reads:

```markdown
1. **Review** — a language-appropriate reviewer panel inspects the change and
   emits findings (bugs, security, performance, code quality, tests). The
   panel runs as visible in-session agents, never as a hidden background
   process.
```

- [ ] **Step 2: Verify (markdownlint + strict docs build)**

```bash
pre-commit run --files docs/explanation/review-loop.md
python3 -m venv "$TMPDIR/venv-docs" && "$TMPDIR/venv-docs/bin/pip" install -q -r requirements-docs.txt
"$TMPDIR/venv-docs/bin/mkdocs" build --strict
```

Expected: markdownlint passes; `mkdocs build --strict` exits 0 (the page is
already in nav — no `mkdocs.yml` change needed).

- [ ] **Step 3: Commit**

```bash
git add docs/explanation/review-loop.md
git commit -m "docs(explanation): review loop — watching it run (step mode) (#971)"
```

---

### Task 8: Version bump, full suite, PR

**Files:**

- Modify: `development/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump the development plugin version (minor), lockstep**

Read the current version, bump minor, keep the two files identical on it —
preserve non-ASCII characters (use `ensure_ascii=False`):

```bash
CUR=$(jq -r .version development/.claude-plugin/plugin.json)
NEW="$(echo "$CUR" | awk -F. '{printf "%d.%d.0", $1, $2+1}')"
python3 - "$NEW" <<'EOF'
import json, pathlib, sys
new = sys.argv[1]
p = pathlib.Path("development/.claude-plugin/plugin.json")
d = json.loads(p.read_text()); d["version"] = new
p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
m = pathlib.Path(".claude-plugin/marketplace.json")
d = json.loads(m.read_text())
for pl in d["plugins"]:
    if pl["name"] == "development":
        pl["version"] = new
m.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
EOF
git diff --stat   # exactly the two version lines
```

- [ ] **Step 2: Run the WHOLE bats suite and pre-commit, read real exits**

```bash
bats tests/
echo "bats exit: $?"
pre-commit run --all-files
```

Expected: bats exit 0 (report the count as passed/total, e.g. 290/290);
pre-commit fully green. Fix anything red before proceeding — including stale
tests, in this same branch.

- [ ] **Step 3: Commit the bump**

```bash
git add development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(development): bump plugin version for review-loop step mode (#971)"
```

- [ ] **Step 4: Open the PR as the bot with auto-merge armed**

Use `/development:open-pr` (the Maintenance-App-authored PR flow) from the
implementation branch. PR body follows the repo template (Type / Summary /
Test plan) and MUST contain `Closes #971`. Auto-merge (squash) armed; a human
approves on this repo.

---

## Verification checklist (whole feature)

- `bats tests/` fully green, exit read directly (passed/total notation).
- `tests/resolve-story-loop.bats` unmodified in the diff
  (`git diff --stat origin/main -- tests/resolve-story-loop.bats` is empty).
- `grep -rn "claude -p" development/skills/resolve-issue/` shows no blessed headless wiring (only the explicit
  prohibitions may mention it).
- A manual smoke: in a scratch repo, run one step-mode round with a seeded blocker → exit 20, `progress.md` has
  the round block; resume clean → exit 0, `**Final:** CONVERGED` appended, exactly one telemetry record.
- Plugin version bumped in both manifests, identical values.
