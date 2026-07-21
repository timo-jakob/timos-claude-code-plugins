# Pre-review Mechanical Guardrails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Epic:** [#918](https://github.com/timo-jakob/timos-claude-code-plugins/issues/918) — each task below is one
> child issue and one PR, landed sequentially off fresh `origin/main` per repo convention.

**Goal:** Move the three mechanically-detectable defect classes that review loops keep catching late (untested
new flags, wrong-file-path edits, exit-code contract drift) into deterministic pre-review checks.

**Architecture:** Three standalone zsh scripts under `scripts/` (repo-level, not plugin content), each with bats
coverage in `tests/`; two run diff-aware in a new `guardrails` CI job in `lint.yml`, one runs as a checked-in
`PreToolUse` hook via a new `.claude/settings.json`. A CLAUDE.md section makes the rules visible to interactive
sessions.

**Tech Stack:** zsh (repo scripting convention), bats (tests/ suite, runs in Docker locally / natively in CI),
jq, GitHub Actions.

## Global Constraints

- New shell scripts are **zsh** (ARCHITECTURE.md scripting convention), start with `#!/usr/bin/env zsh`, use
  `setopt err_exit nounset pipefail` unless exit codes are managed manually (the hook script), and derive
  `REPO_ROOT="${0:A:h:h}"`.
- 120-column limit everywhere; yamllint-clean YAML (two-space comment indent); markdownlint-clean markdown.
- Every script change ships its bats test in the same PR (`tests/<script-name>.bats`), runnable via
  `tests/run-script-tests.zsh --local`.
- Exit-code convention for check scripts: `0` clean, `1` findings, `2` usage error — and the script's header
  comment documents them.
- No plugin content is touched → **no** plugin.json/marketplace.json bumps in this epic. (The spec's
  contract-integrity prompt extension was verified already-present during planning and dropped.)
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Flag-test coverage check + CI job

**Files:**

- Create: `scripts/check-flag-test-coverage.zsh`
- Create: `tests/check-flag-test-coverage.bats`
- Modify: `.github/workflows/lint.yml` (append a `guardrails` job)

**Interfaces:**

- Consumes: nothing from other tasks.
- Produces: `check-flag-test-coverage.zsh [--base <ref>]` (default `origin/main`), exit 0/1/2 as above; the
  `guardrails` job in `lint.yml` that Task 3 extends with a second step.

- [ ] **Step 1: Write the failing tests**

Create `tests/check-flag-test-coverage.bats`:

```bash
#!/usr/bin/env bats
#
# Behavioral tests for check-flag-test-coverage.zsh (#918): a flag newly added
# to a *.zsh case-arm parse loop must appear in at least one tests/*.bats.
# Each test builds a throwaway git repo fixture and runs a COPY of the script
# from inside it (REPO_ROOT derives from the script's own location).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/scripts" "$WORK/tests"
  cp "$REPO_ROOT/scripts/check-flag-test-coverage.zsh" "$WORK/scripts/"
  CHECK="$WORK/scripts/check-flag-test-coverage.zsh"
  cd "$WORK"
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  cat > tool.zsh <<'EOF'
#!/usr/bin/env zsh
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old) old="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
EOF
  cat > tests/tool.bats <<'EOF'
@test "old flag" { run zsh tool.zsh --old x; }
EOF
  git add -A
  git commit -qm init
}

add_new_flag() {  # appends a --new case arm to tool.zsh's parse loop
  cat > tool.zsh <<'EOF'
#!/usr/bin/env zsh
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old) old="$2"; shift 2 ;;
    --new) new="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
EOF
}

@test "no zsh changes: exits 0" {
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
}

@test "new flag with no test mention: exits 1 and names script:flag" {
  add_new_flag
  run zsh "$CHECK" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "tool.zsh:--new"
}

@test "new flag mentioned in a bats file: exits 0" {
  add_new_flag
  cat > tests/tool.bats <<'EOF'
@test "old flag" { run zsh tool.zsh --old x; }
@test "new flag" { run zsh tool.zsh --new y; }
EOF
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
}

@test "pre-existing flag untouched: not flagged" {
  # change the file without adding a case arm — comment-only edit
  print '# trailing comment' >> tool.zsh
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
}

@test "unresolvable base ref: exits 2" {
  run zsh "$CHECK" --base no-such-ref
  [ "$status" -eq 2 ]
}

@test "unknown argument: exits 2" {
  run zsh "$CHECK" --bogus
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/check-flag-test-coverage.bats`
Expected: all tests FAIL (`No such file or directory` — the script does not exist yet).

