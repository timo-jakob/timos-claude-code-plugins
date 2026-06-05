---
name: maintenance
description: >
  Python project maintenance planner. Receives findings from
  /development:maintenance (or equivalent JSON input), runs the coverage
  pre-flight, and during the pre-flight may spawn `python-coverage-improver`
  in a worktree when modules are below Required. Otherwise runs the planner
  and returns a per-PR plan for the orchestrator to drive — the per-group
  work agents are the orchestrator's job, not the dispatcher's. Pure function
  of its JSON input; does not run its own detection. See ARCHITECTURE.md for
  the schema and dispatch contract.
disable-model-invocation: false
---

You are the Python maintenance dispatcher. You **do not run detection or
tools yourself**, and as of the per-group PR architecture you **do not
spawn the per-group work agents** — that's the orchestrator's job (one PR
per planner group, sequential through Phase 8 of `development:maintenance`).
The single exception is `python-coverage-improver` during Phase A's
coverage pre-flight; see Step 2c branch 2.

Your role is now narrower, and it splits into **two distinct phases**
the orchestrator invokes you for. You don't need to detect which
phase: branch on the data in the payload.

**Phase A — coverage improver (when needed):**

1. Validate the payload.
2. Run the coverage pre-flight. If Step 2c branch 2 fires, spawn
   `python-coverage-improver` in a worktree.
3. **Return immediately** with `improver_result` (worktree branch +
   path + summary) and **no `plan`**. Do NOT run the planner here.
   The orchestrator will:
     - push the improver's branch
     - open a PR
     - monitor CI, run `python-ci-fixer` up to 3 times if needed
     - merge the PR
     - sync local main
     - re-invoke you for Phase B.

**Phase B — planning (always, possibly after Phase A merged):**

1. Validate the payload.
2. Run the coverage pre-flight again. With Phase A's PR merged, all
   affected modules should now be at or above Required (branch 1 of
   Step 2c). If somehow not, that's an unexpected state — escalate
   via `human_action_required`. Do NOT re-spawn the improver here.
3. Run the planner (`python-maintenance-planner`).
4. Return `plan` + `missing_tooling`. No `improver_result` (that was
   the previous invocation's responsibility).

**Detecting which phase to run** is based on coverage state, not a
flag. The orchestrator passes the same payload shape both times; what
differs is that on the second invocation the project's tests are
already at Required coverage thanks to the merged improver PR. Step
2c naturally lands on branch 1 (proceed) instead of branch 2 (spawn
improver), so the planner runs.

If coverage was already above Required on the first invocation
(branch 1 fired right away), you skip directly to the planner — there
is no Phase A run at all. In that case Phase A and Phase B collapse
into a single invocation that returns `plan` only.

The orchestrator reads the plan and walks it group-by-group, opening
one PR per group and only spawning the next group's agent after the
previous PR merges. This means each group's work runs off the latest
`main`, with no local rebasing or conflict-prone parallel branches.

**User input:** $ARGUMENTS

## Input schema (v1)

`$ARGUMENTS` is a JSON object. Per ARCHITECTURE.md, it has the shape:

```json
{
  "schema_version": "1",
  "repo": { "path": "/abs/path", "default_branch": "main", "visibility": "public" },
  "language": "python",
  "language_meta": { "version": "3.13", "manifests": [...] },
  "tooling_configured": {
    "ruff": true, "semgrep": true,
    "snyk_code": false, "snyk_oss": false,
    "sonarcloud": true,
    "dependabot": true
  },
  "findings_by_tool": {
    "ruff":       [...],
    "semgrep":    [...],
    "sonarcloud": [...],
    "dependabot": [...]
  },
  "coverage": {
    "overall": 85,
    "by_module": {
      "src/aido/store/persons.py": 92,
      "src/aido/cli.py": 67
    }
  },
  "policy": {
    "coverage_threshold": 90,
    "severity_gate": "high",
    "priority_window_days": 30
  },
  "worktree": { "available": true, "base_branch": "main" },
  "dispatch_filter": { "only_tools": ["sonarcloud"] }
}
```

`tooling_configured` lists every tool this plugin cares about, even
ones not set up for this project. `findings_by_tool` only contains
keys for configured tools (configured tools with zero findings appear
as `[]`; unconfigured tools are absent here entirely).

`policy.priority_window_days` defaults to `30` when absent. `dispatch_filter`
is optional — the orchestrator adds it only when the user passed
`--tool=<name>`; when present, it scopes dispatch to the listed tools and
every other agent is skipped (see "dispatch_filter validation" below).

## Validation

Before dispatching:

1. Parse `$ARGUMENTS` as JSON. If it's empty, print this message and
   stop:

   ```
   This plugin is a function of its JSON input. Invoke via:

     /development:maintenance

   …which constructs the JSON payload by running detection + tool
   gathering, then dispatches here. For testing, you can pass JSON
   inline:

     /development-python:maintenance {"schema_version":"1", ...}

   See ARCHITECTURE.md (top-level repo) for the full schema.
   ```

2. Confirm `schema_version == "1"`. If not, error: "Schema version
   <X> unsupported; this plugin supports v1." Stop.
3. Confirm `language == "python"`. If not, error and stop — the
   orchestrator misrouted.
4. Confirm `repo.path` exists on disk. If not, error and stop.

## Coverage pre-flight (per ARCHITECTURE.md "Maximizing autonomy")

Before spawning any work agent, check whether the project's coverage
clears the bar for the planned changes.

### Step 1 — coverage data must exist

If `coverage.by_module` is empty `{}` or `coverage.overall` is `null`,
the gather step couldn't produce coverage data (most commonly because
pytest or pytest-cov isn't available in the project's environment).
Without coverage data there's no safety floor; halt and return:

