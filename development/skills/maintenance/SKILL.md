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

Anything else: surface the input to the user as "unrecognized
arguments" and stop.

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
- For v1: `languages` contains `python`. If it contains anything else
  *exclusively*, halt with a clear "only Python is supported by
  development-python so far; other language plugins are forthcoming."
  If it contains Python plus others, proceed with Python only.

Extract for use later: `repo` (path = cwd from script), `default_branch`,
`visibility`, `python_version`.

## Phase 2 — gather findings + coverage

Run the Python findings gatherer:

```bash
"<skill-base-dir>/scripts/gather-python-findings.sh" "$(pwd)" > /tmp/findings.json
```

The script outputs a JSON with `tooling_configured`, `findings_by_tool`,
`coverage`, and `notes`. Read those.

If `notes` is non-empty, **remember them** — they describe why certain
tools couldn't produce live findings (e.g., snyk auth missing,
pytest-cov not installed). Surface these to the user in the final
report alongside the maintenance actions.

## Phase 3 — construct the v1 payload

Build the JSON payload per ARCHITECTURE.md schema v1:

```json
{
  "schema_version": "1",
  "repo": {
    "path": "<cwd>",
    "default_branch": "<from detect-stack>",
    "visibility": "<from detect-stack, or 'unknown'>"
  },
  "language": "python",
  "language_meta": {
    "version": "<python_version from detect-stack, or '3.12'>",
    "manifests": [/* whichever of pyproject.toml / requirements.txt / setup.py exist */]
  },
  "tooling_configured": <from findings.json>,
  "findings_by_tool":   <from findings.json>,
  "coverage":           <from findings.json>,
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

The user's current branch from `git rev-parse --abbrev-ref HEAD`.

## Phase 4 — `--dry-run`?

If the user passed `--dry-run`: print the payload (pretty-formatted via
`jq .`), print the notes from phase 2, and stop. Nothing is dispatched
or merged.

## Phase 5 — dispatch

Invoke the language plugin via the Skill tool:

```
Skill(
  skill="development-python:maintenance",
  args="<the JSON payload as a single-line string>"
)
```

The python plugin will:
- Run its coverage pre-flight (it has the data it needs)
- Spawn agents in worktrees
- Return a response JSON with `actions_taken`, `actions_requiring_review`,
  `missing_tooling`, `unable_to_fix`, and possibly `human_action_required`
  (when coverage is below floor)

Capture the response.

## Phase 6 — handle `human_action_required` early-out

If the response contains `human_action_required`, the python plugin
halted because coverage was below floor. Show the reason + recommendation
to the user, skip the merge step, and stop. No worktree branches to
merge in this case.

## Phase 7 — merge worktree branches

The response's `actions_taken` items include `worktree_branch` names.
Collect them all. For each branch, get a diff-stat to size it:

```bash
git diff --stat <user_branch>..<worktree_branch> | tail -1
```

Sort by lines-changed ascending (least conflict first — ruff format
runs end up large but mechanical; bigger semantic refactors more likely
to conflict).

Merge sequentially into the user's current branch:

```bash
git merge --no-ff --no-edit <worktree_branch>
```

If a merge fails with conflicts:

- Abort that one: `git merge --abort`
- Mark it in the user-facing summary as "needed manual merge"
- Continue with the remaining branches

If `--no-merge` was passed: skip this phase. List the branches in the
final summary so the user can merge manually.

## Phase 8 — present the summary

Render a user-facing summary:

```
=== Maintenance summary ===

Project:   <repo path>
Language:  python (<version>)
Branch:    <user's current branch>

✓ Actions applied (N):
  - <tool>: <summary>      <files_changed count>
  ...

! Actions needing your review (N):
  - <tool>: <finding_id>
    <recommendation>
    rationale: <rationale>
  ...

? Missing tooling (N):
  - <tool>: <summary>
    <how to add>
  ...

× Unable to fix (N):
  - <tool>: <finding>
    <reason>
  ...

Notes from the gather step:
  - <note 1>
  - <note 2>

<If branches were merged:>
Merged N branches into <user's branch>:
  - <branch>: <summary>
  ...

<If branches couldn't be merged:>
Manual merge needed:
  - <branch>: <reason>

<If --no-merge:>
Worktree branches available for manual merge:
  - <branch>
  - ...
```

Keep the tone factual. If everything was clean, say so: "No issues
found by the configured tools; project is in good shape."

## What you will NOT do

- **Detection or tool invocation directly** — those are the gather
  script's job; you orchestrate them, you don't reimplement them.
- **Push commits or open PRs** — that's the user's call after seeing
  the summary. The maintenance pipeline ends at merge into the local
  working branch.
- **Spawn agents directly** — the language plugin does that. You
  invoke the plugin via Skill; the plugin handles agent dispatch.
- **Modify files outside of merge operations** — the only writes you
  do are `git merge` and reading the script outputs.
