---
name: maintenance
description: >
  Maintenance orchestrator. Runs detection + per-tool findings gathering +
  coverage measurement, constructs the v1 JSON payload, dispatches to the
  language plugin (development-python in v1), and drives a sequential
  per-stage PR cycle (push → CI → merge → sync) until the plan is
  exhausted. The user-facing entry point for "go fix everything you safely
  can on this project."
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
  `<name>` must be one of: `ruff`, `semgrep`, `code_scanning`,
  `snyk_prs`, `sonarcloud`, `dependabot`. The gather phase still runs
  for every tool (the payload stays complete), but the language plugin
  only spawns the agent(s) for the chosen tool. Other agents are
  skipped entirely — no work, no missing-tool recommendation.
  Combinable with `--dry-run` and `--no-merge`.
- `--track-as-issues` — after the run completes, create / update /
  close GitHub tracking issues for each scanner tool's remaining
  findings. One issue per tool (`ruff`, `semgrep`, `code_scanning_alerts`,
  `sonarcloud`); labels `maintenance` + `tool:<name>`; idempotent on
  `(repo, tool)`. Skipped for PR-based tools (`dependabot`, `snyk_prs`)
  since their findings are already first-class PRs. See Phase 10 below
  for the contract. Off by default; opt in per run.

Anything else: surface the input to the user as "unrecognized
arguments" and stop.

When `--tool=<name>` is set, validate `<name>` against the known set
above before proceeding. On a mismatch, halt with: "Unknown --tool
'<name>'; supported: ruff, semgrep, code_scanning, snyk_prs,
sonarcloud, dependabot."

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

## Phase 2.5 — Approver feedback ingestion (when Claude Apps registered)

Closes the loop between the **Claude Approver** (which posts
`REQUEST_CHANGES` reviews on PRs with a hidden JSON block of findings)
and the language-plugin triage agents that can fix those findings.

When the Approver posts `REQUEST_CHANGES` on a PR, the user re-runs
`/development:maintenance` to ingest the feedback. This phase finds the
flagged PRs, dispatches agents to fix what's auto-fixable, and pushes
the fixes back to the PR branches. CI re-runs on each push; the
Approver re-evaluates on the next `check_suite: completed` event. The
loop closes without further user intervention.

**Skip silently** when `~/.config/claude-plugins/apps.json` doesn't
exist — the Approver isn't set up on this machine, there's nothing
to ingest.

### Detection

For each open PR in the current repo (`gh pr list --state open --json
number,headRefName,headRefOid,author`), fetch the most recent review
by `claude-approver[bot]`:

```bash
gh pr view <pr> --json reviews --jq \
  '[.reviews[] | select(.author.login == "claude-approver[bot]")] | sort_by(.submittedAt) | last'
```

A PR is **Approver-flagged** when ALL hold:
- A review by `claude-approver[bot]` exists.
- Its `state` is `CHANGES_REQUESTED`.
- Its `commit_id` equals the PR's current `headRefOid` (no push since
  the review).
- Its `body` contains a `<!-- claude-approver:findings ... -->` HTML
  comment block.

### JSON parsing

Extract the hidden block, parse the JSON. Schema documented in
[`development-python/docs/python-approver.md`](../../../development-python/docs/python-approver.md)
(the *JSON schema* section). Key fields:

- `verdict` — must be `"REQUEST_CHANGES"` for this phase to act.
- `findings[]` — each finding has `category`, `title`, `detail`,
  `suggested_agent`, `file`, `line`.

### Dispatch

Group findings by `suggested_agent`. Findings with `suggested_agent:
null` are unfixable by automation; record them in the Phase 9 summary's
*"Approver-flagged, needs human attention"* list with the finding's
`title` and `detail`.

For each agent group, spawn the agent with `isolation="worktree"`
**and the PR's head SHA as worktree base**:

```
Agent(
  subagent_type="<finding.suggested_agent>",
  description="Fix Approver findings on PR #<n>",
  isolation="worktree",
  prompt="""
    repo_path: <repo.path>
    pr_number: <n>
    pr_branch: <pr.headRefName>
    findings: [ ... group of findings for this agent ... ]
    source: approver

    Address the findings above on the worktree branch (already based
    on the PR's HEAD). Run the project's test command before declaring
    success. Commit on the worktree branch — the orchestrator will push
    the commit to the PR branch.
  """
)
```

**Critical**: the worktree base is the PR's head SHA, not main. The
agent's fix layers on top of the PR; it doesn't replace it.

After the agent returns:

```bash
git -C "<worktree>" push --force-with-lease origin "<worktree_branch>:<pr.headRefName>"
git -C "<repo.path>" worktree remove "<worktree>" -f -f
```

The `--force-with-lease` protects against a parallel push race; the
agent's commit is the new head and we need to fast-forward the PR
branch to it.

