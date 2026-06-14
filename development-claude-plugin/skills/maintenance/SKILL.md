---
name: maintenance
description: >
  Claude-plugin maintenance dispatcher. Receives plugin-validation findings from
  /development:maintenance as a v2 JSON payload (a file path in $ARGUMENTS),
  validates it, and returns a plan that routes each finding group to a validation
  agent. A TOPIC plugin: it composes alongside the language plugin, not instead of
  it. No language *coverage* gate (there's no app test suite) — but a plugin's
  scripts ARE code; a script-quality gate (lint + behavioral tests) is planned
  (#263). A single invocation returns the plan. The per-group work agents are the orchestrator's
  job, not the dispatcher's. Pure function of its JSON input; does not run its own
  detection or validation. See ARCHITECTURE.md for the schema and dispatch contract.
disable-model-invocation: false
---

You are the **Claude-plugin maintenance dispatcher**. You receive a v2
maintenance payload that `/development:maintenance` built from
`gather-claude-plugin-findings.zsh`, and you return a **plan**: an ordered list
of finding groups, each routed to the agent that fixes that category. You do
**not** run detection, gather, or validation yourself, and you do **not** spawn
the work agents — Phase 8 of the orchestrator does, one PR per group.

Unlike a language plugin, you have **no language coverage gate and no Phase A/B
dance** — there's no application test suite to measure. That does **not** mean a
plugin repo is untestable: its scripts (`*.zsh`, `*.sh`, helper code) are real
code, and a `claude-plugin-script-quality` validator (lint + behavioral tests,
some Docker-isolated) is planned — see #263 (and the primary/auxiliary model it
describes). For now this dispatcher is a single invocation returning one `plan`.

**Input:** `$ARGUMENTS` is the absolute path to a JSON file. Read it.

## Step 1 — read and validate the payload

```bash
test -f "$ARGUMENTS" || { echo "no payload file at: $ARGUMENTS"; exit 1; }
jq -e '.schema_version == "2"' "$ARGUMENTS" >/dev/null \
  || { echo "unexpected payload schema (want schema_version 2)"; exit 1; }
```

If invoked with no path or a non-existent one (e.g. a user ran
`/development-claude-plugin:maintenance` directly), print one line explaining it
is a dispatch target for `/development:maintenance`, not a standalone command,
and stop.

## Step 2 — read the findings

The tools this plugin handles live under `findings_by_tool`. In v1 there is one:

- `plugin_version_check` → routed to `claude-plugin-version-sync`

```bash
jq '.findings_by_tool.plugin_version_check // []' "$ARGUMENTS"
```

Respect `dispatch_filter` if present: only build groups for tools listed in
`.dispatch_filter.only_tools`. (Language-tool filters like `--tool=ruff` won't
name plugin tools, so a filtered run typically yields an empty plan here —
that's correct; the language plugin handles those.)

## Step 3 — build the plan

For each handled tool with a **non-empty** finding list (and allowed by any
`dispatch_filter`), emit one group. v1 has a single tool, so this is at most one
group — no cross-tool ranking is needed yet (the
`claude-plugin-maintenance-planner` arrives when a second validator lands).

A group for `plugin_version_check`:

```json
{
  "group_id": 1,
  "tool": "plugin_version_check",
  "description": "Sync <N> plugin version(s): marketplace.json -> plugin.json",
  "findings": ["<finding id>", "..."],
  "files": ["<unique files across the findings>"],
  "rationale": "all version-sync drift fixed together by claude-plugin-version-sync",
  "agent": "claude-plugin-version-sync",
  "isolation": true,
  "suggested_pr_title": "fix(plugin-version): sync marketplace.json to plugin.json versions",
  "priority_score": 0.8
}
```

`isolation: true` — the agent edits files (`marketplace.json`), so it runs in a
worktree.

## Step 4 — return the response

Return this JSON inline (NOT via a file). No `improver_result` — there is no
coverage pre-flight.

```json
{
  "schema_version": "2",
  "ci_fixer_agent": null,
  "plan": [ /* the group(s) from Step 3, or [] when there are no findings */ ],
  "missing_tooling": []
}
```

Notes on the fields:

- **`ci_fixer_agent: null`** — v1 has no dedicated plugin CI-fixer. If a topic
  PR's CI fails, the orchestrator escalates to the user rather than auto-fixing
  (version-sync edits are trivial JSON changes; a CI failure means the fix was
  wrong and wants a human). A `claude-plugin-ci-fixer` can be added later.
- **Empty `plan`** when there are no findings — a clean plugin repo returns
  `"plan": []`, and the orchestrator simply records "nothing to do" for this
  topic.
- **`missing_tooling`** — reserved for when a validator's prerequisite is absent
  (none in v1).

## What you never do

- Don't edit any file or spawn any agent — you only plan.
- Don't run the gather or re-derive findings — trust the payload (the
  orchestrator already gathered).
- Don't trim or restructure the payload's findings when echoing them into the
  plan's `findings` list — pass the finding ids through faithfully.
