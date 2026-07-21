# Interactive Review-Loop Escalation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a human is driving `/development:resolve-issue`, turn a
`BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` review-loop exit into an
in-session interactive extension (summarize → offer +2 rounds at a time with
optional guidance → answer questions → soft-cap), instead of always dead-ending
to an async GitHub comment.

**Architecture:** The zsh loop stays a headless, deterministic state machine and
only becomes *resumable* (`--resume`, using the shared `--work-dir` as its
state). All prompting lives in the conducting session (the skill layer), gated to
interactive runs. `build-escalation.zsh` gains a `--format summary` mode so the
conversational render and the eventual comment render share one data path.
Autonomous/epic/maintenance runs are untouched.

**Tech Stack:** zsh scripts, `jq`, `bats` (behavioural tests, run via the repo's
bats-in-Docker harness), Markdown skill/docs, MkDocs (strict build).

## Global Constraints

- **zsh for new/edited shell scripts**; keep the existing
  `emulate -L zsh; setopt nounset pipefail` idiom. Scripts ARE code — every
  script change ships with bats coverage.
- **Line length 120** everywhere; Markdown must pass `markdownlint` (the
  pre-commit hook runs it — a wrapped line must never start with `#`; code blocks
  and tables are exempt from MD013).
- **Report test counts faithfully** — passed/total (e.g. `10/10`), never
  passed/failed.
- **Plugin content change ⇒ version bump**: any change under `development/` bumps
  `development/.claude-plugin/plugin.json` **and** its
  `.claude-plugin/marketplace.json` entry in lockstep. This feature is a
  **minor** bump: `1.127.0 → 1.128.0`.
- **The exit-code contract of `resolve-story-loop.zsh` is frozen**:
  `0 CONVERGED · 10 AMBIGUOUS · 11 CONFLICT · 12 NO_CONVERGENCE ·
  13 BUDGET_EXHAUSTED · 2 usage · 1 operational`. `--resume` adds no new codes.
- **Autonomous safety is structural** — the interactive branch must be
  unreachable without a human present; never add a prompt to the zsh loop itself.
- Commit messages: Conventional Commits subject +
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
  Let pre-commit run (never `--no-verify`).

---

### Task 1: Make `resolve-story-loop.zsh` resumable (`--resume`)

Teach the loop to continue from a prior run's `--work-dir` instead of always
starting at round 1: read the last completed round from `history.jsonl`, seed
`prev_changelist` from the persisted `changelist-<n>.json` (so non-convergence
detection spans the extension), honour a raised `--max-rounds`, and **append** to
`history.jsonl` / `changelists.jsonl` rather than truncating.

**Files:**

- Modify: `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`
- Test: `tests/resolve-story-loop.bats`

**Interfaces:**

- Consumes: the existing work-dir artifacts written by a first-pass run —
  `history.jsonl` (one compact JSON object per round with `.round`),
  `changelist-<n>.json` (per-round consolidated changelist file),
  `changelists.jsonl`.
- Produces:
  `resolve-story-loop.zsh --resume --repo PATH --work-dir DIR --max-rounds N
  [--base REF] --review-cmd CMD --fix-cmd CMD [--test-cmd CMD]` — resumes at
  `last_round + 1`, exits with the same status JSON schema and the same exit
  codes as a first-pass run. `--resume` with no existing non-empty
  `history.jsonl` in the work-dir is a usage error (exit 2).

- [ ] **Step 1: Write the failing tests**

Add these three tests to the end of `tests/resolve-story-loop.bats` (top-level
`@test` blocks appended after line 116). They reuse the existing `setup()` and
`loop()` helpers.