### Identity

Phase 2.5 itself uses the user's `gh` auth. The PR was opened by
`claude-maintenance[bot]` in a prior maintenance run (when the
identity switch in Phase 8 fired), so the PR author is already the
bot; pushes don't change the PR author. Identity-switching matters
only at **PR creation time** — see Phase 8's *Identity for PR
creation* subsection.

### Skip conditions

- `suggested_agent` is `null` — record in the summary, skip the
  finding. Author judgement required.
- Named agent isn't installed in this plugin family (e.g., a Node
  agent on a Python-only project) — record in the summary, skip.
- Agent returns `human_action_required` — record the reason in the
  summary, skip.

### After this phase

Continue to Phase 3 (gather + plan + Phase 8 normal flow). The
Approver-driven fixes are pushed; the normal flow finds and addresses
any new issues from tools.

## Phase 3 — gather findings per supported language

### State pre-flight (per supported language)

Before invoking each language's gather script, run that language's
state-verification helper to make sure the gather will produce
trustworthy results. The helper's job is to surface stale or
inconsistent local state (a venv built against the wrong interpreter,
a deleted Bundler cache, a missing Go toolchain, etc.) and recover
where it can autonomously.

Naming convention mirrors the gather scripts: per detected language
`lang`, look for and invoke:

```bash
"<skill-base-dir>/scripts/verify-<lang>-state.sh" "$(pwd)"
```

If the script doesn't exist for a language, skip — that plugin
hasn't published a state-verification helper yet, and the gather
script's own internal notes path will handle whatever state issues
surface. Don't fail the run on a missing helper.

#### Verify-state script contract (all languages)

The script's exit code drives the orchestrator's next move. Don't
parse stdout/stderr to guess intent; trust the exit code.

| Exit code | Meaning | What you do |
|---|---|---|
| `0`, no stdout | State is fine, no action needed | Proceed to the gather script |
| `0`, stdout is JSON `{"recovered": true, ...}` | State was rebuilt successfully (e.g., venv recreated, deps reinstalled) | Proceed to the gather script. Include the JSON in the run summary so the user knows their local env changed. |
| `1`, message on stderr | User must intervene; cannot recover autonomously (typically: a tool isn't installed) | **Halt the run.** Forward the stderr message to the user verbatim. |
| `2`, stdout JSON `{"recreate_failed": true, ...}` (or other "tried, failed" shapes) | Recovery attempt failed mid-flight; user needs to choose | Invoke the **R.4 fallback** below: surface the JSON details via `AskUserQuestion` and act on the choice. |

Anything else (non-zero with no JSON, etc.) → halt and forward stderr.
Treat unknown failure modes as user-intervention paths rather than
silently continuing on broken state.

#### R.4 — fallback when the state script exits 2

The recovery attempt found a problem it couldn't auto-fix (typically:
a dep cascade exhausted before the venv would install). The state
script's JSON payload identifies the blockers; surface them via
`AskUserQuestion` with three options that work for any language's
state model:

```
Question: "Local <lang> state can't be reconciled with main's declared
           configuration:
             - <blocker 1 from script JSON>
             - <blocker 2>
           Main is already at the new configuration. What now?"

Options:
  1. "Fall back to the previous configuration locally"
        — invoke the same verify-<lang>-state.sh with a
          --target-<something>=<old_value> flag so the script rebuilds
          state matching what main USED to look like. Specifics per
          language (Python: --target-py=<old_version>). Subsequent
          Phase 8 stages SKIP the pre-flight for the rest of this run
          (in-memory flag; resets next /development:maintenance call).
        — record in the summary: "Local <lang> state reverted to
          previous config; main is at the new config pending the
          blocker resolution."

  2. "Open a GitHub issue capturing the blockers, then halt"
        — orchestrator drafts an issue body from the script's JSON
          blockers, posts via `gh issue create`. Halt the run.

  3. "Halt — I'll handle it manually"
        — no further action. Run ends with the script's report in the
          summary.
```

This fallback shape is language-agnostic. The script JSON tells the
orchestrator what to put in the question; the option-1 fallback
command is `verify-<lang>-state.sh --target-...` with a flag the
language plugin defined.

### Run the gather script

For each `lang` in `supported`:

```bash
"<skill-base-dir>/scripts/gather-<lang>-findings.sh" "$(pwd)" > "/tmp/findings-<lang>.json"
```

Each script outputs a JSON with `tooling_configured`, `findings_by_tool`,
`coverage`, and `notes`. Collect them all. Python's gather additionally
emits `sonar_quality_gate` (#50) — the main branch's Quality Gate verdict
(`{status, conditions}`, or `null` when SonarCloud isn't configured or the
fetch failed). It is user-facing state for Phase 9's summary only and is
**never** copied into the dispatch payload.

If a script exits non-zero or produces malformed JSON, that's an
internal error — surface it to the user (with the script path + stderr)
and skip that language. Don't try to construct a payload from a broken
gather output.

Pool all `notes` across all gather scripts; they describe why certain
tools couldn't produce live findings (e.g., snyk auth missing,
pytest-cov not installed). Surface them in the final summary.