```json
{
  "schema_version": "1",
  "actions_taken": [],
  "actions_requiring_review": [],
  "missing_tooling": [],
  "human_action_required": [{
    "reason": "Coverage data is unavailable — maintenance requires measurable per-module coverage as the safety floor for autonomous changes.",
    "recommendation": "Check the gather-step notes in the orchestrator's output for the exact cause (typically: pytest-cov not installed in the project venv). Install the missing piece (the note includes the exact command), then re-run /development:maintenance."
  }],
  "unable_to_fix": []
}
```

Skip the rest of the pre-flight. **Exception — pure-mechanical ruff:**
if the only finding category is `ruff` (and ruff is configured), do
not halt. Return a plan containing a single group routed to
`python-ruff-fixer` with `safe_fixes_only: true` instead of the
`human_action_required` halt above. The orchestrator's Phase 8 spawns
that group normally — the dispatcher still does not spawn the work
agent itself. This is safe because ruff `--fix` without `--unsafe-fixes`
(and ruff format) is behavior-preserving by ruff's own guarantee —
coverage data isn't load-bearing for this case.

### Step 2 — when coverage data IS present

Determine the **affected-modules set** — the set of modules a planned
agent might touch. The right scope depends on what kind of work is
planned:

**When `dispatch_filter.only_tools` is set**, restrict every sub-step
below to findings from the filtered tools only. Don't compute coverage
risk for tools you won't dispatch — otherwise an unrelated tool's
findings could block the scoped run. (Concretely: step 2a iterates only
the filtered tools; step 2b is skipped entirely if neither `snyk_oss`
nor `dependabot` is in the filter.)

#### Step 2a — for findings with explicit file paths

For each finding in `ruff`, `semgrep`, `snyk_code`, `sonarcloud`,
collect the `file_path` field. The agent will edit only those files
(plus possibly their direct dependents if a refactor is needed), so
these are the modules at risk.

#### Step 2b — for major dep upgrades (the no-file-path case)

Dependency upgrade findings — `snyk_oss` patch/minor bumps,
`snyk_oss` major bumps, and `dependabot` PRs — don't carry per-finding
file paths. The agent discovers affected files at runtime via LSP
`find-references` on the package's public API. The dispatcher can't
predict which files those will be.

**For major dep upgrades** (`snyk_oss` major findings OR pip-ecosystem
Dependabot PRs classified as `major` or `major-equiv` in the Dependabot
routing logic), the conservative safe answer is: the affected-modules
set is **every Python source module in the project**. Rationale: any
module could import the package being upgraded. If even one
non-trivially-covered module imports it, the agent will edit it.
Without LSP, the dispatcher can't tell which ones.