```bash
@test "--resume continues from a prior work-dir at last_round+1 and can converge" {
  WD="$BATS_TEST_TMPDIR/wd-resume"
  # First pass: budget 1 -> a single round with a blocker -> BUDGET_EXHAUSTED at round 1.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]

  # Resume with a raised ceiling; this round emits nothing -> CONVERGED at round 2.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # continued, did not restart: exit round is 2, and history/changelists span both passes
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
}

@test "--resume carries prev_changelist so the first extension round can trip NO_CONVERGENCE" {
  WD="$BATS_TEST_TMPDIR/wd-resume-nc"
  # First pass budget 1: one blocker, one round, exhausts (no prior round to compare against yet).
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]

  # Resume: the SAME blocker recurs -> non-convergence must fire against the carried prior round.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # exited on the first resumed round (round 2), not after burning to the new ceiling
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "--resume without prior history in the work-dir is a usage error (exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-empty" --resume \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (bats-in-Docker harness — the repo's standard bats runner; if invoking bats
directly it must be a zsh-aware environment with `jq` and `git`):

```bash
bats tests/resolve-story-loop.bats -f "resume"
```

Expected: the three `resume` tests FAIL — the first two because `--resume` is an
unknown flag (`unknown flag: --resume`, exit 2) so the *second* invocation never
converges/escalates as asserted; the third currently exits 2 for the wrong reason
(unknown flag, not the missing-history guard) — it may accidentally pass, which
is fine, but the first two must fail.

- [ ] **Step 3: Add the `--resume` flag and resume-state wiring**

In `development/skills/resolve-issue/scripts/resolve-story-loop.zsh`:

3a. Declare the flag default. Change (around line 60-61):

```zsh
local max_rounds=$MAX_REVIEW_ROUNDS status_file="" work_dir="" no_review=0
local issue="" telemetry_file=""
```

to:

```zsh
local max_rounds=$MAX_REVIEW_ROUNDS status_file="" work_dir="" no_review=0
local issue="" telemetry_file="" resume=0
```

3b. Parse it. In the `while` arg loop, add a case alongside `--no-review` (after
line 74):

```zsh
  --resume) resume=1; shift ;;
```

3c. Update the `--help`/usage string (line 75) to include `[--resume]`:

```zsh
  -h|--help) print -r -- "usage: resolve-story-loop.zsh --repo PATH --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] [--base REF] [--max-rounds N] [--resume] [--issue N] [--telemetry-file PATH] [--no-review]"; exit 0 ;;
```

3d. Replace the work-dir setup block (current lines 136-139):

```zsh
[[ -n "$work_dir" ]] || work_dir=$(mktemp -d)
mkdir -p "$work_dir"
local history_file="$work_dir/history.jsonl"; : > "$history_file"
local changelists_file="$work_dir/changelists.jsonl"; : > "$changelists_file"
```

with a version that branches on `$resume`:

```zsh
[[ -n "$work_dir" ]] || work_dir=$(mktemp -d)
mkdir -p "$work_dir"
local history_file="$work_dir/history.jsonl"
local changelists_file="$work_dir/changelists.jsonl"
# On --resume we CONTINUE a prior run: the work-dir IS the state. Read the last
# completed round from history, and re-use its persisted changelist file as the
# prior round so non-convergence detection spans the extension. A fresh run
# (no --resume) truncates both accumulators as before.
local resume_round=0 resume_prev=""
if (( resume )); then
  [[ -s "$history_file" ]] || {
    print -u2 -- "resolve-story-loop: --resume needs an existing non-empty history in --work-dir"; exit 2 }
  resume_round=$(tail -n 1 "$history_file" | jq -r '.round')
  [[ "$resume_round" == <-> ]] || {
    print -u2 -- "resolve-story-loop: --resume could not read a round number from $history_file"; exit 1 }
  resume_prev="$work_dir/changelist-$resume_round.json"
  [[ -s "$resume_prev" ]] || {
    print -u2 -- "resolve-story-loop: --resume cannot find prior changelist $resume_prev"; exit 1 }
else
  : > "$history_file"
  : > "$changelists_file"
fi
```

3e. Seed the loop counter and prior changelist from the resume state. Change the
loop-locals line (current line 165):

```zsh
local round=1 loop_status="" final_changelist="" prev_changelist=""
```

to:

```zsh
local round=$(( resume_round + 1 )) loop_status="" final_changelist="" prev_changelist="$resume_prev"
```

No other loop-body change is needed: a non-empty `prev_changelist` already routes
consolidation through the `--prev` branch (lines 190-196), and the appends to
`history_file` / `changelists_file` continue naturally because they are no longer
truncated on resume.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats tests/resolve-story-loop.bats
```

