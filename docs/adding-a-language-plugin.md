# Adding a New Language Plugin

How to take the maintenance pipeline from "doesn't know about language `L`" to a
full-maintenance `development-<L>` plugin. This consolidates the pattern proven
by the Java epic (#296) and the Swift epic (#297); `development-python` is the
reference implementation to copy from.

> **TL;DR.** The generic orchestrator has **no language knowledge** — it
> discovers and drives your plugin entirely through contracts. Get the
> **contracts** right (detection output, gather output, the v2 dispatch payload)
> and almost everything else is "copy `development-python` and adapt the tool
> names." Slice the work by capability, one tested PR per slice.

## 1. The architecture you're plugging into

`/development:maintenance` is a **generic orchestrator**. It detects the stack,
gathers per-tool findings, builds a JSON payload, dispatches to the matching
language plugin, and drives the per-stage PR cycle (push → CI → merge → sync).
It hardcodes **no** language: it finds your plugin by file-naming convention and
talks to it through the v2 schema. See `ARCHITECTURE.md` for the orchestrator
internals.

Two tiers exist. **Review-only** (the original `development-swift`: a `review`
skill + reviewer agents) and **full-maintenance** (`development-python`,
`development-java`, post-#297 `development-swift`). New languages target
**full-maintenance**.

A language can also be in a **partial** state: a language with bootstrap
templates but **no gather script** is *bootstrappable but not maintained* (today
`typescript` — `detect-stack` finds it and bootstrap can scaffold it, but no
`development-<L>` plugin processes it yet). That's a legitimate stopping point;
you don't have to build everything at once. `go` crossed that line in #871:
`gather-go-findings.sh` landed, so it is now maintained — at the **core-loop**
tier (`format_lint` only), with triage, coverage, and the rest arriving in the
remaining #868 slices.

## 2. Anatomy — the components you create or extend

| Component | Lives in | Purpose |
| --- | --- | --- |
| **Detection** | `development/skills/bootstrap/scripts/detect-stack.sh` | Detect `L`; emit `language_meta.<L>` |
| **Gather script** | `development/skills/maintenance/scripts/gather-<L>-findings.sh` | Run/collect each tool's findings; emit the findings payload |
| **State pre-flight** *(optional)* | `development/skills/maintenance/scripts/verify-<L>-state.sh` | Surface/repair stale local toolchain state before gather |
| **Dispatcher skill** | `development-<L>/skills/maintenance/SKILL.md` | Validate the payload, run the coverage pre-flight, run the planner, return the plan |
| **Approve skill** | `development-<L>/skills/approve/SKILL.md` | Run the Approver locally (verdict to stdout) |
| **Agent set** | `development-<L>/agents/*.md` | The work agents (see §4) |
| **Bootstrap templates** | `development/skills/bootstrap/templates/languages/<L>/` | CI workflows, quality-gate config, pre-commit |
| **Registration** | `development-<L>/.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` | Make the plugin installable |

The first three live in the **`development`** plugin (shared orchestrator
assets, discovered by filename); the rest are the **`development-<L>`** plugin.

## 3. The contracts (the boundaries — get these right first)

Everything the orchestrator does is mediated by three contracts. Match them
exactly and the orchestrator drives your plugin unchanged.

### 3a. Detection output (`detect-stack.sh`)

Add a `detect_lang` line and a nested `language_meta.<L>` block. The orchestrator
reads `languages[]` and copies `language_meta.<L>.version` into the dispatch
payload. Mirror the existing `language_meta.java` / `language_meta.swift` shape;
**always record `version_source` (`parsed` | `default`)** so a guessed version is
never mistaken for a real pin (#258).

### 3b. Gather output (`gather-<L>-findings.sh`)

The script takes `<repo_path>` and prints one JSON object:

```json
{
  "tooling_configured": { "format_lint": true, "sonarcloud": false, "...": false },
  "findings_by_tool":   { "format_lint": [ ... ], "sonarcloud": [ ... ] },
  "coverage":           { "overall": 0, "by_module": {}, "regions": [], "measurement": { "reliable": true, "reason": "..." } },
  "notes":              [ "..." ]
}
```

- `tooling_configured` lists **every** tool the plugin cares about (even
  unconfigured ones — value `false`). `findings_by_tool` carries keys only for
  configured tools (zero findings → `[]`).
- **Reuse the language-agnostic helpers** rather than re-implementing them:
  `gather-sonarcloud.zsh` (Sonar findings + Quality Gate), `gather-github-security.zsh`
  (CodeQL + Scorecard alerts), `gather-container-scan.zsh` (Snyk container CVEs).
  Java and Swift both call these unchanged — only the CodeQL/Sonar *rule IDs*
  differ per language.
- **Coverage is trustworthy-or-withheld (#258).** Emit `null` with
  `reliable: false` and a `reason` when you can't trust the figure; never
  fabricate. Coverage uses the **region-scoped** model — see the per-language
  playbook in `docs/superpowers/specs/2026-06-29-coverage-safety-signal-design.md`.
- **Failure modes are graceful:** a configured tool that can't run (missing
  binary, no auth) is `configured-but-no-findings` with a `notes` entry, not a
  hard error.
- **Keep it hermetic-testable:** gate any heavy toolchain invocation behind a
  cheap precondition (config present / tests present) so the bats fixtures never
  trigger a real build. See §6.

### 3c. The v2 dispatch payload + response

The orchestrator writes the payload to a temp file and calls
`Skill(skill="development-<L>:maintenance", args="<path>")`. Your dispatcher is a
**pure function of that JSON** — it does not run detection or tools itself. It
returns:

```json
{
  "schema_version": "2",
  "ci_fixer_agent": "<L>-ci-fixer",
  "plan": [ /* planner groups */ ],
  "improver_result": { /* present only after the coverage pre-flight spawned the improver */ },
  "missing_tooling": [ /* one entry per tooling_configured == false */ ]
}
```

The three **de-leak fields** are how language specifics reach the generic
orchestrator without it growing a `case` statement (see ARCHITECTURE.md §
"JSON schema (v2)"):

- **`ci_fixer_agent`** (required, every response) — names your CI-fix agent; the
  orchestrator spawns it when a PR's checks fail.
- **`plan[].isolation`** (boolean) — `true` for agents that edit local files (run
  in a worktree); `false` for agents that act on GitHub PRs via `gh`. The
  orchestrator reads this, never matches on agent names.
- **`plan[].pre_dispatch_hook`** (optional) — for work that needs an environment
  check before spawn (e.g. a runtime upgrade verifying the target toolchain is
  installed). The orchestrator runs the hook generically.

## 4. The agent set (mirror the reference)

Copy `development-python`'s agents and adapt each to `L`'s tools. The reference
set (map `python-*` → `<L>-*`):

| Reference agent | Role | `isolation` |
| --- | --- | --- |
| `python-ruff-fixer` | mechanical format/lint autofix | `true` |
| `python-ci-fixer` | the `ci_fixer_agent` — fix a failing CI run on a PR | `true` (off the PR branch) |
| `python-maintenance-planner` | rank + group findings into one PR-group per tool | n/a (read-only) |
| `python-sonar-triage` | SonarCloud/SonarQube findings | `true` |
| `python-code-scanning-triage` | CodeQL + Scorecard alerts | `true` |
| `python-semgrep-triage` | semgrep findings | `true` |
| `python-coverage-improver` | raise coverage on affected functions (Fable) | `true` |
| `python-dependabot-snyk-triage` | vendor-PR triage (Dependabot/Snyk/Renovate) | `false` |
| `python-major-upgrade` | autonomous major-version dependency upgrade | `true` |
| `python-runtime-upgrade` | interpreter/runtime version bump (Docker base image) | `true` |
| `python-approver` | synthesis-layer PR reviewer | n/a (CI) |
| `python-container-cve-triage` | Snyk container/base-image CVEs | `true` |

You do **not** need all of them at once — ship the **core loop** first
(format-lint-fixer + ci-fixer + planner + the dispatcher) and add triagers,
coverage, vendor-PRs, runtime upgrades, and the approver in later slices.

**Validate tool support honestly.** Not every tool supports every language well
(the Swift slice *deferred* semgrep — its Swift rule registry is empty). When a
tool's support is thin, defer the agent and mark `tooling_configured.<tool>:
false` with a documented reason; don't ship a triager that finds nothing.

**Models:** mechanical fixers → `haiku`; triagers / ci-fixer / planner →
`opus`; coverage-improver and the approver → `fable` (high-judgment work).

## 5. How to slice the work (epic-driven)

A full language plugin is too big for one PR. Both worked epics sliced it the
same way — **each slice a full, independently-testable vertical, one PR, merged
before the next** (in human-merge repos, one slice per invocation).

> **The letters below are the shape, not a fixed numbering.** Each epic assigns
> its own — the Go epic ([#868](https://github.com/timo-jakob/timos-claude-code-plugins/issues/868))
> splits review out as its own slice and merges vendor PRs with runtime
> upgrades, so its letters run A detection, B core loop, C review panel,
> D triage, E coverage, F bootstrap, G vendor+runtime, H approver, I advisors.
> Read the epic for the authoritative mapping rather than inferring issue
> numbers from this list.

1. **A — Detection.** `detect-stack.sh` classifies `L` + emits `language_meta.<L>`.
   Smallest; unblocks everything.
2. **B — Core loop.** `gather-<L>-findings.sh` (format-lint only) + the dispatcher
   skill + format-lint-fixer + ci-fixer + planner → a runnable lint/format → CI-fix
   → PR loop, contract-driven, **no orchestrator edits**.
3. **C — Static-analysis triage.** sonar / code-scanning / semgrep (each gated on
   validated support depth).
4. **D — Coverage.** The region-scoped parser + gather coverage + the dispatcher
   pre-flight + the function-scoped improver (follow the region-coverage
   per-language playbook).
5. **E — Bootstrap.** CI templates, quality gates, pre-commit for a fresh repo.
6. **F — Vendor PRs + dependency majors.**
7. **G — Runtime / language-version upgrades.**
8. **H — Approver + (if valuable) a review skill.**

Order A → B first (B depends on A); C/D/E can follow in any order; F/G/H last.
Use `/development:resolve-issue <epic#>` to drive it: file the epic + a child
issue per slice, and resolve them one at a time. Validate each slice on a **real
`L` project** (the maintainer keeps one per language as the test-bed, à la
`ai-doc-organizer` for Python, `tick-client-snapper` for Java).

## 6. Testing

- **Hermetic bats** for the gather script + any parsers. **Capture real tool
  output as fixtures** — run the real tool on a tiny throwaway project, commit
  the trimmed output, and write the parser/tests against it. Gate live
  toolchain invocation behind a cheap precondition so CI (no toolchain) hits the
  withheld/not-configured paths. See `tests/gather-java.bats` /
  `tests/gather-swift.bats`.
- **Assert through the shared helpers.** Start each `.bats` file with
  `load assertions` and use the helpers rostered in
  [`tests/README.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/README.md)
  (the contributor-facing source of truth for that list); plain `[ ... ]` stays
  correct and is never flagged **as a command of its own** — joined to another
  command it obeys the one-assertion-per-line rule below like anything else.
  A bare `[[ ... ]]` in an `@test` body or a bats
  `setup`/`teardown` hook (including the `_file` variants) is **inert** under
  the bash 3.2 macOS ships — errexit is not applied to it at all, so a false one
  on a non-final line is silently ignored and the test passes while proving
  nothing — while bash >= 4 catches it, so the same test means different things
  on the two CI legs. Inside a test body or hook, position is no exemption and
  neither is an `|| return` tail: a final-line one is rejected too, since it goes
  inert the moment a line is appended below it, and an `|| return` one — though
  genuinely not inert — is rejected there anyway, so the fix stays uniform.
  `tests/no-inert-bracket-assertions.bats` rejects the shapes it can detect
  (#1011), so what you follow is the convention, not the guard. Two carve-outs.
  The first is about code outside those blocks: a `[[ ]]` inside a **named
  helper function** is fine when it is the statement whose status the helper
  returns — typically its last command, or one with an explicit `|| return` —
  because the assertion's status is then the helper's own and the call site is a
  simple command errexit catches; one whose status the helper discards is just
  as inert. The second holds anywhere, inside a test body or hook included: a
  `[[ ]]` used as an **`if`/`elif`/`while`/`until` condition** is control flow,
  not an assertion — don't convert it, since rewriting it as a helper call in a
  file without `load assertions` yields 127 and a silently false branch.
- **Keep one assertion per line** (#1067). A helper call is only caught by
  errexit as a command of its own: `contains "$output" "a" && contains "$output"
  "b"` swallows the first call, because the AND-list exemption applies to a
  function call exactly as it does to `[[ ]]` — and this one holds on *every*
  bash, so neither CI leg catches it. The same guard's `and-tail` rule rejects
  the swallowed left operand of `&&`. The condition carve-out above carries
  over; the named-function one does not, since wrapping the join in a function
  only hides it. The rule is about joining, not about helpers, so `[ -n "$a" ]
  && [ -f "$b" ]` is inert too even though no rule flags it — as is
  `contains … || true`, since an `||` tail is an assertion only when its last
  member can itself fail.
- **End-to-end:** `/development-claude-plugin:test` drives a headless session with
  the local plugins against an isolated clone of a real repo — use it to verify a
  slice actually does what you intend.
- The dispatcher/agents are **prompts**, not unit-testable; their independent
  verification is the e2e harness + the per-PR review (and the Approver in app
  repos).

## 7. Registration, conventions, and gotchas

- **Register the plugin:** add `development-<L>/.claude-plugin/plugin.json` and a
  matching entry in the root `.claude-plugin/marketplace.json`. The two versions
  must stay in lockstep (the `check-marketplace-sync.bats` gate). **Every content
  PR bumps both** or installs never see the change.
- **Discovery is by gather-script presence.** The orchestrator supports `L`
  exactly when `gather-<L>-findings.sh` exists and is executable — that's the
  switch that turns a bootstrappable language into a maintained one.
- **Scripting conventions:** new shell scripts are **zsh** (leave existing bash
  alone); **120-col** line length for every formatter/linter; pre-commit
  (shellcheck/shfmt/zsh-syntax/markdownlint) must pass — never `--no-verify`.
- **Primary / auxiliary:** a repo's `.maintenance.yml` declares its primary
  stack; the dispatcher runs full gates for the primary language and
  mechanical-only for auxiliary ones. Honour `payload.dispatch_mode`.
- **PRs are bot-authored** via `/development:open-pr` so they're Approver-/
  human-approvable; PR bodies follow the Type / Summary / Risk / Test plan
  template.

## Worked references

- **`development-python`** — the reference full-maintenance plugin; copy it.
- **Java epic #296** and **Swift epic #297** — the two worked end-to-end
  additions (detection → core → triage → coverage → bootstrap → vendor → runtime
  → approver), each sliced as in §5.
- **Region-coverage per-language playbook** —
  `docs/superpowers/specs/2026-06-29-coverage-safety-signal-design.md` (the
  coverage slice in depth).
- **`ARCHITECTURE.md`** — the orchestrator internals, the v2 schema, the
  primary/auxiliary model, and the de-leak contract.
