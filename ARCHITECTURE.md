# Architecture

How the plugins in this repository fit together. This document is the
source of truth for naming, responsibilities, and the contract between
generic and language-specific code. Touch this file when those
conventions change; otherwise individual PR descriptions are enough.

## Plugin family

```
development              ← generic, language-agnostic (orchestrator)
development-swift        ← language: Swift
development-python       ← language: Python
development-javascript   ← language: JavaScript + TypeScript (combined)
development-…            ← future: go, rust, …
development-container    ← topic: containers / OCI images
development-…            ← future topics: kubernetes, terraform, …
```

All plugins live in this monorepo. End users install whichever subset
they need; nothing forces installation of the full family.

There are **three categories** of plugin:

| Category | Purpose | Dispatched when | Examples |
|---|---|---|---|
| **Generic** | Orchestrator + shared scripts + policy | Always (entry point) | `development` |
| **Language** | Language-specific idioms + tooling | Project uses that language (`pyproject.toml`, `package.json`, `go.mod`, `Package.swift`, …) | `development-python`, `development-javascript`, `development-swift` |
| **Topic** | Cross-language concern in a specialized domain | Project has the topic marker (Dockerfile, k8s manifests, .tf files, …) | `development-container`, future: `development-kubernetes`, `development-terraform` |

Language plugins and topic plugins share the **same dispatch contract**
(same JSON schema, same response shape, same agent + worktree
patterns). The only thing that differs is what triggers them. From
`development`'s point of view, "this project uses Python and has a
Dockerfile" leads to dispatching to both `development-python` and
`development-container`, potentially in parallel.

### Naming

`development` for the generic plugin. `development-<lang>` for language
plugins. `development-<topic>` for topic plugins. No abbreviations
(`development-typescript` not `development-ts`, `development-kubernetes`
not `development-k8s`). Lowercase, hyphens, the most common
user-facing public name (Python → `python` not `py`; containers →
`container` not `oci` or `docker` — the former is too jargony, the
latter is vendor-coupled).

**Special case: JavaScript + TypeScript** ship as one plugin,
`development-javascript`. Most modern JS projects use TS somewhere; the
tooling (ESLint, Prettier, npm, package.json) overlaps so heavily that
two plugins would duplicate ~90% of their content. The plugin handles
both `.js` and `.ts` files; pure-JS projects get the same skill set
minus TypeScript-specific bits.

### Language-first principle (for topic plugins)

When a language has a canonical path for a topic, the **language plugin
gets first crack at it**, and the topic plugin handles only what's
genuinely language-agnostic or what the language plugin couldn't reach.

Concrete example — container images:

| Language | Canonical container path (owned by the language plugin) |
|---|---|
| Java / Kotlin | Spring Boot's `bootBuildImage`, Cloud Native Buildpacks |
| Python | Multi-stage with `distroless/python3` final |
| Go | Single-stage `distroless/static` (Go binaries are static) |
| Node | `distroless/nodejs` final |
| Rust | `distroless/cc` for libc-linked binaries |

`development-container` therefore does NOT own Dockerfile generation
for these idioms — it owns:

- Container-scan findings (Trivy / Snyk CVE response across base
  images regardless of language)
- Multi-arch build patterns + caching (already in `bootstrap`; the
  maintenance side keeps them current)
- SBOM + provenance + cosign signing patterns
- Distroless migration recommendations when a language plugin's
  default still uses a full base
- Multi-language Dockerfiles (Python + Node bundled in one image,
  etc.) — the case no single language plugin claims

The principle generalizes: a future `development-kubernetes` plugin
would defer to language plugins for the application's entrypoints, and
own only the k8s-manifest concerns (resource limits, probes, network
policy, security contexts).

### Why we split

- **Modularity** — A Python-only project doesn't need Swift skills
  loaded into context.
- **Independent versioning** — Bumping Python-tooling pins shouldn't
  trigger a release of the generic plugin.
- **Idiom isolation** — Python idioms drift from Go drift from Swift.
  Keeping them apart prevents "is this rule Python-only?" confusion.
- **Future ecosystem** — Third parties can publish their own
  `development-rust` without forking this repo.

### When NOT to split

A change belongs in `development` (not in any language plugin) when it:

- Operates on repo structure regardless of language (`.gitignore`,
  `dependabot.yml`, `.github/SECURITY.md`).
