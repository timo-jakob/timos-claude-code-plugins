---
name: maintenance
description: >
  Maintenance orchestrator. Runs detection + per-tool findings gathering +
  coverage measurement, constructs the v1 JSON payload, dispatches to the
  language plugin (development-python in v1), collects results, and merges
  worktree branches back to the user's working branch. The user-facing
  entry point for "go fix everything you safely can on this project."
disable-model-invocation: false
---

You are the maintenance orchestrator. The user invoked you with
`/development:maintenance` (optionally with flags). You drive an entire
maintenance cycle from detection to merged commits.

**User input:** $ARGUMENTS

## Phase 0 — parse flags

Supported flags in `$ARGUMENTS`:

- `--dry-run` — gather everything, construct the payload, **print the
  payload** instead of dispatching. For debugging / inspecting what
  would be sent.
- `--no-merge` — dispatch normally, but skip the auto-merge of worktree
  branches at the end. The user is left with the branches available
  for manual inspection + merge.
- `--tool=<name>` — scope dispatch to a single tool (testing aid).
  `<name>` must be one of: `ruff`, `semgrep`, `snyk_code`, `snyk_oss`,
  `sonarcloud`, `dependabot`. The gather phase still runs for every
  tool (the payload stays complete), but the language plugin only
  spawns the agent(s) for the chosen tool. Other agents are skipped
  entirely — no work, no missing-tool recommendation. Combinable with
  `--dry-run` and `--no-merge`.

Anything else: surface the input to the user as "unrecognized
arguments" and stop.

When `--tool=<name>` is set, validate `<name>` against the known set
above before proceeding. On a mismatch, halt with: "Unknown --tool
'<name>'; supported: ruff, semgrep, snyk_code, snyk_oss, sonarcloud,
dependabot."

## Phase 1 — detect

Run the detection script and capture its JSON:

```bash
"<skill-base-dir>/../bootstrap/scripts/detect-stack.sh" > /tmp/detect.json
```

`<skill-base-dir>` is `development/skills/maintenance/`; the bootstrap
scripts live one directory up. Use the resolved absolute path.

Validate from `detect.json`:

- `git_initialized == true` — if not, halt: "Maintenance needs a git
  repo (worktree-based agents require it). Initialize with `git init`
  and re-run."
- `languages` is non-empty — if not, halt: "No supported languages
  detected (swift / typescript / python / go). If your project uses
  one of these, ensure manifest files (pyproject.toml, package.json,
  etc.) are present."

Extract for use in later phases: `repo` (path = cwd from script),
`default_branch`, `visibility`, `python_version` (when applicable),
`languages` (the array — could be one or more).

## Phase 2 — discover which languages we can act on

Maintenance support is gated by **gather script presence**. For each
detected language, check whether the matching gather script exists:

```bash
test -x "<skill-base-dir>/scripts/gather-<lang>-findings.sh"
```

The naming convention is strict: `gather-<lang>-findings.sh` (e.g.,
`gather-python-findings.sh`). When a new language plugin lands in this
repo, its sibling gather script is what makes it discoverable here.

Partition `languages` into:

- **`supported`** — detected AND a matching gather script exists
- **`unsupported`** — detected BUT no gather script (i.e., no
  development-<lang> plugin built yet)

If `supported` is empty (every detected language is unsupported), halt
with a message listing the detected languages and pointing the user at
the README's Plugins section for current per-language status. Don't
proceed — there's nothing this run can do.

If `supported` is non-empty but `unsupported` is also non-empty,
proceed with the supported set; remember `unsupported` to include in
the final summary as an informational note ("Detected <X>, <Y> but
their plugins are not built yet — only <Z> findings were processed").

## Phase 3 — gather findings per supported language

For each `lang` in `supported`:

```bash
"<skill-base-dir>/scripts/gather-<lang>-findings.sh" "$(pwd)" > "/tmp/findings-<lang>.json"
```

Each script outputs a JSON with `tooling_configured`, `findings_by_tool`,
`coverage`, and `notes`. Collect them all.

If a script exits non-zero or produces malformed JSON, that's an
internal error — surface it to the user (with the script path + stderr)
and skip that language. Don't try to construct a payload from a broken
gather output.

Pool all `notes` across all gather scripts; they describe why certain
tools couldn't produce live findings (e.g., snyk auth missing,
pytest-cov not installed). Surface them in the final summary.

## Phase 4 — construct one payload per supported language

For each `lang` in `supported`, build the JSON payload per ARCHITECTURE.md
schema v1:

