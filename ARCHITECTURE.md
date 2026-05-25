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
5. Each plugin receives JSON, does its work, returns JSON.
6. development aggregates results, presents to user, optionally
   commits / opens PR.
```

Language and topic plugins are **pure functions of their JSON input**.
They do not call back into `development` for helpers; they do not run
their own detection; they do not read repo state outside of what the
JSON payload tells them to read. This keeps coupling one-directional
and prevents the "where does this helper live?" problem at install
time.

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
  "findings_by_tool": {
    "ruff":         [/* tool-native finding objects */],
    "snyk_code":    [/* … */],
    "snyk_oss":     [/* … */],
    "semgrep":      [/* … */],
    "sonarcloud":   [/* … */],
    "dependabot":   [/* … */]
  },
  "policy": {
    "coverage_threshold": 90,
    "severity_gate": "high",
    "allow_nosemgrep_with_justification": true
  },
  "worktree": {
    "available": true,
    "base_branch": "main"
  }
}
```

Tool-native finding objects retain their original shape — we don't
normalize. Each language plugin already knows the shape of its own
tools' output; adding a translation layer is duplicate work.

### Response (`development-<lang>` → `development`)

```json
{
  "schema_version": "1",
  "actions_taken": [
    {
      "tool": "ruff",
      "type": "autofix",
      "summary": "applied 26 auto-fixes (UP042, SIM105, …)",
      "files_changed": ["src/aido/types.py", "tests/conftest.py"],
      "worktree_branch": "wt-ruff-fixes-abc123"
    }
  ],
  "actions_requiring_review": [
    {
      "tool": "snyk_oss",
      "finding_id": "SNYK-PYTHON-…",
      "recommendation": "bump <pkg> from 1.2.3 to 1.2.5",
      "rationale": "patches the CVE; one breaking change in <module>",
      "draft_branch": "wt-snyk-bump-pkg-abc123"
    }
  ],
  "unable_to_fix": [
    {
      "tool": "semgrep",
      "finding": "python.flask.security.audit.hardcoded-config.…",
      "reason": "test-fixture annotation requires human judgment"
    }
  ]
}
```

`worktree_branch` and `draft_branch` are populated when the agent ran
with `isolation: "worktree"` and made changes. The orchestrator merges
these branches back to the user's working branch in topological order
(least-conflict first).

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

### Parallel execution

Spawn independent agents in a **single assistant turn** so they run
concurrently:

```
Agent(name="python-ruff-fixer",   isolation="worktree", prompt=…)
Agent(name="python-snyk-fixer",   isolation="worktree", prompt=…)
Agent(name="python-semgrep-fixer", isolation="worktree", prompt=…)
```

All three run in parallel against the same base SHA in separate
worktrees. None can see or interfere with the others' work.

### Merging branches back

The orchestrator collects branch names from each agent's result and
merges them sequentially into the user's working branch. Default
strategy: **least-conflict first** — count `git diff` lines per
branch, merge smallest first to maximize the chance the bigger
branches still apply cleanly. If a merge conflict surfaces despite
that, surface it to the user with `actions_requiring_review`.

### When NOT to use worktrees

Read-only / advisory agents (review, audit, classify) shouldn't run
in worktrees — they make no changes, so isolation buys nothing. Save
the worktree creation time.

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