- Defines policy (Quality Gate thresholds, security severity bars).
- Is cross-cutting tooling (Trivy config, container scanning,
  pre-commit framework setup).
- Is a generic helper (commit message generation, git branch naming).

If you find yourself adding language-specific logic to `development`,
or generic logic to `development-<lang>`, the split is doing its job
by surfacing a category error.

## Responsibilities

### `development` owns

- Generic skills: `bootstrap`, `commit-message`, `git-branch-naming`,
  `cleanup`, future `maintenance` orchestrator.
- Shared scripts that operate on detected state without language
  knowledge: `detect-stack.sh`, `merge-gitignore.sh`,
  `branch-protection.sh`, `preflight.sh`, the `automate-*.sh` family.
- Policy text: Zero Tolerance Quality Gate definitions, security
  thresholds, `.snyk` ignore conventions.
- The **dispatch JSON schema** (see below) — the contract every
  language plugin and topic plugin reads and writes.
- This `ARCHITECTURE.md`.

### `development-<lang>` owns

- Language-specific skills: `fix-ruff-findings`,
  `fix-snyk-findings`, `improve-test-coverage`, etc.
- Language-specific agents (with `model:` declarations chosen per
  task; see "agent model selection").
- Knowledge of language idioms (e.g., for Python: `with` vs
  `contextlib.suppress`, `StrEnum`, adjacent-string-literal SQL).
- Language-specific tool invocations (`ruff check --fix`, `pytest`,
  `go test`, `swift test`).
- The language's canonical container path when one exists
  (see "Language-first principle" above) — Spring Boot's
  `bootBuildImage`, Python's distroless multi-stage, Go's distroless
  static, etc.

### `development-<topic>` owns

- Topic-specific skills for the cross-language part of the topic
  (e.g., `development-container`: `respond-to-cve-findings`,
  `migrate-to-distroless`, `refresh-pinned-digests`).
- Topic-specific agents (same model-selection guidelines).
- Knowledge that applies regardless of which language the project
  uses (e.g., for containers: multi-arch QEMU patterns, cosign keyless
  OIDC, SBOM attestation formats).

### What language plugins and topic plugins **must not** own

