# Plugin overview

A narrative tour of each plugin — what it's for, its policies, and how the
pieces compose. For the *why* behind splitting these per language, see
[Why per-language plugins?](../explanation/why-per-language-plugins.md).

> **Looking for the exhaustive, always-current listing?** The
> [Commands](commands.md) and [Agents](agents.md) pages are **generated from
> the skill/agent frontmatter** and diff-checked in CI, so they can never drift
> from the code. This page is the hand-written overview; those are the
> authoritative reference.
>
> **Adding support for a new language?** See
> [Add a language plugin](../adding-a-language-plugin.md) — the consolidated
> guide for taking the maintenance pipeline from "doesn't know about language
> `L`" to a full-maintenance `development-<L>` plugin (the pattern proven by the
> Java and Swift epics).

## development

Language-agnostic workflow tooling for git operations, committing, and branch management.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Bootstrap | `/development:bootstrap` | Sets up the full quality + security toolchain. Public repos get SonarCloud + Snyk + CodeQL; private repos get self-hosted SonarQube + Trivy + a self-hosted runner. Generates pre-commit hooks, Dependabot config, issue/PR templates, branch protection, and the **Zero Tolerance standard** (≥90% new-code coverage, 0 code smells, all A ratings) enforced via a layered model: a `coverage-floor` CI step + a `diff-cover` pre-push hook + the configured Sonar gate. The Sonar gate uses a custom Quality Gate on paid SonarCloud / self-hosted SonarQube; on SonarCloud free (where custom-gate assignment is paywalled) it falls back to `Sonar way` and the CI step remains the real 90% enforcement. On macOS, automation scripts handle SonarCloud / SonarQube / Snyk setup, secret storage, gate configuration, and runner registration. Idempotent — safe to re-run. **Requires macOS + Homebrew** (see [Requirements](requirements.md)). |
| Maintenance | `/development:maintenance [--dry-run] [--no-merge]` | Orchestrator. Runs detection + per-tool findings gathering + coverage measurement, constructs the JSON payload, dispatches to the matching language plugin (`development-python`, `development-java`, `development-swift`) and any topic plugins (`development-spring`, `development-claude-plugin`), collects results, and merges worktree branches back to the user's current branch. Effective entry point for "go fix everything safely fixable on this project." `--dry-run` prints the payload without dispatching; `--no-merge` leaves the worktree branches available for manual merge. |
| Commit | `/development:commit [message]` | Runs formatting/linting (delegates to language-specific plugin), generates a commit message, ensures a feature branch, and commits |
| Resolve Issue | `/development:resolve-issue <issue#\|epic#>` | Takes a filed issue (or an epic of issues) and drives it to a merge-ready, **bot-authored** PR: dependency precheck (GitHub-native `blockedBy`; rejects on open blockers, refuses cycles, offers guided remediation interactively — epic #583) → readiness gate → branch off fresh main → implement → validate (tests must be green) → commit → `open-pr` (Maintenance-App-authored, auto-merge armed). For an epic: decomposes the children, orders them conflict-aware (sequential-by-default, disjoint-only parallel worktrees), tests each before merge, then runs a holistic end-to-end test over the merged epic. Repo-type-agnostic (Python / Java / Claude-plugin). |
| Refine Issue | `/development:refine-issue <issue#>` | **Interactive** — drives a `needs-refinement` issue back to READY. Diagnoses via the readiness gate, then loops the `issue-refiner` agent with you (explanation → questions → recommendations → a prose rewrite → a proposed `story-spec/v1` block, with outside-in test cases mined from the repo), writes back the **human-approved** prose + block (a human-authored issue edit, not a bot PR), re-gates, and clears the label only on READY. Spins out linked `test-case` issues for a surface-touching story's outside-in cases; takes a typed parked exit when a session can't converge; pointed at an **epic**, walks each `needs-refinement` child and posts an epic summary. |
| Define Personas | `/development:define-personas` | **Interactive** — creates or updates a repo's `personas/v1` registry (`docs/personas.md`): who actually uses each surface and what they type into it. Loops the `persona-definer` agent with you (repo-grounded candidate personas + Socratic questions), then writes back the **human-approved** prose + machine block to the working tree (lands via the normal PR flow). The registry feeds `refine-issue`'s realistic test-data generation and the readiness gate's advisory persona-reference check. |
| Git Branch Naming | `/development:git-branch-naming` | Defines the branch naming convention (`<type>/<issue>-<description>`) and creates properly named branches |
| Open PR | `/development:open-pr` | Opens a PR for the current branch **authored by the Claude Maintenance bot** — so you can approve it (GitHub blocks self-approval) — with squash auto-merge armed; falls back to a user-authored PR when the writer App isn't installed |
| Library Docs | `/development:library-docs` | Ensures work proceeds from current, authoritative docs for any library / framework / CLI / API in scope rather than stale training-data guesses |
| Cleanup | `/development:cleanup` | Tidies the local git environment after a merge — prunes stale remote-tracking branches and deletes local branches already merged into `main` |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| Commit Message | opus | Generates clear commit messages from diffs, ignoring formatting/linting noise |
| Bootstrap Security Reviewer | fable | Reviews planned workflows for GH Actions permissions, secret refs, self-hosted runner safety, scan-before-push gates |
| Bootstrap Config Consistency | opus | Cross-references Sonar keys, workflow job IDs ↔ branch-protection contexts, language fragments ↔ detected languages |
| Bootstrap Idempotency Reviewer | opus | For each existing file conflicting with a template, recommends skip/overwrite/merge |
| Bootstrap Validator | haiku | Fast post-write check — YAML/JSON parses, no unresolved placeholders, cross-references resolve |
| Bootstrap Reviewer | opus | Optional senior-engineer review of the full bootstrap output (`--review` flag) |
| Story Readiness | opus | Readiness gate for `/development:resolve-issue` — judges whether a story is specified well enough to build (testable acceptance, bounded scope, resolved dependencies) and emits a low/normal/elevated risk classification. Classifies the runtime `surface` and, for surface-touching stories, hard-requires outside-in `use_case` + `test_cases` (interface-aware check 5, #670). Also emits a proposed `story-spec/v1` block for READY stories and non-blocking advisories (e.g. persona-reference validation against the repo's `personas/v1` registry); verdict JSON only |
| Review Consolidator | opus | Consolidates one review round's findings into a single prioritised changelist for the `resolve-issue` local review loop (dedup, blocking classification, conflict + non-convergence detection); changelist JSON only |
| Issue Refiner | opus | Per-turn refinement engine for `/development:refine-issue` — turns the gate's objections + a human reply into a why-not-ready explanation, questions, recommendations, a prose rewrite, and a proposed `story-spec/v1` block (mining the repo for outside-in test cases, drawing realistic payloads from persona `data_traits`); pure function, no writes |
| Persona Definer | opus | Per-turn elicitation engine for `/development:define-personas` — proposes repo-grounded candidate personas, asks Socratic questions to extract tacit knowledge, and returns a draft `personas/v1` registry update; challenges gaps (missing kinds, uncovered surfaces) rather than only confirming; pure function, no writes |

## development-swift

Swift maintenance — a **full-maintenance tier**, mirroring `development-python`
/ `development-java` (epic #297). Triages and fixes findings from the Swift
toolchain `/development:bootstrap` installs (swift-format, SwiftLint,
SonarCloud, CodeQL + Scorecard), reviews Dependabot / Snyk vendor PRs, applies
SwiftPM dependency-major and Swift-toolchain upgrades, raises code coverage,
migrates to the Swift 6 language mode, and reviews PRs as the Claude Approver.
Pure function of its JSON input — dispatched by `/development:maintenance`; it
runs no detection of its own. (semgrep is deferred for Swift — its rule
registry is empty, per [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).)

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Maintenance dispatcher | `/development-swift:maintenance <json>` | Validates the payload, runs the coverage pre-flight (may raise coverage first), plans the per-tool groups, returns the plan + `ci_fixer_agent`. |
| Approve | `/development-swift:approve [<pr>]` | Runs `swift-approver` against an open PR and posts the verdict as the Claude Approver identity (same agent as CI). |
| Review | `/development-swift:review [paths]` | Spawns 6 specialized agents in parallel to analyze bugs, security, performance, Swift 6 compliance, code quality, and test coverage |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| swift-format-lint-fixer | haiku | `swift format` + SwiftLint autofixes; behaviour-preserving |
| swift-sonar-triage | opus | SonarCloud (Sonar Swift) bugs/smells/vulns/hotspots; LSP-scoped |
| swift-code-scanning-triage | opus | CodeQL (Swift) + Scorecard; pins GH Actions to SHAs; dataflow rules → human-review |
| swift-dependabot-snyk-triage | opus | Vendor PRs: dedup, digest-refresh verify, auto-merge green patch/minor (never self-approves) (#446) |
| swift-major-upgrade | fable | SwiftPM dependency majors — release notes + LSP call-site migration + `swift test` (#446) |
| swift-runtime-upgrade | fable | Swift toolchain bumps — pin swap, dep cascade, guide-licensed adaptations (#447) |
| swift-coverage-improver | fable | Writes meaningful XCTest / Swift Testing tests to raise coverage; never edits production code |
| swift6-compliance | fable | Strict concurrency, typed throws, modern syntax — review mode; also the v6 language-mode migration agent (migrate mode, #447) |
| swift-maintenance-planner | opus | Ranks + groups findings, routes each to its agent |
| swift-ci-fixer | opus | Fixes a failing CI run on a maintenance PR (build/test, format, coverage) |
| swift-approver | fable | Synthesis-layer PR reviewer once CI is green; risk register fed by the five review dimensions (#448) |
| swift-lint-format | haiku | Runs SwiftFormat and SwiftLint, fixes issues in-place |
| bug-hunter | fable | Logic errors, nil crashes, race conditions, stability |
| security-reviewer | fable | Secrets, injection, insecure storage, ATS, keychain |
| performance-reviewer | opus | Retain cycles, allocations, O(n²), main thread blocking |
| code-quality | opus | Naming, SOLID, readability, dead code, API design |
| test-reviewer | opus | Coverage gaps, assertion quality, flaky tests |

## development-python

Python-specific maintenance — triages and fixes findings produced by the
toolchain `/development:bootstrap` installs (ruff, semgrep, Snyk Code,
Snyk Open Source, SonarCloud), and autonomously applies dependency
upgrades (patch + minor + major) with test-based verification.

Pure function of a JSON input per
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)
— it does not run detection itself; the `/development:maintenance` orchestrator constructs the
input and dispatches here.

> ⚠️ **Cost expectations**: These agents deliberately favor autonomy
> over speed and token cost. They read code with LSP (find references,
> type info, public-API detection), fetch release notes from the web for
> major upgrades, run the project's test suite in their isolated
> worktrees, and iterate up to 3 times on test failures before escalating.
> A maintenance run on a non-trivial project can consume tens of thousands
> of tokens; on a project with major-version CVEs requiring fable-driven
> migration, more. The trade is intentional — see ARCHITECTURE.md's
> "Maximizing autonomy" section.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Maintenance dispatcher | `/development-python:maintenance <json>` | Parses input, runs coverage pre-flight, spawns per-tool agents in parallel worktrees, aggregates results. Standalone invocation prints usage and stops. |
| Approve | `/development-python:approve [<pr>]` | Runs `python-approver` against an open PR and posts the verdict as the Claude Approver identity (same agent as CI) |
| Improve Test Coverage | `/development-python:improve-test-coverage` | Raises coverage toward a target by spawning `python-coverage-improver` agents in parallel worktrees — deliberate investment outside the maintenance pipeline |
| Review | `/development-python:review [paths]` | Spawns 5 specialized review agents in parallel — bugs, security, performance, code quality, tests (#449) |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| python-ruff-fixer | haiku | `ruff check --fix` (safe) + `ruff format` + `--unsafe-fixes` with test verification |
| python-semgrep-triage | opus | Per-finding: fix (refactor) / suppress (`# nosemgrep` + reason); LSP-driven scope check; only escalates when public API changes |
| python-code-scanning-triage | opus | CodeQL + Scorecard alerts: pins GH Actions to commit SHAs (Scorecard `PinnedDependenciesID`), removes unused globals / ineffectual statements (CodeQL `py/unused-*`); defers dataflow rules (`py/path-injection`, `py/sql-injection`, etc.) to human-review with concrete recommendations; surfaces process-policy findings (`MaintainedID`, `CodeReviewID`) as informational. Replaces deprecated `python-snyk-triage` per #87. |
| python-sonar-triage | opus | SonarCloud bugs/smells/vulns; security hotspots investigated context-first, not punted by default |
| python-major-upgrade | fable | Reads official release notes via WebFetch; maps breaking changes to call sites via LSP; applies migration; iterates up to 3 times on test failures |
| python-runtime-upgrade | fable | Applies a Python interpreter bump (Dependabot's `python:X.Y → Z.W` Docker base-image PR). Swaps Dockerfile FROM and pyproject.toml `requires-python`; best-effort local verify; **cascade-upgrades dependencies** that need newer versions for the new interpreter, reading their release notes and applying migrations (up to 3 passes). Stops only when a required dep has no version on PyPI supporting the new Python — does NOT search for alternative libraries |
| python-coverage-improver | fable | Brings under-covered modules up to threshold by writing meaningful behavior tests; never modifies production code |
| python-dependabot-snyk-triage | opus | Reviews each open Dependabot PR; auto-approves + merges patch + minor bumps with green CI (after scanning release notes for breaking-change flags); defers majors and red-CI PRs to human-review |
| python-container-cve-triage | opus | Triages Snyk container / base-image CVEs — pins apt packages installed by our Dockerfile when a fix exists; recommends-only for base-image bumps (cross-links the Dependabot docker path); proposes a justified 90-day `.snyk` ignore when no upstream fix exists (reviewable PR, never auto-merged) |
| python-maintenance-planner | opus | Ranks + groups findings, routes each to its agent (one tool's findings stay together) |
| python-ci-fixer | opus | Fixes a failing CI run on a maintenance PR (pytest, ruff, coverage) |
| python-bug-hunter | fable | Logic errors, None-handling crashes, mutable defaults, async races, swallowed exceptions (#449) |
| python-security-reviewer | fable | Secrets, injection, unsafe deserialization, TLS verification, data exposure (#449) |
| python-performance-reviewer | opus | Accidental O(n²), event-loop blocking, N+1 I/O, unbounded caches (#449) |
| python-code-quality | opus | Naming, SOLID, readability, dead code, API design (#449) |
| python-test-reviewer | opus | Coverage gaps, assertion quality, flaky tests, mock misuse (#449) |

All worktree-modifying agents run their fixes through the project's
test suite locally before declaring success. CI is the secondary
safety net, not the primary verification loop.

## development-java

Java/Gradle maintenance — the **full-maintenance tier**, mirroring
`development-python`. Triages and fixes findings from the Gradle toolchain
`/development:bootstrap` installs (Spotless, SonarCloud, CodeQL + Scorecard,
semgrep), reviews Dependabot / Snyk / Renovate vendor PRs, applies
dependency-major and JDK-LTS upgrades, raises JaCoCo coverage, flags
versioning risks, and reviews PRs as the Claude Approver. Pure function of its JSON input — dispatched by
`/development:maintenance`; it runs no detection of its own. **Adding it
required zero edits to the generic orchestrator** (discovered purely via the
gather-script + dispatch contract).

> **Build policy: Gradle + Kotlin DSL only.** The Java/Spring plugins
> maintain exactly one blessed build format — `build.gradle.kts`. Maven
> (`pom.xml`) isn't supported, and a Groovy `build.gradle` must be converted
> to Kotlin DSL first: `/development:bootstrap` offers a confirmed conversion,
> and `/development:maintenance` **refuses to run** on a Groovy/Maven build
> until it's done. One format, nothing to choose. (The Maven *artifact
> ecosystem* — Maven Central, `mavenCentral()` — is unaffected; only the
> build tool is.) See ARCHITECTURE.md § "Build policy".

**Skills:**

| Skill | Command | Description |
| --- | --- | --- |
| Maintenance dispatcher | `/development-java:maintenance <json>` | Validates the payload, runs the JaCoCo coverage pre-flight (may raise coverage first), plans the per-tool groups, returns the plan + `ci_fixer_agent`. |
| Approve (local dry-run) | `/development-java:approve [<pr>]` | Runs the `java-approver` against an open PR locally — prints the verdict instead of posting. |
| Review | `/development-java:review [paths]` | Spawns 5 specialized review agents in parallel — bugs, security, performance, code quality, tests (#449) |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| java-format-lint-fixer | haiku | `./gradlew spotlessApply` (google-java-format); behaviour-preserving |
| java-sonar-triage | opus | SonarCloud bugs/smells/vulns/hotspots (`java:Sxxxx`); LSP-scoped; `// NOSONAR` for justified accepts |
| java-code-scanning-triage | opus | CodeQL (Java) + Scorecard; pins GH Actions to SHAs; dataflow rules → human-review |
| java-semgrep-triage | opus | semgrep: fix / `// nosemgrep` suppress / escalate; SQL concat → `PreparedStatement` |
| java-dependabot-snyk-triage | opus | Vendor PRs (Dependabot / Snyk / Renovate): auto-merge green patch/minor (never self-approves); defers majors + docker to the right handler |
| java-major-upgrade | fable | Gradle dependency majors — release notes + LSP call-site migration + `gradle build` |
| java-runtime-upgrade | fable | JDK LTS bumps (Docker base image) — swaps the Gradle toolchain + wrapper, cascades JDK-sensitive deps |
| java-coverage-improver | fable | Writes meaningful JUnit tests to raise JaCoCo coverage; never edits production code |
| java-versioning-advisor | opus | Flags a hardcoded `version` (a SemVer risk); recommends build-driven versioning (nebula-release) |
| java-grpc-advisor | opus | Audits gRPC/protobuf code generation — the `com.google.protobuf` Gradle plugin generating Java + gRPC stubs from the authoritative `.proto` contract; recommends excluding generated sources from coverage |
| java-openapi-advisor | opus | Audits **non-Spring** contract-first OpenAPI — openapi-generator's `jaxrs-spec` (Jakarta REST) generator from a committed spec, so code/spec drift fails the build (the Spring case is `development-spring`'s `spring-api-advisor`) |
| java-maintenance-planner | opus | Ranks + groups findings, routes each to its agent (defers `org.springframework.boot` bumps to `development-spring`) |
| java-ci-fixer | opus | Fixes a failing CI run on a maintenance PR (Gradle build/test, Spotless, JaCoCo) |
| java-approver | fable | Synthesis-layer PR reviewer once CI is green (mirrors `python-approver`); risk register fed by the five review dimensions (#449) |
| java-bug-hunter | fable | Logic errors, NPEs, `==` vs `equals`, resource leaks, race conditions (#449) |
| java-security-reviewer | fable | Secrets, injection, unsafe deserialization, TLS validation, data exposure (#449) |
| java-performance-reviewer | opus | Accidental O(n²), allocation pressure, N+1 I/O, lock contention, unbounded caches (#449) |
| java-code-quality | opus | Naming, SOLID, readability, dead code, API design (#449) |
| java-test-reviewer | opus | Coverage gaps, assertion quality, flaky tests, mock misuse (#449) |

**API-style convention.** gRPC is the standard for **internal, inter-service
communication** — efficient on the wire, low-latency, with bidirectional /
parallel streaming. **Public endpoints for external users get REST APIs**
(OpenAPI). The advisors are split to match: `java-grpc-advisor` governs the
internal-comms contract (`.proto`), `java-openapi-advisor` (and, for Spring,
`spring-api-advisor`) governs the public REST contract (OpenAPI) — and the
gather routes a repo to exactly one OpenAPI advisor based on whether it's a
Spring web app.

**Build-driven semantic versioning:** `/development:bootstrap` emits a
`release.yml` whose default `auto` scope runs `derive-release-scope.zsh` to
derive the SemVer bump from the Conventional Commits since the last tag
(breaking → major, `feat` → minor, else patch) and cuts a nebula-release
version — no manual bump, SemVer obeyed automatically. The agent contract is
documented in
[`development-java/docs/java-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-java/docs/java-approver.md).

## development-spring

A **topic plugin** for **Spring Boot 4+** projects. It **composes alongside
`development-java`** (per
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md))
— it holds zero Java-foundation logic, only dispatches when both Java and Spring
markers are present, and
reuses `java-ci-fixer` for its CI cycle. Audits Spring configuration, owns
Spring Boot version upgrades, configures container images, and gates the API
contract.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Maintenance dispatcher | `/development-spring:maintenance <json>` | Routes Spring findings to their advisor; returns the plan (with `ci_fixer_agent: "java-ci-fixer"`). |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| spring-config-advisor | opus | Relocates deprecated/relocated Spring Boot 4 config keys; flags actuator over-exposure (human-review) |
| spring-boot-upgrade | fable | Owns Spring Boot version bumps end-to-end (config relocations + removed-API fixes per the migration guide); `development-java` defers `org.springframework.boot` bumps here |
| spring-container-advisor | opus | Audits `bootBuildImage` (Cloud Native / Paketo Buildpacks) config — pinned builder/run-image, image name, publish; JVM mode (native-image deferred) |
| spring-api-advisor | opus | Contract-first API drift gate: a committed OpenAPI spec + openapi-generator Spring interfaces, so code/spec drift fails the build |

Scope: **Spring Boot 4+** (baseline Spring Framework 7 / Jakarta EE 11) —
older Boot lines and the `javax`→`jakarta` migration are out of scope.

## development-claude-plugin

Topic plugin for projects that **are** Claude Code plugins (marker: a
`.claude-plugin/` dir with `plugin.json` or `marketplace.json`). It composes
*alongside* language plugins rather than replacing them — `/development:maintenance`
dispatches to both when a repo matches (this repo is a Claude plugin; a plugin
repo that is also Python gets both dispatchers).

**What's built:** the test harness, the review panel
(`/development-claude-plugin:review` — five read-only agents, the step-3.5 panel
for plugin repos, epic
[#810](https://github.com/timo-jakob/timos-claude-code-plugins/issues/810)), plus
the maintenance dispatcher with its five
validators — `claude-plugin-version-sync` (`plugin.json` ↔ `marketplace.json`
version drift), `claude-plugin-skill-validator` (SKILL.md / agent frontmatter
contract), `claude-plugin-reference-checker` (orphaned slash-command / agent
references), `claude-plugin-structure-validator` (plugin directory layout), and
`claude-plugin-script-quality` (shell-script lint — shellcheck / `zsh -n` /
shebang consistency). Behavioral script tests and the primary/auxiliary model are
designed in [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263).

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Test harness | `/development-claude-plugin:test [--target <path>] [--task "<prompt>"] [--expect "<text>"]` | Exercises a plugin's real behaviour end-to-end. A fresh-context judge subagent drives a *separate* headless `claude` session — local plugins loaded via `--plugin-dir`, run against an isolated clone of the target repo — and returns a structured `PASS`/`FAIL` verdict plus a transcript digest, without flooding the authoring context. See [`docs/test-harness.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-claude-plugin/docs/test-harness.md). |
| Review panel | `/development-claude-plugin:review [scope]` | Comprehensive plugin-content review with 5 parallel read-only agents (prose logic, contract integrity, script quality, tests, manifests). The step-3.5 review panel for claude-plugin repos (dispatched once the fallback `repo_type` lands, epic [#810](https://github.com/timo-jakob/timos-claude-code-plugins/issues/810)); also invocable standalone. Emits #558-schema findings to a machine-readable findings file alongside the prose report; measured against the #798 golden fixture. |
| Maintenance dispatcher | (dispatch target of `/development:maintenance`) | Topic dispatcher. Validates plugin conventions and returns a plan routing each finding group to a validator agent. No language coverage gate (a script-quality gate is planned, [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263)). Validates version sync, SKILL.md/agent frontmatter, orphaned references, directory layout, and shell-script quality. |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| claude-plugin-version-sync | haiku | Syncs `marketplace.json` version entries to each plugin's `plugin.json` (the source of truth); escalates add/remove-entry decisions to human review |
| claude-plugin-skill-validator | opus | Triages SKILL.md / agent frontmatter findings (missing/invalid `name`/`description`/`model`/`tools`, empty body); fixes name-to-location mismatches, escalates authored-content gaps |
| claude-plugin-reference-checker | opus | Triages orphaned `/<plugin>:<skill>` and agent references; fixes clear typos of a defined name, escalates removed-target / planned-work cases |
| claude-plugin-structure-validator | opus | Triages plugin directory-layout findings (missing/misnamed `plugin.json`, wrong `skills/`-`agents/` layout, marketplace `source` mismatch); fixes source paths, escalates file moves / identity renames |
| claude-plugin-script-quality | opus | Triages shell-script lint (shellcheck error/warning, `zsh -n` syntax, shebang/extension mismatch); applies verified safe fixes + justified suppressions, escalates renames and behavior-changing rewrites |
| claude-plugin-prose-logic | fable | Review panel, `prose_logic` dimension: skill/agent instructions as behaviour — missing failure branches, contradictions, model-ambiguous rules; severity bounded by the behavioural bar (no `>= WARNING` without naming the concrete wrong action) |
| claude-plugin-contract-integrity | opus | Review panel, `contract` dimension: dangling skill/agent/script references, prose-vs-script flag/subcommand drift, ARCHITECTURE.md schema drift |
| claude-plugin-script-reviewer | fable | Review panel, `script_quality` dimension: zsh logic review — exit codes, quoting, error paths, unhandled failure modes (not a shellcheck re-run) |
| claude-plugin-test-reviewer | opus | Review panel, `tests` dimension (core dimension reused): bats coverage for changed scripts, weak assertions, untested failure branches |
| claude-plugin-manifest-check | sonnet | Review panel, `manifest` dimension: `plugin.json` ↔ `marketplace.json` lockstep + semver bump appropriateness |

> ⚠️ **Cost**: a full maintenance run as a test is a real autonomous
> child session (tens of thousands of tokens). Narrow `--task` to one
> tool + `--dry-run` for cheap iteration, or use the no-arg plumbing
> smoke test to verify plugin loading first.

## development-docs

Topic plugin for **documentation** (marker: a `docs/architecture/` directory —
language-agnostic, so it composes with any language or none). Like the other
topic plugins, `/development:maintenance` dispatches to it *alongside* the
language plugin when a repo matches.

**What's built (v1):** the plugin skeleton and its maintenance **dispatch
path** — nothing more. The dispatch table is deliberately empty: this plugin was
stood up ([#801](https://github.com/timo-jakob/timos-claude-code-plugins/issues/801))
so the `c4_drift` finding source (declared C4 containers vs detected reality) can
land as *one tool* rather than a whole plugin. Its gather
(`gather-docs-findings.zsh`) and first tool arrive in
[#793](https://github.com/timo-jakob/timos-claude-code-plugins/issues/793); until
then the `docs` topic reports as an unsupported topic (marker present, no gather
yet) and the dispatcher is not on the dispatch path. Future docs-site and
docs-freshness tooling will live under this one topic.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Maintenance dispatcher | (dispatch target of `/development:maintenance`) | Topic dispatcher for documentation findings. Validates the v2 payload and returns a plan routing each finding group to a docs agent. Empty dispatch table in v1 — always an empty plan until [#793](https://github.com/timo-jakob/timos-claude-code-plugins/issues/793) registers `c4_drift`. |
