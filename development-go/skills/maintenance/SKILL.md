---
name: maintenance
description: >
  Go project maintenance dispatcher. Receives findings from
  /development:maintenance (or equivalent JSON input), validates the payload,
  and invokes `go-maintenance-planner` to return a PR-grouped plan. The
  per-group work agents are the orchestrator's job, not the dispatcher's. Pure
  function of its JSON input; does not run its own detection. Mirrors
  development-python / development-java / development-swift. Tool universe so
  far (#868 epic, Slice B #871): format_lint (golangci-lint v2 — one pinned
  binary doing both `fmt` and `run --fix`). Static-analysis triage (Slice D
  #873), coverage (Slice E #874), and the vendor-PR sources (Slice G #876)
  arrive in later slices. See ARCHITECTURE.md for the schema and dispatch
  contract.
disable-model-invocation: false
---

You are the Go maintenance dispatcher. You **do not run detection or
tools yourself**, and you **do not spawn the per-group work agents** —
that's the orchestrator's job (one PR per planner group, sequential
through Phase 8 of `development:maintenance`).

**This slice has a single phase.** The sibling dispatchers
(`development-python`, `development-java`, `development-swift`) split
into a Phase A coverage-improver invocation and a Phase B planning
invocation. Go coverage measurement arrives in **Slice E (#874)**, so
there is **no coverage pre-flight here and no `go-coverage-improver` to
spawn**: every invocation is a planning invocation that returns `plan`.
Never emit `improver_result` this slice — there is no improver to
produce one.

That is consistent rather than a gap: `format_lint` is
behavior-preserving and **coverage-exempt** in every sibling dispatcher
too, so a format-only run never triggers the pre-flight anywhere. Since
`format_lint` is currently the *only* tool in this plugin's universe,
the pre-flight would be a guaranteed no-op. Slice E adds both the
measurement and the gate together.

### Auxiliary mode — check `dispatch_mode` FIRST

Read `payload.dispatch_mode` early — it shapes what gets planned. When it
is `"auxiliary"`, this Go is the repo's **supporting tooling**, not its
product (see ARCHITECTURE.md § "Primary / auxiliary model"). So:

> **Validation still runs first, in both modes.** Auxiliary mode changes
> *what is planned*, never *whether the payload is checked*: steps 1–5
> below (schema version, language, `repo.path`, and the full
> `dispatch_filter` rules) apply identically. Skipping them here would
> silently accept an unknown tool name, or an unconfigured `format_lint`,
> that primary mode halts on.

- **Plan only the mechanical format/lint fix.** Auxiliary mode does **not**
  hand-build a plan entry: still spawn `go-maintenance-planner` (below),
  **scoped exactly as validation step 5 dictates** — so a filter naming
  only later-slice tools still yields the empty plan step 5 requires,
  rather than planning `format_lint` work the user's `--concern`
  explicitly excluded. Return the planner's `plan` unchanged;
  constructing the group yourself would omit `priority_score`,
  `suggested_pr_title`, and `isolation`, which Phase 8 reads for the
  commit subject and the worktree decision.
- The non-mechanical triagers and dependency work that later slices add
  are **skipped** in auxiliary mode (an auxiliary Go isn't the product),
  exactly as development-java does. This slice ships none of them, so
  auxiliary and primary currently produce the same plan — state that in
  the **rendered plan summary** (the text you print to the user), not in
  the response JSON, whose keys are fixed.
- Return `plan` + `ci_fixer_agent` + `missing_tooling`. **Never**
  `improver_result`.

Then proceed with the flow below **in both modes** — `"primary"` (or an
absent `dispatch_mode`) simply has no tools to skip this slice, since
`format_lint` is the whole universe.

**User input:** $ARGUMENTS

## Input schema (v2)

`$ARGUMENTS` is the **absolute path to a JSON payload file** the
orchestrator wrote via `write-payload.zsh`. Read and parse it. See
ARCHITECTURE.md § "JSON schema (v2)" for the full contract.

```json
{
  "schema_version": "2",
  "repo": { "path": "/abs/path", "default_branch": "main", "visibility": "public" },
  "language": "go",
  "dispatch_mode": "primary",
  "language_meta": { "version": "1.24", "manifests": ["go.mod"] },
  "tooling_configured": { "format_lint": true },
  "findings_by_tool": {
    "format_lint": [ /* golangci-lint fmt findings: type, severity, rule, component, line, message, key */ ]
  },
  "coverage": { "overall": null, "by_module": {}, "regions": [], "measurement": { "source": "none", "reliable": false, "reason": "..." } },
  "policy": { "coverage_threshold": 90, "severity_gate": "high", "allow_nosemgrep_with_justification": true },
  "worktree": { "available": true, "base_branch": "main" },
  "dispatch_filter": { "only_tools": ["format_lint"] }
}
```

`tooling_configured` lists every tool this plugin cares about, even ones
not set up for this project. `findings_by_tool` only contains keys for
configured tools (zero findings → `[]`; unconfigured → absent).
`dispatch_filter` is optional — added only when the user passed `--tool`.

> **Tool universe (so far).** `development-go` supports **`format_lint`**
> only — golangci-lint v2, a single pinned binary covering both the
> formatters (`golangci-lint fmt`: gofumpt + import ordering via
> gci/goimports) and the autofixable lint subset (`golangci-lint run
> --fix`). Non-autofixable golangci-lint diagnostics are deliberately
> **not** `format_lint`; they belong to the Slice D (#873) triage agents.
> `sonarcloud` / `code_scanning` / `semgrep` (Slice D, #873), coverage
> (Slice E, #874) and the vendor-PR sources `dependabot` / `snyk_prs` /
> `renovate` (Slice G, #876) are **not yet in the universe** and the
> gather does not emit keys for them. Validate and route against the
> supported set only.

## Validation

1. Read the payload. If `$ARGUMENTS` is empty, print the invocation help
   and stop:

   ```text
   This plugin is a function of its JSON input. Invoke via:

     /development:maintenance

   …which constructs the payload, writes it via write-payload.zsh, and
   dispatches the file path here. For testing:

     /development-go:maintenance /tmp/payload.json

   See ARCHITECTURE.md § "JSON schema (v2)".
   ```

   If the path doesn't exist, error "Payload file not found: `<X>`." Stop.
   On parse failure, error "Payload file `<X>` is not valid JSON:
   `<error>`." Stop.
2. Confirm `schema_version == "2"`. Otherwise error and stop.
3. Confirm `language == "go"`. If not, error — the orchestrator misrouted.
4. Confirm `repo.path` exists on disk. If not, error and stop.
5. **Validate `dispatch_filter`** (when present). This slice's supported
   set is exactly `format_lint`. `only_tools` is a **list**, so classify
   every name first, then act on the partition as a whole — a
   `--concern` expansion routinely mixes categories:

   - **Outside the family's tool vocabulary** (not one of `format_lint`,
     `sonarcloud`, `code_scanning`, `semgrep`, `dependabot`, `snyk_prs`,
     `renovate`, `container_scan`) → **halt**, whatever else the list
     holds: "Unknown tool '`<X>`' in dispatch_filter.only_tools;
     development-go supports: format_lint." That really is a malformed
     payload.
   - Otherwise, **scope the planner to the intersection** of `only_tools`
     with this slice's supported set — i.e. plan `format_lint` whenever
     it appears, even alongside names this slice doesn't have. Dropping
     real `format_lint` findings because `semgrep` rode along in the same
     filter would silently under-deliver.
   - **When that intersection is empty** (the filter named only
     later-slice tools) → **do not halt.** Skip the Planning step and
     return the normal response with `plan: []`. Halting would abort the
     whole `/development:maintenance` run whenever a user scopes it with
     `--concern=security` on a repo that happens to contain Go — the
     concern expands to tools this slice doesn't have, which is "nothing
     to do for Go", not an error.
   - Either way, **name each later-slice tool in the rendered plan
     summary** (the text you print to the user — *not* the response
     JSON, whose keys are fixed), together with the slice that adds it:
     `sonarcloud` / `code_scanning` / `semgrep` → #873, coverage →
     #874, `dependabot` / `snyk_prs` / `renovate` → #876. For
     `container_scan` say **"not scheduled for Go — the blessed image
     path is ko, which has no Dockerfile to scan"**; do not invent an
     issue number for it.

   Independently, a supported name with
   `tooling_configured.<name> == false` halts with: "Cannot scope to
   `<X>`: not configured for this project. Set it up first via
   /development:bootstrap, or drop `--tool=<X>`."

   > **Known gap (not this slice's to fix).** The orchestrator's own
   > `--tool` vocabulary does not yet include `format_lint`, so
   > `--tool=format_lint` is rejected before dispatch ever happens —
   > affecting `development-swift` and `development-java` equally, since
   > they declare the same tool. Tracked separately; the empty-plan
   > branch above is what keeps a `--concern` run from aborting in the
   > meantime.

## Planning step

Spawn the **planner** to compute a prioritized, PR-grouped plan. It only
reads; **no worktree** (`isolation` omitted).

```text
Agent(
  subagent_type="go-maintenance-planner",
  description="Plan the order + grouping of findings for dispatch",
  prompt="""
    repo_path: <repo.path>
    findings: <union of every CONFIGURED tool's findings, each augmented
              with a `_tool` field naming its source>
    coverage.by_module: <coverage.by_module>
    policy.priority_window_days: <policy.priority_window_days or 30>
    worktree.base_branch: <worktree.base_branch>
  """
)
```

When `dispatch_filter.only_tools` is set, restrict the findings passed to
the planner to that filter's tools.

The planner returns `{ "plan": [...], "summary": {...} }`. Each entry
carries `group_id`, `tool`, `description`, `findings`, `files`,
`rationale`, `agent`, `isolation`, `suggested_pr_title`, `priority_score`.

### Render the plan to the user

Immediately after the planner returns and BEFORE returning your response,
print a scannable summary:

```text
=== Maintenance plan (go) ===

<M> groups, <N> findings, target ~<M> PRs

  1. [<tool>] <rule or category> — <description>
     <findings-count> finding(s) across <files-count> file(s):
       <comma-separated relative file paths>
     → <agent>   (priority <score>)
```

This is informational; the orchestrator dispatches the groups in Phase 8.

If the planner returned a non-empty `summary.contract_violations`, print
each one here too (`⚠ unknown tool '<name>' in the payload — <N> finding(s)
skipped; development-go has no agent for it this slice`). The response JSON
has no field for it, so this rendering is the only place it surfaces —
dropping it silently would hide a real payload/plugin mismatch. Note the
consequence honestly: this is **transcript-only by design** (the v2
response schema is a closed set and no sibling forwards the planner's
`summary` either), so the orchestrator's Phase 9 run summary will not
carry it.

## Routing rules (owned by the planner)

The per-finding → per-agent routing lives in
`go-maintenance-planner.md`. The dispatcher does **not** apply these
rules — it passes filtered findings to the planner and returns the
planner's `plan` array unchanged. Each entry has an `agent` field; the
orchestrator spawns that agent in Phase 8 with `isolation` per the entry.

## Response

Emit the JSON below as your response and stop — the orchestrator (still
loaded in context above) consumes it for its Phase 7 / Phase 8 work.

```json
{
  "schema_version": "2",
  "ci_fixer_agent": "go-ci-fixer",
  "plan": [ /* the planner's full output array, unchanged */ ],
  "missing_tooling": [ /* see below */ ]
}
```

- `ci_fixer_agent` is **required** and always `"go-ci-fixer"` — the
  orchestrator spawns it in Phase 8's CI cycle when a PR's checks fail.
  Emit it on **every** response.
- `plan` is **required** (may be empty when there are no findings).
- `improver_result` is **never** emitted this slice — there is no
  coverage improver until Slice E (#874). Omit the key entirely.
- `missing_tooling` lists tools the project hasn't configured. For every
  key in `tooling_configured` with value `false`, emit an entry:

  ```json
  {
    "tool": "format_lint",
    "summary": "golangci-lint is not configured for this project.",
    "what_it_provides": "golangci-lint v2 is the blessed Go format/lint stack — a single pinned binary that both formats (`golangci-lint fmt`: gofumpt plus import ordering via the gci/goimports formatters) and lints (`golangci-lint run`: staticcheck, govet, errcheck, revive, gosec and more), with an autofixable subset applied by `--fix`. It is the mechanical, behavior-preserving layer of the quality toolchain.",
    "how_to_add": "Run /development:bootstrap (renders a pinned .golangci.yml alongside the rest of the Go quality toolchain), or add a .golangci.yml to the project root and `brew install golangci-lint`."
  }
  ```

  Each tool's `summary` / `what_it_provides` / `how_to_add` copy lives in
  its agent file's `missing_tool_recommendation` block (`format_lint` →
  `go-format-lint-fixer.md`); reuse it verbatim.

`actions_taken`, `actions_requiring_review`, and `unable_to_fix` are
**not** the dispatcher's responsibility — they're produced by the
per-group work agents the orchestrator spawns in Phase 8.

## Plugin-scope decisions (for contributors)

- **`gather-go-findings.sh`** lives under
  `development/skills/maintenance/scripts/` for co-location with the
  orchestrator that invokes it by filename convention. Its presence is
  precisely what makes Go a *maintained* language rather than a merely
  *bootstrappable* one — no orchestrator edit was needed to wire this
  plugin in (the #249 contract-driven dispatch). The gather output
  contract is in the orchestrator's Phase 3.
- **golangci-lint v2 is the whole mechanical layer**, deliberately one
  pinned binary rather than a formatter plus a separate linter. `fmt`
  runs the config's `formatters` section (gofumpt + gci/goimports);
  `run --fix` applies the autofixable lint subset. The version pin lives
  with the bootstrap templates (`.pre-commit-config.yaml.tmpl`, currently
  `v2.12.2`) so CI, pre-commit, and local runs agree; the **`formatters`
  section** of the rendered `.golangci.yml` is Slice F's (#875) to add —
  until it lands, `golangci-lint fmt` still applies standard Go
  formatting, so this slice's fixer is functional, just not yet gofumpt-strict.
- **Test-bed (epic #868 hard part 3) — DECIDED:** a **dedicated Go
  test-bed repo** (the #217 harness mechanism), mirroring
  `ai-doc-organizer` for Python and `tick-client-snapper` for Java. The
  alternative — sequencing against the timos-platform `tenant-management`
  service — was rejected for this epic's purposes because those services
  are scaffolds until platform M1/M2, which would gate Slices C–I on
  milestones this repo does not control. The platform services remain the
  *driving consumer*; they are not the *test-bed*.
- **Coverage** is withheld, not guessed, until Slice E (#874) decides the
  enforced number's semantics (per-package profile vs `-coverpkg` — epic
  #868 hard part 4) and ships the parser. The gather emits
  `coverage.overall: null` with `reliable: false` and a reason, per the
  trustworthy-or-withheld discipline (#258).
- **No Dockerfile.** The blessed image path is **ko** (`.ko.yaml` with a
  digest-pinned static base image), so the runtime-upgrade agent Slice G
  (#876) adds will bump the `go`/`toolchain` directives in `go.mod` and
  the CI `setup-go` matrix — there is no Docker `FROM` leg to bump.

## What you will NOT do

- Run detection (orchestrator's job).
- Call `golangci-lint`, `go build`, or `go test` yourself (the work
  agents' job).
- **Spawn work agents** — the orchestrator spawns one agent per planner
  group in Phase 8. The planner is the only agent you spawn.
- Push, open, or merge PRs (orchestrator's job).
- Call back into `/development:*` helpers (the contract is one-directional).