- [ ] **Step 3: Implement the script**

Create `scripts/check-flag-test-coverage.zsh`:

```zsh
#!/usr/bin/env zsh
# check-flag-test-coverage.zsh — diff-aware guardrail (#918): every flag newly
# added to a *.zsh script's case-arm parse loop must appear in at least one
# tests/*.bats file, or the check fails.
#
# Usage: check-flag-test-coverage.zsh [--base <ref>]      (default origin/main)
#
# Exits 0 when every newly added flag has a test mention, 1 on findings
# (listing script:flag pairs), 2 on usage errors (unknown argument,
# unresolvable merge-base) — an unresolvable base is never a silent pass.
#
# The floor this enforces is "the token appears somewhere under tests/" —
# deliberately shallow; test QUALITY stays the review loop's job. See
# docs/superpowers/specs/2026-07-21-pre-review-guardrails-design.md.

setopt err_exit nounset pipefail

readonly REPO_ROOT="${0:A:h:h}"

base="origin/main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { print -u2 -- "--base needs a value"; exit 2 }
      base="$2"; shift 2 ;;
    *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done

mb=$(git -C "$REPO_ROOT" merge-base "$base" HEAD 2>/dev/null) \
  || { print -u2 -- "cannot resolve merge-base of '$base' and HEAD"; exit 2 }

findings=0
while IFS= read -r -d '' f; do
  [[ "$f" == *.zsh ]] || continue
  # Newly added case-arm lines, e.g. `+    --foo) x="$2"; shift 2 ;;` or
  # `+  --a|--b)`; extract each flag token from them.
  added=$(git -C "$REPO_ROOT" diff "$mb" -- "$f" \
    | grep -E '^\+[[:space:]]*(--[a-z0-9-]+\|)*--[a-z0-9-]+\)' \
    | grep -oE -- '--[a-z0-9][a-z0-9-]*' | sort -u) || true
  [[ -z "$added" ]] && continue
  while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if ! grep -rqF --include='*.bats' -- "$flag" "$REPO_ROOT/tests"; then
      print -u2 -- "✗ ${f}:${flag} — new flag with no mention in tests/*.bats"
      findings=$((findings + 1))
    fi
  done <<< "$added"
done < <(git -C "$REPO_ROOT" diff -z --name-only --diff-filter=d "$mb")

if (( findings > 0 )); then
  print -u2 -- ""
  print -u2 -- "$findings new flag(s) without bats coverage. Add a test exercising each flag"
  print -u2 -- "(parse + behaviour) in tests/ — see CLAUDE.md 'Pre-review guardrails' (#918)."
  exit 1
fi
print -- "flag-test coverage: clean"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/check-flag-test-coverage.bats`
Expected: 6/6 PASS. Then run the whole suite: `tests/run-script-tests.zsh --local` — all green.

- [ ] **Step 5: Add the CI job**

Append to `.github/workflows/lint.yml` (same file, new job after `lint:`):

```yaml
  guardrails:
    # Diff-aware pre-review guardrails (#918). PR-only: they need a base ref.
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - name: Install zsh
        run: sudo apt-get update && sudo apt-get install -y --no-install-recommends zsh
      - name: Flag-test coverage check
        run: zsh scripts/check-flag-test-coverage.zsh --base "origin/${{ github.base_ref }}"
```

Verify locally: `pre-commit run --all-files` (yamllint gate) and `zsh scripts/check-flag-test-coverage.zsh`
(against `origin/main`; expect `flag-test coverage: clean` — the new script's own `--base` flag is mentioned in
its bats file, which is exactly the discipline).

