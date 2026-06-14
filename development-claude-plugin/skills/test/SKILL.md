---
name: test
description: >
  Test a Claude Code plugin's behaviour end-to-end against a real reference
  project. Spawns a fresh-context judge subagent that drives a *separate*
  headless `claude` session — with the LOCAL (uncommitted) plugins loaded via
  --plugin-dir — against an isolated clone of the target repo, then returns a
  structured PASS/FAIL verdict plus a transcript digest without flooding the
  authoring context. Use it to verify a skill/agent/command you just edited
  actually does what you intend, in any language the family supports. Pass
  `--target <path>`, `--task "<prompt>"`, and optionally `--expect "<...>"`.
disable-model-invocation: false
---

You are running the **plugin test harness**. The user wants to exercise a
plugin's real behaviour against a concrete project and get the *feedback from a
separate session* — without that session's raw transcript polluting this
(authoring) conversation.

**User input:** $ARGUMENTS

## Mental model — two layers

1. **You + a fresh-context judge subagent = the firewall.** You parse args, set
   up the isolated target, and spawn one subagent. The subagent owns the noisy
   work (launching the child, parsing its transcript, diffing the clone) and
   returns only a compact verdict. The raw child transcript never enters this
   conversation.
2. **A headless `claude -p` child = the system under test.** Launched by the
   subagent via `scripts/run-headless.zsh`, it loads the **local** plugins from
   this worktree (`--plugin-dir`) and runs against an isolated clone of the
   target repo. This is what makes the test faithful: the skill/agent loads and
   runs exactly as a user would experience it.

You do **not** parse the child transcript yourself — that is the subagent's job,
precisely so the bytes stay out of your context.

## Step 1 — Parse arguments

From `$ARGUMENTS`, extract (all optional; apply defaults):

- `--target <path>` — the real reference project. **Default:**
  `/Users/timo/repositories/ai-doc-organizer` (the canonical Python test bed).
- `--task "<prompt>"` — what the child session should do. **Default (cheap
  plumbing smoke test):**
  `Confirm the development-claude-plugin plugin loaded by listing its slash commands, then stop.`
  For a real functional test, pass something like
  `/development:maintenance --dry-run --tool ruff`.