```json
{
  "schema_version": "1",
  "repo": {
    "path": "<cwd>",
    "default_branch": "<from detect-stack>",
    "visibility": "<from detect-stack, or 'unknown'>"
  },
  "language": "<lang>",
  "language_meta": {
    "version": "<lang-appropriate version from detect-stack, or a sensible default>",
    "manifests": [/* lang-appropriate manifest files that exist */]
  },
  "tooling_configured": <from findings-<lang>.json>,
  "findings_by_tool":   <from findings-<lang>.json>,
  "coverage":           <from findings-<lang>.json>,
  "policy": {
    "coverage_threshold": 90,
    "coverage_threshold_minor_patch": 80,
    "severity_gate": "high",
    "allow_nosemgrep_with_justification": true
  },
  "worktree": {
    "available": true,
    "base_branch": "<the user's current branch, NOT default_branch — that's where we'll merge back to>"
  }
}
```

When `--tool=<name>` was passed in Phase 0, also add the optional
`dispatch_filter` field to the payload (omit it entirely otherwise):

```json
"dispatch_filter": { "only_tools": ["<name>"] }
```

This is what the language plugin reads to know it should skip every
other agent. The gather output is unchanged — only dispatch is scoped.

The user's current branch from `git rev-parse --abbrev-ref HEAD`.

`language_meta.version` — language-appropriate:
- python → `python_version` field from detect-stack (default `3.12`)
- (future) typescript → Node version from package.json `engines.node`
- (future) go → Go version from `go.mod`
- etc.

`language_meta.manifests` — list whichever manifest files exist that
are conventional for that language (Python: pyproject.toml,
requirements.txt, setup.py, setup.cfg). Don't include files that
don't exist.

## Phase 5 — `--dry-run`?

If `--dry-run`: print each payload (pretty-formatted via `jq .`)
labeled by language, print the pooled notes, list any unsupported
languages, and stop. Nothing is dispatched or merged.

## Phase 6 — dispatch per supported language to plan

For each `lang` in `supported`, invoke the matching language plugin via
the Skill tool:

```
Skill(
  skill="development-<lang>:maintenance",
  args="<the JSON payload as a single-line string>"
)
```

The language plugin will:

- Validate the payload
- Run its coverage pre-flight (it has the data it needs)
- Spawn `python-coverage-improver` if Step 2c branch 2 fired
- Run its planner against the (possibly improved) base branch
- Return a response JSON containing **`plan`** and (when present)
  the **coverage improver's worktree branch + summary**

**The language plugin does NOT spawn work agents in this Phase.** Work
agents are spawned per-group in Phase 8 below so that each group's PR
cycle (push → CI → merge → sync) completes before the next group
starts off the just-merged main.

Capture each response, keyed by language.

If a `Skill(...)` invocation fails (plugin not actually registered
despite the gather script existing — shouldn't happen but defend
anyway), treat that language as if it were `unsupported` for this run
and continue with the rest.

## Phase 7 — handle `human_action_required` early-outs

For any response that contains `human_action_required`, the language
plugin halted because coverage was below floor. Pass the reasons +
recommendations through to the user-facing summary and **skip all
remaining phases for that language**. Other languages still proceed.

## Phase 8 — per-stage PR cycle

Replaces the old "merge worktree branches locally" with a remote-first
flow: each stage (coverage improvement + each planner group) becomes
its own PR. PRs are processed **sequentially** — the next stage only
spawns its agent after the previous stage's PR has merged, so each
stage runs off the latest `main`.

If `--no-merge` was passed, **skip this phase entirely** and list the
plan + any local worktree branches in the final summary for manual
handling.

### Stage 0 — coverage improver (when present)

If the language plugin's response includes an improver worktree branch
**and path** (both are returned by the Claude Code runtime when the
improver was spawned with `isolation="worktree"`):

1. **Push the branch** to origin:
   ```bash
   git -C "<repo.path>" push -u origin "<improver_branch>"
   ```
2. **Open a PR** against the user's working branch (the same branch the
   improver was based on):
   ```bash
   gh pr create --base "<base_branch>" --head "<improver_branch>" \
     --title "test: <improver's summary>" \
     --body "$(<auto-generated body referencing the affected modules + coverage deltas>)"
   ```
   Capture the PR number.
3. **Run the CI cycle below** against that PR, passing the improver's
   worktree path so the cycle's `worktree remove` step can clean it up.
4. After merge, sync local `main`:
   ```bash
   git -C "<repo.path>" switch "<base_branch>"
   git -C "<repo.path>" pull --ff-only origin "<base_branch>"
   ```

### Stages 1..N — one PR per planner group, in priority order

For each entry in `response.plan`, in priority order:

1. **Determine the effective base branch** — the user's current branch
   after all prior merges (initially `worktree.base_branch`; updated
   after each merge by the sync step).