- [ ] **Step 6: Commit**

```bash
git add scripts/check-flag-test-coverage.zsh tests/check-flag-test-coverage.bats .github/workflows/lint.yml
git commit -m "feat(guardrails): diff-aware flag-test coverage check + CI job (#918)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Edit-target PreToolUse hook + checked-in settings

**Files:**

- Create: `scripts/edit-target-guard.zsh`
- Create: `.claude/settings.json`
- Create: `tests/edit-target-guard.bats`

**Interfaces:**

- Consumes: nothing from other tasks.
- Produces: `edit-target-guard.zsh` — hook JSON on stdin; exit 0 allow, exit 2 block (reason on stderr), exit 1
  internal error. Reads `$CLAUDE_PROJECT_DIR` and `$HOME`.

- [ ] **Step 1: Write the failing tests**

Create `tests/edit-target-guard.bats`:

```bash
#!/usr/bin/env bats
#
# Behavioral tests for edit-target-guard.zsh (#918) — the PreToolUse hook that
# blocks writes to the installed plugin cache and, from a worktree session,
# to the main checkout. Env (HOME, CLAUDE_PROJECT_DIR) is faked per test.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$REPO_ROOT/scripts/edit-target-guard.zsh"
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  MAIN="$BATS_TEST_TMPDIR/main-checkout"
  WT="$MAIN/.claude/worktrees/fixture-worktree"
  mkdir -p "$FAKE_HOME/.claude/plugins/cache/some-plugin" "$WT"
}

hook_json() {  # $1 = file_path
  printf '{"tool_input":{"file_path":"%s"}}' "$1"
}

@test "plugin cache path: blocked (exit 2)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< "$(hook_json "$FAKE_HOME/.claude/plugins/cache/some-plugin/SKILL.md")"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "plugin cache"
}

@test "main-checkout path from a worktree session: blocked (exit 2)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< "$(hook_json "$MAIN/development/some-file.md")"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "main checkout"
}

@test "worktree path from a worktree session: allowed (exit 0)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< "$(hook_json "$WT/development/some-file.md")"
  [ "$status" -eq 0 ]
}

@test "unrelated path (scratchpad): allowed (exit 0)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< "$(hook_json "$BATS_TEST_TMPDIR/scratch/notes.md")"
  [ "$status" -eq 0 ]
}

@test "non-worktree session may edit its own checkout: allowed (exit 0)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$MAIN" \
    zsh "$GUARD" <<< "$(hook_json "$MAIN/development/some-file.md")"
  [ "$status" -eq 0 ]
}

@test "input without file_path: allowed (exit 0)" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< '{"tool_input":{}}'
  [ "$status" -eq 0 ]
}

