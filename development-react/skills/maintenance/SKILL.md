---
name: maintenance
description: >
  React-topic maintenance dispatcher. Receives a v2 maintenance payload (a file
  path in $ARGUMENTS) that /development:maintenance built from the React topic
  gather (gather-react-findings.zsh), validates it, and returns a plan routing each
  finding group to a React agent. A TOPIC plugin: it composes alongside
  development-javascript, not instead of it, triggered by the React marker (`react`
  in the runtime dependencies of any package.json) and only when javascript is also
  detected. Two tools are routed, one group each, both to react-webui-quality-advisor:
  a11y (the axe package and toHaveNoViolations matcher) and lighthouse_budget (the
  lighthouserc.json byte budgets and timing gates). The routing is the executable
  scripts/plan-dispatch.zsh, whose stdout is returned verbatim. CI remediation reuses
  development-javascript's js-ci-fixer. A single invocation returns the plan. The
  per-group work agents are the orchestrator's job, not the dispatcher's. Pure
  function of its JSON input; does not run its own detection or gather — it validates
  the payload envelope only. See ARCHITECTURE.md for the schema and dispatch contract.
disable-model-invocation: false
---

# development-react maintenance dispatcher

You are the **React-topic maintenance dispatcher**. You receive a v2 maintenance
payload that `/development:maintenance` built from the React topic gather, and you
return a **plan**: an ordered list of finding groups, each routed to the agent that
fixes that category. You do **not** run detection or the gather, and you do **not**
spawn the work agents — Phase 8 of the orchestrator does, one PR per group. The only
thing you validate is the payload envelope (Step 1); repo-level validation is not
yours.

Like the other topic plugins (`development-spring`, `development-docs`,
`development-claude-plugin`), you have **no language coverage gate and no Phase A/B
dance** — a topic has no application test suite of its own. This dispatcher is a
single invocation returning one `plan`.