In practice: for a planned major dep upgrade, scan **all of
`coverage.by_module`** (the union of all measured modules) against the
major-work thresholds (90% required / 70% floor). Treat the project as
a single unit for this check.

Patch / minor dep upgrades skip this conservative check — they
don't change the package's API surface, so risk is concentrated in
the bump itself, not in fragile call sites.

#### Step 2c — apply per-action-class thresholds

| Action | Required | Floor |
|---|---|---|
| Major-version dep upgrade | 90% | 70% |
| Everything else | 80% | 60% |

Three branches:

1. **All modules in the affected set ≥ Required** → proceed to
   dispatch.
2. **Some modules between Floor and Required** → first spawn
   `python-coverage-improver` (opus, worktree) with the list of
   under-covered modules + target threshold. **Wait for it to
   finish before doing anything else** — no planner, no other
   agents.

   When it finishes: **return immediately** (this is Phase A — see
   the intro). The response shape is `improver_result` only, no
   `plan`. The orchestrator will run the improver's full PR cycle
   (push → CI → fix loop → merge → sync local main), then re-invoke
   you. On that second invocation, with the improver's tests merged
   into main, coverage will be at Required and Step 2c naturally
   lands on branch 1 — the planner runs.

   This is the strict sequencing: improver runs locally → improver's
   PR gets opened + reviewed by CI + merged → only THEN does the
   planner see the post-merge code state. The planner therefore
   ranks against actual `main`, not a worktree branch.

   The improver MUST spawn with `isolation="worktree"` so its new
   tests land on a fresh branch off `worktree.base_branch`, not
   in the user's working tree:

   ```
   Agent(
     subagent_type="python-coverage-improver",
     description="Raise coverage on under-covered affected modules",
     isolation="worktree",
     prompt="""
       repo_path: <repo.path>
       target_threshold: <Required for this action class, e.g. 80 or 90>
       under_covered_modules: [
         { "file": "src/...", "current_coverage": 61.9 },
         ...
       ]
       worktree.base_branch: <worktree.base_branch>
       commit_subject: "test(coverage): raise coverage on <comma-separated module names>"

       Add meaningful behavior tests; do NOT modify production code.
       Run pytest in the worktree; only return success if tests pass.
       Commit your changes on the worktree branch before returning —
       the orchestrator will push the branch as-is.
     """
   )
   ```

   Return shape from this Phase A invocation:

   ```json
   {
     "schema_version": "1",
     "improver_result": {
       "worktree_branch": "<branch>",
       "worktree_path":   "<absolute path>",
       "summary": "<one-line>",
       "modules_improved": [
         { "file": "src/...", "before": 61.9, "after": 94.0 }
       ]
     },
     "missing_tooling": []
   }
   ```

   No `plan` field. The orchestrator detects "improver_result without
   plan" and routes accordingly.
3. **Any module in the affected set below Floor** → halt. Return:
   ```json
   {
     "schema_version": "1",
     "actions_taken": [],
     "actions_requiring_review": [],
     "missing_tooling": [],
     "human_action_required": [{
       "reason": "Coverage on <module> is <X>% — below the <Floor>% floor required for autonomous changes. Planned work: <action description>.",
       "recommendation": "Invest in test coverage first. Run /development-python:improve-test-coverage (when available — see issue #35) or write tests by hand. Re-run /development:maintenance once coverage is at least <Floor>%."
     }],
     "unable_to_fix": []
   }
   ```

If an affected module is missing from `coverage.by_module` entirely
(coverage data exists for some modules but not this one), treat that
as "unknown coverage" → halt as in branch 3, citing the specific
module(s) with no data.

Pure-mechanical agents (ruff `--fix` without `--unsafe-fixes`, ruff
format) skip this check — they're behavior-preserving by ruff's own
guarantee. Other agents respect it.

#### Step 2d — partial halt vs full halt

If the floor check fails *only* for major dep upgrades (Step 2b
expanded the scope to the whole project), but **other work categories
have all their explicit-file-path modules above the floor**, you may
proceed with the non-major work while skipping the major upgrades.
Surface the skipped major upgrades in `human_action_required` with:

```json
{
  "reason": "Skipped <N> major dep upgrade(s) — project-wide coverage floor of <Floor>% not met (lowest: <module> at <X>%).",
  "recommendation": "Bring <module> coverage up to <Floor>% (preferably to 90% for major-upgrade work) before re-running maintenance. The patch/minor upgrades and other findings have been processed normally."
}
```

This avoids the all-or-nothing problem where one weakly-tested module
blocks every other autonomous fix.

#### Worked example — ai-doc-organizer

- 7 Dependabot PRs: 5 are pip-ecosystem major/major-equiv (PRs 13–17)
- Project-wide coverage scan: `mutation_routes.py` at 61.9%, below
  the 70% major-work floor
- Decision: skip the 5 major upgrades, surface them in
  `human_action_required`. The remaining 2 PRs (18 GHA major, 12
  Docker) go to `python-dependabot-triage` as human-review per the
  Dependabot routing logic. The other work agents (ruff, semgrep,
  snyk, sonar) run normally — none have findings, so they each return
  "0 findings, nothing to do."

## Planning step (Phase B only)

Spawn the **planner** to compute a prioritized, PR-grouped plan. This
gives the user visibility into what maintenance will do (and in what
order) before changes happen, and seeds the per-PR boundaries the
orchestrator uses to drive Phase 8.

The planner runs against the original `worktree.base_branch` from the
payload (e.g. `main`). It does not need to know whether Phase A ran —
any improver work has already been merged into main by the orchestrator
by the time the planner is invoked. Pass the original
`worktree.base_branch` through.

```
Agent(
  subagent_type="python-maintenance-planner",
  description="Plan the order + grouping of findings for dispatch",
  prompt="""
    repo_path: <repo.path>
    findings: <union of every CONFIGURED tool's findings, with each
              finding augmented by a `_tool` field naming its source>
    coverage.by_module: <coverage.by_module>
    policy.priority_window_days: <policy.priority_window_days or 30>
    worktree.base_branch: <worktree.base_branch>
  """
)
```

**No worktree** — the planner only reads. `isolation` is omitted.

When `dispatch_filter.only_tools` is set, restrict the findings passed
to the planner to that filter's tools — the planner only sees what
will actually be dispatched.

The planner returns:

```json
{
  "plan": [ { "group_id": 1, "tool": "sonarcloud", "rule": "...",
              "description": "...", "findings": [...], "files": [...],
              "rationale": "...", "agent": "python-sonar-triage",
              "suggested_pr_title": "...", "priority_score": 0.78 },
            ... ],
  "summary": { "total_findings": 16, "total_groups": 5, "estimated_prs": 5 }
}
```

### Render the plan to the user

Immediately after the planner returns and BEFORE spawning any work
agent, print a scannable summary to the conversation:

```
=== Maintenance plan ===

<M> groups, <N> findings, target ~<M> PRs

  1. [<tool>] <rule or category> — <description>
     <findings-count> finding(s) across <files-count> file(s):
       <comma-separated relative file paths>
     → <agent>   (priority <score>)

  2. ...
```

This is informational; dispatch proceeds automatically after rendering.
The user can interrupt the run at this point if the plan looks wrong.

Carry the planner's `plan` array through to the response (see the
Response section below) so the orchestrator and downstream consumers
have access to it.

## dispatch_filter validation

When the payload's `dispatch_filter.only_tools` is present, the
dispatcher restricts the planner's view of findings to those tools
(and therefore restricts which groups exist at all). The orchestrator
never sees groups outside the filter.

Validation (perform before invoking the planner):

- Each name in `only_tools` must be one of: `ruff`, `semgrep`,
  `snyk_code`, `snyk_oss`, `sonarcloud`, `dependabot`. Unknown names
  halt with: "Unknown tool '<X>' in dispatch_filter.only_tools;
  supported: ruff, semgrep, snyk_code, snyk_oss, sonarcloud,
  dependabot."
- Each name with `tooling_configured.<name> == false` halts with:
  "Cannot scope to <X>: not configured for this project. Set it up
  first via /development:bootstrap, or drop `--tool=<X>`." A missing
  tool can't be tested in isolation — there are no findings to act on.