Expected: PASS — all tests, including the pre-existing ones (a fresh run still
truncates and starts at round 1) and the three new `resume` tests. Report as
passed/total.

- [ ] **Step 5: Lint the script**

```bash
zsh -n development/skills/resolve-issue/scripts/resolve-story-loop.zsh
```

Expected: `zsh -n` clean (exit 0). The pre-commit `zsh -n` hook is the gate;
shellcheck is advisory for zsh.

- [ ] **Step 6: Commit**

```bash
git add development/skills/resolve-issue/scripts/resolve-story-loop.zsh tests/resolve-story-loop.bats
git commit -m "feat(resolve-issue): resumable review loop (--resume continues from work-dir)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `build-escalation.zsh --format summary`

Give the escalation builder a conversational render mode that shares the comment's
data extraction, so the interactive summary shown in-session can never drift from
the async comment. `summary` emits the typed header, one-line summary, the details
block, and the round history — **no** options list, **no** branch/no-PR note,
**no** machine marker (the skill drives the live options itself).

**Files:**

- Modify: `development/skills/resolve-issue/scripts/build-escalation.zsh`
- Test: `tests/build-escalation.bats`

**Interfaces:**

- Consumes: the same loop status JSON as today.
- Produces: `build-escalation.zsh --status FILE [--format comment|summary] ...`.
  Default `comment` is byte-for-byte today's output. `summary` omits the options,
  the branch link, and the `<!-- review-loop-escalation: ... -->` marker. An
  unknown `--format` value is a usage error (exit 2).

- [ ] **Step 1: Write the failing test**

Append to `tests/build-escalation.bats` (top-level `@test` blocks after line 94):

```bash
@test "--format summary: conversational render, no options / marker / branch note" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,
 "history":[{"round":1,"blocking":1,"conflicts":0,"non_converging":false},
            {"round":2,"blocking":1,"conflicts":0,"non_converging":false},
            {"round":3,"blocking":1,"conflicts":0,"non_converging":false}],
 "final_changelist":{"blocking":[{"priority":"High","dimension":"performance","file":"b.py","line":5,"title":"N+1"}]}}
EOF
  run zsh "$S" --status "$ST" --issue 603 --format summary
  [ "$status" -eq 0 ]
  # shares the comment's data: the status and the remaining blocker location appear
  echo "$output" | grep -q 'BUDGET_EXHAUSTED'
  echo "$output" | grep -q 'b.py:5'
  echo "$output" | grep -q 'Round 3:'
  # but it is NOT the comment: no options, no marker, no no-PR note
  ! echo "$output" | grep -q 'How to proceed'
  ! echo "$output" | grep -q '<!-- review-loop-escalation'
  ! echo "$output" | grep -q 'no PR opened'
}

@test "--format: unknown value is a usage error (exit 2)" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,"history":[],"final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --format bogus
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats tests/build-escalation.bats -f "format"
```

Expected: FAIL — `--format` is an unknown flag today (`unknown flag: --format`,
exit 2), so the `summary` test fails its `status -eq 0` / content assertions.

- [ ] **Step 3: Parse `--format` and branch the assembly**

3a. Declare and parse the option. Change (current lines 27-33) from:

```zsh
local status_file="" issue="" branch="" compare_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --branch) branch="$2"; shift 2 ;;
  --compare-url) compare_url="$2"; shift 2 ;;
```

to:

```zsh
local status_file="" issue="" branch="" compare_url="" fmt="comment"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --branch) branch="$2"; shift 2 ;;
  --compare-url) compare_url="$2"; shift 2 ;;
  --format) fmt="$2"; shift 2 ;;
```

3b. Validate it right after the arg loop, next to the existing `--status`
required-check (after line 40):

```zsh
[[ "$fmt" == "comment" || "$fmt" == "summary" ]] || {
  print -u2 -- "build-escalation: --format must be 'comment' or 'summary'"; exit 2 }
```

3c. Update the usage string on line 34 to mention `[--format comment|summary]`:

```zsh
  -h|--help) print -r -- "usage: build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL] [--format comment|summary]"; exit 0 ;;
