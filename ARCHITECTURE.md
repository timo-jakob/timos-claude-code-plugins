# Architecture

How the plugins in this repository fit together. This document is the
source of truth for naming, responsibilities, and the contract between
generic and language-specific code. Touch this file when those
conventions change; otherwise individual PR descriptions are enough.

## Plugin family

```text
development              ← generic, language-agnostic (orchestrator)
development-swift        ← language: Swift
development-python       ← language: Python
development-java         ← language: Java (Gradle); composes with development-spring
development-javascript   ← language: JavaScript + TypeScript (combined)
development-…            ← future: go, rust, …
development-container    ← topic: containers / OCI images
development-claude-plugin ← topic: projects that ARE Claude Code plugins
development-spring       ← topic: Spring framework (composes with development-java)
development-…            ← future topics: kubernetes, terraform, …
```

All plugins live in this monorepo. End users install whichever subset
they need; nothing forces installation of the full family.

There are **three categories** of plugin:

| Category | Purpose | Dispatched when | Examples |
| --- | --- | --- | --- |
| **Generic** | Orchestrator + shared scripts + policy | Always (entry point) | `development` |
| **Language** | Language-specific idioms + tooling | Project uses that language (`pyproject.toml`, `package.json`, `go.mod`, `Package.swift`, `build.gradle`, …) | `development-python`, `development-java`, `development-javascript`, `development-swift` |
| **Topic** | Cross-language concern in a specialized domain | Project has the topic marker (Dockerfile, k8s manifests, .tf files, `.claude-plugin/plugin.json`, an `org.springframework.boot` plugin, …) | `development-container`, `development-claude-plugin`, `development-spring`, future: `development-kubernetes`, `development-terraform` |

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
| --- | --- |
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

### Primary / auxiliary model

Every repo has exactly one **primary type** — its reason to exist — and zero or
more **auxiliary** languages/topics (supporting material). Maintenance treats
them differently:

- **Primary** gets the full, opinionated pipeline with its app-grade gates
  (coverage floor, dependency upgrades, …).
- **Auxiliary** gets a *fit-for-purpose* treatment: mechanical / lint-level
  checks only — **not** primary-grade gates. Running a Python app's 90%-coverage
  pipeline over a plugin repo's three helper scripts is a category error; this
  prevents it.

This **generalizes the language-first principle above**: there a *language* gets
first crack at a *topic*; here the **primary** (which may itself be a topic, e.g.
`claude-plugin`) gets the full treatment and the rest is auxiliary. Language-first
is the special case where the primary is a language and the auxiliary is a topic.

**Declared, not inferred.** The primary is set by `/development:bootstrap` in a
repo-root `.maintenance.yml`:

```yaml
primary: claude-plugin   # a language (python) or a topic (claude-plugin)
```

No file ⇒ no distinction: every detected stack is treated as primary (the
pre-model behavior). The model is opt-in and backward-compatible.