@test "malformed JSON: internal error (exit 1), never a silent allow decision" {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$WT" \
    zsh "$GUARD" <<< 'not json'
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/edit-target-guard.bats`
Expected: all FAIL (script missing).

- [ ] **Step 3: Implement the hook script**

Create `scripts/edit-target-guard.zsh`:

```zsh
#!/usr/bin/env zsh
# edit-target-guard.zsh — PreToolUse hook (#918) on Edit|Write|NotebookEdit,
# wired via the checked-in .claude/settings.json.
#
# Blocks (exit 2, reason on stderr):
#   - writes into the installed plugin cache (~/.claude/plugins/cache/**) —
#     a cache edit is lost on the next install refresh and validates nothing;
#   - when the session's project dir is a git worktree under
#     <main>/.claude/worktrees/, writes into the main checkout outside the
#     worktree — the "edited the wrong tree" false-positive class.
#
# Exit 0 allows; exit 1 is an internal error (jq missing, malformed hook
# JSON) which Claude Code surfaces as a hook error — never a silent allow.
#
# No err_exit: every exit is an explicit decision here.

setopt nounset pipefail

command -v jq >/dev/null 2>&1 \
  || { print -u2 -- "edit-target-guard: jq required, not on PATH"; exit 1 }

input=$(cat) || { print -u2 -- "edit-target-guard: cannot read stdin"; exit 1 }
fp=$(print -r -- "$input" \
  | jq -er '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) \
  || { print -u2 -- "edit-target-guard: malformed hook JSON on stdin"; exit 1 }
[[ -z "$fp" ]] && exit 0

abs=${fp:A}  # absolute, with . / .. / symlinks resolved

if [[ "$abs" == "$HOME/.claude/plugins/cache/"* ]]; then
  print -u2 -- "BLOCKED: $abs is inside the installed plugin cache."
  print -u2 -- "Edit the repo checkout (this session's worktree), never the cache — a cache edit"
  print -u2 -- "is lost on the next refresh and validates nothing (#918)."
  exit 2
fi

proj="${CLAUDE_PROJECT_DIR:-}"
if [[ -n "$proj" && "$proj" == */.claude/worktrees/* ]]; then
  main_root="${proj%%/.claude/worktrees/*}"
  proj_abs=${proj:A}
  if [[ "$abs" == "$main_root/"* && "$abs" != "$proj_abs" && "$abs" != "$proj_abs/"* ]]; then
    print -u2 -- "BLOCKED: this session's project dir is the worktree"
    print -u2 -- "  $proj"
    print -u2 -- "but the edit targets the main checkout:"
    print -u2 -- "  $abs"
    print -u2 -- "Work only inside the worktree (#918)."
    exit 2
  fi
fi

exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/edit-target-guard.bats`
Expected: 7/7 PASS.

- [ ] **Step 5: Wire the hook**

Create `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "zsh \"$CLAUDE_PROJECT_DIR/scripts/edit-target-guard.zsh\""
          }
        ]
      }
    ]
  }
}
```

Manual verification (the hook layer itself can't run under bats): in a fresh Claude Code session in this repo,
attempt an Edit to `~/.claude/plugins/cache/<anything>` — expect the block message; an Edit inside the repo —
expect it to succeed.

- [ ] **Step 6: Run the whole suite and commit**

Run: `tests/run-script-tests.zsh --local` — all green, then:

```bash
git add scripts/edit-target-guard.zsh tests/edit-target-guard.bats .claude/settings.json
git commit -m "feat(guardrails): edit-target PreToolUse hook + checked-in settings (#918)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Exit-code contract check (warn-level)

**Files:**

- Create: `scripts/check-exit-code-contract.zsh`
- Create: `tests/check-exit-code-contract.bats`
- Modify: `.github/workflows/lint.yml` (extend the `guardrails` job from Task 1)

**Interfaces:**

- Consumes: the `guardrails` job in `lint.yml` (Task 1) — this task appends one step to it.
- Produces: `check-exit-code-contract.zsh [--base <ref>] [--strict]` — warn-level by default (findings reported,
  exit 0); `--strict` exits 1 on findings; exit 2 usage errors.

- [ ] **Step 1: Write the failing tests**

Create `tests/check-exit-code-contract.bats`:

```bash
#!/usr/bin/env bats
#
# Behavioral tests for check-exit-code-contract.zsh (#918): literal `exit N`
# codes in a changed *.zsh script vs the exit codes enumerated by *.md prose
# that references the script by filename. Warn-level by default; --strict
# turns findings into exit 1.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/scripts"
  cp "$REPO_ROOT/scripts/check-exit-code-contract.zsh" "$WORK/scripts/"
  CHECK="$WORK/scripts/check-exit-code-contract.zsh"
  cd "$WORK"
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  cat > tool.zsh <<'EOF'
#!/usr/bin/env zsh
[[ -f input ]] || exit 2
exit 0
EOF
  cat > TOOL.md <<'EOF'
Run `tool.zsh`. Exits 0 on success, 2 on usage errors.
EOF
  git add -A
  git commit -qm init
}

@test "script and prose agree: exits 0, no findings" {
  print 'echo touched' >> tool.zsh
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "⚠"
}

@test "new undocumented exit code: reported, still exit 0 (warn-level)" {
  cat > tool.zsh <<'EOF'
#!/usr/bin/env zsh
[[ -f input ]] || exit 2
[[ -s input ]] || exit 3
exit 0
EOF
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "tool.zsh"
  echo "$output" | grep -q "3"
}

@test "--strict turns findings into exit 1" {
  cat > tool.zsh <<'EOF'
#!/usr/bin/env zsh
[[ -f input ]] || exit 2
[[ -s input ]] || exit 3
exit 0
EOF
  run zsh "$CHECK" --base main --strict
  [ "$status" -eq 1 ]
}

@test "script with no referencing prose: skipped silently" {
  cat > orphan.zsh <<'EOF'
#!/usr/bin/env zsh
exit 7
EOF
  git add orphan.zsh
  run zsh "$CHECK" --base main
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "orphan"
}

@test "unresolvable base ref: exits 2" {
  run zsh "$CHECK" --base no-such-ref
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/check-exit-code-contract.bats`
Expected: all FAIL (script missing).

- [ ] **Step 3: Implement the script**

Create `scripts/check-exit-code-contract.zsh`:

```zsh
#!/usr/bin/env zsh
# check-exit-code-contract.zsh — diff-aware guardrail (#918): for each changed
# *.zsh script, compare the literal `exit N` codes the script emits with the
# exit codes enumerated by *.md prose that references the script by filename.
#
# Usage: check-exit-code-contract.zsh [--base <ref>] [--strict]
#
# Warn-level by default: findings are reported but the exit is 0, because the
# prose-side extraction is heuristic (dynamic exits, sourced helpers, numbers
# that aren't exit codes). --strict exits 1 on findings — local use now; CI
# promotes to strict once the signal has stayed clean (#918 follow-up).
# Exits 2 on usage errors (unknown argument, unresolvable merge-base).
#
# Codes 0 and 1 are treated as implicitly emitted by every script (0 is the
# fallthrough success, err_exit makes any failing command an implicit 1), and
# are never themselves reported as undocumented — they only suppress phantom
# "prose documents 0/1 but the script never emits it" findings.

setopt err_exit nounset pipefail

readonly REPO_ROOT="${0:A:h:h}"

base="origin/main"
strict=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { print -u2 -- "--base needs a value"; exit 2 }
      base="$2"; shift 2 ;;
    --strict) strict=1; shift ;;
    *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done

mb=$(git -C "$REPO_ROOT" merge-base "$base" HEAD 2>/dev/null) \
  || { print -u2 -- "cannot resolve merge-base of '$base' and HEAD"; exit 2 }

findings=0
while IFS= read -r -d '' f; do
  [[ "$f" == *.zsh ]] || continue
  name="${f:t}"

  # Literal `exit N` codes the script emits, and the same set plus the
  # implicit 0 and 1 (fallthrough success / err_exit failure).
  literal=$(grep -hoE '\bexit[[:space:]]+[0-9]+' "$REPO_ROOT/$f" \
    | grep -oE '[0-9]+' | sort -un) || true
  actual=$(  { print -l -- 0 1; print -- "$literal" } | grep -E '^[0-9]+$' | sort -un )

  # Prose files that reference the script by filename (design specs excluded —
  # they describe planned behaviour, not the shipped contract).
  docs=$(grep -rlF --include='*.md' -- "$name" "$REPO_ROOT" 2>/dev/null \
    | grep -v '/docs/superpowers/') || true
  [[ -z "$docs" ]] && continue

  # Codes the prose documents: "exit 0" / "exits 1" / "exit code 2" plus the
  # enumerating list convention "#   0 + ..." / "0 → ..." / "- 2 —".
  documented=$(grep -hoiE '(exit(s)?( code)?[[:space:]]*[0-9]+|^[#[:space:]-]*[0-9]+[[:space:]]*[+→—-])' \
      ${(f)docs} 2>/dev/null | grep -oE '[0-9]+' | sort -un) || true
  [[ -z "$documented" ]] && continue

  for c in ${(f)literal}; do
    [[ "$c" == 0 || "$c" == 1 ]] && continue  # implicit codes are never findings
    if ! print -l -- ${(f)documented} | grep -qx -- "$c"; then
      print -- "⚠ ${f}: emits exit $c but no referencing prose documents it"
      findings=$((findings + 1))
    fi
  done
  for c in ${(f)documented}; do
    if ! print -l -- ${(f)actual} | grep -qx -- "$c"; then
      print -- "⚠ ${f}: prose documents exit code $c but the script never emits it"
      findings=$((findings + 1))
    fi
  done
done < <(git -C "$REPO_ROOT" diff -z --name-only --diff-filter=d "$mb")

if (( findings > 0 )); then
  print -- ""
  print -- "$findings exit-code contract drift finding(s) — update the prose (or the script)"
  print -- "in this same change; see CLAUDE.md 'Pre-review guardrails' (#918)."
  (( strict )) && exit 1
  exit 0
fi
print -- "exit-code contract: clean"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/check-exit-code-contract.bats`
Expected: 5/5 PASS. Then the whole suite: `tests/run-script-tests.zsh --local`.

- [ ] **Step 5: Extend the CI job**

In `.github/workflows/lint.yml`, append one step to the `guardrails` job (after the flag-test step):

```yaml
      - name: Exit-code contract check (warn-level)
        run: zsh scripts/check-exit-code-contract.zsh --base "origin/${{ github.base_ref }}"
```

Verify: `pre-commit run --all-files`; then run the script locally against `origin/main` and read its report —
warn output on pre-existing drift is acceptable (that's the signal-collection phase), a crash is not.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-exit-code-contract.zsh tests/check-exit-code-contract.bats .github/workflows/lint.yml
git commit -m "feat(guardrails): warn-level exit-code contract check (#918)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: CLAUDE.md "Pre-review guardrails" section

**Files:**

- Modify: `CLAUDE.md` (append a section after "Definition of green CI on a PR")

**Interfaces:**

- Consumes: the three scripts from Tasks 1–3 by path — this section is written only after all three exist on
  `main`.
- Produces: nothing consumed by code; the rules interactive sessions follow.

- [ ] **Step 1: Append the section**

Add to `CLAUDE.md`:

```markdown
## Pre-review guardrails (#918)

Mechanical checks that front-load what review loops kept catching late. Run
them before considering any script change done — CI enforces them on PRs:

- **New flag ⇒ bats test.** Every flag added to a `*.zsh` case-arm parse loop
  must appear in at least one `tests/*.bats`. Check locally:
  `zsh scripts/check-flag-test-coverage.zsh` (CI runs it diff-scoped).
- **Edit the worktree, never the cache.** A `PreToolUse` hook
  (`scripts/edit-target-guard.zsh`, wired in `.claude/settings.json`) blocks
  writes to `~/.claude/plugins/cache/**` and — from a worktree session — to
  the main checkout. If it blocks you, fix the target path; never bypass it.
- **Exit codes are a contract.** When a script's `exit N` set changes, update
  the prose documenting it in the same change.
  `zsh scripts/check-exit-code-contract.zsh` reports drift (warn-level in CI,
  `--strict` locally).
```

- [ ] **Step 2: Verify and commit**

Run: `pre-commit run --all-files` (markdownlint gate).
Expected: PASS.

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md pre-review guardrails section (#918)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Epic / child-issue mapping

| Task | Child issue | Blocked by |
| --- | --- | --- |
| 1 — flag-test coverage check + CI job | filed as child of #918 | — |
| 2 — edit-target hook + settings | filed as child of #918 | — |
| 3 — exit-code contract check | filed as child of #918 | Task 1's child (shares the `guardrails` job in `lint.yml`) |
| 4 — CLAUDE.md section | filed as child of #918 | Tasks 1–3's children (documents what must exist) |

Each child lands as its own PR off fresh `origin/main` (squash, no stacking).
The epic is closed explicitly after all children merge and a final end-to-end
check (CI `guardrails` job green on a probe PR, hook verified in a live
session).
