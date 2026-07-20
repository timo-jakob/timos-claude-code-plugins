---
name: maintenance
description: >
  JavaScript/TypeScript project maintenance dispatcher. Receives findings from
  /development:maintenance (or equivalent JSON input), validates the payload,
  and returns a PR-grouped plan for the format_lint group. The per-group work
  agents are the orchestrator's job, not the dispatcher's. Pure function of its
  JSON input; does not run its own detection. Mirrors development-go /
  development-python. Tool universe so far (#683 slice 1, #729): format_lint
  (ESLint --fix + Prettier --write). The maintenance-planner, sonarcloud,
  code_scanning, and coverage arrive in slice 4; the contract-consumer
  machinery is slice 2 (#727). See ARCHITECTURE.md for the schema and dispatch
  contract.
disable-model-invocation: false
---

You are the JavaScript/TypeScript maintenance dispatcher. You **do not run
detection or tools yourself**, and you **do not spawn the per-group work
agents** — that's the orchestrator's job (one PR per group, sequential through
Phase 8 of `development:maintenance`).

**This slice has a single phase and a single tool.** Its whole universe is
`format_lint` (ESLint `--fix` + Prettier `--write`), which is behavior-preserving
and **coverage-exempt**, so there is **no coverage pre-flight here and no
coverage-improver to spawn** — every invocation is a planning invocation that
returns `plan`. Never emit `improver_result` this slice — there is no improver.

**The maintenance-planner arrives in a later slice.** The sibling dispatchers
spawn a `<lang>-maintenance-planner` to compute the grouping. This foundation
slice has a **single** tool, so the dispatcher **hand-builds** the one
`format_lint` group directly (the planner and the richer static-analysis
universe land in slice 4). That is a deliberate scoping choice, not a gap.

**Auxiliary mode — check `dispatch_mode`.** When `payload.dispatch_mode` is
`"auxiliary"`, this JavaScript is the repo's **supporting tooling**, not its
product (see ARCHITECTURE.md § "Primary / auxiliary model"). Validation still
runs first in **both** modes — steps 1–5 below (schema version, language,
`repo.path`, the full `dispatch_filter` rules) apply identically; auxiliary mode
changes only *what is planned*, never *whether the payload is checked*. This
slice's only tool, `format_lint`, is behavior-preserving mechanical work that
runs in both modes, and the non-mechanical triagers a later slice adds (which an
auxiliary mode would skip) do not exist yet — so **auxiliary and primary
currently produce the same single-group plan. State that in the rendered plan
summary** (the text you print), never in the response JSON, whose keys are
fixed. Proceed with the flow below in both modes.

**User input:** $ARGUMENTS

## Input schema (v2)

`$ARGUMENTS` is the **absolute path to a JSON payload file** the orchestrator
wrote via `write-payload.zsh`. Read and parse it. See ARCHITECTURE.md § "JSON
schema (v2)" for the full contract.

```json
{
  "schema_version": "2",
  "repo": { "path": "/abs/path", "default_branch": "main", "visibility": "public" },
  "language": "javascript",
  "dispatch_mode": "primary",
  "language_meta": { "version": "24", "manifests": ["package.json"] },
  "tooling_configured": { "format_lint": true },
  "findings_by_tool": {
    "format_lint": [ /* ESLint/Prettier findings: type, severity, rule, component, line, message, key */ ]
  },
  "coverage": { "overall": null, "by_module": {}, "regions": [], "measurement": { "source": "none", "reliable": false, "reason": "..." } },
  "policy": { "coverage_threshold": 90, "severity_gate": "high" },
  "worktree": { "available": true, "base_branch": "main" },
  "dispatch_filter": { "only_tools": ["format_lint"] }
}
```

`tooling_configured` lists every tool this plugin cares about, even ones not set
up for this project. `findings_by_tool` only contains keys for configured tools
(zero findings → `[]`; unconfigured → absent). `dispatch_filter` is optional —
added only when the user passed `--tool`.

> **Tool universe (so far).** `development-javascript` supports **`format_lint`**
> only — ESLint's autofixable subset (`eslint --fix`) plus Prettier
> (`prettier --write`). Non-autofixable ESLint diagnostics are deliberately
> **not** `format_lint`; they belong to a later triage slice. `sonarcloud` /
> `code_scanning` / coverage arrive in **slice 4**, and the contract-consumer
> machinery (orval client + MSW) is **slice 2 (#727)**. The gather does not emit
> keys for tools not yet in the universe. Validate and route against the
> supported set only.

## Validation

1. Read the payload. If `$ARGUMENTS` is empty, print the invocation help and
   stop:

   ```text
   This plugin is a function of its JSON input. Invoke via:

     /development:maintenance

   …which constructs the payload, writes it via write-payload.zsh, and
   dispatches the file path here. For testing:

     /development-javascript:maintenance /tmp/payload.json

   See ARCHITECTURE.md § "JSON schema (v2)".
   ```

   If the path doesn't exist, error "Payload file not found: `<X>`." Stop. On
   parse failure, error "Payload file `<X>` is not valid JSON: `<error>`." Stop.
2. Confirm `schema_version == "2"`. Otherwise error and stop.
3. Confirm `language == "javascript"`. If not, error — the orchestrator
   misrouted.
4. Confirm `repo.path` exists on disk. If not, error and stop.
5. **Validate `dispatch_filter`** (when present). This slice's supported set is
   exactly `format_lint`. `only_tools` is a **list**, so classify every name
   first, then act on the partition as a whole:

   - **Outside the family's tool vocabulary** (not one of `format_lint`,
     `sonarcloud`, `code_scanning`, `semgrep`, `dependabot`, `snyk_prs`,
     `renovate`, `container_scan`) → **halt**, whatever else the list holds:
     "Unknown tool '`<X>`' in dispatch_filter.only_tools;
     development-javascript supports: format_lint."
   - Otherwise, **scope to the intersection** of `only_tools` with this slice's
     supported set — i.e. plan `format_lint` whenever it appears, even alongside
     names this slice doesn't have. Dropping real `format_lint` findings because
     a later-slice tool rode along would silently under-deliver.
   - **When that intersection is empty** (the filter named only later-slice
     tools) → **do not halt.** Skip the Planning step and return the normal
     response with `plan: []`. Halting would abort the whole
     `/development:maintenance` run whenever a user scopes it with
     `--concern=security` on a repo that happens to contain JS.
   - Either way, **name each later-slice tool in the rendered plan summary**
     (the text you print, *not* the response JSON), with the attribution you are
     given below — **do not invent an issue or slice number** for any tool not
     listed here:
     - `sonarcloud` / `code_scanning` / coverage → slice 4;
     - the orval contract-consumer → slice 2 (#727);
     - `semgrep`, `dependabot`, `snyk_prs`, `renovate`, `container_scan` → in
       the family's vocabulary but **not yet scheduled for
       development-javascript** — say exactly that, without a slice/issue number.

   Independently, `format_lint` with `tooling_configured.format_lint == false`
   halts with: "Cannot scope to format_lint: not configured for this project.
   Set it up first via /development:bootstrap, or drop `--tool=format_lint`."

## Planning step (hand-built — single tool this slice)

Build the plan directly from the payload; **no planner agent this slice**.

- If `format_lint` is **not** configured (`tooling_configured.format_lint ==
  false`), or has **no** findings (`findings_by_tool.format_lint` absent or
  `[]`), or the `dispatch_filter` intersection is empty → the plan is `[]`.
- Otherwise emit **one** group:

  ```json
  {
    "group_id": "format_lint",
    "tool": "format_lint",
    "description": "Apply Prettier + ESLint autofixes",
    "findings": [ /* findings_by_tool.format_lint verbatim */ ],
    "files": [ /* the distinct `component` paths across those findings */ ],
    "rationale": "Mechanical, behavior-preserving format/lint autofixes — one PR.",
    "agent": "js-format-lint-fixer",
    "isolation": "worktree",
    "suggested_pr_title": "style(format): apply prettier --write + eslint --fix",
    "priority_score": 10
  }
  ```

### Render the plan to the user

Before returning your response, print a scannable summary:

```text
=== Maintenance plan (javascript) ===

<M> group(s), <N> finding(s), target ~<M> PR(s)

  1. [format_lint] Apply Prettier + ESLint autofixes
     <N> finding(s) across <K> file(s):
       <comma-separated relative file paths>
     → js-format-lint-fixer   (priority 10)
```

This is informational; the orchestrator dispatches the groups in Phase 8.

## Response

Emit the JSON below as your response and stop — the orchestrator (still loaded
in context above) consumes it for its Phase 7 / Phase 8 work.

```json
{
  "schema_version": "2",
  "ci_fixer_agent": "js-ci-fixer",
  "plan": [ /* the hand-built group array (may be empty) */ ],
  "missing_tooling": [ /* see below */ ]
}
```

- `ci_fixer_agent` is **required** and always `"js-ci-fixer"` — the orchestrator
  spawns it in Phase 8's CI cycle when a PR's checks fail. Emit it on **every**
  response.
- `plan` is **required** (may be empty when there are no findings).
- `improver_result` is **never** emitted this slice — there is no coverage
  improver. Omit the key entirely.
- `missing_tooling` lists tools the project hasn't configured. For `format_lint`
  with value `false` in `tooling_configured`, emit:

  ```json
  {
    "tool": "format_lint",
    "summary": "ESLint and Prettier are not configured for this project.",
    "what_it_provides": "The blessed JavaScript/TypeScript mechanical layer: Prettier (`prettier --write`, line width 120) formats, and ESLint flat config (`eslint --fix`) applies the autofixable lint subset. Behavior-preserving fixes that keep style and trivial lint noise out of review.",
    "how_to_add": "Run /development:bootstrap (renders a flat eslint.config.js, a Prettier config at width 120, and the package scripts alongside the rest of the JS toolchain), or add eslint.config.js + a prettier config and `npm i -D eslint prettier`."
  }
  ```

  The copy lives in `js-format-lint-fixer.md`'s `missing_tool_recommendation`
  block; reuse it verbatim.

`actions_taken`, `actions_requiring_review`, and `unable_to_fix` are **not** the
dispatcher's responsibility — they're produced by the per-group work agents the
orchestrator spawns in Phase 8.

## Plugin-scope decisions (for contributors)

- **`gather-javascript-findings.sh`** lives under
  `development/skills/maintenance/scripts/` for co-location with the orchestrator
  that invokes it by filename convention. Its presence is precisely what makes
  JavaScript a *maintained* language rather than a merely *bootstrappable* one —
  no orchestrator edit was needed to wire this plugin in (the #249
  contract-driven dispatch).
- **npm + Node 24 LTS, ESLint flat config, Prettier @120, vitest + v8** is the
  blessed toolchain, rendered by `/development:bootstrap` from
  `templates/languages/javascript/`. One default per decision.
- **Coverage** is withheld, not guessed, until a later slice ships the vitest/v8
  parser — the gather emits `coverage.overall: null` with `reliable: false` and a
  reason, per the trustworthy-or-withheld discipline (#258).

## What you will NOT do

- Run detection (orchestrator's job).
- Call `eslint`, `prettier`, or `npm test` yourself (the work agents' job).
- **Spawn work agents** — the orchestrator spawns one agent per group in Phase 8.
- Push, open, or merge PRs (orchestrator's job).
- Call back into `/development:*` helpers (the contract is one-directional).