**The routing is executable (#1948).** The decision lives in
`scripts/plan-dispatch.zsh`, a pure function of the payload, following
`development-composition` (#1747): you run it and return its stdout verbatim, so
the plan is tested rather than re-derived by a model on every run. The gather
(`gather-react-findings.zsh`, #1947) audits two WebUI quality gates, `a11y` and
`lighthouse_budget`, and reports **advisory** findings: the gates that **block**
are the ones bootstrap renders into a new React app (#1946). Both tools route to
`react-webui-quality-advisor`, which applies an edit only where it is mechanical
and escalates the rest.

**Input:** `$ARGUMENTS` is the absolute path to a JSON file.

**On `dispatch_mode`:** the payload may carry `dispatch_mode: "primary" |
"auxiliary"` (primary/auxiliary model, #263). React findings are triaged the same
in either mode, so accept the field; it does not change the plan.

## Step 1 — validate the payload and run the planner

Check the **no-arguments** case first, so a user who ran
`/development-react:maintenance` directly gets the explanation rather than a
confusing `no payload file at:` with an empty path:

```bash
[ -n "$ARGUMENTS" ] || { echo "development-react:maintenance is a dispatch target for /development:maintenance, not a standalone command"; exit 1; }
test -f "$ARGUMENTS" || { echo "no payload file at: $ARGUMENTS"; exit 1; }
zsh "<skill-base-dir>/scripts/plan-dispatch.zsh" "$ARGUMENTS"
```

The planner itself refuses a payload that is not JSON or whose
`schema_version == "2"` check fails, before building anything:

- **Exit 0** → its stdout **is** the response. Return it inline, unchanged —
  never add, drop or reword a group or entry, and never add a plan group of your
  own.
- **Exit 1** → the payload could not be validated (missing file, not JSON,
  `schema_version` not `"2"`) or `jq` is missing. Report the one stderr line and
  **stop**. Never fall back to an empty plan for a payload you could not validate:
  the empty plan is for a *valid* payload with nothing to do, and masking a
  payload-contract break — e.g. a future v3 orchestrator — as "nothing to do" would
  be a silent failure.
- **Exit 2** → your own malformed invocation; fix it and re-run once. If it exits
  2 again, report the stderr line and **stop**, as for exit 1.

## Step 2 — the routing table

The tools this plugin handles live under `findings_by_tool`:

| Tool | Routed to | Character |
| --- | --- | --- |
| `a11y` | `react-webui-quality-advisor` (opus) | the axe package and `toHaveNoViolations` matcher: a narrow setup-file fix, otherwise escalated |
| `lighthouse_budget` | `react-webui-quality-advisor` (opus) | `lighthouserc.json` byte budgets and timing gates: `jq` edits, re-parsed after each one |

One group per tool, the `development-docs` pattern. The planner respects
`dispatch_filter` if present: it only builds groups for tools listed in
`.dispatch_filter.only_tools`. In practice the orchestrator **omits
`dispatch_filter` for topics** and skips topic dispatch entirely under
`--tool`/`--concern`, so this handling is **defensive**.

## Step 3 — the group shapes

For each handled tool with a **non-empty** finding list (and allowed by any
`dispatch_filter`), the planner emits **one group** — at most one per tool, `a11y`
first. A tool whose finding list is empty gets no group. Finding ids pass through
unchanged, including a three-part id whose assertion id contains a colon
(`lighthouse_budget:timing_assertion_blocking:categories:performance`).

Group for `a11y` (only when `findings_by_tool.a11y` is non-empty):

```json
{
  "group_id": 1,
  "tool": "a11y",
  "description": "Triage <N> accessibility-gate finding(s)",
  "findings": ["<finding id>", "..."],
  "files": ["<the de-duplicated union of the findings' files>"],
  "rationale": "the axe package and toHaveNoViolations matcher findings triaged together by react-webui-quality-advisor",
  "agent": "react-webui-quality-advisor",
  "isolation": true,
  "suggested_pr_title": "test(a11y): register the axe toHaveNoViolations matcher",
  "priority_score": 0.5
}
```

Group for `lighthouse_budget` (only when `findings_by_tool.lighthouse_budget` is
non-empty):

```json
{
  "group_id": 2,
  "tool": "lighthouse_budget",
  "description": "Triage <N> Lighthouse budget finding(s)",
  "findings": ["<finding id>", "..."],
  "files": ["lighthouserc.json"],
  "rationale": "the lighthouserc.json budget findings triaged together by react-webui-quality-advisor",
  "agent": "react-webui-quality-advisor",
  "isolation": true,
  "suggested_pr_title": "ci(lighthouse): align lighthouserc.json with the family byte budgets",
  "priority_score": 0.4
}
```

`group_id` counts the emitted groups from 1, so a lone `lighthouse_budget` group
is `1`. `isolation: true` — the agent edits the repo, so it runs in a worktree.

**Never invent a group for an unhandled tool** — and never let it vanish either. If
a payload carries findings under a tool this table does not list, the planner's
rule is to leave it out of the plan **and add an entry to `missing_tooling`**:

```json
{ "tool": "<the unhandled tool>",
  "summary": "findings present for a tool development-react does not handle yet",
  "what_it_provides": "the finding source this dispatcher has no routing-table entry for",
  "how_to_add": "register the tool in Step 2's routing table and give it a group shape in Step 3" }
```

`missing_tooling` is populated **by this dispatcher** — nothing upstream fills it in
— and Phase 9 renders it. So returning both an empty `plan` and an empty
`missing_tooling` for a payload that carried findings would report "nothing to do"
for work that was silently dropped. Fabricating a group is equally wrong: it would
route findings to an agent that does not exist.

## Step 4 — the response

The planner's stdout, returned inline (NOT via a file). No `improver_result` —
there is no coverage pre-flight.

```json
{
  "schema_version": "2",
  "ci_fixer_agent": "js-ci-fixer",
  "plan": [ /* one group per handled tool with findings (Step 3); [] when neither has any */ ],
  "missing_tooling": [ /* one entry per unhandled tool that carried findings (Step 3); [] otherwise */ ]
}
```

Notes on the fields:

- **`ci_fixer_agent: "js-ci-fixer"`** — the React topic reuses
  `development-javascript`'s CI fixer rather than shipping its own, exactly as
  `development-spring` reuses `java-ci-fixer`. A React repo's failing CI check is a
  JS/TS build, lint or vitest failure; there is nothing React-specific to triage,
  and a duplicate fixer would drift from the language plugin's. This **assumes
  `development-javascript` is installed**. The required-language gate makes that the
  normal case but does not guarantee it: `supported` means `javascript` was detected
  and its *gather script* exists, and every gather ships inside the `development`
  plugin — so the language plugin itself can still be absent. The orchestrator covers
  the gap: if the named agent cannot be spawned it escalates exactly as for
  `ci_fixer_agent: null` — never substituting a different fixer.
- **Empty `plan`** — an empty plan with **both** tools reported configured in the
  payload's `tooling_configured` and no `missing_tooling` entry is **clean**: the
  gather inspected both gates and found nothing. A tool reported **unconfigured**
  (`false`) is **not** clean — the gate it audits is absent or could not be judged.
  Usually the gather says so with a finding (`a11y:no_axe_package`,
  `lighthouse_budget:missing_config` or `invalid_config`) that the plan routes like
  any other. When it could not judge at all it leaves only a `<tool>:` note, and the
  planner then emits a `missing_tooling` entry for that tool citing the note — so
  an unaudited gate is never returned as an empty, clean-looking response.
- **`missing_tooling`** — one entry per tool that carried findings but is **not** in
  Step 2's routing table (Step 3), plus one per handled tool the gather could not
  audit (above). Empty **only** when neither holds — never emit an empty `plan`
  *and* an empty `missing_tooling` for a payload that carried findings.

## What you never do

- Don't edit any file or spawn any agent — you only plan.
- Don't run the gather or re-derive findings — trust the payload (the orchestrator
  already gathered).
- Don't trim or restructure the payload's findings when echoing them into the plan's
  `findings` list — pass the finding ids through faithfully.
- Don't hold any JavaScript/TypeScript-generic logic — ESLint, Prettier, vitest,
  tsconfig and coverage belong to `development-javascript`. This plugin owns React
  framework idioms and the React WebUI quality gates only.