- `--expect "<text>"` — a plain-language statement of what a PASS looks like
  (e.g. "the maintenance dispatcher ran in dry-run and produced a plan with at
  least one ruff group, no PRs opened"). If omitted, the verdict reports what
  happened and the subagent judges PASS unless the child errored.
- `--permission-mode <mode>` — forwarded to the child. **Default:**
  `bypassPermissions` (the child only ever touches a throwaway clone). Override
  to `acceptEdits` for a tighter run.

Echo the resolved values back to the user before proceeding.

## Step 2 — Preflight

```bash
command -v claude >/dev/null 2>&1 || {
  echo "::error::'claude' not on PATH. Install Claude Code first."; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)" || {
  echo "::error::Run this skill from inside the plugin repo worktree."; exit 1; }

TARGET="<resolved --target>"
test -d "$TARGET/.git" || {
  echo "::error::--target is not a git repo: $TARGET"; exit 1; }
```

Halt with the printed pointer if either check fails.

## Step 3 — Build an isolated clone of the target

Never run the child against the user's real working copy — maintenance-style
tasks create branches/worktrees/commits even under `--dry-run`. Clone locally
(fast, hardlinked) into a temp dir and remember the path:

```bash
CLONE="$(mktemp -d -t plugin-test-XXXXXX)/$(basename "$TARGET")"
git clone --local --no-hardlinks "$TARGET" "$CLONE" >/dev/null 2>&1
OUT="$(mktemp -t plugin-test-transcript-XXXXXX).jsonl"
echo "clone:      $CLONE"
echo "transcript: $OUT"
```

## Step 4 — Decide which local plugins to load

The child must load the plugins under test **from this worktree**, not the
versions installed from the marketplace. Always include `development` and
`development-claude-plugin`; add the language plugin matching the target:

- Python target (`pyproject.toml` / `setup.py` present) → also
  `$REPO_ROOT/development-python`.
- Swift target (`Package.swift`) → also `$REPO_ROOT/development-swift`.

Compose the comma-separated list, e.g.
`$REPO_ROOT/development,$REPO_ROOT/development-claude-plugin,$REPO_ROOT/development-python`.

> **Known caveat — double load.** If the same-named plugin is also installed in
> the user's Claude config, both copies may load and the marketplace version can
> shadow the local one. When that matters, bump the local plugin's version above
> the installed one, or temporarily disable the installed copy. Surface this in
> the verdict if the child appears to run stale behaviour.

## Step 5 — Spawn the fresh-context judge subagent

Spawn **one** subagent (Task tool, `general-purpose` type). It runs with a clean
context and does all the noisy work. Give it this prompt, with the placeholders
filled from the steps above:

```
You are the JUDGE for a plugin integration test. Run the system under test in a
separate headless Claude session, then return a STRUCTURED VERDICT. Do not dump
the raw transcript back — only the structured block below.

Inputs:
- Wrapper script: <REPO_ROOT>/development-claude-plugin/skills/test/scripts/run-headless.zsh
- Clone (cwd for the child): <CLONE>
- Transcript output path: <OUT>
- Local plugin dirs: <PLUGINS_CSV>
- Permission mode: <PERMISSION_MODE>
- Task prompt for the child: <TASK>
- Expectation (PASS criteria): <EXPECT or "none given">

Do this:
1. Snapshot the clone's clean state: `git -C <CLONE> rev-parse HEAD` and
   `git -C <CLONE> status --porcelain`.
2. Launch the child via the wrapper:
     <REPO_ROOT>/development-claude-plugin/skills/test/scripts/run-headless.zsh \
       --cwd <CLONE> --out <OUT> --plugins "<PLUGINS_CSV>" \
       --permission-mode <PERMISSION_MODE> --prompt "<TASK>"
   Capture its exit code. If it is non-zero, the verdict is FAIL unless the task
   was *expected* to exit non-zero.
3. Parse the transcript <OUT> (newline-delimited JSON, one event per line).
   Extract: which skills/slash-commands fired, which subagents/agents the child
   spawned (Task tool uses), which tools it used, the final `result` text, and
   any error events. Read the file with Read/grep; reason about it — do not
   assume a rigid schema.
4. Diff the clone to see real effects: `git -C <CLONE> status --porcelain` and
   `git -C <CLONE> diff --stat`.
5. Judge PASS/FAIL against the expectation (or, if none, PASS unless the child
   errored or clearly failed to load the local plugin).
6. Return EXACTLY this block and nothing else:

   VERDICT: PASS | FAIL
   task: <the task you ran>
   child_exit: <code>
   fired: <comma-separated skills/commands/agents that activated, or "none detected">
   tools: <notable tools the child used>
   changed: <files changed in the clone per git, or "none">
   plugin_loaded: <yes | no | unclear — did the LOCAL plugin demonstrably load?>
   digest: <2–4 sentence plain-language summary of what the child actually did>
   mismatch: <if FAIL, the specific way reality diverged from the expectation; else "n/a">
```

## Step 6 — Surface the verdict and clean up

Show the subagent's verdict block verbatim to the user, then add a one-line
interpretation (what to do next: re-run with a different `--task`, file a finding,
etc.). Finally remove the temp artifacts:

```bash
rm -rf "$(dirname "$CLONE")" "$OUT"
```

If the subagent could not launch the child at all (the undocumented
"claude launches claude" nesting was blocked), fall back: run
`run-headless.zsh` yourself from this session against the clone, then read and
judge the transcript inline. Note in the result that the firewall was bypassed,
so this run's transcript did enter the authoring context.