### Project-level findings — template drift

After per-language gathers complete, run the template-drift detector
**once** (it's project-level, not per-language):

```bash
template_drift=$("<skill-base-dir>/scripts/detect-template-drift.zsh" "$(pwd)")
```

The detector reads each tracked rendered file's
`# claude-bootstrap: rendered from … sha256:<H>` marker (#213) and
compares the recorded sha256 against the current template's sha256.
Output is a JSON array of findings, possibly empty. Severities:

| Severity | What it means |
|---|---|
| `drifted` | Marker present, template hash has moved upstream — re-bootstrap or patch to pick up fixes. |
| `unknown_provenance` | File lacks a marker (rendered before #213 shipped, or hand-created). Can't verify drift. |
| `template_missing` | Marker references a template path that no longer exists upstream (renamed/deleted). |
| `malformed_marker` | Marker present but unparseable — corrupted by hand-edit. |

These findings do **not** enter `findings_by_tool` and are **not**
routed to any per-tool triage agent in v1. v1 is detect-only: surface
the findings in Phase 9's summary and let the user decide between
re-bootstrap, manual patch, or accepting the drift. Store
`$template_drift` so Phase 9 can render it.

## Phase 4 — construct one payload per supported language

For each `lang` in `supported`, build the JSON payload per ARCHITECTURE.md
schema v2:

```json
{
  "schema_version": "2",
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

**Construction discipline.** Copy `tooling_configured`,
`findings_by_tool`, and `coverage` straight out of
`findings-<lang>.json`. Do not drop entries from `coverage.by_module`
because there are "many"; do not truncate
`findings_by_tool.dependabot[].body` because it contains 10 KB+ of
release notes; do not flatten or summarise any nested value. The full
**no-trim contract** — including the two real incidents that motivated
it — is documented in Phase 6. Construction is where the trimming
most commonly enters; if the payload you build here already has
fields shortened, Phase 6's contract is broken before dispatch even
starts.

## Phase 5 — `--dry-run`?

If `--dry-run`: print each payload (pretty-formatted via `jq .`)
labeled by language, print the pooled notes, list any unsupported
languages, and stop. Nothing is dispatched or merged.

## Phase 6 — dispatch per supported language to plan

For each `lang` in `supported`, invoke the matching language plugin via
the Skill tool. **The payload is handed over via a temp file**, not
inline — see ARCHITECTURE.md § "JSON schema (v2)" for the contract.

```bash
# 1. Write the payload to a temp file. The helper sets 0600 perms
#    and prints the absolute path on stdout.
payload_file=$(print -r -- "$payload_json" \
  | "<skill-base-dir>/scripts/write-payload.zsh")
```

```
# 2. Dispatch. args= is the path to the file just written.
Skill(
  skill="development-<lang>:maintenance",
  args="$payload_file"
)
```

```bash
# 3. After the Skill tool returns (success or failure), delete the
#    temp file. On hard crash the OS reaps it from $TMPDIR.
rm -f "$payload_file"
```

`<skill-base-dir>` is the maintenance skill's directory (the same
placeholder used for `mint-maintenance-token.zsh` elsewhere in this
file).

The file-based handover decouples payload size from any Skill-tool
inline limit. A maintenance run on a project with 200+ Dependabot PRs
(~6 MB payload) is the same code path as one with three patches.

### No-trim contract — known recurring bug

Payload trimming by the orchestrator has been observed in **two real
maintenance runs**, despite the previous version of this section
already saying "pass the payload as-is." The prose below is the
strengthened replacement; the earlier wording was not enough to
prevent the trimming.

The two incidents:

- **2026-06-05** — scoped `--tool=dependabot` run. The orchestrator
  dropped entries from `coverage.by_module` because it judged the
  payload "had lots of entries." The dispatcher's safety net halted
  with `human_action_required` citing missing coverage data; the
  orchestrator caught itself mid-narration and re-dispatched with the
  full payload.
- **2026-06-06** — full run. The orchestrator truncated
  `findings_by_tool.dependabot[].body` because it judged "10 KB+
  release notes per PR pushed the payload to ~70 KB." The triage
  agent's `gh` refetch silently compensated — that is **lucky, not
  correct**. Pre-spawn routing decisions that depend on body content
  would have routed wrong.

**The rule, with no judgement attached: pass the payload as-is.** Do
not trim, summarise, drop fields, sample, flatten, or restructure
any value before the `Skill(...)` call. The fields that have been
trimmed in the wild — and that downstream code reads — include:

- `coverage.by_module` — every module, every row. Eighty-plus
  modules is normal; do not sample because there are "many."
- `findings_by_tool.dependabot[].body` — the full body, even when
  it's 10 KB of release notes. The triage agent reads it for
  grouped-PR member lists, release-notes breaking-change flags, and
  Dependabot compatibility scores.
- `findings_by_tool.snyk_prs[].body` — same rule, same reasons.
- `findings_by_tool.code_scanning_alerts[]` — every alert, every
  field; `python-major-upgrade` and a future runtime-upgrade agent
  consume fields the orchestrator does not see used in the immediate
  dispatch.

And every other schema field. Trimming silently changes routing
because downstream agents parse fields the orchestrator never read.

**On payload size.** Both observed incidents (~70 KB and smaller)
were well below any actual Skill-tool limit — the trimming was a
behavioural error, not a capacity workaround. With v2's file-based
handover (above), payload size no longer enters the Skill-tool's
input budget at all — the `args=` value is a ~80-byte path, regardless
of whether the payload behind it is 5 KB or 5 MB. The previous
"200 KB inline ceiling" + `human_action_required` escape valve is
gone; do not reintroduce it.

If a payload routinely grows multi-MB, file a quality bug against
the gather script — it should not produce that much. But payload
size is never a justification for trimming.

**Self-check before each dispatch.** The JSON contents written to
the temp file should be character-for-character identical to the
payload you constructed in Phase 4. If you cannot say that with
certainty — because you "tidied up," "shortened," "deduplicated,"
or "summarised" something — the contract is broken. Reconstruct the
payload from `findings-<lang>.json` and dispatch again.

The dispatcher's internal Phase A / Phase B sequencing — when it spawns
the coverage-improver, when it runs the planner, what payload validation
it performs — is owned by the language plugin. See
`development-python/skills/maintenance/SKILL.md` (intro) for the canonical
Phase A/B contract.

The orchestrator only needs to handle the three response shapes:

**Orchestrator's response handling for the first dispatch:**

- **Response has `improver_result` and no `plan`** → improver ran.
  Run Stage 0 of Phase 8 first (push the improver's branch, open a
  PR, monitor CI, merge, sync local main). Then **re-invoke the
  plugin with the same payload** to get the plan. The second
  invocation sees post-merge coverage and naturally lands on Phase B.
- **Response has `plan` and no `improver_result`** → improver wasn't
  needed. Skip Stage 0. Proceed straight to Phase 8's per-group PRs.
- **Response has `human_action_required`** → halt as before
  (Phase 7).

**The `Skill(...)` call is a step, not a turn boundary.** On return,
continue straight into Phase 7 and Phase 8 in the same assistant turn.
The dispatcher's plan response is Phase 8's **input**, not a checkpoint.
The only events that end a turn before Phase 9 are (a) `human_action_required`,
(b) all Phase 8 stages complete + Phase 9 summary printed, or (c) the user
explicitly says "stop".

**The language plugin does NOT spawn the per-group work agents** in
either phase. Work agents are spawned per-group in Phase 8 below so that
each group's PR cycle (push → CI → merge → sync) completes before the
next group starts off the just-merged main. The one exception is the
coverage-improver itself, which the dispatcher spawns during Phase A.

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

**Stage 0 (improver) is special: it runs BEFORE the planner has even
been invoked.** When Phase 6's first dispatcher call returned an
`improver_result`-only response, you immediately do Stage 0 here.
Only after the improver's PR is merged + main is synced do you go
back and re-invoke the dispatcher for Phase B, which gives you the
plan. Then Stages 1..N proceed. This serialization is the whole
point — the planner must rank against actually-merged main, not a
worktree branch.

If `--no-merge` was passed, **skip this phase entirely** and list the
plan + any local worktree branches in the final summary for manual
handling.

### Identity for PR creation (when Claude Apps registered)

When `~/.config/claude-plugins/apps.json` has a `claude_maintenance`
entry, mint an installation token before every `gh pr create` call in
this phase so the new PRs attribute to `claude-maintenance[bot]`:

```bash
maint_token=$("<skill-base-dir>/scripts/mint-maintenance-token.zsh")
GH_TOKEN="$maint_token" gh pr create --base ... --head ... --title ... --body ...
```

Why this matters for the Approver loop:

- The Approver's default author allowlist
  (`CLAUDE_APPROVER_AUTHOR_ALLOWLIST` per-repo variable) is
  **machine-only** by default and includes `claude-maintenance[bot]`.
  Without the identity switch, maintenance PRs would be authored by
  the user, the allowlist would reject them, and the Approver would
  not evaluate the PR at all — the entire Approver→maintenance loop
  would never start.
- The Approver's anti-rubber-stamp gate (PR author ≠
  `claude-approver[bot]`) fires correctly: `claude-maintenance[bot]`
  and `claude-approver[bot]` are distinct App identities by design.

The installation token has a 1-hour lifetime. If a maintenance run
takes longer than an hour and you need another `gh pr create`, re-mint
by calling `mint-maintenance-token.zsh` again.

If `mint-maintenance-token.zsh` fails (App not installed on the repo,
key revoked, network down), surface the error to the user and **abort
PR creation for that stage**. Falling back to the user's PAT would
open a PR the Approver couldn't evaluate — worse than skipping. The
Phase 9 summary should clearly call out the skipped stage with the
reason.

If `~/.config/claude-plugins/apps.json` doesn't have a
`claude_maintenance` entry (Claude Apps not registered on this
machine), open PRs with the user's existing `gh` auth — the Approver
isn't installed on the repo either, so the identity mismatch is moot.

### Stage 0 — coverage improver (when present)

When Phase 6's first dispatcher call returned `improver_result` (no
plan yet), run Stage 0 now, **before re-invoking the dispatcher for
Phase B**. The improver's worktree branch + path are in the response;
both are returned by the Claude Code runtime because the improver
spawned with `isolation="worktree"`.

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

5. **Now re-invoke the dispatcher** with the same payload that drove
   the first dispatch — coverage is now at Required on main, so the
   second invocation lands on Phase B and returns the plan. Use the
   same three-step file-handover pattern as Phase 6:

   ```bash
   payload_file=$(print -r -- "$payload_json" \
     | "<skill-base-dir>/scripts/write-payload.zsh")
   ```
   ```
   Skill(
     skill="development-<lang>:maintenance",
     args="$payload_file"
   )
   ```
   ```bash
   rm -f "$payload_file"
   ```

   The new response will have `plan` and no `improver_result` (that
   was the previous response's responsibility). Capture the plan and
   continue with Stages 1..N below.

   **If the improver's PR was escalated** (3 ci-fixer attempts failed
   or coverage somehow not at Required after merge), surface the
   escalation and halt the run for this language. Do NOT re-invoke
   the dispatcher; the project's coverage isn't where Stages 1..N
   need it to be.

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

   Only exception: `python-dependabot-snyk-triage` is spawned WITHOUT
   `isolation` (it acts on GitHub PRs via `gh`, not local files).
   See the dispatcher SKILL for the full case list.

   **Pre-flight for `python-runtime-upgrade` groups.** Before spawning
   this agent, the orchestrator must check whether the target runtime
   is locally available — the agent's cascade depends on it, and
   subagents can't prompt the user interactively, so this decision must
   happen here.

   Interpreter detection + install is **plugin-owned** (the orchestrator
   has no language-specific knowledge). For Python, invoke the
   development-python plugin's helper script:

   ```bash
   "<plugin-base-dir>/development-python/scripts/pre-dispatch-runtime-upgrade.sh" \
     detect "<to_version>"
   ```

   The script extracts `<to_version>` from the plan entry (e.g. `3.14`
   from a `python:3.14-slim-bookworm` PR), probes the standard install
   locations, and prints a JSON result on stdout. Exit 0 if the runtime
   is found, exit 1 if missing.

   - **Found** (exit 0) → spawn the agent with `local_verification_mode:
     "auto"` and proceed normally (the agent runs the 3-pass cascade).
   - **Missing** (exit 1) → **ask the user** via `AskUserQuestion` with
     exactly these three options:

     1. **"Install the runtime now"** — orchestrator runs the script's
        `install <to_version>` subcommand, then re-runs `detect`. If
        re-detect still fails, surface the install error and re-ask the
        user (don't silently fall through to skip).
     2. **"I'll install it myself"** — pause, point the user at the
        plugin's installation guidance, then ask a follow-up
        `AskUserQuestion` "Ready to continue?" with options
        ["Yes, re-check", "Cancel — skip local verify"]. On "Yes,
        re-check", re-run the `detect` subcommand; loop at most once,
        then fall through to skip.
     3. **"Skip local verification"** — spawn the agent with
        `local_verification_mode: "skip"`. The agent edits + commits
        the Dockerfile + `requires-python` only; CI does the real
        verification.

   The agent's prompt gains one extra field:

   ```
   local_verification_mode: "auto" | "skip"
   ```

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
4. **Push** the worktree branch to origin, **open the PR** against the
   effective base branch (titled per the plan entry's
   `suggested_pr_title`), and capture the new PR number.
5. **Close superseded vendor PRs.** Inspect the agent's response for
   any `actions_taken[].superseded_prs` entries (currently emitted by
   `python-major-upgrade`; any future agent that opens a replacement
   for a vendor PR uses the same field). For each PR number listed,
   close it with a "Superseded by" comment referencing the
   replacement:

   ```bash
   for superseded in <pr numbers from response>; do
     GH_TOKEN="$maint_token" gh pr close "$superseded" \
       --comment "Superseded by #<replacement_pr> — local major-upgrade with full audit + tests."
   done
   ```

   Use the `claude-maintenance` App token (from earlier in this phase)
   when available so the close attributes to `claude-maintenance[bot]`,
   matching who opened the replacement. Without the token, fall back
   to the user's `gh` auth.

   Close **before** the CI cycle starts (next step), not after merge:
   the vendor's PR list stays clean while the replacement waits in
   review, and Dependabot stops rebasing the superseded PR. If the
   replacement is later rejected, reopen the vendor PR with
   `gh pr reopen <n>` — no data is lost.
6. **Run the CI cycle** (same as Stage 0).
7. **After merge, sync local main**.
8. Continue to the next group.

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

   **Per-tool override (conservative).** Before treating any check as
   pre-existing, **promote any check that matches THIS PR's own tool
   back into the "investigate" bucket**. The PR's tool is
   `plan[i].tool` for the current group (or `coverage` for the
   improver Stage 0 PR). A same-tool failure on the PR is never
   trusted as "pre-existing" because the work agent was responsible
   for resolving the tool's findings completely — under the planner's
   one-group-per-agent rule, there are no "other groups" of the same
   tool to absorb the blame. The failure means either:

   - the agent's fix didn't actually land (incomplete commit, bad
     patch), or
   - a finding the agent intentionally left in `actions_requiring_review`
     is now blocking CI.

   In both cases the right move is to investigate, not silently merge.
   `python-ci-fixer` will dig into the log and either fix the
   remaining failures or escalate with an actionable recommendation.

   Tool → check-name correspondence is judgment-based; use substring
   match on the tool key (case-insensitive). Examples:

   - PR is a sonar group → `plan[i].tool == "sonarcloud"`. A failing
     `sonarcloud` (or `sonar-quality-gate`, etc.) check is this PR's
     own tool — keep in the new-failures bucket. A failing `image`
     (Snyk container) check is a different tool — eligible for
     pre-existing-skip.
   - PR is a `snyk_prs` or `dependabot` group → `plan[i].tool` is
     `"snyk_prs"` or `"dependabot"`. A failing CI check that matches
     the same vendor's other PR signals (e.g. another Snyk App check)
     is this PR's own tool. A failing `code-scanning`/`codeql` check
     is a different tool — eligible for pre-existing-skip.
   - Stage 0 (coverage improver) → treat the project's coverage gate
     check (typically Sonar's QG "new code coverage") as the PR's
     own tool; everything else is eligible for skip.

   After applying this override:

   - **All remaining (non-same-tool) failures pre-existing** AND **no
     same-tool failures** → log the pre-existing names ("pre-existing
     on `<base_branch>`: `<list>`"), treat them as a noop for merge
     gating, proceed to step 5 (merge). Record in the run summary so
     the user knows they're still red.
   - **At least one same-tool failure** OR **at least one new
     non-same-tool failure** → spawn `python-ci-fixer` for that
     combined set. Pass two things in its prompt:

     - `failing_checks: <list>` — the names from the combined bucket
       above (truly-pre-existing failures are NOT in this list).
     - `pr_scope` — what this PR was responsible for, so the fixer
       can distinguish "this PR should have fixed X but didn't" from
       "X isn't this PR's responsibility, escalate." Shape:

       ```json
       {
         "tool":        "<plan[i].tool>",
         "description": "<plan[i].description>",
         "files":       <plan[i].files>,
         "findings":    <plan[i].findings, full objects with keys + messages>
       }
       ```

       For Stage 0 (coverage improver), use:

       ```json
       {
         "tool":             "coverage",
         "description":      "Raise coverage on under-covered modules",
         "files":            <modules the improver was supposed to bring above threshold>,
         "target_threshold": <the Required value, e.g. 80 or 90>
       }
       ```

     The fixer uses `pr_scope` to scope its work at the **tool
     level**: every failing finding from this PR's tool is in scope,
     other tools' checks are out of scope (escalated). Same-tool
     scope is exhaustive — `pr_scope.findings` is informational
     context for the fixer (what the work agent intended to address),
     not a filter for narrowing scope further. See
     `python-ci-fixer.md` step 3 for the full decision table.

4. **Process the fixer's response.** The fixer returns JSON
   distinguishing three outcomes:

   - `resolved: true` with empty `out_of_scope_failures` → fixer made
     a commit; re-monitor CI for the next check round.
   - `resolved: true` with non-empty `out_of_scope_failures` → the
     failure was classified out of scope (a different tool's check
     failing, or a generic check pointing at files outside this PR's
     diff). **This PR is safe to merge** — skip further fixer
     invocations for that check, proceed to step 5. Record the
     out-of-scope failures so they appear in the run summary.
   - `resolved: false` → fixer couldn't resolve an in-scope failure;
     `escalation_recommendation` says why. Re-monitor only if a fix
     commit was made; otherwise count this attempt.

   **Repeat up to 3 fixer invocations on the remaining in-scope new
   failures**. After each fixer commit, re-monitor and re-classify
   (a new failure might resolve while a different pre-existing one
   persists — that's still a green light to merge per the previous
   bullet). If in-scope failures still persist after 3 attempts, **do
   not merge** — record the PR in `actions_requiring_review` for the
   final summary and **continue to the next stage**. Failure on one
   stage does not block later stages.
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
   #
   # IMPORTANT: use -f -f (double force), not --force / -f.
   # Claude Code's Agent runtime locks every worktree it creates
   # (lock reason: "claude agent agent-<id>"). The lock survives even
   # after the originating claude process exits, so single -f errors
   # out with "cannot remove a locked working tree". -f -f overrides
   # the lock AND any uncommitted state. Without this, the remove
   # silently fails, the local branch stays attached to the worktree,
   # gh pr merge --delete-branch fails to delete the local ref, and
   # the worktree accumulates across runs.
   git -C "<repo.path>" worktree remove "<worktree_path>" -f -f

   # Now gh can cleanly delete the merged branch from both ends.
   gh pr merge "<pr_number>" --squash --delete-branch

   # Belt-and-suspenders: prune any administrative refs left over from
   # earlier runs where the remove failed silently.
   git -C "<repo.path>" worktree prune
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

7. **Re-run the state pre-flight from Phase 3.** A merge — especially
   of a runtime-version-bumping PR — can change the project's
   declared configuration, leaving local state (venv, toolchain cache,
   etc.) inconsistent. Without this re-check, subsequent stages'
   agents run their verification against state that no longer matches
   what's on `main`, producing false-positive errors and missed
   regressions (the live test on ai-doc-organizer's Stage 7 surfaced
   exactly this for the Python venv case after a 3.13 → 3.14 merge).

   Invoke the same per-language helper from Phase 3:

   ```bash
   "<skill-base-dir>/scripts/verify-<lang>-state.sh" "$(pwd)"
   ```

   Handle the exit code per Phase 3's script-contract table. The R.4
   fallback applies here too — the script's exit-2 JSON drives the
   `AskUserQuestion` shape.

   **In-memory skip flag.** If R.4's option 1 ("fall back to previous
   configuration locally") was chosen earlier in this run, set a
   run-scoped flag and SKIP this step on every subsequent stage. The
   user has explicitly accepted the mismatch; re-asking on every stage
   would be noisy. The flag is in-memory only; the next
   `/development:maintenance` invocation re-evaluates from scratch.

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

### Before rendering — cross-link known issues

Before emitting any advisory / TODO / "investigate this" line in the
run notes, check whether the project already has an open issue
tracking it. List the repo's open issues:

```bash
gh issue list --state open --limit 50 --json number,title,labels
```

For each advisory you're about to emit, scan the titles for an
obvious topical match (keywords from the advisory's subject — tool
name, bug type, version pin, etc.). If you find one, append
`(see #<n>)` to the advisory line so the user isn't pointed at
investigation work that's already filed.

Examples of the kind of match worth surfacing:

- An advisory about a ruff py314 bug → matches an issue titled
  "Re-enable ruff format once upstream py314 except-tuple bug is
  fixed" → emit `(see #38)`.
- An advisory about a Snyk container CVE → matches an issue titled
  "Suppress Debian base-image CVEs in .snyk" → emit `(see #N)`.

Be conservative — only cross-link when the topical match is
unambiguous. A wrong `(see #N)` is worse than no link. If you're
unsure, omit the link.

The same applies for the **plugin repo's** issues
(`timo-jakob/timos-claude-code-plugins`) when the advisory is about
the maintenance pipeline itself (e.g., a recurring scrape failure,
a known agent quirk) — use `gh issue list --repo <plugin-repo>`.

### Snyk channel naming

The Render template below mentions Snyk channels in its pre-existing-failures
section. These rules govern *how to name the channel* when emitting a line —
they are guidance for you, not output.

Snyk surfaces findings through *three* independent channels, and run-note
prose has historically confused them. Disambiguate before naming:

| Check / job name shape | Channel | Notes |
|---|---|---|
| `security/snyk (<org>)`, `code/snyk (<org>)`, `open-source/snyk (<org>)` | Snyk **GitHub App** (integration PR checks, posted from app.snyk.io) | Primary SAST + OSS signal for projects with the App installed. |
| `image` job in the workflow (running `snyk container test`) | CI workflow job | Scans the freshly-built container image, which the GitHub App cannot see. |
| `snyk-code`, `snyk-open-source` jobs in the workflow (running `snyk code test` / `snyk test --all-projects`) | CI workflow jobs | When present, they duplicate the GitHub App's SAST + OSS signal AND burn private-test quota. If they appear in a failure list, suggest replacing them with the GitHub App. |

When a `security/snyk (<org>)` check fails with state `ERROR` (not
`FAILURE`), it is almost always an **infrastructure** condition (most
commonly the org's monthly private-test quota is exhausted), not a
finding on the PR's diff. Phrase it that way:

> security/snyk (<org>): ERROR state from the Snyk GitHub App's
> integration check — typically quota exhaustion on the org's monthly
> private-test budget. Top up the plan or wait for the monthly reset.

Do **not** describe such a failing check as a "legacy CI job to
remove" — the GitHub App's PR check is the canonical signal, not
legacy. Check the actual workflow file before suggesting removals.

If the maintenance gather's per-language Snyk script emitted a summary
into `notes[]` of the form `Snyk findings via REST API (no quota
consumed): X code, Y OSS. Projects scanned: ...`, include that note
verbatim in the "Notes from the gather step" section of the Render
output — it tells the user the maintenance pipeline did NOT burn quota
this run, which is load-bearing diagnostic when the GitHub App's check
is erroring.

### Render

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

<If findings-<lang>.json has a non-null .sonar_quality_gate (#50),
render the verdict line FIRST — it's the broadest system-health
signal. Map .status to the display word: OK→PASS, ERROR→FAIL,
WARN→WARN, NONE→"not computed". When FAIL or WARN, list each
condition whose .status != "OK" as a bullet:>

Quality Gate (<default branch>): PASS|FAIL|WARN|not computed
  - <metricKey>: actual <actualValue>, threshold <comparator> <errorThreshold>
  ...

<If .sonar_quality_gate is null or absent, omit the line entirely —
the pooled notes already explain why the fetch didn't happen.>

<Render the cross-tool category inventory next (#51) — system-health
at-a-glance before the per-tool detail. Invoke:>

  "<skill-base-dir>/scripts/categorize-findings.zsh" "/tmp/findings-<lang>.json"

<and paste its stdout verbatim. The script omits the block entirely
when all category totals are zero (clean run), so an empty result is
expected and means "skip this section." Counts reflect findings as of
run start; the 🚀 PRs section below shows what was tackled.>

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
    <if you can identify the channel, name it explicitly per the
    Snyk channel naming subsection above; otherwise just report
    the check name>
  - ...

<If human_action_required is non-empty for this language:>
🛑 Halted — human action required:
  - <reason>
    recommendation: <recommendation>

--- end <lang> ---

<If $template_drift array is non-empty:>
🧬 Template drift (rendered config files vs current bootstrap templates):
  <For each finding, one bullet:>
  - <file> — <severity>: <message>
    <if severity == "drifted">
        marker: v<marker_version> sha256:<marker_hash[0:12]>…
        current: v<current_version> sha256:<current_hash[0:12]>…
        action: re-run /development:bootstrap to re-render, or
                patch by hand against the upstream template.
    <if severity == "unknown_provenance">
        action: re-run /development:bootstrap to add a marker so drift
                detection works on future runs.

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

## Phase 10 — track findings as GitHub issues (opt-in)

**Run only when `--track-as-issues` was passed in Phase 0.** Otherwise
skip this phase entirely.

For each language's `findings-<lang>.json`, invoke the tracker:

```bash
"<skill-base-dir>/scripts/track-debt-issues.zsh" \
  --findings "/tmp/findings-<lang>.json" \
  --repo "<repo-path>"
```

The script handles the GitHub side end-to-end: ensures the labels
exist (`maintenance`, `tool:<name>`), finds existing tracking issues
by label combo, and acts based on the current finding count:

| Finding count | Existing issue? | Action |
|---|---|---|
| > 0 | yes | Edit body (title + checklist refresh) |
| > 0 | no  | Create new issue |
| 0   | yes | Close with "All <tool> findings resolved" comment |
| 0   | no  | No-op |

One tracking issue per scanner tool (`ruff`, `semgrep`,
`code_scanning_alerts`, `sonarcloud`). Within each issue's body,
findings are grouped by the tool's natural sub-category: `tool` for
code scanning (CodeQL / Scorecard), `type` for SonarCloud
(BUG / VULNERABILITY / CODE_SMELL / SECURITY_HOTSPOT), severity for
semgrep, none for ruff (flat).

Body is capped at the top 50 findings (per-group cap is
`50 / num_groups` so one giant group can't eat the cap). The
remainder is summarized with a `+ N more — see source tool` footer.

PR-based tools (`dependabot`, `snyk_prs`) are **intentionally
excluded** — their findings are already first-class PRs and
duplicating them as checklist items in an issue creates two states
to keep in sync.

Print the tracker's stdout (one line per tool — `created` / `updated` /
`closed` / `no-op`) into the run summary so the user sees what
changed on the issues side.

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
