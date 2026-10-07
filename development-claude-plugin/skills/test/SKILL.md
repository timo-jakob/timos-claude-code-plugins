---
name: test
description: >
  Test a Claude Code plugin's behaviour end-to-end against a real reference
  project — human-invoked only, never an autonomous pipeline step. The invoking
  session launches a *separate* headless `claude` session — with the LOCAL
  (uncommitted) plugins loaded via --plugin-dir — against an isolated clone of
  the target repo and waits for it to finish; a fresh-context judge subagent
  then reads the finished transcript and returns a structured PASS/FAIL verdict
  plus a transcript digest without flooding the authoring context. Use it to
  verify a skill/agent/command you just edited actually does what you intend,
  in any language the family supports. Pass `--target <path>`,
  `--task "<prompt>"`, and optionally `--expect "<...>"`.
disable-model-invocation: false
---

You are running the **plugin test harness**. The user wants to exercise a
plugin's real behaviour against a concrete project and get the *feedback from a
separate session* — without that session's raw transcript polluting this
(authoring) conversation.

**User input:** $ARGUMENTS

**Human-invoked only.** This harness is for a person verifying their own edit.
It is **not** for autonomous pipeline steps — no unattended flow launches a
headless `claude` child (#2191); `/development:resolve-issue`'s epic
verification runs its end-to-end half in the session instead.

## Mental model — two layers

1. **You + a fresh-context judge subagent = the firewall.** You parse args, set
   up the isolated target, launch the child, and **wait for it yourself** — a
   main session is re-woken by its own Monitor and task notifications, where a
   background subagent that ends its turn is not reliably re-woken by its own
   (#2191). Only once the child has finished do you spawn one subagent. The
   subagent owns the noisy work (parsing the finished transcript, diffing the
   clone) and returns only a compact verdict. The raw child transcript never
   enters this conversation.
2. **A headless `claude -p` child = the system under test.** Launched by you
   via `scripts/run-headless.zsh`, it loads the **local** plugins from
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

> **Safety guard — dry-run only for the maintenance *orchestrator*.** Step 3
> gives the child read-only GitHub context (`GH_REPO`) so gh-based gathers
> (vendor PRs, code scanning, container scan) resolve the **real** repo. That
> context also lets a *non*-dry-run **orchestrator** run **mutate real, shared
> GitHub state** (`gh pr merge` / `review` / auto-merge), and its PR cycle's
> `gh pr create` would reference branches pushed only to the throwaway clone.
> A clone can't isolate GitHub. So if `--task` invokes the **orchestrator**
> `/development:maintenance` **without `--dry-run`**, **halt** and tell the
> user: "The test harness runs the maintenance orchestrator in read-only mode
> only — add `--dry-run` to your `--task`. Its mutating half (vendor-PR triage,
> the PR cycle) acts on shared GitHub state a clone can't isolate."
>
> **This applies to the orchestrator only.** A per-language **dispatcher**
> invoked directly — `/development-<lang>:maintenance <payload.json>` (e.g.
> `/development-java:maintenance`) — is a **pure function of its payload**: it
> returns a plan (or a halt) and **does not** spawn work agents, push, or touch
> GitHub (that's the orchestrator's job). So a direct dispatcher task is
> GitHub-safe **with or without** `--dry-run` — do **not** block it. (This is
> how you test dispatcher-only behavior like a validation halt, which
> `--dry-run` can't reach because the orchestrator never dispatches under it.)

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
(fast, hardlinked) into a temp dir and remember the path. The local clone's
`origin` is a filesystem path, so also capture the source repo's **GitHub
slug** (`owner/repo`) — the child needs it as `GH_REPO` or every gh-based
gather (vendor PRs, code scanning, container scan) silently returns empty:

```bash
CLONE="$(mktemp -d -t plugin-test-XXXXXX)/$(basename "$TARGET")"
git clone --local --no-hardlinks "$TARGET" "$CLONE" >/dev/null 2>&1
OUT="$(mktemp -t plugin-test-transcript-XXXXXX).jsonl"
# Resolve the real GitHub slug from the SOURCE repo (it has the real remote).
# Empty if the target isn't a GitHub repo — then gh-based gathers stay empty,
# which is correct (nothing to resolve), and local-file tools still work.
GH_REPO_SLUG="$( (cd "$TARGET" && gh repo view --json nameWithOwner -q .nameWithOwner) 2>/dev/null || true)"
echo "clone:      $CLONE"
echo "transcript: $OUT"
echo "gh-repo:    ${GH_REPO_SLUG:-<none — gh gathers will be empty>}"
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

## Step 5 — Launch the child and wait for it yourself

You — the invoking session — launch the child and wait on it. The judge is not
spawned yet: a background subagent that ends its turn while waiting is not
reliably re-woken by its own Monitor, and one that went to sleep stalled a run
for 78 minutes with the child long finished (#2191).

1. **Snapshot the clone's clean state**, for the judge's diff later:

   ```bash
   echo "base_head=$(git -C "$CLONE" rev-parse HEAD)"   # fills <BASE_HEAD>
   git -C "$CLONE" status --porcelain   # expected: empty
   ```

2. **Launch the child detached** via the wrapper (include `--gh-repo` only when
   the slug is non-empty, so gh-based gathers resolve the real repo):

   ```bash
   "$REPO_ROOT/development-claude-plugin/skills/test/scripts/run-headless.zsh" \
     --detach \
     --cwd "$CLONE" --out "$OUT" --plugins "<PLUGINS_CSV>" \
     --gh-repo "$GH_REPO_SLUG" \
     --permission-mode <PERMISSION_MODE> --prompt "<TASK>"
   ```

   It returns immediately, printing `exit_marker=<OUT>.exit`. **Never** launch
   the wrapper as a Bash background task (`run_in_background: true`): #811
   recorded that such a task is killed the instant the turn that started it
   ends, SIGTERM-ing the child mid-run. Never rely on a foreground call
   finishing either — a real child can outlive the foreground cap. `--detach`
   is the only launch mode that survives a turn boundary.

3. **Wait on the marker file with your own Monitor until-loop** (generous
   timeout — a full panel run takes 10–20 minutes):

   ```bash
   until [ -f "$OUT.exit" ] || ! kill -0 <DETACHED_PID> 2>/dev/null; do sleep 10; done
   [ -f "$OUT.exit" ] && echo "child_exit=$(cat "$OUT.exit")" || echo "no_verdict"
   ```

   `<DETACHED_PID>` is the launch's `detached_pid=`. You are re-woken when it
   fires; read the child's exit code from the marker. If the Monitor expires
   first, re-arm the same wait, for at most 45 minutes in total. On
   `no_verdict`, or once the 45 minutes are used up, the run produced no
   verdict — report that, with `<OUT>.log`'s path and whether `<DETACHED_PID>`
   is still running, and stop. Never spawn the judge, and never read a
   verdict, without the marker.
   (`<OUT>.log` holds the wrapper's stderr banner if you need it.)

## Step 6 — Spawn the judge on the finished transcript

Spawn the judge only once the marker exists. It parses a finished transcript
and diffs the clone; it never launches anything and never waits on anything.

Spawn **one** subagent (Task tool, `general-purpose` type), in the foreground.
It runs with a clean context and does all the noisy work. Give it this prompt,
with the placeholders filled from the steps above:

```text
You are the JUDGE for a plugin integration test. The system under test has
ALREADY RUN to completion in a separate headless Claude session. Read what it
did and return a STRUCTURED VERDICT. Do not dump the raw transcript back — only
the structured block below. Launch nothing.

Inputs:
- Finished transcript (newline-delimited JSON): <OUT>
- Child exit code: <CHILD_EXIT>
- Clone the child ran in: <CLONE>
- Clone HEAD before the run: <BASE_HEAD>
- Task prompt the child ran: <TASK>
- Expectation (PASS criteria): <EXPECT or "none given">

Do this:
1. Parse the transcript <OUT> (one event per line). Extract: which
   skills/slash-commands fired, which subagents/agents the child spawned (Task
   tool uses), which tools it used, the final `result` text, and any error
   events. Read the file with Read/grep; reason about it — do not assume a
   rigid schema.
2. Diff the clone to see real effects: `git -C <CLONE> status --porcelain`,
   `git -C <CLONE> diff --stat`, and `git -C <CLONE> log --oneline <BASE_HEAD>..HEAD`.
3. Judge PASS/FAIL against the expectation (or, if none, PASS unless the child
   errored or clearly failed to load the local plugin). A non-zero exit code is
   a FAIL unless the task was *expected* to exit non-zero.
4. Return EXACTLY this block and nothing else:

   VERDICT: PASS | FAIL
   task: <the task the child ran>
   child_exit: <code>
   fired: <comma-separated skills/commands/agents that activated, or "none detected">
   tools: <notable tools the child used>
   changed: <files changed in the clone per git, or "none">
   plugin_loaded: <yes | no | unclear — did the LOCAL plugin demonstrably load?>
   digest: <2–4 sentence plain-language summary of what the child actually did>
   mismatch: <if FAIL, the specific way reality diverged from the expectation; else "n/a">
```

## Step 7 — Surface the verdict and clean up

Show the subagent's verdict block verbatim to the user, then add a one-line
interpretation (what to do next: re-run with a different `--task`, file a finding,
etc.). Finally remove the temp artifacts:

```bash
rm -rf "$(dirname "$CLONE")" "$OUT" "$OUT.exit" "$OUT.log"
```

If the judge subagent cannot be spawned, read and judge the transcript inline
yourself, and note in the result that the firewall was bypassed, so this run's
transcript did enter the authoring context.