2. **Spawn the group's agent with `isolation="worktree"`.** This is
   the single most load-bearing parameter in the call. **Omitting it
   silently breaks the entire per-group-PR invariant**: the agent
   then edits the main workspace instead of a fresh worktree branch,
   its changes land on `main`'s working tree, and you (the
   orchestrator) end up creating a branch + commit ad-hoc after the
   fact — exactly the failure mode this phase exists to prevent.

   **Always pass `isolation="worktree"`, every group, no exceptions
   for work agents.** Use this exact call shape:

   ```
   Agent(
     subagent_type="<plan[i].agent>",
     description="<plan[i].description>",
     isolation="worktree",
     prompt="""
       repo_path: <repo.path>
       configured: true
       findings: <plan[i].findings, with their full finding objects>
       policy: <policy>
       worktree.base_branch: <effective base after prior merges>
       commit_subject: <plan[i].suggested_pr_title>

       End with the project's test command in the worktree; only
       return success if tests pass. Commit your changes on the
       worktree branch before returning — the orchestrator will push
       the branch as-is.
     """
   )
   ```

   Only exception: `python-dependabot-triage` is spawned WITHOUT
   `isolation` (it acts on GitHub PRs via `gh`, not local files).
   See the dispatcher SKILL for the full case list.

3. **Wait for the agent** → receive **both** the worktree branch and
   the worktree path. The Claude Code runtime returns both alongside
   the agent's response because you passed `isolation`. **Capture
   both** — the branch is what you push, the path is what you
   `git worktree remove` post-merge (step 5 in the CI cycle below).

   **If the agent comes back without a worktree branch and the main
   workspace has uncommitted changes, that's a contract violation,
   not a graceful path.** Surface it in the summary as a quality bug.
   Do NOT silently create a `maint/...` branch from the dirty main
   workspace — that masks the underlying failure and breaks
   reproducibility for subsequent stages.
4. **Push, open PR, run CI cycle** (same as Stage 0), titled per the
   plan entry's `suggested_pr_title`.
5. **After merge, sync local main**.
6. Continue to the next group.

### CI cycle (used by all stages)

After pushing and opening the PR:

1. **Monitor checks** until completion:
   ```bash
   gh pr checks "<pr_number>" --watch
   ```
   (Or poll `gh pr checks --json` until no check is in `PENDING` or
   `QUEUED` state.)
