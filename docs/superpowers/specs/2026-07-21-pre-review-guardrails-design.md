# Pre-review mechanical guardrails — design

**Issue:** [#918](https://github.com/timo-jakob/timos-claude-code-plugins/issues/918)
**Date:** 2026-07-21
**Status:** approved design, pre-implementation

## Problem

Cross-session insights identify the repo's largest friction source (21 recorded
instances): code that ships with bugs or false positives caught only in the
local review loop (resolve-issue Step 3.5) — after the Step-3 test gate already
reported green. Two representative incidents:

- A CRITICAL bug where the `--has-ko` flag was never parsed/forwarded reached
  review because no bats test exercised the flag; the suite stayed green around
  the bug.
- An edit landed in the installed plugin cache
  (`~/.claude/plugins/cache/...`) instead of the session's worktree, producing a
  false positive in detection logic that had to be undone and redone.

All observed instances share one property: the defect was a **mechanically
detectable fact** (a token absent from `tests/`, a path outside the repo, an
exit code missing from the documented contract) that only a judgment layer — the
review panel — caught. Judgment is the most expensive and latest place to catch
them.

## Failure classes covered

1. **Untested new script behaviour** — a new flag or branch in a `*.zsh` script
   with no bats test exercising it.
2. **Wrong-file-path edits** — writes to the plugin cache, or to the main
   checkout from a worktree session.
3. **Exit-code contract drift** — a script's actual `exit N` set drifting from
   the exit codes its referencing prose (SKILL.md / agent .md) documents
   (cf. #917, #915).

## Decision

Repo-wide **mechanical enforcement** (deterministic scripts + a hook), not
prose-only rules and not an extra pre-review model pass:

- Prose alone demonstrably does not hold across long autonomous sessions — the
  21 instances accumulated under the existing discipline.
- A shift-left review agent costs tokens per session and duplicates the review
  loop; scripts cost nothing per session and run identically in CI and locally.

The review loop remains the owner of judgment (test *quality*, forwarding
*semantics*); the guardrails only move the mechanical floor earlier.

## Components

### 1. `scripts/check-flag-test-coverage.zsh` — diff-aware flag-test check

- **Input:** `--base <ref>` (default `origin/main`); operates on the merge-base
  diff of the current tree.
- **Extraction:** for each changed `*.zsh` file, collect *newly added* case-arm
  flag tokens from added diff lines. The repo's flag parsing is uniformly
  `while [[ $# -gt 0 ]] … case "$1" in --foo) …`, so the extractor matches
  case-arm patterns (`--foo)` and `--foo|…)`) on `+` lines only.
- **Check:** each new token must appear in at least one `tests/*.bats` file in
  the same tree (existing or changed).
- **Output / exit codes:** `0` clean; `1` findings, listing `script:flag` pairs
  with no test mention; `2` usage error (including: no merge-base resolvable —
  never a silent pass).
- **Known limitation (accepted):** "token appears in tests/" is a floor, not
  proof of a meaningful test. Test quality remains the review loop's job.

### 2. `scripts/edit-target-guard.zsh` + checked-in `.claude/settings.json` — edit-target hook

- A `PreToolUse` hook on `Edit|Write|NotebookEdit`. The script reads the hook
  JSON from stdin, resolves `tool_input.file_path`, and **blocks** (exit 2,
  reason on stderr) when either:
  - the path is under `~/.claude/plugins/cache/` — editing the installed cache
    is never correct in this repo's sessions; or
  - `$CLAUDE_PROJECT_DIR` contains `/.claude/worktrees/` (a worktree session)
    **and** the target path is inside the main checkout (the path prefix before
    `/.claude/worktrees/`) but outside the worktree itself.
- Everything else — the worktree, the scratchpad, `/tmp` — passes through.
- `.claude/settings.json` is checked in, so every clone and every worktree gets
  the guard automatically. The repo currently has no checked-in settings file;
  this creates it.
- Failure semantics: exit 2 blocks with feedback; any other non-zero exit
  surfaces as a hook error to the session — never a silent allow.

### 3. `scripts/check-exit-code-contract.zsh` — exit-code contract check

- For each changed `*.zsh` script: collect literal `exit N` values; locate
  prose files (SKILL.md / agent `.md` within the same plugin) that reference
  the script by filename and enumerate exit codes (the repo's established
  `#   0 … / 1 … / 2 …` comment-block and prose conventions); report codes the
  script emits that the prose omits, and codes the prose documents that the
  script never emits.
- **Warn-level initially:** report findings, exit 0 in CI. Real false-positive
  risk (dynamic exits, sourced helpers); promote to failing only after a few
  weeks of clean signal. Local invocation offers `--strict` for a non-zero exit
  on findings.
- Complemented by one added line in
  `development-claude-plugin/agents/claude-plugin-contract-integrity.md` making
  prose-vs-script **exit-code drift** an explicit review target. This touches
  plugin content → requires the `plugin.json` + `marketplace.json` version bump
  per repo convention.

### 4. Wiring and documentation

- **CI:** `lint.yml` gains a `guardrails` step running checks 1 and 3 on PRs
  (checkout with `fetch-depth: 0` so the merge-base resolves).
- **Tests:** bats tests in `tests/` for all three scripts — plugin/repo scripts
  are code (#263 discipline).
- **CLAUDE.md:** a short **Pre-review guardrails** section stating the three
  rules and pointing at the scripts, so interactive sessions apply them before
  claiming work done.
- All new scripts: zsh (per the ARCHITECTURE.md scripting convention),
  shellcheck-clean, 120-column.

## Out of scope (YAGNI)

- Generic diff-coverage tooling.
- Verifying flag *forwarding* semantics — the review panel's job.
- Changes to the resolve-issue skill itself; the guardrails are repo-wide and
  the skill's Step 3 picks them up implicitly via CLAUDE.md / CI.

## Testing

- Each script gets bats coverage of: clean pass, each finding class, and each
  usage-error path (missing base ref, malformed hook JSON).
- The hook script is additionally exercised with representative hook-JSON
  fixtures for: cache path (block), main-checkout path from a worktree (block),
  worktree path (allow), scratchpad path (allow).
- CI proof: the `guardrails` step must pass on the PR that introduces it.