**Mechanism.** The orchestrator reads `.maintenance.yml` and tags each dispatch
via the payload's `dispatch_mode` (`"primary"` | `"auxiliary"`). The language /
topic plugin honors it — *auxiliary* means **delegate with a policy override**
(run the plugin's mechanical fixers, skip its app-grade gates), **not
re-implement** the auxiliary's linting inside the primary. E.g. `development-python`
in auxiliary mode runs `python-ruff-fixer` only — no coverage pre-flight, no
dependency upgrades.

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

## Polyrepo, contracts, and the cross-repo big picture

The plugin family is *about* a single repo at a time — bootstrap runs in
one repo, maintenance runs in one repo. But the **projects those plugins
serve are not single-repo systems.** The default project shape we design
for is:

- Many small repos, each producing a deployable artifact (microservice,
  micro-UI, library, design-system package, CLI tool).
- Each repo deployable **independently** — no coordinated-release
  requirements between repos.
- Each producer-consumer pair held together by a **stable contract**, so
  the producer can roll forward without breaking the consumer and vice
  versa.
- Different teams owning different repos (often a frontend team vs. a
  backend team; sometimes per-service teams).
- Shared libraries and a shared UI/UX design system, each in their own
  published-package repos consumed across many projects.

This is a deliberate architectural choice, not a default. A repo design
that *forces* coordinated releases across producer + consumer is, by our
standard, **not stable**. Backward-compatible evolution is the criterion;
polyrepo is the shape that makes the criterion enforceable per-repo.

Monorepo projects still work — `development:maintenance` already dispatches
to multiple language and topic plugins in parallel, so a polyglot
monorepo bootstraps and maintains identically to a polyrepo from the
plugin family's point of view. The architecture is monorepo-tolerant; the
*default design we optimize for* is polyrepo.

### API contracts are first-class published artifacts

Every repo that exposes an outward-facing surface treats its contract as
a **published artifact**, not an implementation detail to be inferred from
the code. "Outward-facing surface" is broad and the bootstrap detection
must recognise every form of it:

- **REST APIs** (OpenAPI / Swagger).
- **gRPC and Protobuf services**.
- **GraphQL schemas**.
- **AsyncAPI / event-driven message schemas** (Avro, JSON Schema, Protobuf
  in a registry).
- **CLI tools** — flags, subcommands, exit codes, output formats. The
  `--help` snapshot is the contract.
- **Library public exports** — any function, class, type, or constant
  exported from a published package. Per language: TypeScript declaration
  files, Python `__all__` + type stubs, Java public classes, Go exported
  identifiers, Rust `pub` items, Swift `public` declarations.
- **Environment-variable contracts** — required env vars, their formats,
  their defaults.
- **Config-file schemas** — anything a user writes to configure the
  program.
- **Webhook payload shapes** — outgoing event bodies the consumer parses.
- **Queue / topic message formats** — every shape this repo publishes to
  a shared bus.
- **MCP tool signatures** — for repos exposing MCP servers, the tool
  argument schemas.
- **Database views / stored procedures** when the repo shares state with
  other services through a database (anti-pattern but real).

Any of those that the bootstrap detection finds in a repo becomes a
tracked contract artifact.

### Contracts are prominent, not buried

The contract must be **readable by a downstream consumer (human or
Claude) without reading the whole producer repo.** Concretely, every
producer repo gets:

- A top-level **`contracts/`** (or `api/`) directory holding the
  authoritative artifacts. Generated artifacts are committed, not built
  on demand — consumers and grep can read them directly.
- A top-level **`CONTRACTS.md`** that names every exposed surface, links
  to its artifact, records the surface type (REST, gRPC, library export,
  CLI, …), describes the compatibility policy (semver for libraries,
  URL-path versioning for REST, etc.), and best-effort lists known
  consumers.

These exist because the central question for any consumer working in a
sibling repo is: *what can I rely on from this producer?* The answer
should be `cat CONTRACTS.md` + reading the linked artifact, never "clone
the whole repo and read its code." This is the seam that makes polyrepo
work — without it, every cross-repo task degrades into a full-repo read.

### Backward compatibility is enforced mechanically, not by policy text

Policy text in `CONTRACTS.md` describes the intent; the **enforcement is
in CI** and runs on every PR that touches a contract artifact. The
detector is matched to the surface type:

| Surface | Detector |
| --- | --- |
| REST / OpenAPI | `oasdiff` / `openapi-diff` |
| gRPC / Protobuf | `buf breaking` |
| GraphQL | `graphql-inspector` |
| AsyncAPI / event schemas | `asyncapi-diff` or schema-registry diff |
| CLI parameters | `--help` snapshot diff |
| Library exports (TS) | `api-extractor` |
| Library exports (Python) | `griffe` + `python-semver-check` |
| Library exports (Java) | `revapi` or `japicmp` |
| Library exports (Go) | `gorelease` |
| Library exports (Rust) | `cargo-semver-checks` |
| Library exports (Swift) | `swift-api-digester` |
| Env-var schemas, config schemas, webhook payloads | JSON Schema diff |
| MCP tool signatures | JSON Schema diff against the tool definitions |

A breaking change in any contract artifact fails the build **unless** the
PR carries a deliberate signal that the break is intentional and the
version bump matches (`feat!:` / `BREAKING CHANGE:` for libraries, major
version increment for the package, URL-path or header version bump for
REST).

The Approver's per-language policy template ships an *API stability*
criterion that reads the same detector output, so a breaking change
without the right signal is automatic `REQUEST_CHANGES` — not a separate
judgement call, just the mechanical gate raised to a review verdict.

The full bootstrap-and-Approver scope for this is tracked in
[#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174).

### Cross-repo Claude: the big-picture problem

A Claude session in one repo cannot see siblings by default, and in a
polyrepo world most non-trivial tasks span at least one producer and one
consumer. Patterns we lean on, ranked by leverage:

1. **Contract repos as the source of truth.** Most cross-repo work
   doesn't actually need both implementations — it needs the contract.
   If the producer's `contracts/` is prominent and complete, the
   consumer-side Claude reads one file and proceeds. This is the highest
   leverage and the cheapest to set up.
2. **Parent-workspace folder.** Check out related repos as siblings under
   a parent (e.g. `~/work/product-x/{frontend-cart, backend-orders,
   design-system, contracts}`) and launch Claude from the parent.
   `Read` / `Grep` / `Bash` cross repo boundaries trivially when invoked
   above them. Cheap, works for tens of repos.
3. **Workspace manifest.** A small file (e.g. `.claude-workspace.yaml`)
   declaring the constellation: which repos belong, their roles, where
   their contracts live. Lets a skill validate that a breaking change
   has been propagated to all consumers, and lets bootstrap learn
   "this repo is part of constellation X" so it can apply
   constellation-specific conventions.
4. **MCP server for cross-repo indexing.** Indexes contracts across the
   org's repos and answers "who consumes `POST /orders`?" or "which
   services depend on `@design-system/button`?" Higher build cost; the
   only path that scales to hundreds of repos.

The leverage stack is the order of investment: get the contracts right,
then the parent-workspace pattern handles 80% of cross-repo work, then a
workspace manifest formalises the convention, then MCP for scale. Don't
build (4) before (1) — without prominent contracts, an indexer indexes
the wrong thing.

### What this implies for the plugin family

Each piece below is captured at the right level of detail in #174; the
plugin-family implications:

- **Bootstrap** detects every outward-facing surface in the repo and
  installs the matching breaking-change detector. It also generates
  `contracts/` + `CONTRACTS.md` from templates.
- **Approver** policy templates gain an `## API stability` section
  evaluated for every PR that touches a contract artifact.
- **Language plugins gain a library mode** — `--library` (or auto-detected
  from `publishConfig` / `[project].version` / `Cargo.toml [package]
  .publish`, etc.). Library mode applies stricter public-API gates,
  semver enforcement, and a different coverage / test-quality
  expectation (more public-API snapshot, less integration).
- **The design-system case is a library at the constellation scale** —
  same library-mode bootstrap, but with the additional expectation that
  visual-regression tests (Chromatic, Percy, or equivalent) sit in the
  test mix.

This section frames the *why*; the *how* lives in #174 and in the
per-language policy templates.

## Responsibilities

### `development` owns

- Generic skills: `bootstrap`, `commit-message`, `git-branch-naming`,
  `cleanup`, the `maintenance` orchestrator (layout under "Dispatch
  model" below).
- Shared scripts that operate on detected state without language
  knowledge: `detect-stack.sh`, `merge-gitignore.sh`,
  `branch-protection.sh`, `preflight.sh`, the `automate-*.sh` family.
- Policy text: Zero Tolerance standard definitions (the 90/0/A thresholds
  and the layered enforcement model — Sonar gate + CI `coverage-floor` +
  pre-push hook), security thresholds, `.snyk` ignore conventions.
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

## Build policy — Gradle + Kotlin DSL only (Java/Spring)

The Java/Spring plugins maintain exactly **one** blessed build format:
**Gradle with the Kotlin DSL (`build.gradle.kts`)**. This is a deliberate
application of the *minimize-options* principle — every supported format is a
maintenance + expertise cost, and DSL choice is a decision adopters shouldn't
have to make. Concretely:

- **Maven is not accepted.** A `pom.xml`-only project (no Gradle) is out of
  scope.
- **Groovy `build.gradle` is not maintained.** It must be converted to
  `build.gradle.kts` first.

Enforcement is layered, and each layer reads a signal rather than re-deciding:

1. **Detection** (`detect-stack.sh`) still detects Java on Groovy/Maven repos
   (it must, to flag them) and emits `language_meta.java.gradle_dsl`
   (`"kotlin" | "groovy" | ""`) alongside `build_system` (`"gradle" | "maven"`).
2. **Bootstrap converts.** `/development:bootstrap` rejects Maven and offers a
   confirmed Groovy→Kotlin conversion (validated with `./gradlew help`,
   rolled back on failure).
3. **Maintenance halts.** The `development-java` and `development-spring`
   dispatchers infer the flavor from `language_meta.manifests` and **refuse to
   run** on a Groovy/Maven build, returning a `human_action_required` that
   points at bootstrap's conversion. This is a per-dispatcher gate (no generic
   orchestrator edit — the orchestrator forwards `manifests`, it doesn't
   interpret them).
4. **Gathers + advisors are Kotlin-only.** The gather scripts and the Spring
   topic-marker recipe scan `build.gradle.kts` only; every advisor that edits
   the build reads/writes Kotlin DSL.

Note the distinction the advisors preserve: the **Maven build tool** (`pom.xml`)
is rejected, but the **Maven artifact ecosystem** Gradle depends on (Maven
Central, `group:artifact` coordinates, `mavenCentral()`) is unaffected.

## Dispatch model

`development:maintenance` (and any future orchestrator) follows a
**pure-function** dispatch contract:

```text
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

```text
This project uses Python.
Required plugin: development-python  (not installed).
Install with: claude plugin install timo-jakob/timos-claude-code-plugins/development-python
After install, re-run /development:maintenance.
```

Other detected languages still get processed. The user can opt to act
on partial results.

### Maintenance skill layout (orchestrator + reference docs)

`development:maintenance` is one slim, invocable `SKILL.md` (Phases 0–10,
the imperative procedure) plus a `reference/` directory holding the *why*:

```text
development/skills/maintenance/
  SKILL.md         # imperative orchestrator: flags, detect, dispatch,
                   #   the per-stage PR cycle, summary, issue tracking
  reference/
    pr-cycle.md    # Phase 8 rationale: identity switch, isolation invariant,
                   #   per-tool override, `-f -f`, post-merge state re-check
    gather.md      # Phases 3–4/6: no-trim contract incidents, drift severities
    report.md      # Phase 9: Snyk channel-naming table, cross-link examples
  scripts/         # gather-/verify-<lang>, write-payload, token mint, …
```

**Convention (mirrors `bootstrap`'s `docs/`):** executable procedure —
steps, commands, `Agent(...)` shapes, decision branches, and the lookup
tables the orchestrator *follows* — stays inline in `SKILL.md`. The
reasoning behind the non-obvious steps (incident history, why-this-order,
exhaustive disambiguation tables) lives in `reference/*.md`, cited inline
as "see `reference/<file>.md` § `<heading>`". The happy path never depends
on reading a reference doc, so a missed read can't break a phase — the docs
are there when a step's intent is unclear or an edge case fires. This keeps
the orchestrator scannable without losing the hard-won rationale (#249).

## JSON schema (v2)

The contract between `development` and any `development-<lang>`.

**Stability stance.** Treated as stable now. While we're the only
consumer of these plugins, we may revise v2 in place if a real need
surfaces — change the schema, update all language plugins in the same
PR set, no minor-version bump required. The moment a third party installs
any of these plugins, v2 freezes and any incompatible change becomes
v3 (language plugins declare supported versions in their `SKILL.md`
so `development` picks the highest common). Until then, this section
is the canonical reference and lives here, not in a versioned schema
file.

**v1 → v2 transition (2026-06).** The wire shape of the payload did
not change between v1 and v2 — only the **handover mechanism**. v1
passed the payload as an inline JSON string in the Skill tool's
`args=`. v2 passes a path to a temp file the orchestrator wrote (see
*Handover* below). The bump exists so dispatcher and orchestrator fail
loudly on mismatch instead of silently truncating large payloads.

### Handover (`args=` is a file path, not inline JSON)

The orchestrator writes the payload to a `mktemp` file via
`development/skills/maintenance/scripts/write-payload.zsh` and passes
the absolute path as the Skill tool's `args=`. The dispatcher reads
the file from disk, parses, and proceeds.

```bash
payload_file=$(echo "$payload_json" | <skill-base-dir>/scripts/write-payload.zsh)
Skill(skill="development-<lang>:maintenance", args="$payload_file")
rm -f "$payload_file"
```

The orchestrator owns the temp file's lifecycle: write before
dispatch, delete after the Skill call returns (success or failure).
On hard crash, the file is left in `$TMPDIR` for the OS to reap.

This decouples payload size from any Skill-tool inline limit — a
maintenance run on a project with 200+ Dependabot PRs (~6 MB
payload) is the same code path as one with three patches.

### Request (`development` → `development-<lang>`)

The wire shape below is identical to v1; only `schema_version` and
the delivery mechanism changed.

```json
{
  "schema_version": "2",
  "repo": {
    "path": "/abs/path/to/repo",
    "default_branch": "main",
    "visibility": "public"
  },
  "language": "python",
  "dispatch_mode": "primary",
  "language_meta": {
    "version": "3.13",
    "manifests": ["pyproject.toml", "requirements.txt"]
  },
  "tooling_configured": {
    "ruff":           true,
    "semgrep":        true,
    "code_scanning":  true,
    "snyk_prs":       true,
    "sonarcloud":     true,
    "dependabot":     true,
    "container_scan": true
  },
  "findings_by_tool": {
    "ruff":                 [/* tool-native finding objects */],
    "semgrep":              [/* … */],
    "code_scanning_alerts": [/* GitHub Code Scanning alerts (CodeQL etc.) */],
    "snyk_prs":             [/* open PRs with snyk-fix-* / snyk-upgrade-* head branches */],
    "sonarcloud":           [/* … */],
    "dependabot":           [/* … */],
    "container_scan":       [/* Snyk base-image CVEs, harvested from the CI
                               snyk-container-scan artifact; deduped by id (#299) */]
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

**`language_meta` in this payload is the dispatched language's slice**
of detect-stack's nested `language_meta` registry. detect-stack emits
`language_meta` keyed by every detected language — e.g.
`{"python": {"version": "3.13", "version_source": "parsed", "has_cov":
true}, "java": {"version": "21", "version_source": "default",
"build_system": "gradle", "gradle_dsl": "kotlin", "has_cov": false}}` —
and the orchestrator copies the dispatched language's `version` into this
payload, adding the `manifests` it found. Detection-only fields
(`version_source`, `has_cov`, `build_system`, `gradle_dsl`) stay in
detect-stack output for the bootstrap skill and are not forwarded here.
`version_source` is `"parsed"` | `"default"` — `"default"` flags a version
that fell back to the LTS guess because the build declared no toolchain
(#258 reliability). `gradle_dsl` (`"kotlin" | "groovy" | ""`) drives the
bootstrap build-system gate; the maintenance dispatchers don't receive it,
so they infer the same Groovy/Maven/Kotlin distinction from the forwarded
`manifests` to apply the "§ Build policy" halt — keeping the gate inside
the language plugins with zero generic-orchestrator edits.

**`dispatch_filter` is optional** and added by the orchestrator only
when the user passed `--tool=<name>` (a testing aid). When present,
the language plugin scopes dispatch to the listed tools only — every
other agent is skipped entirely (no work, no missing-tool
recommendation). The gather output remains complete; the filter is
purely a dispatch concern. When `dispatch_filter` is absent the
default "always spawn every agent" rule applies.

**`dispatch_mode`** is `"primary"` | `"auxiliary"` (see § "Primary /
auxiliary model"). The orchestrator sets it from the repo's
`.maintenance.yml` declaration: the declared primary stack gets
`"primary"`, every other detected stack gets `"auxiliary"`. Defaults to
`"primary"` when there is no declaration, so existing runs are
unaffected. In `"auxiliary"` mode a language plugin runs only its
mechanical fixers and **skips its app-grade gates** (coverage
pre-flight, dependency upgrades) — a policy override, not a separate
code path per tool.

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

The response is **returned inline** as the Skill tool's result string,
not via a file. Response payloads stay small (a planning artifact,
not raw findings), so the file-handover one-way only applies to the
request side.

```json
{
  "schema_version": "2",
  "ci_fixer_agent": "python-ci-fixer",
  "plan": [
    {
      "group_id": 1,
      "tool": "sonarcloud",
      "description": "Triage all 16 SonarCloud findings (14 issues + 2 hotspots)",
      "findings": ["<finding-key>", "..."],
      "files": ["src/aido/webui/mutation_routes.py", "..."],
      "rationale": "all sonarcloud findings handled together by python-sonar-triage",
      "agent": "python-sonar-triage",
      "isolation": true,
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
      "tool": "code_scanning",
      "summary": "GitHub Code Scanning (CodeQL etc.) is not enabled for this project.",
      "what_it_provides": "Source-level vulnerability scanning via CodeQL — free for public repos, GitHub-native, populated by bootstrap's CodeQL workflow.",
      "how_to_add": "Run /development:bootstrap (it generates .github/workflows/codeql.yml). For existing repos: enable in GitHub repo Settings → Code security → Code scanning."
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
an opus agent that runs without a worktree, reads the findings + git
history, and returns an ordered list of "groups". **One group per
agent**: each tool's findings stay together as a single group handled
end-to-end by that tool's agent. The exceptions are `dependabot` and
`snyk_prs`, which split when their findings dispatch to multiple
agents (e.g. a pip-major Dependabot PR or Snyk Fix PR goes to
`python-major-upgrade` while patch/minor PRs stay with
`python-dependabot-snyk-triage`; one group per agent in that case).

Each group carries: source tool, included finding IDs, affected files,
rationale, **the agent the orchestrator will spawn for this group's
PR**, an `isolation` flag, an optional `pre_dispatch_hook`, a suggested
PR title, and a priority score. Plans are language-local — each
language plugin produces its own.

**`plan[].isolation`** (boolean, default `true` when absent) tells the
orchestrator whether to spawn the group's agent with
`isolation="worktree"`. It is `true` for every agent that edits local
files (the overwhelming majority) and `false` for agents that act on
GitHub PRs via `gh` rather than the working tree (e.g.
`python-dependabot-snyk-triage`). This is how the orchestrator decides
isolation **from the contract**, never by matching an agent name — a
prerequisite for a second language plugin, whose vendor-PR agent has a
different name but the same `isolation: false` semantics.

**`ci_fixer_agent`** (top-level, required) names the language plugin's
CI-fix agent — the one the orchestrator spawns in Phase 8's CI cycle
when a PR's checks fail (`python-ci-fixer` for `development-python`).
It is the same constant on every dispatcher response, **including the
Phase A `improver_result`-only response**, because Stage 0's CI cycle
needs it before any `plan` exists. The orchestrator reads this field
rather than hardcoding a per-language fixer name.

**`plan[].pre_dispatch_hook`** (optional, per-group) lets a language
plugin ask the orchestrator to run an environment check *before* it
spawns the group's agent — the case where the agent depends on
something the orchestrator can only provision interactively (a subagent
can't prompt the user). The orchestrator dispatches on the hook's
`type` and stays language-agnostic; all specifics (script path, target,
the agent-prompt field to set, the user-facing label) come from the
hook. The one `type` defined in v2 is **`runtime_availability`**:

```json
"pre_dispatch_hook": {
  "type": "runtime_availability",
  "script": "development-python/scripts/pre-dispatch-runtime-upgrade.zsh",
  "target": "3.14",
  "prompt_field": "local_verification_mode",
  "modes": { "available": "auto", "unavailable": "skip" },
  "label": "Python 3.14 interpreter"
}
```

The orchestrator runs `<plugin-base-dir>/<script> detect <target>`
(exit 0 = available, exit 1 = missing); on missing it offers
install / self-install / skip via `AskUserQuestion`, running
`<script> install <target>` for the install path. It then spawns the
agent with `<prompt_field>` set to `modes.available` or
`modes.unavailable` accordingly. This replaces the previous
orchestrator code that hardcoded the `python-runtime-upgrade` agent
name, its helper-script path, and the `local_verification_mode` field —
so a second language plugin's runtime bump reuses the same protocol
with its own script + label. An unrecognized `type` is skipped and
surfaced as a quality bug (forward-compatibility: an older orchestrator
ignores hook types it doesn't implement rather than failing the run).

The orchestrator processes the plan **sequentially in priority order**:

1. If `improver_result` is present, promote it to a PR first
   (Stage 0): push, open, monitor CI, optionally invoke the CI-fix
   agent (`ci_fixer_agent`) up to 3 times on failure, pass the approval
   gate, merge, sync local main.
2. For each entry in `plan`, in order: spawn `plan[i].agent` (with
   `isolation="worktree"` when `plan[i].isolation` is `true`/absent,
   without it when `false`) off the latest base; a worktree group
   returns a worktree branch; push, open a PR, run the same CI cycle,
   pass the approval gate, merge, sync. Only then move to `plan[i+1]`.

**The approval gate (#224, Phase 2 of #476):** a maintenance merge requires an
approving review from `claude-approver[bot]` or a human — the pipeline never
posts approvals with the operator's identity. The Approver is **user-invoked
locally** via `/development-<lang>:approve` skills (Python, Java, Swift)
rather than CI-driven. When the user runs the skill, it mints an Approver
token locally from system Keychain, posts the verdict as `claude-approver-bot`,
and requires no Claude platform account.

For orchestrator-driven maintenance PRs after CI green, the orchestrator polls
`reviewDecision` (10-minute budget); an Approver `REQUEST_CHANGES` triggers an
in-run re-ingest fix round (max 2 per PR). If no approval arrives within the
budget, auto-merge is armed so the PR merges when an approval eventually lands
(via the user-invoked skill). The same rule applies to vendor PRs handled by an
`isolation: false` group (in `development-python`, `python-dependabot-snyk-triage`):
merge only if already approved; otherwise arm auto-merge.

This serialization means each group's work runs against the latest
post-merge state. There is no local merging, no topological ordering of
worktree branches, and no rebasing. The pipeline ends when every
group has either merged, armed auto-merge awaiting approval, or
escalated.

`missing_tooling` lists tools the project hasn't configured. The
dispatcher builds it directly from `tooling_configured` (entries with
value `false`) — without spawning per-tool agents in unconfigured mode.
The orchestrator surfaces this to the user as a checklist alongside
the merged PR list.

### Approver skills — user-invoked local approval (Phase 2 of #476)

Each language plugin ships an `approve` skill that users invoke locally to post
approval verdicts to GitHub. Unlike the old CI-driven model, approval is now
**user-controlled and client-initiated**.

**Invocation:**

```bash
/development-python:approve <PR>    # Python projects
/development-java:approve <PR>      # Java/Gradle projects
/development-swift:approve <PR>     # Swift projects
```

**Flow:**

1. User invokes the skill (or it can be called by an orchestrator after CI green).
2. Skill mints Approver token locally: reads app ID from `~/.config/claude-plugins/apps.json`,
   fetches private key from system Keychain, calls GitHub API to mint a 1-hour installation token.
3. Spawns the language-specific `-approver` agent (same agent as CI) with `DRY_RUN=false`.
4. Agent posts the verdict to GitHub as `claude-approver-bot` using `gh pr review`.

**Security & portability:**

- **No platform lock-in:** Token is minted locally. No Claude platform account or GitHub
  Actions required. Works with any AI coding assistant.
- **Approver App is user-registered:** Each developer registers their own Approver App
  via `register-claude-apps.zsh` (one-time setup per machine).
- **Minimal permissions:** Approver App has read-only code access + pull-request review posting.
  Can't push code or modify configuration.
- **Token lifetime:** 1 hour (GitHub default), auto-expired. Re-mint on demand.

**Integration with orchestrator:**

When the orchestrator finishes CI on a maintenance PR and needs approval, it can arm
auto-merge with a 10-minute poll timeout. The user then runs the appropriate `/approve`
skill to post the verdict. The orchestrator detects the posted review and proceeds with merge
(or re-ingest if `REQUEST_CHANGES`).

## Review finding schema (review panels → consolidator)

The `development-<lang>:review` panels (Swift 6 agents, Python 5, Java 5 — #449)
report findings as prose in the native `[CRITICAL|WARNING|SUGGESTION]` format,
for humans. The autonomous story-delivery loop (#557) also needs those findings
in a form a consolidator can parse, deduplicate, and count. So the review panel
has **every reviewer emit a machine-readable JSON block alongside its prose**
(#558): the prose is unchanged and stays for humans; the JSON is for the
machine. The severity taxonomy is untouched — the JSON carries the same
severities.

**The emission directive lives in one place, not sixteen.** Rather than copy the
JSON instruction into every reviewer agent's definition, the `review` skill
**injects it into each agent's launch prompt**, substituting that agent's
`dimension` and `reviewer` name from its Step 1 table. The reviewer agents stay
pure prose reviewers; only the skill knows about the JSON layer. A new language
wires this up once — in its own `review` skill's Step 1 — and every reviewer it
launches emits the block for free, with no per-agent boilerplate to maintain.

### The finding object

Each reviewer emits one fenced `json` block whose body is a **JSON array of
finding objects** (`[]` when it found nothing). Each object has exactly these
fields:

| Field | Type | Value |
| --- | --- | --- |
| `severity` | string | `CRITICAL` \| `WARNING` \| `SUGGESTION` — the native taxonomy, same as the prose tag |
| `dimension` | string | the emitting agent's dimension (enum below) |
| `file` | string | repo-relative path |
| `line` | integer \| null | line number, or `null` for a file-level finding |
| `title` | string | the finding title (same as the prose title) |
| `description` | string | one- or two-sentence explanation |
| `suggested_fix` | string | concrete remediation (may be `""`) |
| `reviewer` | string | the emitting agent's name (e.g. `python-bug-hunter`) |
| `round` | integer | the review round from the agent's prompt; `1` when the panel runs standalone |

**Dimension enum.** The five core dimensions are shared across all languages
(the #449 enum): `bugs` (`*-bug-hunter`), `security` (`*-security-reviewer`),
`performance` (`*-performance-reviewer`), `code_quality` (`*-code-quality`),
`tests` (`*-test-reviewer`). Swift adds one language-specific dimension,
`swift6_compliance` (`swift6-compliance`), for six Swift dimensions in total. A
language may extend the enum with its own dimension the same way; the core five
never change meaning.

### Aggregation (per round)

Each review skill's synthesis step concatenates every agent's JSON array into a
**single findings array for the round** and writes it to one findings file (the
caller/orchestrator supplies the path; the panel defaults to
`review-findings-round-<round>.json`). Because every finding is self-describing
— it carries its own `reviewer`, `dimension`, and `round` — aggregation is a
flat concatenation, no join. `jq` then reads severity counts straight off the
aggregate:

```bash
# per-severity counts for a round's aggregate
jq '[.[].severity] | group_by(.) | map({severity: .[0], count: length})' \
  review-findings-round-1.json

# blocking-finding count (Critical + High == CRITICAL + WARNING, per #557)
jq '[.[] | select(.severity == "CRITICAL" or .severity == "WARNING")] | length' \
  review-findings-round-1.json
```

The consolidator (#561) consumes this aggregate; the severity→blocking mapping
(`CRITICAL→Critical`, `WARNING→High`, `SUGGESTION→Low`; Critical + High block)
lives with it, not here.

## Review-panel invocation contract (#560)

The autonomous review loop's orchestrator (#562) must invoke the right language
review panel **without knowing language specifics** — the same principle as the
`/development:maintenance` dispatch contract, where adding a language requires
zero orchestrator edits. The seam is
`development/skills/resolve-issue/scripts/review-dispatch.zsh`, a pure function
of the worktree with two subcommands.

**`plan --repo PATH [--base REF] [--round N]`** emits the dispatch descriptor:

```json
{
  "repo_type": "python",
  "review_skill": "development-python:review",
  "round": 1,
  "base": "origin/main",
  "findings_path": "<repo>/.review/findings-round-1.json",
  "changed_files": ["src/app/checkout.py", "src/app/cart.py"]
}
```

- **Repo-type detection reuses the maintenance logic** — it runs
  `bootstrap/scripts/detect-stack.sh` and reads its `.languages`. Supported
  review types are `swift` | `python` | `java`, each mapping to that language's
  `:review` skill. When several apply, `.maintenance.yml`'s `primary`
  disambiguates.
- **The review scope is the story's diff, never the whole repo.** `changed_files`
  is everything that differs from `base` (committed + staged + unstaged) plus new
  untracked files. Pre-existing findings in untouched code belong to
  `/development:maintenance`, not the loop — without diff-scoping, round 2
  re-litigates legacy code and the loop never converges.
- **The panel writes its aggregate findings JSON** (the *Review finding schema*
  above) to `findings_path`, a well-known per-round path in the worktree.

**`scope-findings --repo PATH [--base REF] --findings FILE`** reads the panel's
aggregate and prints only the findings whose `file` is inside the story's diff —
the enforcement point for "findings outside the diff do not appear", downstream
of whatever the panel reported. A missing/empty file yields `[]`.

**An unsupported or ambiguous repo type is a typed escalation, not a crash.**
`plan` prints a JSON error object (`{"error":"unsupported_repo_type", …}` or
`{"error":"ambiguous_repo_type", …}`) and exits `3`; the orchestrator surfaces
that as a `needs-human-decision` escalation (#564) rather than proceeding. Exit
`2` is a usage error; `1` is an internal (detect-stack/git/jq) failure. Tests
seam detection via `DETECT_STACK_BIN` and git via `GIT_BIN`.

## Review-findings consolidator (#561)

Five reviewers giving unmediated feedback to the implementor produces conflicting
advice and thrash. One consolidation step turns a round's parallel reviewer
output (the diff-scoped aggregate above) into a single prioritised **changelist**
the review-loop orchestrator (#562) acts on.

The consolidation is split the same way as the review panel itself — a
deterministic engine plus a judgment layer — because the counting must be
reliable but the merging needs semantics:

- **`consolidate-findings.zsh`** is the deterministic engine (jq), fully
  bats-tested. It applies the **severity map** `CRITICAL→Critical`,
  `WARNING→High`, `SUGGESTION→Low`; **blocking = Critical + High** (Low is logged
  in `suggestions` and never triggers a round); **dedup** by `file`+`line`+
  `dimension` (most-detailed description kept, reviewers unioned, `agreement`
  counted, highest severity carried); a **conflict** item for co-located
  `performance`-vs-`code_quality` recommendations; and **non-convergence** —
  a blocker whose fingerprint (`file`+`dimension`+normalized `title`) also
  blocked the previous round (`--prev`) is marked `non_converging: true`. A
  surviving conflict and a non-converging blocker are both `escalation_reasons`.
- **`review-consolidator`** (agent, opus) runs the engine, then adds the
  judgment the exact-key heuristics can't: merging findings that describe the
  same defect in different words / across dimensions, and confirming or demoting
  conflicts by reading the cited code. It never re-grades a reviewer's severity
  and never invents or drops a finding.

Changelist shape: `{ round, summary{critical,high,low,blocking,conflicts},
blocking[], suggestions[], conflicts[], non_converging, escalation_reasons[] }`.
The `blocking` array (Critical first, then High) is what the loop must clear;
`suggestions` ride into the dossier (#563) but never loop.

## Review-loop state machine (#562)

`resolve-story-loop.zsh` ties the gate (#559), the diff-scoped panel (#560), and
the consolidator (#561) into an autonomous implement→review→fix loop that runs
**entirely in the worktree** — nothing is pushed and no PR is opened until it
exits `CONVERGED`. It sits in `/development:resolve-issue` between validate
(step 3) and open-pr, so CI minutes are only spent on code a panel has already
converged on. Constants live at the top: `MAX_REVIEW_ROUNDS=3`,
`BLOCKING_SEVERITIES=(CRITICAL WARNING)` (= Critical + High).

**The agentic steps are hooks.** Running the panel and applying the fix pass are
model-driven, so they are injected as `--review-cmd` / `--fix-cmd` (and an
optional `--test-cmd` gate). This keeps the deterministic state machine — rounds,
budget, consolidation, exit-state — a pure, bats-testable function, and lets the
skill wire the real panel/fix behind the seam (inline, or a headless `claude -p`).

Per round: run panel (diff-scoped) → `scope-findings` → `consolidate-findings`.
No blockers ⇒ `CONVERGED`. Otherwise the early-exit escalations fire *before* the
budget is spent — a surviving conflict ⇒ `ESCALATE_CONFLICT`, a `non_converging`
blocker (same fingerprint two rounds running) ⇒ `ESCALATE_NO_CONVERGENCE` — else
feed the blockers-only slice to the fix hook, re-run the gate, and loop. Reaching
the last round with blockers still open ⇒ `BUDGET_EXHAUSTED`; an unpickable repo
type from dispatch ⇒ `ESCALATE_AMBIGUOUS`. Each state is a distinct exit code
(0 `CONVERGED`/`SKIPPED`; 10 ambiguous; 11 conflict; 12 no-convergence; 13 budget;
2 usage; 1 operational — e.g. a red gate after a fix) alongside a machine-readable
status JSON (`{status, rounds, max_rounds, repo_type, review_skill,
escalation_reasons, history, final_changelist}`). `--no-review` yields `SKIPPED`
— the fast path that bypasses the loop.

Only `CONVERGED` proceeds to commit + open-pr; every escalation stops without a
PR and is surfaced as a `needs-human-decision` issue comment (#564), never a
draft PR (a draft would trigger CI, defeating the local loop).

## Review-loop telemetry (#566)

Raising autonomy safely needs evidence, so the loop appends **one JSONL record
per run** to `.claude/telemetry/review-loop.jsonl` (git-ignored — the bootstrap
gitignore fragments for python/java/swift carry `.claude/telemetry/`). The record
is built deterministically from the loop's status JSON by
`build-telemetry-record.zsh`: `ts`, `issue`, `repo_type`, `status`, `escalation`
(the type, or `null` when converged/skipped), `rounds`, `max_rounds`,
`findings_by_round` (per round, by priority and by dimension), `fixed` (blockers
found and cleared) vs `waived` (Low suggestions logged), `wall_s`, and a reserved
`tokens` field (not observable from zsh in v1). The append is never fatal — a
telemetry failure can't break the loop's exit.

The three headline metrics come straight off the file with `jq`:

```bash
# first-pass convergence rate
jq -s '([.[] | select(.status == "CONVERGED")] | length) / length' .claude/telemetry/review-loop.jsonl
# mean rounds to converge
jq -s '([.[].rounds] | add) / length' .claude/telemetry/review-loop.jsonl
# escalation breakdown
jq -s 'group_by(.escalation) | map({(.[0].escalation | tostring): length}) | add' .claude/telemetry/review-loop.jsonl
```

This is the raw material for the DORA-style dashboard and for deciding future
budgets (tokens, wall-clock) and risk-based review depth.

## Review dossier + Approver re-ingest (#563)

The PR is the durable audit record for why auto-merge happened, so a `CONVERGED`
loop's history lands in it — human-readable for reviewers, machine-readable for
the Approver. `build-dossier.zsh` turns the loop's status JSON (which now retains
every round's changelist in `round_changelists`, so the per-dimension detail a
converged clean final round lacks is still available) into two things appended to
the PR body by `open-pr`:

1. a **"Review dossier"** section — rounds run, per-round blockers found & fixed,
   dimensions reviewed (the #449 lenses, each `clean` or with a fixed count),
   waived Low suggestions, and the reviewers who contributed; and
2. a hidden `<!-- review-dossier: {…} -->` JSON block, dimension-tagged with the
   #449 enum.

The Approver re-ingests the hidden block **the same way maintenance re-ingests
Approver findings** — via the shared `approver-policy-core` (#555), so all three
language Approvers get it without per-agent edits. A `clean` dimension lowers
that lens's residual-risk weight (the panel already looked and found nothing); a
non-clean dimension is where to look hardest; `waived_low` is context, never a
`REQUEST_CHANGES` on its own. A PR **without** a dossier (`--no-review`, or a
human-authored PR) is judged exactly as before — `build-dossier.zsh` emits
nothing, so the body and the Approver's behavior are unchanged.

## Typed escalation path (#564)

Escalation quality decides whether a human interruption costs two minutes or an
afternoon, so every non-`CONVERGED` loop exit produces exactly **one**
decision-ready artifact and nothing else. `build-escalation.zsh` turns the loop's
status JSON into an issue-comment body: a typed header (the escalation type), a
one-line summary, a type-specific detail block (the conflicting dimensions / the
non-converging blocker / the remaining blockers / the dispatch error), the round
history one line each, and **2–3 concrete options** tailored to the type (pick a
winner, reconcile, split; unblock, waive, split; extend, triage, split; name the
language, skip review, add support). A trailing `<!-- review-loop-escalation:
<STATUS> -->` marker makes the comment machine-findable.

The skill then: pushes the branch as the bot so the diff-so-far is linkable but
**creates no PR object** (a draft would trigger CI and defeat the local loop);
posts the comment; and applies the `needs-human-decision` label idempotently (the
`ensure_label` idiom — no bootstrap labels manifest exists). The **resume path**
closes the loop: the human answers in the thread and re-runs
`/development:resolve-issue <N>`; because the implement step and the readiness
gate read the issue's *comments*, the decision becomes implementation context and
the next run can converge. No PR exists until it does.

## Issue-dependency model (#583)

**GitHub-native `blockedBy` relationships are the single source of truth for
issue dependencies.** Prose ("depends on #M", "after #M") is advisory at best:
nothing can enforce it, and it drifts. So the contract is:

- **Declare it or it doesn't exist.** A dependency required to start must be a
  native *blocked-by* relationship on the issue (queryable via GraphQL:
  `blockedBy` / `blocking` / `issueDependenciesSummary`, alongside `subIssues` /
  `trackedIssues` for hierarchy). The `story-readiness` gate enforces the
  declaration: a prose-implied dependency with no corresponding native
  relationship is a `NEEDS_REFINEMENT` reason ("declare #M as a blocked-by
  relationship"), never something the gate silently infers.
- **No second machine-readable copy.** The `story-spec` block (#574) carries
  **no** `dependencies` field — that was a deliberate cut, not an omission. Two
  machine-readable copies of the same fact would drift; the AI reads
  dependencies only the native way.
- **One shared reader.** Every consumer — the readiness gate, the single-issue
  dependency precheck (#585), the epic-as-dependency recursion (#587) — reads
  through `development/skills/resolve-issue/scripts/read-dependencies.zsh`, so
  traversal, classification, and cycle semantics cannot drift between them.

The helper (`read-dependencies.zsh --repo OWNER/NAME --issue N`) emits one JSON
object: the issue's **transitive** open blockers (`blocked`, `open_blockers`),
every distinct blocker reached with `state`/`open`/`depth` and a `kind` of
`epic` (the `epic` label, tracked issues, or a task-list body) vs `issue` —
the hook #587 uses to require a whole epic resolved before its dependent — and
**cycles reported explicitly** as the paths that closed them. A CLOSED blocker
is recorded but not recursed into: a met prerequisite's own history can't block
anything. `GH_BIN` is the test seam; exit codes are 0 (result), 2 (usage),
1 (gh/GraphQL failure or nonexistent issue).

**The enforcement point is `dependency-precheck.zsh` (#585)** — step 0a of the
single-issue flow, before the readiness gate and before any branch exists. It
wraps the reader into one typed decision (`DEPS_BIN` seam): `PROCEED` (exit 0)
only when no open blockers exist; `REJECT_BLOCKED` (10) with a ready-to-post
argumentation naming every open blocker; `REJECT_CYCLE` (11) when the graph
contains a cycle — the cycle wins over the blocker list, because "resolve these
first" can never be satisfied. Like the readiness gate it performs no GitHub
writes; the skill posts. In **autonomous** runs (maintenance pipeline,
epic-driven resolve) a rejection posts the comment, applies the `blocked` label,
and stops — an unattended run never auto-chains into resolving the blocker
itself. In **interactive** runs the skill layers guided remediation on top
(#586): the human explicitly chooses *resolve blocker + named issue* or
*just the blocker* (declining stops); plain-issue chains resolve
**deepest-first**, each blocker through the full single-issue flow (one PR per
blocker, merged before its dependent branches), with closure **re-verified by
re-running the precheck** before the named issue proceeds. Cycles are never
remediated (a relationship edit is the human's call). An **epic-kind blocker
remediates as a whole** (#587): its rung runs the full epic flow — all
children plus the holistic E4 verification and the explicit E5 close, reused
as written — and the dependent stays queued until the blocking epic is
**closed**, not merely children-merged; autonomous runs still reject +
escalate rather than auto-running the epic.

## Story-spec contract (`story-spec/v1`, #574)

The refinement phase (`/development:refine-issue`, epic #573) is where an AI has
its richest, verified understanding of a story. `story-spec/v1` **persists that
understanding as a durable, machine-readable spec on the issue**, so the
downstream implementer (`resolve-issue`) consumes a precise interface instead of
re-deriving everything from prose — while the prose stays foregrounded and
human-authoritative. The `story-readiness` agent (#559) both **emits** a proposed
block (part of its verdict) and **validates** an existing one against the prose.

### Where the block lives

Unlike `personas/v1` (a file in the target repo), the story-spec block lives **in
the GitHub issue body** — appended, collapsed, below the human prose:

```markdown
<!-- story-spec:prose:start -->
... the human-authoritative issue prose the block summarises ...
<!-- story-spec:prose:end -->

<details>
<summary>🤖 machine-readable story spec (<code>story-spec/v1</code>) — generated, do not hand-edit</summary>

<!-- the story-spec/v1 JSON block (schema below) goes here -->

</details>
```

The `story-spec:prose:start`/`:end` sentinels bound the prose the provenance hash
covers (below), exactly as `personas/v1` does. When `refine-issue` writes the
block, it wraps the (refined) issue prose in the sentinels; the block follows.

### The `story-spec/v1` block

One fenced `json` object inside the `<details>`. Shape:

```json
{
  "schema": "story-spec/v1",
  "provenance": {
    "generated_by": "story-readiness via /development:refine-issue",
    "generated_at": "2026-07-10T12:00:00Z",
    "prose_sha256": "9b2e0a1c4d6f83b5a7c9e1f3058d2a4b6c8e0f1a3b5d7c9e1f2a4b6c8d0e2f4a"
  },
  "acceptance_criteria": ["job files in under 20 s", "half-typed entry survives a network drop"],
  "scope_boundaries": {
    "in": ["the mobile job-entry form", "local draft persistence"],
    "out": ["the web dashboard", "offline sync conflict resolution"]
  },
  "risk_classification": "normal",
  "testable_checks": ["POST /jobs with a dropped connection re-submits the saved draft"],
  "interface_surfaces": ["rest", "web-ui"],
  "use_case": {
    "actor": "dana-dispatcher",
    "goal": "file a job from the depot floor before the truck leaves",
    "data_sketch": "job_ref JOB-2291, site 'Müller & Sons', notes pasted from SMS"
  },
  "personas": ["dana-dispatcher"],
  "test_cases": [
    {
      "id": "tc-happy-file-job",
      "kind": "happy",
      "shape": "POST /jobs {job_ref, site_name, notes} -> 201 + job id",
      "tooling": "curl",
      "issue": null
    },
    {
      "id": "tc-error-oversized-note",
      "kind": "error",
      "shape": "POST /jobs with a 40 KB note -> 413, no partial write",
      "tooling": "curl",
      "issue": null
    }
  ]
}
```

**Field contract:**

| Field | Type | Value |
| --- | --- | --- |
| `schema` | string | the schema identifier — literally `story-spec/v1` |
| `acceptance_criteria` | string[] | testable definition-of-done checks |
| `scope_boundaries` | object | `{ in: string[], out: string[] }` — what the story does and explicitly does not cover |
| `risk_classification` | string | `low` \| `normal` \| `elevated` — reuses the gate's classification (#559), given a durable home |
| `testable_checks` | string[] | seeds for the implementation's tests |
| `interface_surfaces` | string[] | runtime surfaces the story touches: `rest` \| `grpc` \| `web-ui` \| `cli` (the #242 taxonomy); `[]` when none |
| `use_case` | object | `{ actor, goal, data_sketch }` — concrete enough to derive realistic test data |
| `personas` | string[] | persona ids referencing the target repo's `personas/v1` registry (#665). **Advisory; may be `[]`** |
| `test_cases` | object[] | outside-in cases: `id`, `kind` (`happy` \| `corner` \| `error`), `shape` (given/when/then or request→expected), `tooling` (`curl` \| `grpcurl` \| `playwright` \| `cli`), and `issue` (the linked test-case issue number after spin-out #671, else `null`) |
| `provenance` | object | `{ generated_by, generated_at, prose_sha256 }` — as below |

**No `dependencies` field — deliberately (#583).** Dependencies live in
GitHub-native `blockedBy` relationships, the single source of truth. A second
machine-readable copy in the block would drift; the gate and `resolve-issue`
read dependencies only the native way. See the issue-dependency model above.

### Provenance and staleness (shared with `personas/v1`)

Identical mechanism to `personas/v1`: `prose_sha256` is the SHA-256 of the
sentinel-delimited prose region (`<!-- story-spec:prose:start -->` …
`<!-- story-spec:prose:end -->`), under the **same normalisation** (LF endings →
strip per-line trailing whitespace → drop leading/trailing blank lines → append
one `LF`), lowercase hex. A consumer recomputes and compares: **match** → the
block is in sync; **mismatch** → the issue prose was hand-edited after the block
was generated, so the block is **stale**. See the personas provenance subsection
for the exact byte-level recipe — the two contracts share it verbatim.

### How the gate emits and validates it

The `story-readiness` agent extends its read-only verdict (it still writes
nothing) in two ways:

- **Emit.** For a `READY` story it includes a **proposed** `story_spec` object in
  its verdict JSON, derived from the issue it just judged — the raw material
  `refine-issue` writes back (human-approved) and `resolve-issue` can consume.
  The proposal is advisory output; spawning skills that don't want it ignore the
  field, so this is backward-compatible with every existing caller.
- **Validate — only when a block is already present.** If the issue body already
  carries a `story-spec/v1` block, the gate checks it against the prose: a
  **stale** block (provenance mismatch) or one that **contradicts** the prose
  (e.g. acceptance criteria the prose no longer supports, or
  `interface_surfaces` claiming `rest` when the prose describes a CLI-only
  change) is a `NEEDS_REFINEMENT` reason, named as such. An **absent** block is
  *not* a
  failure — most issues have never been refined, and the gate simply proposes
  one rather than demanding it.

**Interface-aware check 5 (#670).** The gate also classifies the story's runtime
`surface` (`rest` | `grpc` | `web-ui` | `cli`, the #242 taxonomy, or `none`) and,
for **surface-touching** stories, hard-requires **check 5 — outside-in
testability**: a concrete `use_case`, `test_cases` covering happy/corner/error in
the surface's native tooling, and the spun-out `test-case` issues existing and
linked (#671). A `none`-surface story skips check 5 (proportionality — the
backlog is not mass-flipped). The verdict JSON grows two fields:
`surface` (the classified surfaces, `[]` for none — reported at verdict level
because it's needed even when `story_spec` is `null`) and
`checks.outside_in_testable`. Personas stay advisory (`advisories[]`, #668),
never a check-5 failure. The full verdict shape is the `story-readiness` agent
contract (`development/agents/story-readiness.md`).

### How resolve-issue consumes the block (#577)

`/development:resolve-issue` reads the block as its **authoritative structured
interface** in its implement step, via the robust extractor
`development/skills/resolve-issue/scripts/read-story-spec.zsh` (selects the fenced
`json` object whose `.schema` is `story-spec/v1` by **content**, not position, so
an unrelated code block in the prose can't be mistaken for it). It drives
implementation from `acceptance_criteria` / `testable_checks` (the definition of
done the Step-3 gate must demonstrate) and bounds the change by
`scope_boundaries`; dependencies are **never** read from the block (native
`blockedBy` only, #583). Consumption is safe because step 0b's gate already
proved the block fresh and consistent with the prose. When **no** block is
present — the common case for unrefined issues — the extractor exits non-zero and
resolve-issue **falls back to the prose** exactly as before; a missing block is
never an error. Implementing the block's `test_cases[]` as acceptance tests and
co-closing linked test-case issues is a separate concern (the same-PR test-case
lifecycle, #696), not part of block-consumption.

### Test-case issue convention (`test-case`, #671)

Outside-in test cases follow a **hybrid model**: each case in a story's
`story-spec/v1` `test_cases[]` lives *both* structured in the block (the single,
gate-validatable source of truth) *and* as a separate linked **`test-case`
issue**, so the case is independently visible in the backlog and its existence is
checkable — while staying implemented in the **same PR** as its parent story, so
tests and feature can never drift apart.

- **Label.** `test-case` (green, `0e8a16`). `refine-issue` ensures it idempotently
  on spin-out.
- **Spin-out.** After the human approves a rewrite, `refine-issue` (Step 2.5)
  runs `development/skills/refine-issue/scripts/test-case-spinout.zsh` to
  reconcile the approved `test_cases[]` into `test-case` issues, then splices the
  returned issue links back into the block before write-back. One issue per case;
  the **body is generated from the spec entry** (`kind` · `tooling` · `shape` ·
  a `Parent story: #<N>` reference), stamped with a managed marker and a
  `<!-- test-case: story=<N> id=<id> -->` locator.
- **Identity + reconcile.** The stable `test_cases[].id` is the reconcile key.
  A re-refinement round: a new id creates an issue; an id already linked (via the
  prior block's `test_cases[].issue`) edits that issue in place; an id **dropped**
  since last round has its orphaned `test-case` issue **closed with an explanatory
  comment**. The `test_cases[].issue` field carries the link (`null` before
  spin-out, the issue number after).
- **Lifecycle — same PR, joint closure.** Test-case issues are implemented in the
  **same PR** as their parent story and closed together, one `Closes #N` per issue
  (`resolve-issue`, #577/#696). There is deliberately **no `blockedBy`** between a
  story and its test-case issues — same-PR closure makes ordering moot, so the
  dependency graph (#583) stays uncluttered by within-PR relationships.
- **Proportionality.** A **no-surface** story (`interface_surfaces: []`,
  `test_cases: []`) spins out nothing.

## Persona registry contract (`personas/v1`, #665)

A **persona registry** is a target repo's answer to *"who actually uses this
surface, and what do they type into it?"* It is an **advisory** readiness input
(who a story serves) and the source of **realistic test data** — the value
shapes refinement mines to generate `curl` / `grpcurl` / Playwright payloads
that look like real user input instead of `foo`/`bar`. This section defines the
`personas/v1` artifact: the file layout, the machine-readable schema, the five
persona kinds, the registry conventions, and the provenance mechanism that makes
staleness detectable. The `persona-definer` agent (#666) generates it and the
`/development:define-personas` skill (#667) writes it back; `story-readiness`
(advisory check) and `refine-issue` (data-trait mining) consume it (#668).

The artifact lives at **`docs/personas.md` in the target repo** — not in this
plugin repo, which has no product surface of its own. Seeding a starter registry
into new repos is an explicit follow-up, out of scope here.

### The registry file (`docs/personas.md`)

Same two-layer contract as `story-spec/v1` (#574): **prose is
human-authoritative**, and a collapsed `<details>` block carries the
machine-readable mirror the agents read. The authoritative persona prose is
fenced by two sentinel comments so the provenance hash (below) covers exactly
that region and nothing else — edits to the intro, the conventions blurb, or the
machine block never false-trip staleness:

````markdown
# Personas

<intro: what this file is, how to regenerate it, the conventions below>

<!-- personas:prose:start -->
## Dana, the field dispatcher (`dana-dispatcher`)

- **Kind:** end-user
- **Role:** logs jobs from a phone in a noisy depot, one-handed, in a hurry
- **Goals:** file a job in under 20 s; never lose a half-typed entry
- **Failure costs:** a dropped job = a truck sent to the wrong site
- **Proficiency:** fluent with the app, not technical; never reads docs
- **Context:** Android, spotty 3G, gloves on, glances not reads
- **Data traits:** job refs like `JOB-2291`; site names with accents and
  ampersands (`Müller & Sons`); notes pasted from SMS with emoji
- **Primary for:** mobile-job-entry

## Mallory, the scraper (`mallory-scraper`)

- **Kind:** adversarial
- ... (same fields) ...
<!-- personas:prose:end -->

<details>
<summary>🤖 machine-readable personas (<code>personas/v1</code>) — generated, do not hand-edit</summary>

<!-- the personas/v1 JSON block (schema below) goes here -->

</details>
````

### The `personas/v1` block

One fenced `json` object inside the `<details>` (example truncated to two
personas — a real registry has 3–7; `prose_sha256` is an illustrative digest,
not the hash of the prose shown above). Shape:

```json
{
  "schema": "personas/v1",
  "provenance": {
    "generated_by": "persona-definer via /development:define-personas",
    "generated_at": "2026-07-10T12:00:00Z",
    "prose_sha256": "9b2e0a1c4d6f83b5a7c9e1f3058d2a4b6c8e0f1a3b5d7c9e1f2a4b6c8d0e2f4a"
  },
  "personas": [
    {
      "id": "dana-dispatcher",
      "name": "Dana, the field dispatcher",
      "kind": "end-user",
      "role": "logs jobs from a phone in a noisy depot, one-handed, in a hurry",
      "goals": ["file a job in under 20 s", "never lose a half-typed entry"],
      "failure_costs": ["a dropped job = a truck sent to the wrong site"],
      "proficiency": "fluent with the app, not technical; never reads docs",
      "context": "Android, spotty 3G, gloves on, glances not reads",
      "data_traits": [
        { "field": "job_ref", "shape": "JOB-<4 digits>", "example": "JOB-2291" },
        { "field": "site_name", "shape": "unicode + ampersands", "example": "Müller & Sons" },
        { "field": "notes", "shape": "SMS-pasted text with emoji", "example": "on site 🚚 call gate" }
      ],
      "primary_for": ["mobile-job-entry"]
    },
    {
      "id": "mallory-scraper",
      "name": "Mallory, the scraper",
      "kind": "adversarial",
      "role": "automated client probing the public API for weaknesses",
      "goals": ["exfiltrate other tenants' jobs", "bypass rate limits"],
      "failure_costs": ["a successful probe leaks customer data"],
      "proficiency": "expert; scripts every request, reads error bodies",
      "context": "headless bot, rotating IPs, high request volume",
      "data_traits": [
        { "field": "job_ref", "shape": "SQLi / path-traversal payloads", "example": "JOB-1' OR '1'='1" },
        { "field": "site_name", "shape": "oversized + control chars", "example": "<40 KB of 0x00>" }
      ],
      "primary_for": []
    }
  ]
}
```

**Field contract.** Every persona object carries exactly these fields:

| Field | Type | Value |
| --- | --- | --- |
| `id` | string | stable kebab-case identifier, unique in the registry; **never renamed or reused** — `story-spec/v1.personas` references it |
| `name` | string | short human-readable label |
| `kind` | string | one of the five kinds (enum below) |
| `role` | string | who they are relative to the surface — one decision-bearing sentence |
| `goals` | string[] | ≥1 — what they are trying to accomplish |
| `failure_costs` | string[] | ≥1 — what it costs **this** persona when the system fails them (drives failure-mode prioritisation) |
| `proficiency` | string | technical proficiency *relative to this surface* (e.g. "backend dev integrating our API", "non-technical") |
| `context` | string | usage context — device, environment, frequency, pressure |
| `data_traits` | object[] | the realistic value shapes this persona produces; each `{ field, shape, example }`. Required (≥1) for any persona that produces input; `[]` only for a pure observer (e.g. a read-only operator) |
| `primary_for` | string[] | surface id(s) this persona is *primary* for; `[]` for a non-primary persona |

`data_traits[]` is the field refinement mines: `field` is the input
parameter/category name, `shape` its realistic pattern (format, length, locale,
edge characteristics), `example` a concrete representative value.

### Persona kinds

Five kinds, each earning its place by unlocking a class of design or test
decision the others miss:

| `kind` | Who | What it unlocks |
| --- | --- | --- |
| `end-user` | a human using the product UI/CLI directly | happy-path + realistic-input test data for the primary surface |
| `operator` | runs/deploys/monitors the system (SRE, admin) | operability, observability, and failure-recovery requirements |
| `api-consumer` | another team's developer integrating our API | the "user" is a developer; `data_traits` describe **request payloads**, not UI input |
| `negative` | a legitimate user who produces problematic-but-innocent input | robustness/validation cases — wrong formats, empty fields, huge inputs, unusual locales (no malice) |
| `adversarial` | an attacker deliberately probing for weaknesses | security corner cases — injection, auth bypass, malformed/oversized input |

`negative` and `adversarial` are distinct on purpose: the first hardens
validation against honest mistakes, the second against attacks. Include an
`adversarial` (and usually a `negative`) persona for any surface that accepts
untrusted input.

### Registry conventions

Baked into the schema so a registry stays useful, not decorative:

- **3–7 personas.** Fewer misses a real class of user; more is unmaintainable
  fluff.
- **One primary per surface.** Each surface has exactly one persona whose
  `primary_for` names it — the default voice a story is written for. Others may
  be secondary (`primary_for: []`).
- **No demographic fluff.** Age, gender, and location appear **only** when they
  change a design or test decision. The test for every field: *could this value
  change what we build or how we test it?* If not, cut it.
- **Cover the untrusted-input surfaces.** A surface that accepts external input
  gets at least an `adversarial` persona; developer-facing surfaces get an
  `api-consumer`.

### Provenance and staleness detection

The block is **generated from the prose**, so the prose can silently outrun it.
Provenance makes that detectable — the same mechanism `story-spec/v1` uses:

- **What is hashed.** The bytes strictly **between** the
  `<!-- personas:prose:start -->` and `<!-- personas:prose:end -->` sentinels —
  the authoritative persona prose, nothing else.
- **Normalisation (so the hash is reproducible).** Apply in this exact order:
  (1) convert line endings to `LF`; (2) strip trailing whitespace from each
  line; (3) drop leading and trailing **blank** lines, where "blank" means empty
  *after* step 2; (4) append exactly one trailing `LF`. Then take the SHA-256 of
  the resulting UTF-8 bytes, lowercase hex, stored as `provenance.prose_sha256`.
  The fixed order matters: an implementer who dropped blank lines before
  stripping trailing whitespace could hash a different byte string.
- **The check.** A consumer recomputes the hash over the current prose region and
  compares. **Match** → the block is in sync with its prose. **Mismatch** → the
  prose was hand-edited after generation; the block is **stale**, and the
  consumer flags it and routes the human to `/development:define-personas` to
  regenerate rather than trusting the drifted block.

This is the whole staleness machinery — no background job. The registry is
re-derived exactly when reality (the prose a human edited) contradicts the
generated mirror, on the next pull by a consumer.

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
| --- | --- | --- |
| **haiku** | Mechanical, deterministic transforms; no judgment | Apply `ruff check --fix`; bump pinned versions; remove unused imports |
| **opus** | Context-aware work; reads surrounding code to decide what fix is appropriate | Triage a Snyk finding (suppress vs fix); choose between refactor patterns; pick a `# nosemgrep` annotation; CI-failure triage |
| **fable** | High-stakes judgment; security-critical or architectural; cross-codebase migration | Decide if a vulnerability is exploitable; review whether a `# noqa` is justified; migrate a major dep version; apply a Python interpreter upgrade and structured-escalate when deps aren't ready |

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

```text
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
| --- | --- | --- |
| Major-version dep upgrade | 90% (matches the Zero Tolerance standard, enforced by the bootstrap-generated `coverage-floor` CI step) | 70% |
| All other changes (refactors, patch/minor bumps, sonar/semgrep/snyk fixes) | 80% | 60% |

Three branches per planned change, evaluated against the touched
modules' coverage (not whole-project coverage):

| Module coverage | Behavior |
| --- | --- |
| ≥ Required | Proceed with the change. |
| Floor ≤ coverage < Required | Agent runs `python-coverage-improver` first to bring affected modules up to Required, then makes the change. Adds tests only; never modifies production code under test. |
| < Floor | Refuse. Surface a `missing_tooling`-shaped recommendation pointing at the standalone `/development-python:improve-test-coverage` skill (issue #35). The user invests in coverage deliberately, then re-runs maintenance. |

#### Region-scoped gate (Swift — epic #462)

The whole-file model above measures coverage of the **touched module**.
`development-swift` refines it to the **enclosing function**: each
coverage-respecting finding (`sonarcloud`, a file-bearing `code_scanning`
alert) resolves to the function containing its line — via the per-function
`coverage.regions` the Swift gather emits — and is gated against a **single
Required threshold (80%)**, with whole-file fallback when a finding maps to
no function. The unit being the function means a 40%-covered file is fine to
refactor inside a well-tested function, and a 95%-covered file is correctly
blocked at its one untested function. It also collapses the Floor/Required
tiers (a single function is small enough to reach Required in one improver
pass) and removes the dead-end where bootstrapping a from-zero class to a
Floor never cleared the finding's Required bar. The `swift-coverage-improver`
is correspondingly **function-scoped**. **Java** (#466) and **Python** (#467)
adopt the same gate for their refactor findings — the `*-coverage-improver`
takes a method/function-scoped entry, while a *major dependency upgrade* (which
has no per-finding line) keeps the whole-class/module Floor/Required scan. With
all three languages done, the region-scoped gate is the family-wide model; the
whole-file thresholds above remain only for the major-upgrade path.
**Adding region coverage to a new language** follows a fixed vertical (parser
emits `regions[]` → gather → dispatcher containment → function-scoped improver
→ docs), with only the parser's per-tool data source differing — see the
**Per-language playbook** in
`docs/superpowers/specs/2026-06-29-coverage-safety-signal-design.md`.

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

The earlier "haiku / opus / fable by task character" table still
holds, with two refinements:

- **Major-version dep upgrades use fable.** Reading release notes,
  identifying breaking changes, applying migrations across the
  codebase, and verifying against tests is exactly fable's strong
  suit. Don't try this on opus.
- **Coverage improvement uses fable.** Writing meaningful tests
  (not just line-touching tests that pass false-confidently) requires
  understanding intent. Mechanical test-writing is worse than no test
  because it creates a false safety floor.

### Major-version upgrades, end to end

The hard case. Flow:

1. `python-dependabot-snyk-triage` (opus) classifies the Snyk Fix-PR
   or Dependabot PR as a major bump; dispatcher routes it to
   `python-major-upgrade` (fable). (For CVEs surfaced through Code
   Scanning / CodeQL rather than a PR, `python-code-scanning-triage`
   defers to the existing PR flow via `actions_requiring_review`.)
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
reads, test runs, possibly fable on the major-upgrade branch). This
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

## Line-length policy

**Every formatter and linter we configure targets 120 columns** — one limit
across the whole toolchain so reviewers and contributors never fight per-tool
widths. When we add a new language, set 120 from the start.

Per-language state (templates under
`development/skills/bootstrap/templates/languages/`):

| Language   | Tool                          | Limit | Notes |
|------------|-------------------------------|-------|-------|
| Python     | ruff (`ruff.toml.tmpl`)       | 120   | `line-length = 120`. |
| TypeScript | ESLint (`.eslintrc.json`)     | 120   | `max-len` warning at 120 (URLs/strings/template-literals exempt). |
| Swift      | SwiftLint (`.swiftlint.yml`)  | 120   | `line_length: warning 120`. |
| Go         | golangci-lint (`.golangci.yml`) | —   | **Exemption.** `gofmt` does not wrap lines and Go convention avoids line-length linting; the `lll` linter is intentionally not enabled. |
| Java       | Spotless → google-java-format | 100   | **Exemption.** google-java-format is hardcoded to 100 columns and is not configurable; we keep it (do not switch to palantir-java-format). |

When a tool genuinely cannot do 120 (google-java-format), document the
exemption explicitly here and in the template rather than leaving a silent
mismatch.

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
- `development/skills/bootstrap/docs/CLAUDE-APPS.md` — GitHub App registration
  and setup for both Maintenance and Approver identities.
- `development/skills/bootstrap/docs/APPROVER-APP.md` — detailed design of the
  decentralized Approver: app registration, installation, token minting, permissions.
- `development/skills/bootstrap/scripts/register-claude-apps.zsh` — user-facing
  script to register and store local GitHub App credentials.
- `development/skills/maintenance/scripts/mint-approver-token.zsh` — invoked by
  approve skills to mint fresh Approver tokens from local Keychain.
- `development/skills/bootstrap/SKILL.md` — the most detailed example
  of a generic skill; references the conventions in this document.