2. **If all checks pass** → proceed to step 5 below.
3. **If any check fails**, distinguish **new** from **pre-existing**
   failures before spending tokens on `python-ci-fixer`.

   A failure that's already failing on `<base_branch>` is not caused
   by this PR — it belongs on the project's main, not on a maintenance
   PR that didn't touch its cause. Spawning the fixer on it wastes
   tokens and can produce confusing "fixes" that don't apply.

   Run the classification:

   ```bash
   # 1. failing check names on this PR
   gh pr checks "<pr_number>" --json name,state \
     --jq '[.[] | select(.state == "FAILURE") | .name] | sort | unique' \
     > /tmp/pr_fail.json

   # 2. failing check-run names on <base_branch>'s latest commit
   #    (use the same names that gh pr checks reports — workflow + job name)
   gh api "repos/{owner}/{repo}/commits/<base_branch>/check-runs" \
     --jq '[.check_runs[] | select(.conclusion == "failure") | .name] | sort | unique' \
     > /tmp/base_fail.json

   # 3. new failures = PR failures − base failures
   comm -23 /tmp/pr_fail.json /tmp/base_fail.json > /tmp/new_fail.json
   # 4. pre-existing failures = PR failures ∩ base failures
   comm -12 /tmp/pr_fail.json /tmp/base_fail.json > /tmp/preexisting_fail.json
   ```

   (`gh` returns JSON arrays; `comm` needs sorted line-delimited input.
   `jq -r '.[]'` between the two converts JSON arrays to lines if the
   piping is awkward — adapt as needed for the shell. The intent is
   the set diff, not the exact incantation.)

   - **All failures pre-existing** → log the names ("pre-existing on
     `<base_branch>`: `<list>`"), treat the checks as a noop for merge
     gating, proceed to step 5 (merge). Record in the run summary so
     the user knows these failures still need attention on main.
   - **At least one new failure** → spawn `python-ci-fixer` for the
     new ones (pass `failing_checks: <list of new failure names>` in
     its prompt). Leave the pre-existing failures out of its scope —
     they're not its responsibility.

4. **Repeat up to 3 fixer invocations on the new failures**. After
   each fixer commit, re-monitor and re-classify (a new failure might
   resolve while a different pre-existing one persists — that's still
   a green light to merge per the previous bullet). If new failures
   still persist after 3 attempts, **do not merge** — record the PR
   in `actions_requiring_review` for the final summary and **continue
   to the next stage**. Failure on one stage does not block later
   stages.
5. **Remove the local worktree first, then merge the PR.** Order
   matters: `gh pr merge --delete-branch` tries to delete the local
   branch ref, which fails with *"cannot delete branch X used by
   worktree at Y"* if the worktree is still attached. The merge + the
   remote-branch delete still happen, but the local ref is left
   behind and the next stage's `cleanup` won't find a clean slate.

   ```bash
   # Free the local branch from its worktree first.
   # <worktree_path> is what the Agent runtime returned alongside the
   # branch name in step 3 — capture both, use both here.
   git -C "<repo.path>" worktree remove "<worktree_path>" --force

   # Now gh can cleanly delete the merged branch from both ends.
   gh pr merge "<pr_number>" --squash --delete-branch
   ```

   If `<worktree_path>` is empty (legacy path where isolation didn't
   apply — shouldn't happen after #64), skip the `worktree remove`
   step and just call `gh pr merge`; the local-branch delete will
   then succeed because there's no worktree holding the ref.

6. **Sync local main** so the next stage starts from the updated tree:
   ```bash
   git -C "<repo.path>" switch "<base_branch>"
   git -C "<repo.path>" pull --ff-only origin "<base_branch>"
   ```

### Agents commit before returning

The agent's final procedure step runs
`git add -A && git commit -m "<commit_subject>"` on its worktree branch
(only when it made changes). The orchestrator then pushes that
already-committed branch — no ad-hoc "commit pending changes" logic in
this phase. **If a worktree branch comes back uncommitted, that's a
legacy-agent quality bug** — surface it in the summary; do not silently
bridge it.

This pairs with the isolation contract in step 2: the agent only ever
commits to its own worktree branch, and the orchestrator only ever
pushes a branch the runtime created. Together those two invariants
keep `main`'s working tree clean throughout the entire run.

If `--no-merge` was passed: skip this phase. List the branches in the
final summary so the user can merge manually.

## Phase 9 — present the summary

Render a user-facing summary. Each language's results are reported in
its own block so it's clear which plugin produced what.

```
=== Maintenance summary ===

Project:       <repo path>
Branch:        <user's current branch>
Languages processed: <comma-separated list from supported>
<If --tool=<name> was set:>
⚠ Scoped to single tool: <name>
  Other tools were gathered but not dispatched. Re-run without --tool
  to process them.

<If unsupported is non-empty:>
⚠ Languages detected but not yet supported:
  - <lang>: no development-<lang> plugin built yet — see README's
    Plugins section for current per-language status.

<For each language in supported, a block:>
--- <lang> ---

<If response.plan is non-empty (planner ran):>
📋 Plan (M groups, N findings):
  1. [<tool>] <description>
     <findings-count> finding(s) across <files-count> file(s) — priority <score>
     → <agent>
  2. ...

🚀 PRs opened & merged (M):
  - #<pr> [stage 0: coverage] <title> — <merged|escalated after 3 CI fixes>
  - #<pr> [group 1: <tool>] <title> — <merged|escalated after 3 CI fixes>
  - ...

? Missing tooling (N):
  - <tool>: <summary>
    <how to add>
  ...

! Stages requiring your review (N):
  - PR #<pr> ("<title>") — escalated after 3 CI-fix attempts failed.
    Last failing checks: <list>
    Suggested action: <from ci-fixer's escalation_recommendation>
  ...

<If any stage observed pre-existing failures on <base_branch>:>
ℹ Pre-existing CI failures observed on <base_branch> (not maintenance's
  scope — flagging so you know they're still red):
  - <check_name>: failing on <base_branch> and on PR #<pr> — merged anyway
  - ...

<If human_action_required is non-empty for this language:>
🛑 Halted — human action required:
  - <reason>
    recommendation: <recommendation>

--- end <lang> ---

<If pooled notes are non-empty:>
Notes from the gather step:
  - <note 1>
  - <note 2>

<If --no-merge:>
Worktree branches available for manual review (no PRs opened):
  - <branch>: <summary>
  - ...
```

Keep the tone factual. If everything was clean, say so: "No issues
found by the configured tools; project is in good shape."

## What you will NOT do

- **Detection or tool invocation directly** — those are the gather
  script's job; you orchestrate them, you don't reimplement them.
- **Push to main directly, force-push, or `--no-verify`** — every
  change reaches `main` through a PR with passing CI. The CI fixer
  may push additional commits to an open PR's branch (that's the
  flow), but never to a protected base.
- **Run more than 3 CI-fix iterations per PR** — after 3, escalate
  via the summary and move on to the next stage. The user reviews
  the failing PR manually.
- **Process multiple stages in parallel** — stages are sequential so
  each runs against the previous merge's result. Within a stage, the
  spawned agent works in its own worktree.
- **Modify the dispatched language plugin's response** — pass the
  plan through verbatim. The dispatcher is the source of truth for
  what gets spawned per group; you just orchestrate the stages.