```

3d. Branch the final assembly. The existing `{ ... }` assembly block (current
lines 113-145) stays as the `comment` path. Insert a `summary` path before it —
change:

```zsh
# assemble the comment
{
  print -r -- "## 🚦 Review loop escalation — \`${st}\`"
```

to:

```zsh
# --- summary render (interactive, #562 resume): shares the extraction above,
# omits options / branch note / marker — the skill drives the live options.
if [[ "$fmt" == "summary" ]]; then
  {
    print -r -- "Review loop **\`${st}\`** — ${rounds}/${max_rounds} rounds."
    print -r --
    print -r -- "$summary"
    if [[ -n "$detail" ]]; then
      print -r --
      print -r -- "**Remaining**"
      print -r --
      print -r -- "$detail"
    fi
    print -r --
    print -r -- "**Round history**"
    print -r --
    print -r -- "$history_lines"
  }
  exit 0
fi

# assemble the comment
{
  print -r -- "## 🚦 Review loop escalation — \`${st}\`"
```

The round-history lines already render as `- Round N: ...`, so the `Round 3:`
assertion is satisfied by the shared `$history_lines`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats tests/build-escalation.bats
```

Expected: PASS — all tests (the existing `comment`-path tests are unchanged
because `fmt` defaults to `comment`, plus the two new `format` tests). Report as
passed/total.

- [ ] **Step 5: Lint the script**

```bash
zsh -n development/skills/resolve-issue/scripts/build-escalation.zsh
```

Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add development/skills/resolve-issue/scripts/build-escalation.zsh tests/build-escalation.bats
git commit -m "feat(resolve-issue): build-escalation --format summary (shared conversational render)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire the interactive escalation branch into `SKILL.md`

Add the human-present interactive extension to §3.5's Escalation section: on a
gated exit (`BUDGET_EXHAUSTED` / `ESCALATE_NO_CONVERGENCE`) in an interactive run,
summarize (via `build-escalation.zsh --format summary`), offer +2 rounds /
guidance / Q&A (`AskUserQuestion`), resume the loop (`--resume`, ceiling `+2`),
post guidance to the issue for re-read, soft-cap at ~5 grants, and fall back to
today's typed comment on Stop. Autonomous runs and the other exits keep today's
behaviour verbatim.

**Files:**

- Modify: `development/skills/resolve-issue/SKILL.md` (insert into §3.5
  Escalation, currently lines 456-487)

**Interfaces:**

- Consumes: `resolve-story-loop.zsh --resume` (Task 1) and
  `build-escalation.zsh --format summary` (Task 2).
- Produces: prose only — no new script surface. The existing
  `build-escalation.zsh` comment path (steps 1-4 of today's Escalation) becomes
  the **Stop/decline terminal** the new branch falls back to.

- [ ] **Step 1: Insert the interactive branch**

In `development/skills/resolve-issue/SKILL.md`, immediately **after** the
escalation section heading + intro (current lines 456-460, ending
`…**no PR, no auto-merge exposure**:`) and **before** the numbered
`1. **Push the branch as the bot**…`, insert this block. The numbered comment
steps that follow remain, now framed as the *Stop / autonomous* terminal.

````markdown
**Interactive extension (human present, `BUDGET_EXHAUSTED` /
`ESCALATE_NO_CONVERGENCE` only, #562-resume).** When the run is
**interactive** — the same human-present determination §0a's remediation uses —
and the loop exited `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE`, do **not**
jump straight to the comment. The person who can grant "two more rounds" or
supply the missing constraint is right here; offer that in-session first. (Every
other exit — `ESCALATE_CONFLICT`, `ESCALATE_AMBIGUOUS` — and **every autonomous
run** skip this branch entirely and go straight to the typed comment below.)

Run this extension loop, tracking a `grants` counter (starts at 0):

1. **Summarize** the exit in the conversation — never make the human read a
   comment when they are right here:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> --format summary
   ```

   It prints the typed status, the remaining blockers, and the round history —
   the same data the comment would carry, so nothing drifts.

2. **Offer the choice** with `AskUserQuestion` (one question), tailored to the
   exit type. The built-in **"Other"** option is the free-text channel — the
   human uses it to *ask you a question* ("why is that blocker stuck?", "show me
   the diff for `b.py`") **or** to *type guidance*.
   - `BUDGET_EXHAUSTED`: **Grant +2 rounds** · **Grant +2 with guidance** ·
     **Stop**.
   - `ESCALATE_NO_CONVERGENCE`: **Give guidance & retry (+2)** — the primary
     lever, since more rounds alone will not move a stuck blocker — · **Stop**.

3. **If they asked a question** (Other → a question, not guidance): answer it
   from the changelist / dossier, then **re-present step 2**. A question never
   consumes a grant.

4. **If they gave guidance** (with or without a grant): **post it as an issue
   comment** so it is durable and survives a dead session, tagged so the audit
   trail separates human guidance from the automated escalation comment:

   ```bash
   gh issue comment <N> --body "<!-- review-loop-guidance -->
   $GUIDANCE"
   ```

   Then resume (step 5) with a `--fix-cmd` that **re-reads the issue's
   comments** as fix context (the readiness gate and escalation already read
   comments — reuse that, do not invent an env side-channel).

5. **If they granted rounds** (with or without guidance): resume the loop —
   same `--work-dir`, `--resume`, ceiling raised by 2 — and increment `grants`:

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <same-work-dir> --resume --max-rounds <prev_max + 2> \
     --review-cmd <cmd> --fix-cmd <guidance-aware cmd> --test-cmd <cmd> \
     --issue <N> --status-file <status.json>
   ```

   On `CONVERGED` (exit 0) → leave this branch and proceed to step 4 (version
   bump) / PR as normal. On another `BUDGET_EXHAUSTED` /
   `ESCALATE_NO_CONVERGENCE` → go back to step 1 with the new status. On
   `ESCALATE_CONFLICT` / `ESCALATE_AMBIGUOUS` / an operational error → leave this
   branch and take the typed-comment terminal below (a resumed run can surface a
   different exit).

6. **Soft cap.** Before re-offering, if `grants >= 5` **or** the just-finished
   extension produced **zero net blocker reduction** vs. the prior round
   (compare `.round_changelists[-1].summary.blocking` to the round before), say
   so plainly — "this isn't converging; the diff may need rethinking" — and nudge
   toward **Stop** or splitting the work into a follow-up issue. Never hard-stop
   on the human; they may still choose to extend.

7. **Stop / decline** (the human picks Stop, or bails via "Other"): fall through
   to the typed-comment terminal below, exactly as an autonomous run does. The
   diff-so-far and any guidance are already on the issue; the human can resume
   later with `/development:resolve-issue <N>`.

If the interactive extension ended in `CONVERGED`, skip the terminal below and
continue to §4. Otherwise:
````

- [ ] **Step 2: Confirm the terminal steps still flow**

The inserted block ends with "Otherwise:", immediately before the existing
`1. **Push the branch as the bot**` line. No change to the numbered steps
themselves is required — they now read as the shared Stop/autonomous terminal.
Verify the numbered list still begins at `1.` and flows correctly after the
inserted block.

- [ ] **Step 3: Update the §3.5 status-handling bullet**

In the loop-exit bullet list (current lines 449-451), note the interactive fork.
Replace:

```markdown
- **`ESCALATE_CONFLICT` / `ESCALATE_NO_CONVERGENCE` / `ESCALATE_AMBIGUOUS`
  (10–12) / `BUDGET_EXHAUSTED` (13)** → do **not** commit or open a PR — go to
  *Escalation* below. Opening a PR here would spend CI on unconverged work.
```

with:

```markdown
- **`ESCALATE_CONFLICT` / `ESCALATE_NO_CONVERGENCE` / `ESCALATE_AMBIGUOUS`
  (10–12) / `BUDGET_EXHAUSTED` (13)** → do **not** commit or open a PR — go to
  *Escalation* below. Opening a PR here would spend CI on unconverged work.
  On an interactive run, `BUDGET_EXHAUSTED` and `ESCALATE_NO_CONVERGENCE` first
  enter the **interactive extension** (offer more rounds / guidance) before any
  comment; the others, and all autonomous runs, go straight to the typed comment.
```

- [ ] **Step 4: Verify the Markdown lints and references resolve**

```bash
markdownlint development/skills/resolve-issue/SKILL.md
grep -q -- '--format summary' development/skills/resolve-issue/SKILL.md
grep -q -- '--resume' development/skills/resolve-issue/SKILL.md
```

Expected: markdownlint clean (exit 0), and both `grep`s succeed (the prose
references the two real new flags from Tasks 1-2).

- [ ] **Step 5: Commit**

```bash
git add development/skills/resolve-issue/SKILL.md
git commit -m "feat(resolve-issue): interactive review-loop escalation for budget/non-convergence

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: User documentation — explain the loop and the interactive escalation

Add a Diátaxis **explanation** page that walks a human through the local review
loop and, in particular, exactly what the new interactive escalation prompt looks
and behaves like. Wire it into the MkDocs nav and cross-link from the reference.

**Files:**

- Create: `docs/explanation/review-loop.md`
- Modify: `mkdocs.yml` (nav, Explanation section, after line 105)
- Modify: `docs/reference/commands.md:24` (the `/development:resolve-issue` row —
  add a clause about the interactive extension)

**Interfaces:**

- Consumes: nothing at runtime; documents Tasks 1-3.
- Produces: a nav-reachable page `explanation/review-loop.md`.

- [ ] **Step 1: Write the explanation page**

Create `docs/explanation/review-loop.md` with this content:

```markdown
# The local review loop

Before `/development:resolve-issue` opens a pull request, it runs a **local,
pre-push review loop** on the change. The point is simple: a PR is only opened on
code a reviewer panel has already converged on, so no CI minutes are ever spent
on work that still has open review blockers.

## What one round does

Each round, scoped to the story's diff:

1. **Review** — a language-appropriate reviewer panel inspects the change and
   emits findings (bugs, security, performance, code quality, tests).
2. **Consolidate** — findings are de-duplicated and split into **blockers**
   (Critical + High) and **Low suggestions**. Only blockers drive the loop; Low
   suggestions are logged, never looped on.
3. **Fix** — if there are blockers, an implementor pass fixes them.
4. **Re-test** — the full test suite runs again; a fix that breaks anything
   aborts the loop rather than shipping.

The loop repeats until it **converges** — a round with **zero blockers**. Low
suggestions remaining is still converged.

## The round budget and how it can end

The loop has a hard budget (three rounds by default). A round can end the loop in
one of a few ways:

- **Converged** — zero blockers. The run proceeds to open the PR.
- **Budget exhausted** — the rounds ran out with blockers still open.
- **Not converging** — the *same* blocker survived two rounds unchanged; more
  automated fixing clearly is not moving it.
- **Conflict / ambiguous** — two reviewers gave opposing recommendations, or the
  repository type could not be resolved to a review panel.

## When a human is driving: the interactive extension

If **you** launched `/development:resolve-issue` and are present, the two
"still making progress but not done" endings — **budget exhausted** and **not
converging** — do not dead-end. Instead the run pauses and talks to you:

1. It **summarizes** what is left: the remaining blockers and a per-round
   history.
2. It **offers you a choice**:
   - **Grant two more rounds** — keep the loop going against the current state.
   - **Give guidance, then retry** — tell it something it is missing ("that auth
     check is intentional, don't flag it"; "try a documented fast-path helper for
     the retry logic"). Your note is posted to the issue and folded into the next
     fix pass. For a *not-converging* blocker this is the main lever — more rounds
     alone will not move a stuck blocker, but the missing constraint will.
   - **Ask a question** — "why is that blocker stuck?", "show me the diff for
     that file". You get an answer and the same choice again; asking never uses
     up a grant.
   - **Stop** — hand off asynchronously (see below).
3. If you grant rounds, the loop **resumes where it left off** — the round count
   and the not-converging detection carry across the extension, so it is a true
   continuation, not a restart.
4. You can extend repeatedly, two rounds at a time. After about five grants, or
   any round that removes no blockers, the run will warn you that it does not
   look like it is converging and suggest stopping or splitting the work — but
   the decision stays yours.

## When you stop, or a run is unattended

If you choose **Stop**, or the run is **autonomous** (an epic-driven or
maintenance run, with no human to prompt), the loop takes the asynchronous path
instead: it posts **one** typed comment on the issue — the escalation type, a
summary, the round history, and two or three concrete options — applies the
`needs-human-decision` label, and pushes the branch so the diff-so-far is
linkable, **without opening a PR** (a draft would spend the CI minutes the local
loop exists to save). You (or anyone) answer in the thread and re-run
`/development:resolve-issue <N>`; the next run reads your comment as context and
picks up from there.

## Skipping the loop

`/development:resolve-issue` can run with the loop disabled (the `--no-review`
fast path) when you deliberately want no local review round — for example on a
trivial change you will review yourself.
```

- [ ] **Step 2: Wire it into the MkDocs nav**

In `mkdocs.yml`, in the `Explanation:` block, add the page after the
`target-repo docs stack` line (current line 105):

```yaml
      - The local review loop: explanation/review-loop.md
```

- [ ] **Step 3: Cross-link from the command reference**

In `docs/reference/commands.md`, at the end of the `/development:resolve-issue`
description cell (line 24), append this sentence before the closing `|` (one
physical line — table rows are exempt from MD013):

```markdown
 When a human is driving, a `BUDGET_EXHAUSTED` / non-converging review-loop exit becomes an interactive extension (offer more rounds, give guidance, ask questions) — see [The local review loop](../explanation/review-loop.md).
```

- [ ] **Step 4: Verify the docs build (strict) and lint**

```bash
markdownlint docs/explanation/review-loop.md docs/reference/commands.md
mkdocs build --strict 2>&1 | tail -5
```

Expected: markdownlint clean; `mkdocs build --strict` finishes with no warnings
(a nav-orphaned page or a broken relative link would fail `--strict`). If the
repo invokes mkdocs via a wrapper (e.g. `python -m mkdocs`), use that form.

- [ ] **Step 5: Commit**

```bash
git add docs/explanation/review-loop.md mkdocs.yml docs/reference/commands.md
git commit -m "docs(resolve-issue): explain the review loop and interactive escalation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Version bump (development plugin, minor)

Bump the `development` plugin in lockstep so installs pick up the new behaviour
and CI's manifest check passes.

**Files:**

- Modify: `development/.claude-plugin/plugin.json` (`version`)
- Modify: `.claude-plugin/marketplace.json` (the `development` entry `version`)

**Interfaces:** none.

- [ ] **Step 1: Bump `plugin.json`**

In `development/.claude-plugin/plugin.json` change `"version": "1.127.0",` to
`"version": "1.128.0",`.

- [ ] **Step 2: Bump the marketplace entry**

In `.claude-plugin/marketplace.json`, in the object with `"name": "development"`,
change `"version": "1.127.0",` to `"version": "1.128.0",`.

- [ ] **Step 3: Verify lockstep**

```bash
grep -m1 version development/.claude-plugin/plugin.json
grep -n -A3 '"name": "development"' .claude-plugin/marketplace.json | grep version
```

Expected: both read `1.128.0`.

- [ ] **Step 4: Commit**

```bash
git add development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(development): bump to 1.128.0 for interactive review-loop escalation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] **Run the full affected bats suites:**

```bash
bats tests/resolve-story-loop.bats tests/build-escalation.bats
```

Expected: all tests pass (report passed/total for each file).

- [ ] **Confirm autonomous behaviour is untouched:** re-read the inserted
  SKILL.md block and confirm the interactive branch is gated on *both* an
  interactive run *and* status ∈ {BUDGET_EXHAUSTED, NO_CONVERGENCE}, and that the
  numbered comment terminal is reached unchanged for every other path.

- [ ] **Confirm the spec's non-goal held:** grep the diff for any consolidator/PR
  change implementing "waive" — there must be none (interactive waive is a v1
  non-goal).

```bash
git diff main --stat
```

- [ ] **Open the PR** via `/development:open-pr` (bot-authored, squash auto-merge
  armed), body following the Type / Summary / Test plan template with the bats
  evidence, and `Closes #<issue>` once an issue is filed for this work.