- Detection (always handled by `development`'s `detect-stack.sh`).
- Cross-language policy (lives in `development`).
- Cross-plugin helpers (`development` is the canonical source; see
  "shared helpers" below).
- For topic plugins: anything a language plugin can do better
  (see "Language-first principle").

## Dispatch model

`development:maintenance` (and any future orchestrator) follows a
**pure-function** dispatch contract:

```
1. development runs detection + tool gathering.
2. For each detected language L, development packages findings as a
   JSON payload (schema below) and invokes `/development-<L>:maintenance`.
3. For each detected topic T (Dockerfile present, k8s manifests, etc.),
   development packages findings the same way and invokes
   `/development-<T>:maintenance`.
4. Language and topic dispatches can run in parallel — they share no
   state and the JSON payload is identical in shape.
5. Each plugin receives JSON. It runs its coverage pre-flight (spawning
   the coverage-improver in a worktree when needed) and its planner,
   then returns JSON: `plan` + `improver_result` (when present) +
   `missing_tooling`. The plugin does NOT spawn work agents.
6. development reads the plan and walks it **group-by-group**, in
   priority order. For each group: spawn the agent listed on the plan
   entry (in a fresh worktree off the latest base), push, open a PR,
   monitor CI, run the CI-fixer agent up to 3 times on failure, merge,
   sync. The next group only starts after the previous PR has merged,
   so each group's work runs against the latest base — no rebasing.
```

Language and topic plugins are **pure functions of their JSON input**.
They do not call back into `development` for helpers; they do not run
their own detection; they do not read repo state outside of what the
JSON payload tells them to read. This keeps coupling one-directional
and prevents the "where does this helper live?" problem at install
time.

The split also means **work-agent spawning is a generic concern** owned
by `development` — every language plugin's planner outputs an `agent`
field per group, and `development` does the per-group spawning. Adding
a new language plugin doesn't require duplicating PR-cycle logic.

### Missing-plugin handling

`development:maintenance` attempts to invoke `/development-<lang>:…`.
If the slash command is not registered (the language plugin isn't
installed), `development` catches that, prints a clear message:

```
This project uses Python.
Required plugin: development-python  (not installed).
Install with: claude plugin install timo-jakob/timos-claude-code-plugins/development-python
After install, re-run /development:maintenance.
```

Other detected languages still get processed. The user can opt to act
on partial results.

## JSON schema (v1)

The contract between `development` and any `development-<lang>`.

**Stability stance.** Treated as stable now. While we're the only
consumer of these plugins, we may revise v1 in place if a real need
surfaces — change the schema, update all language plugins in the same
PR set, no version bump required. The moment a third party installs
any of these plugins, v1 freezes and any incompatible change becomes
v2 (language plugins declare supported versions in their `SKILL.md`
so `development` picks the highest common). Until then, this section
is the canonical reference and lives here, not in a versioned schema
file.

### Request (`development` → `development-<lang>`)

```json
{
  "schema_version": "1",
  "repo": {
    "path": "/abs/path/to/repo",
    "default_branch": "main",
    "visibility": "public"
  },
  "language": "python",
  "language_meta": {
    "version": "3.13",
    "manifests": ["pyproject.toml", "requirements.txt"]
  },
  "tooling_configured": {
    "ruff":       true,
    "semgrep":    true,
    "snyk_code":  false,
    "snyk_oss":   false,
    "sonarcloud": true,
    "dependabot": true
  },
  "findings_by_tool": {
    "ruff":       [/* tool-native finding objects */],
    "semgrep":    [/* … */],
    "sonarcloud": [/* … */],
    "dependabot": [/* … */]
  },
  "policy": {
    "coverage_threshold": 90,
    "severity_gate": "high",
    "allow_nosemgrep_with_justification": true
  },
  "worktree": {
    "available": true,
    "base_branch": "main"
  },
  "dispatch_filter": {
    "only_tools": ["sonarcloud"]
  }
}
```

Tool-native finding objects retain their original shape — we don't
normalize. Each language plugin already knows the shape of its own
tools' output; adding a translation layer is duplicate work.

**`dispatch_filter` is optional** and added by the orchestrator only
when the user passed `--tool=<name>` (a testing aid). When present,
the language plugin scopes dispatch to the listed tools only — every
other agent is skipped entirely (no work, no missing-tool
recommendation). The gather output remains complete; the filter is
purely a dispatch concern. When `dispatch_filter` is absent the
default "always spawn every agent" rule applies.

**`tooling_configured` covers tools the language plugin cares about,
including ones that aren't set up for this project.** When
`tooling_configured.X == false`, the language plugin still dispatches
its agent for X, and the agent produces a "this tool isn't configured
— here's how to add it" output instead of doing work. This lets a
half-bootstrapped project still get partial maintenance plus a
checklist of what's missing. `findings_by_tool` only contains keys
for configured tools (tools with `configured == false` are absent
from `findings_by_tool`).

### Response (`development-<lang>` → `development`)

```json
{
  "schema_version": "1",
  "plan": [
    {
      "group_id": 1,
      "tool": "sonarcloud",
      "description": "Triage all 16 SonarCloud findings (14 issues + 2 hotspots)",
      "findings": ["<finding-key>", "..."],
      "files": ["src/aido/webui/mutation_routes.py", "..."],
      "rationale": "all sonarcloud findings handled together by python-sonar-triage",
      "agent": "python-sonar-triage",
      "suggested_pr_title": "fix(sonar): triage all 16 SonarCloud findings",
      "priority_score": 0.91
    }
  ],
  "improver_result": {
    "worktree_branch": "<branch returned by python-coverage-improver>",
    "worktree_path":   "<absolute path the runtime returned alongside the branch>",
    "summary": "Raised coverage on 2 modules above the 80% required threshold",
    "modules_improved": [
      { "file": "src/aido/webui/mutation_routes.py", "before": 61.9, "after": 94.0 },
      { "file": "src/aido/cli.py", "before": 69.3, "after": 97.0 }
    ]
  },
  "missing_tooling": [
    {
      "tool": "snyk_code",
      "summary": "Snyk Code (SAST) is not configured for this project.",
      "what_it_provides": "Source-level vulnerability scanning; catches issues the lint tools miss.",
      "how_to_add": "Run /development:bootstrap (it sets up Snyk end-to-end), or sign up at snyk.io and add SNYK_TOKEN to GitHub Actions secrets."
    }
  ]
}
```

`improver_result` is **omitted entirely** when the coverage pre-flight
took Step 2c branch 1 (all modules already at Required) — only present
when branch 2 fired and spawned the improver.

The dispatcher does NOT include `actions_taken`, `actions_requiring_review`,
or `unable_to_fix` in v2. Those arrays are produced by per-group work
agents that the orchestrator spawns in Phase 8, and aggregated there.
The dispatcher's response is now a planning artifact, not a work
record.

`plan` is the output of the language plugin's pre-dispatch planner
(`python-maintenance-planner` for `development-python`). The planner is
a sonnet agent that runs without a worktree, reads the findings + git
history, and returns an ordered list of "groups". **One group per
agent**: each tool's findings stay together as a single group handled
end-to-end by that tool's agent. The two exceptions are `snyk_oss` and
`dependabot`, which split when their findings dispatch to multiple
agents (e.g. a `snyk_oss` major bump goes to `python-major-upgrade`
while patch/minor bumps stay with `python-snyk-triage`; one group per
agent in that case).

Each group carries: source tool, included finding IDs, affected files,
rationale, **the agent the orchestrator will spawn for this group's
PR**, a suggested PR title, and a priority score. Plans are
language-local — each language plugin produces its own.

The orchestrator processes the plan **sequentially in priority order**:

1. If `improver_result` is present, promote it to a PR first
   (Stage 0): push, open, monitor CI, optionally invoke
   `python-ci-fixer` up to 3 times on failure, merge, sync local main.
2. For each entry in `plan`, in order: spawn `plan[i].agent` with
   `isolation="worktree"` off the latest base; the runtime returns a
   worktree branch; push, open a PR, run the same CI cycle, merge,
   sync. Only then move to `plan[i+1]`.

This serialization means each group's work runs against the latest
post-merge state. There is no local merging, no topological ordering of
worktree branches, and no rebasing. The pipeline ends when every
group has either merged or escalated.

`missing_tooling` lists tools the project hasn't configured. The
dispatcher builds it directly from `tooling_configured` (entries with
value `false`) — without spawning per-tool agents in unconfigured mode.
The orchestrator surfaces this to the user as a checklist alongside
the merged PR list.

## Agent model selection

Every agent in a language plugin declares its model in frontmatter:

```yaml
---
name: python-ruff-fixer
description: Apply ruff --fix and report what was changed.
model: haiku
tools: Read, Edit, Bash
---
```

Pick by task character, not by importance:

| Model | When | Examples |
|---|---|---|
| **haiku** | Mechanical, deterministic transforms; no judgment | Apply `ruff check --fix`; bump pinned versions; remove unused imports |
| **sonnet** | Context-aware work; reads surrounding code to decide what fix is appropriate | Triage a Snyk finding (suppress vs fix); choose between refactor patterns; pick a `# nosemgrep` annotation |
| **opus** | High-stakes judgment; security-critical or architectural | Decide if a vulnerability is exploitable; review whether a `# noqa` is justified; senior-eng PR review |

The right model is whichever produces a correct result on the first
try most often. A wrong haiku output costs more than the haiku tokens
saved — agents that frequently come back with "I need more context"
should move up the ladder.

## Worktree pattern for parallel work

The Agent tool natively supports `isolation: "worktree"`. The runtime
creates a temp git worktree on a new branch, the agent works in it,
and the runtime returns either:

- "no changes" → worktree cleaned up
- "changes made" → branch + worktree path returned in the agent's
  result

### Sequential per-group execution (the maintenance pipeline)

The maintenance pipeline runs work agents **sequentially**, one per
planner group, with a full PR cycle between groups. The orchestrator
spawns the agent listed on each plan entry off the latest base:

```
# group 1
Agent(subagent_type="python-sonar-triage",
      isolation="worktree",
      prompt=<group 1 findings + repo_path + base_branch + …>)
# … wait, push, PR, CI, merge, sync …

# group 2 (now off the post-group-1 main)
Agent(subagent_type="python-ruff-fixer",
      isolation="worktree",
      prompt=<group 2 findings + …>)
# … wait, push, PR, CI, merge, sync …
```

Why sequential, not parallel: each group's PR may touch files that
another group also intends to touch, and running them in parallel would
either require risky rebasing or surface false conflicts. Sequencing
makes every group's worktree open against the previous group's merged
state, so the agent always sees the latest code. The cost is wall-clock
time; the gain is reliability + a clean per-group PR for the human to
review later.

The coverage improver (Stage 0) runs the same way — its PR closes
before any work agent's worktree is created.

### From worktrees to PRs

The Agent runtime returns the worktree branch name when the agent made
changes. The orchestrator then drives the per-PR cycle: push, `gh pr
create`, `gh pr checks --watch`, `python-ci-fixer` on failure (up to 3
iterations), `gh pr merge --squash --delete-branch`, sync local main.
There is no local merging anymore — every change reaches `main` only
via a merged PR with passing CI.

### Parallel execution (other use cases)

The original parallel pattern — multiple `Agent(...)` calls in a single
assistant turn — is still valid for *non-maintenance* contexts where
agents are read-only or operate on disjoint files. The maintenance
pipeline specifically chose serialization because PRs are the unit of
record.

### When NOT to use worktrees

Read-only / advisory agents (review, audit, classify) shouldn't run
in worktrees — they make no changes, so isolation buys nothing. Save
the worktree creation time.

## Maximizing autonomy

The plugins deliberately favor autonomous fixes over speed and token
cost. Maintenance runs are intended to be expensive and thorough, not
cheap and shallow. The principle:

> Human decides whether things should change. The plugins take care
> of everything else — whatever it costs in tokens.

### What's sacred (never changed autonomously)

- Public API surface (function signatures, exported symbols, module
  layout, return shapes)
- Behavior contracts the project's tests don't cover
- Database schemas and persisted-data formats
- License-bearing choices (e.g., swapping a dep for one with a
  different license is a strategic call, not a maintenance task)
- Operational concerns (env vars, secrets, deploy config)

### What agents fix autonomously

- Bugs (changing wrong behavior to correct behavior)
- Security findings whose fix preserves functionality
- Style, format, mechanical refactors (ruff `--fix`, ruff format)
- Dep upgrades (patch, minor, AND major — see below)
- Code smells that don't change behavior
- SQL injection refactors (parameterized queries — preserves results)
- Test additions (never modifies production code under test)

### Coverage as the safety floor

Local tests — not CI — are the verification loop. Agents end every
worktree-modifying run by executing the project's test suite in the
worktree; only branches with passing tests are returned for merge.
This means **coverage of the touched code must be high enough that
"tests pass" actually means "behavior preserved."**

Two thresholds, per action class:

| Action class | Required coverage | Floor |
|---|---|---|
| Major-version dep upgrade | 90% (matches the Zero Tolerance Quality Gate) | 70% |
| All other changes (refactors, patch/minor bumps, sonar/semgrep/snyk fixes) | 80% | 60% |

Three branches per planned change, evaluated against the touched
modules' coverage (not whole-project coverage):

| Module coverage | Behavior |
|---|---|
| ≥ Required | Proceed with the change. |
| Floor ≤ coverage < Required | Agent runs `python-coverage-improver` first to bring affected modules up to Required, then makes the change. Adds tests only; never modifies production code under test. |
| < Floor | Refuse. Surface a `missing_tooling`-shaped recommendation pointing at the standalone `/development-python:improve-test-coverage` skill (issue #35). The user invests in coverage deliberately, then re-runs maintenance. |

**Exception**: pure-mechanical agents skip the coverage check:
- `ruff check --fix` without `--unsafe-fixes` (ruff has formally
  verified these are behavior-preserving)
- `ruff format` (whitespace + line-breaks only)

`--unsafe-fixes` and all other refactors respect the policy.

### Reading code: LSP first, grep fallback

Claude Code's `LSP` tool gives agents proper code understanding —
find-definition, find-references, type info, "is this symbol exported
from `__init__.py` / `__all__`?". Use it as the default for any
semantic question:

- "Is this function part of the public API?" → LSP check `__all__` +
  callers
- "Does changing this signature break any caller?" → LSP find-references
- "What's the actual type of this variable?" → LSP hover

Grep / regex is the fallback when LSP can't answer (dynamic
attribute access, string-based symbol lookup, dependencies that
aren't in the workspace).

### Model selection for autonomy at scale

The earlier "haiku / sonnet / opus by task character" table still
holds, with two refinements:

- **Major-version dep upgrades use opus.** Reading release notes,
  identifying breaking changes, applying migrations across the
  codebase, and verifying against tests is exactly opus's strong
  suit. Don't try this on sonnet.
- **Coverage improvement uses opus.** Writing meaningful tests
  (not just line-touching tests that pass false-confidently) requires
  understanding intent. Mechanical test-writing is worse than no test
  because it creates a false safety floor.

### Major-version upgrades, end to end

The hard case. Flow:

1. `python-snyk-triage` (sonnet) identifies the major-version CVE finding;
   dispatcher routes it to `python-major-upgrade` (opus).
2. `python-major-upgrade` reads the official release notes (via WebFetch
   to PyPI / the project's CHANGELOG). Identifies breaking changes.
3. Uses LSP to map breaking-change patterns to actual call sites in
   this repo.
4. Applies migration in the worktree.
5. Bumps the version pin.
6. Runs the project's test suite in the worktree.
7. If tests pass → success.
8. If tests fail:
   - Diagnose the failure (read the test, the prod code, the error).
   - Attempt up to 2 more remediation passes (e.g., a migration pattern
     the agent missed).
   - If still failing after 3 attempts → escalate to
     `actions_requiring_review` with full context (release notes URL,
     migration applied, test failures, agent's diagnosis).

### Residual human-in-the-loop list

After all the above, the cases that genuinely need human decisions:

- **Hardcoded secrets requiring env-var setup** — operational change,
  not a code change.
- **License-incompatible dep replacements** — strategic.
- **DB schema or data-format migrations** — deploy concern.
- **Public API removals** — even if LSP says "no internal callers,"
  external users might exist. The agent can recommend; user decides.
- **Major upgrades where the agent's 3 remediation passes still fail
  tests** — escalation, not punt: the agent attaches release notes,
  diff, test output, and its diagnosis.

Everything else: the agent should figure it out.

### Cost expectations

Higher per-run token usage in exchange for fewer manual triage cycles
is the deliberate trade. A maintenance run on a non-trivial project
can consume tens of thousands of tokens (LSP queries, release-note
reads, test runs, possibly opus on the major-upgrade branch). This
is intentional — the alternative is the user spending an afternoon
clicking through findings.

## Shared helpers — kept canonical in `development`

`development` is the only plugin that ships `detect-stack.sh`,
`merge-gitignore.sh`, etc. Language plugins **do not** invoke these
helpers directly. Why: at install time each plugin lands in its own
directory; cross-plugin paths are fragile and break when users install
plugins individually instead of cloning the monorepo.

Instead, the orchestrator pre-runs every helper it needs and passes
the results as part of the JSON payload. Language plugins receive
"here is the parsed detect-stack output" rather than "here is the path
to detect-stack.sh; go run it." Pure functions, no path coupling.

## Scripting conventions

This project targets **macOS only, Apple Silicon, Homebrew-based**. There
is no Linux support claim in `marketplace.json` and none is planned.

**New shell scripts use zsh, not bash.** Default shebang:

```zsh
#!/usr/bin/env zsh
setopt err_exit nounset pipefail
```

Why zsh:
- macOS ships bash 3.2 (from 2007) as `/bin/bash`; Apple won't update
  it for GPLv3 reasons. `#!/usr/bin/env bash` resolves to whatever's
  first on PATH, so contributors without Homebrew bash silently land
  on 3.2 and lose features like associative arrays.
- zsh has been the macOS default shell since Catalina (2019) and is
  kept current by Apple.
- zsh has cleaner idioms for the patterns this codebase actually uses:
  `typeset -A` for lookups, `${(s/:/)var}` for splits, `${(j:,:)arr}`
  for joins, `$match` for regex captures, sane empty-array expansion
  without the `${arr[@]+"${arr[@]}"}` workaround.

**Existing bash scripts in `development/skills/*/scripts/` are not
being ported.** They were written carefully against bash 3.2, are
tested in production, and a port would carry real regression risk
(`BASH_REMATCH` → `match`, `BASH_SOURCE` → `${(%):-%N}`, `printf -v`
→ `typeset -g`). When modifying one of those files, stay in bash for
consistency. Don't half-port.

The zsh default applies to new files only. If a substantial new feature
inside an existing bash script would benefit clearly from zsh idioms
(e.g., several associative-array lookups), propose extracting it into a
new zsh helper rather than mixing styles in one file.

## Open questions

(none currently — see git history for resolved items: TS+JS combined,
schema v1 stability stance, cross-language findings now handled via
the topic-plugin category)

## Related documents

- `MAINTAINING.md` — quarterly refresh procedure for pinned versions
  across the plugin family.
- `development/skills/bootstrap/SKILL.md` — the most detailed example
  of a generic skill; references the conventions in this document.
- Future: `development-python/SKILL.md` — first example of a language
  plugin following the contract above.