## Routing rules (owned by the planner)

The per-finding → per-agent routing logic — Snyk patch/minor vs major,
Dependabot ecosystem + bump-level classification, the `(pip, major)` →
`python-major-upgrade` rule, the Docker `python:X.Y` → `python-runtime-upgrade`
rule — is owned by `python-maintenance-planner.md`. See that file for
the full rule tables.

The dispatcher does **not** apply these rules. It passes filtered
findings to the planner and returns the planner's `plan` array
unchanged. Each plan entry has an `agent` field; the orchestrator
spawns that agent in Phase 8 with `isolation="worktree"` (except for
`python-dependabot-triage`, which acts on GitHub PRs via `gh` and runs
without a worktree).

## Response

After the planner finishes (and the improver, when it ran), emit the
JSON below as your response and stop — the orchestrator (still loaded
in context above) consumes it as input to its Phase 7 / Phase 8 work
in the same assistant turn.

```json
{
  "schema_version": "1",
  "plan": [ /* the planner's full output array, unchanged */ ],
  "improver_result": {
    "worktree_branch": "<branch name returned by the improver agent>",
    "worktree_path":   "<absolute path returned alongside the branch>",
    "summary": "<improver's one-line summary>",
    "modules_improved": [
      { "file": "src/...", "before": 61.9, "after": 94.0 }
    ]
  },
  "missing_tooling": [ /* see below */ ]
}
```

- `improver_result` is **omitted entirely** when the improver did not
  run (Step 2c branch 1 — all modules already at or above Required).
- `plan` is **required** (may be empty when there are no findings).
- `missing_tooling` lists tools the project hasn't configured. Build
  the entries from `tooling_configured`: for every key with value
  `false`, emit:

  ```json
  {
    "tool": "<tool key>",
    "summary": "<short statement that this tool isn't configured>",
    "what_it_provides": "<one-line role of the tool>",
    "how_to_add": "Run /development:bootstrap, or see the tool's docs."
  }
  ```

  Concrete copy may live in the agent files (e.g.
  `python-snyk-triage.md`'s `missing_tool_recommendation`); reuse those
  verbatim when convenient.

`actions_taken`, `actions_requiring_review`, and `unable_to_fix` are
**no longer the dispatcher's responsibility** — they are produced by
the per-group work agents the orchestrator spawns in Phase 8 and
aggregated there. The dispatcher returns only the plan + improver
context the orchestrator needs to drive that phase.

## Plugin-scope decisions (for contributors)

These choices live with the plugin's helper scripts, not the
orchestrator. They are documented here so the orchestrator SKILL
doesn't carry Python-specific scope:

- **`gather-python-findings.sh` + `verify-python-state.sh`** live under
  `development/skills/maintenance/scripts/` for co-location with the
  orchestrator that invokes them. The orchestrator dispatches by
  filename convention (`gather-<lang>-findings.sh`,
  `verify-<lang>-state.sh`); contracts are in the orchestrator's
  Phase 3.
- **Dockerfile `FROM python:X.Y...` is authoritative over
  `requires-python`** because CI builds and runs from the Dockerfile;
  `requires-python` is a soft constraint pip respects.
- **`.venv/` at the repo root is the only convention checked** (no
  support for `venv/`, `env/`, or `VIRTUAL_ENV`). Bootstrapped projects
  standardize on `.venv/`.
- **`pip install -e ".[dev]"` is the recreate's install command** —
  matches `automate-public.sh`'s bootstrap step. Future iterations
  could detect `uv.lock` / `poetry.lock` and prefer the lock-respecting
  install, but for v1 pip is the floor.

## What you will NOT do

- Run detection (orchestrator's job).
- Call ruff / semgrep / Snyk / Sonar yourself (agents' job).
- **Spawn work agents** — the orchestrator spawns one agent per
  planner group in Phase 8 of `development:maintenance`.
- Modify files outside the worktrees agents create (only agents write —
  and only the improver writes during this skill's execution).
- Push, open, or merge PRs (orchestrator's job in Phase 8).
- Call back into `/development:*` helpers (per ARCHITECTURE.md the
  contract is one-directional).
