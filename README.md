# Claude Code Plugins

A collection of plugins for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Motivation

This repo exists to bootstrap new projects in no time and ship features and
applications that are high quality — both for the user experience and inside
the code — and that are secure by default. Across all of it, the goal is to
use Claude for maximum automation, pulling a human into the loop only when
human judgment is genuinely required.

I believe that in one or two years AI — and especially Claude — will be
capable enough that human-in-the-loop will be needed even more rarely in a
context like this. So this repo prepares for that now: build the seams,
gates, and policies today so that as the model gets stronger, the share of
work it can safely close out without a human grows automatically.

### How the plugins implement this today

What is shipped and aligned with the motivation:

- **Bootstrap installs the full Zero Tolerance toolchain by default.**
  `/development:bootstrap` doesn't ask which gates you want — ruff, mypy,
  semgrep, Sonar, Snyk, CodeQL, the 90 % new-code coverage floor, branch
  protection, and signed commits all land in one run. That is the
  "fast bootstrap + quality + security baked in by default" half of the
  motivation.
- **Maintenance is policy-driven, not narration-driven.**
  `/development:maintenance` is a JSON-dispatch contract to the language
  plugin. Each per-tool agent fixes what it can, suppresses with a written
  justification when the pattern is a false positive, and only escalates to
  a human when a public-API change would be required. That matches the
  "automate everything safely fixable, escalate only on judgment" half.
- **Dependabot / Snyk triage merges what is safe — once approved.**
  `python-dependabot-snyk-triage` merges patch + minor bumps when CI is
  green and an approving review exists (from `claude-approver[bot]` or a
  human); otherwise it arms GitHub's native auto-merge. It never posts
  approvals itself (#224). Deduplication keeps Snyk and Dependabot from
  stepping on each other when both target the same package.
- **Worktree isolation + local test verification.** Every agent that
  modifies code runs the project's test suite *locally* in its worktree
  before declaring success. CI is the secondary safety net, not the primary
  verification loop — exactly the shape that makes raising automation safe
  as models improve.
- **The Approver.** The motivation's "movable seam." Two distinct
  GitHub Apps, in-repo policy file, author allowlist, per-type
  criteria, hidden-JSON re-ingest into `/development:maintenance`.
  Phases 0–3 are shipped (App registration, bootstrap install, workflow
  - policy + PR templates, the `python-approver` fable agent); Phases
  4–6 (maintenance re-ingest, local `/approve`, end-to-end validation)
  remain. The Python library-exports API-stability gate (`griffe` +
  version-bump bypass) is also shipped and couples into the Approver's
  per-type rules. See "Claude Approver" below for the design and the
  current ship-status table.
- **Autonomous story delivery — readiness gate + local review loop.**
  `/development:resolve-issue` runs a **story-readiness gate** before any code is
  written (testable acceptance, bounded scope, resolved dependencies, plus a
  risk classification — [#559](https://github.com/timo-jakob/timos-claude-code-plugins/issues/559)),
  then a **local, pre-push review loop**
  ([#562](https://github.com/timo-jakob/timos-claude-code-plugins/issues/562)):
  the language review panel is invoked **diff-scoped**
  ([#560](https://github.com/timo-jakob/timos-claude-code-plugins/issues/560)),
  emits **machine-readable findings**
  ([#558](https://github.com/timo-jakob/timos-claude-code-plugins/issues/558)),
  and a **consolidator** turns them into one prioritised changelist
  ([#561](https://github.com/timo-jakob/timos-claude-code-plugins/issues/561)).
  The loop fixes blockers and re-reviews up to three rounds, so a PR is only
  opened — and CI minutes only spent — on code the panel has already converged
  on. Convergence attaches a **review dossier** the Approver re-ingests
  ([#563](https://github.com/timo-jakob/timos-claude-code-plugins/issues/563));
  every non-converged exit is a **typed `needs-human-decision` escalation** with
  no draft PR
  ([#564](https://github.com/timo-jakob/timos-claude-code-plugins/issues/564));
  each run appends **JSONL telemetry**
  ([#566](https://github.com/timo-jakob/timos-claude-code-plugins/issues/566)).
  The epic flow drives all children in one invocation, halting only on those
  escalations
  ([#565](https://github.com/timo-jakob/timos-claude-code-plugins/issues/565)).
  Epic [#557](https://github.com/timo-jakob/timos-claude-code-plugins/issues/557),
  validated end-to-end on the `ai-doc-organizer` test bed
  ([#567](https://github.com/timo-jakob/timos-claude-code-plugins/issues/567)):
  a well-specified story ran gate → review loop → dossier PR → Approver →
  auto-merge; an underspecified one halted at the readiness gate; and a
  security-conflicted one escalated to `needs-human-decision` with no PR.
- **Dependency-aware resolve-issue — GitHub-native `blockedBy` as the enforced
  source of truth.** Before the readiness gate or any branch, a **dependency
  precheck** walks the issue's native blocked-by graph transitively
  ([#584](https://github.com/timo-jakob/timos-claude-code-plugins/issues/584))
  and rejects on open blockers — autonomous runs post an argumentation
  comment plus the `blocked` label and **never auto-chain**
  ([#585](https://github.com/timo-jakob/timos-claude-code-plugins/issues/585));
  interactive runs offer **guided remediation** (resolve blocker + named issue,
  or just the blocker; deepest-first, one PR per blocker
  — [#586](https://github.com/timo-jakob/timos-claude-code-plugins/issues/586));
  an **epic blocker remediates as a whole epic** (full Epic flow to a closed
  epic before the dependent proceeds —
  [#587](https://github.com/timo-jakob/timos-claude-code-plugins/issues/587));
  cycles are refused, not looped (GitHub only rejects direct 2-cycles — our
  transitive detection caught a live 3-cycle). Epic
  [#583](https://github.com/timo-jakob/timos-claude-code-plugins/issues/583),
  validated end-to-end on a native-relationship test bed
  ([#588](https://github.com/timo-jakob/timos-claude-code-plugins/issues/588)
  — evidence in `development/skills/resolve-issue/docs/DEPENDENCY-VALIDATION.md`).
- **Issue refinement + persona registry — the definition layer.** When the gate
  says "not ready," `/development:refine-issue` is the guided path back: a human
  loops the `issue-refiner` agent
  ([#575](https://github.com/timo-jakob/timos-claude-code-plugins/issues/575)),
  which turns the gate's objections into questions, a prose rewrite, and a
  durable **`story-spec/v1`** block
  ([#574](https://github.com/timo-jakob/timos-claude-code-plugins/issues/574)) —
  machine-readable and provenance-stamped so a later prose edit is detectable as
  staleness — written back onto the issue (human-authored). For a
  **surface-touching** story the gate's **interface-aware check 5**
  ([#670](https://github.com/timo-jakob/timos-claude-code-plugins/issues/670))
  classifies the runtime `surface` (`rest`/`grpc`/`web-ui`/`cli`) and
  hard-requires a concrete `use_case` plus outside-in happy/corner/error
  `test_cases`; those cases spin out into linked **`test-case` issues**
  ([#671](https://github.com/timo-jakob/timos-claude-code-plugins/issues/671))
  that `resolve-issue` then implements as acceptance tests **in the same PR** as
  the feature, closing story + test-case issues together so tests and feature
  can never drift
  ([#696](https://github.com/timo-jakob/timos-claude-code-plugins/issues/696)).
  The block's **outside-in** test data is drawn from a repo's **persona
  registry**: `/development:define-personas` builds `personas/v1`
  ([#665](https://github.com/timo-jakob/timos-claude-code-plugins/issues/665))
  via the `persona-definer` agent
  ([#666](https://github.com/timo-jakob/timos-claude-code-plugins/issues/666)),
  the readiness gate validates persona references as **advisories** (never a hard
  fail), and `refine-issue` mines their `data_traits` for realistic payloads
  ([#668](https://github.com/timo-jakob/timos-claude-code-plugins/issues/668)).
  A session that can't converge takes a **typed parked exit** a later run resumes
  from ([#578](https://github.com/timo-jakob/timos-claude-code-plugins/issues/578)),
  every run emits JSONL **telemetry**
  ([#579](https://github.com/timo-jakob/timos-claude-code-plugins/issues/579)),
  and pointed at an **epic** `refine-issue` walks each `needs-refinement` child
  ([#580](https://github.com/timo-jakob/timos-claude-code-plugins/issues/580)).
  Epics [#573](https://github.com/timo-jakob/timos-claude-code-plugins/issues/573)
  (refinement) + [#664](https://github.com/timo-jakob/timos-claude-code-plugins/issues/664)
  (personas); a **documented end-to-end run** is in
  [`development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md`](./development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md)
  ([#581](https://github.com/timo-jakob/timos-claude-code-plugins/issues/581) /
  [#669](https://github.com/timo-jakob/timos-claude-code-plugins/issues/669)).

### Current gaps

Honest list of where the implementation does not yet match the motivation.
Each gap has a tracking issue, and that issue is responsible for updating
this section when it lands.

1. **Approver shipped; live validation in progress.** Phases 0–5 of
   [#89](https://github.com/timo-jakob/timos-claude-code-plugins/issues/89)
   plus [#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174)
   have merged — App registration, bootstrap install, workflow / policy
   / PR templates, the `python-approver` fable agent, maintenance
   re-ingest of the Approver's hidden-JSON findings, local `/approve`
   dry-run, and the griffe-based API-stability gate. Adoption docs
   shipped in [`development/skills/bootstrap/docs/APPROVER.md`](./development/skills/bootstrap/docs/APPROVER.md)
   ([#88](https://github.com/timo-jakob/timos-claude-code-plugins/issues/88)).
   **Remaining:** Phase 6 — end-to-end validation against the
   `ai-doc-organizer` test bed. The first bot PR after a fresh
   bootstrap will exercise the workflow including the
   Claude-Code-install detail.
2. **Coverage is a number, not a judgment — addressed.** Phase 3 of
   #89 shipped the agent's test-quality detection (`assert True`
   filler, mock-return-only assertions, tests-mocking-the-unit,
   name-promises-the-assertions-don't-verify); Phase 4 closed the loop
   so `/development:maintenance` re-ingests test-quality findings and
   dispatches `python-coverage-improver` to rewrite the offending
   tests. Live validation that this works end-to-end is part of
   Phase 6.
3. **Maintenance language parity.** Python, Java, and Swift each have the
   full triage + worktree + autonomous-fix pipeline (Java via epic #296,
   Swift via epic #297). JavaScript / Angular, PowerShell, zsh, Go, and Rust
   are not yet implemented. This is intentional sequencing — Python was the
   proving ground for the dispatch contract; the other languages follow once
   each prior loop is solid. Tracked:
   [#170](https://github.com/timo-jakob/timos-claude-code-plugins/issues/170).
4. **macOS + Homebrew lock-in.** `/development:bootstrap`'s automation
   scripts assume macOS + Homebrew. The generated `SETUP.md` is
   platform-agnostic but the one-shot bootstrap isn't. Tracked:
   [#171](https://github.com/timo-jakob/timos-claude-code-plugins/issues/171).
5. **Topic plugins are aspirational.** `development-container`,
   `development-kubernetes`, and `development-terraform` are described in
   `ARCHITECTURE.md` but not implemented. Security-by-default really wants
   the container plugin (Trivy, SBOM, distroless) shipped. Tracked:
   [#172](https://github.com/timo-jakob/timos-claude-code-plugins/issues/172).

## Why per-language plugins?

An experienced developer looking at the plugin list below asked the obvious
question: *"Why are there separate plugins per programming language at all?
Claude already knows how to program each of them."* That premise is true — and
it misses what these plugins actually encode. They don't teach Claude Python,
Java, or Swift. They encode five things a generic "Claude, fix my project"
prompt cannot carry:

1. **My experience and my favorites — accumulated over many years.** This is
   the headline reason. These plugins are opinionated because *I* am: they
   bake in the tools, policies, and defaults I've converged on across years of
   building and maintaining software. Claude knowing Java doesn't tell it that
   here Gradle with the Kotlin DSL is the only build system (Maven is
   rejected, Groovy DSL must be converted), that Spring Boot 4+ is the
   minimum, that gRPC is for internal service-to-service calls while public
   endpoints are REST/OpenAPI contract-first, that async messaging defaults
   to ActiveMQ Artemis (Kafka only at genuine scale), that every linter is
   set to 120 columns, or that new shell scripts are zsh. Each of those is a
   decision, not knowledge — one blessed path with one good default, because
   every extra option is a permanent maintenance and expertise cost. The
   per-language plugin is where those decisions live.

2. **Tool semantics, not just tool names.** Running JaCoCo vs `coverage.py`
   vs `xccov` is a one-line script difference; *interpreting* their output is
   not. JaCoCo reports per-class with method regions, `coverage.py`
   per-module, and Swift coverage needs symbol demangling before it means
   anything (see
   [`demangle-swift-regions.py`](./development/skills/maintenance/scripts/demangle-swift-regions.py)).
   The same holds for upgrades: a JDK bump (Gradle toolchains, Temurin
   images, migration-guide-licensed code adaptations) and a Python
   interpreter bump (`requires-python`, whatsnew documents, removed stdlib
   modules) share the outer loop but diverge in failure modes, evidence
   sources, and escalation rules. That judgment layer is what the per-language
   agents carry.

3. **Everything mechanical is *already* language-parameterized scripts.**
   The suggestion "put the formatters, linters, and coverage tools in shared
   scripts with the language as a parameter" is not a missed alternative —
   it's the shipped design. The orchestrator's script layer
   ([`development/skills/maintenance/scripts/`](./development/skills/maintenance/scripts/))
   is mostly language-agnostic (`merge-pr-cycle.zsh`, `await-pr-checks.zsh`,
   `gather-sonarcloud.zsh`, …) with thin per-language
   `gather-<lang>-findings` / `parse-<lang>-coverage` adapters. The plugins
   hold only what genuinely needs per-language judgment and policy; the rest
   was factored into scripts long ago.

4. **Context economy.** Installed plugins load their agent descriptions and
   skill triggers into every Claude Code session. Per-language plugins mean a
   Swift project pays only for Swift context. One monolithic
   "development-everything" plugin — even with perfectly parameterized
   scripts underneath — would push the Java, Python, Spring, and Swift agent
   rosters into every session on every project. In a context-window-
   constrained system, install-what-you-use is an architectural feature, not
   packaging trivia.

5. **Composition.** Topic plugins dispatch *alongside* the language plugin,
   not instead of it: `development-spring` only activates when both Java and
   Spring markers are present, and `development-claude-plugin` layers over
   whatever language the repo uses. The orchestrator → language plugin →
   topic plugin layering works because plugins are the unit of packaging and
   dispatch; a `--language` flag on a monolith cannot express "when both
   markers are present, also run the Spring advisors."

The one valid kernel in the critique: the *prose* of some parallel agents
(the per-language ci-fixers, coverage-improvers, review dimensions) is
substantially duplicated across languages and can drift. That's an
authoring-time problem, not an architecture problem — tracked in
[#619](https://github.com/timo-jakob/timos-claude-code-plugins/issues/619)
(single-source the near-twin agents via shared-core generation), which changes
how those agents are *written* while keeping the per-language plugins exactly
as they are.

## Plugins

> **Adding support for a new language?** See
> [`docs/adding-a-language-plugin.md`](docs/adding-a-language-plugin.md) — the
> consolidated guide for taking the maintenance pipeline from "doesn't know
> about language `L`" to a full-maintenance `development-<L>` plugin (the pattern
> proven by the Java and Swift epics).

### development

Language-agnostic workflow tooling for git operations, committing, and branch management.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Bootstrap | `/development:bootstrap` | Sets up the full quality + security toolchain. Public repos get SonarCloud + Snyk + CodeQL; private repos get self-hosted SonarQube + Trivy + a self-hosted runner. Generates pre-commit hooks, Dependabot config, issue/PR templates, branch protection, and the **Zero Tolerance standard** (≥90% new-code coverage, 0 code smells, all A ratings) enforced via a layered model: a `coverage-floor` CI step + a `diff-cover` pre-push hook + the configured Sonar gate. The Sonar gate uses a custom Quality Gate on paid SonarCloud / self-hosted SonarQube; on SonarCloud free (where custom-gate assignment is paywalled) it falls back to `Sonar way` and the CI step remains the real 90% enforcement. On macOS, automation scripts handle SonarCloud / SonarQube / Snyk setup, secret storage, gate configuration, and runner registration. Idempotent — safe to re-run. **Requires macOS + Homebrew** (see Requirements below). |
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

### development-swift

Swift maintenance — a **full-maintenance tier**, mirroring `development-python`
/ `development-java` (epic #297). Triages and fixes findings from the Swift
toolchain `/development:bootstrap` installs (swift-format, SwiftLint,
SonarCloud, CodeQL + Scorecard), reviews Dependabot / Snyk vendor PRs, applies
SwiftPM dependency-major and Swift-toolchain upgrades, raises code coverage,
migrates to the Swift 6 language mode, and reviews PRs as the Claude Approver.
Pure function of its JSON input — dispatched by `/development:maintenance`; it
runs no detection of its own. (semgrep is deferred for Swift — its rule
registry is empty, per `ARCHITECTURE.md`.)

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
| swift-lint-format | opus | Runs SwiftFormat and SwiftLint, fixes issues in-place |
| bug-hunter | fable | Logic errors, nil crashes, race conditions, stability |
| security-reviewer | opus | Secrets, injection, insecure storage, ATS, keychain |
| performance-reviewer | opus | Retain cycles, allocations, O(n²), main thread blocking |
| code-quality | opus | Naming, SOLID, readability, dead code, API design |
| test-reviewer | opus | Coverage gaps, assertion quality, flaky tests |

### development-python

Python-specific maintenance — triages and fixes findings produced by the
toolchain `/development:bootstrap` installs (ruff, semgrep, Snyk Code,
Snyk Open Source, SonarCloud), and autonomously applies dependency
upgrades (patch + minor + major) with test-based verification.

Pure function of a JSON input per `ARCHITECTURE.md` — it does not run
detection itself; the `/development:maintenance` orchestrator constructs the
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
| python-security-reviewer | opus | Secrets, injection, unsafe deserialization, TLS verification, data exposure (#449) |
| python-performance-reviewer | opus | Accidental O(n²), event-loop blocking, N+1 I/O, unbounded caches (#449) |
| python-code-quality | opus | Naming, SOLID, readability, dead code, API design (#449) |
| python-test-reviewer | opus | Coverage gaps, assertion quality, flaky tests, mock misuse (#449) |

All worktree-modifying agents run their fixes through the project's
test suite locally before declaring success. CI is the secondary
safety net, not the primary verification loop.

### development-java

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
| java-security-reviewer | opus | Secrets, injection, unsafe deserialization, TLS validation, data exposure (#449) |
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
[`development-java/docs/java-approver.md`](./development-java/docs/java-approver.md).

### development-spring

A **topic plugin** for **Spring Boot 4+** projects. It **composes alongside
`development-java`** (per `ARCHITECTURE.md`) — it holds zero Java-foundation
logic, only dispatches when both Java and Spring markers are present, and
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

### development-claude-plugin

Topic plugin for projects that **are** Claude Code plugins (marker: a
`.claude-plugin/` dir with `plugin.json` or `marketplace.json`). It composes
*alongside* language plugins rather than replacing them — `/development:maintenance`
dispatches to both when a repo matches (this repo is a Claude plugin; a plugin
repo that is also Python gets both dispatchers).

**What's built:** the test harness, plus the maintenance dispatcher with its five
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
| Test harness | `/development-claude-plugin:test [--target <path>] [--task "<prompt>"] [--expect "<text>"]` | Exercises a plugin's real behaviour end-to-end. A fresh-context judge subagent drives a *separate* headless `claude` session — local plugins loaded via `--plugin-dir`, run against an isolated clone of the target repo — and returns a structured `PASS`/`FAIL` verdict plus a transcript digest, without flooding the authoring context. See [`docs/test-harness.md`](./development-claude-plugin/docs/test-harness.md). |
| Maintenance dispatcher | (dispatch target of `/development:maintenance`) | Topic dispatcher. Validates plugin conventions and returns a plan routing each finding group to a validator agent. No language coverage gate (a script-quality gate is planned, [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263)). Validates version sync, SKILL.md/agent frontmatter, orphaned references, directory layout, and shell-script quality. |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| claude-plugin-version-sync | haiku | Syncs `marketplace.json` version entries to each plugin's `plugin.json` (the source of truth); escalates add/remove-entry decisions to human review |
| claude-plugin-skill-validator | opus | Triages SKILL.md / agent frontmatter findings (missing/invalid `name`/`description`/`model`/`tools`, empty body); fixes name-to-location mismatches, escalates authored-content gaps |
| claude-plugin-reference-checker | opus | Triages orphaned `/<plugin>:<skill>` and agent references; fixes clear typos of a defined name, escalates removed-target / planned-work cases |
| claude-plugin-structure-validator | opus | Triages plugin directory-layout findings (missing/misnamed `plugin.json`, wrong `skills/`-`agents/` layout, marketplace `source` mismatch); fixes source paths, escalates file moves / identity renames |
| claude-plugin-script-quality | opus | Triages shell-script lint (shellcheck error/warning, `zsh -n` syntax, shebang/extension mismatch); applies verified safe fixes + justified suppressions, escalates renames and behavior-changing rewrites |

> ⚠️ **Cost**: a full maintenance run as a test is a real autonomous
> child session (tens of thousands of tokens). Narrow `--task` to one
> tool + `--dry-run` for cheap iteration, or use the no-arg plumbing
> smoke test to verify plugin loading first.

## Claude Approver

> **Operator-facing adoption guide:**
> [`development/skills/bootstrap/docs/APPROVER.md`](./development/skills/bootstrap/docs/APPROVER.md).
> Start there if you want to use the Approver on your own project. The
> section below is the design summary that explains *why* the Approver
> works the way it does.
>
> **Status — Phases 0–5 + #174 shipped; Phase 6 (live validation) in
> progress.** The two GitHub App identities can be registered
> (`Phase 0`, #179), bootstrap installs them on a repo with the secrets
>
> - variables they need (`Phase 1`, #180), the workflow + Python policy
> - PR description template render at bootstrap time (`Phase 2`, #181),
> the `python-approver` fable agent the workflow invokes is in
> [`development-python/agents/python-approver.md`](./development-python/agents/python-approver.md)
> with the operator-facing runtime spec at
> [`development-python/docs/python-approver.md`](./development-python/docs/python-approver.md)
> (`Phase 3`, #183), `/development:maintenance` re-ingests the
> Approver's hidden-JSON findings on the next run (`Phase 4`, #185),
> and `/development-python:approve` runs the same agent locally for a
> dry-run verdict (`Phase 5`, #186). The
> [`api-stability`](./development-python/docs/api-stability.md) gate
> (`griffe` + version-bump bypass, from
> [#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174))
> couples in via the artifact the agent reads. **Remaining:** Phase 6 is
> live validation against the `ai-doc-organizer` test bed; the first
> bot PR after merge will exercise the workflow end-to-end. All tracked
> under
> [#89](https://github.com/timo-jakob/timos-claude-code-plugins/issues/89)
> and the meta-tracker
> [#176](https://github.com/timo-jakob/timos-claude-code-plugins/issues/176).
>
> The section below is the design summary. Operator-facing runtime
> details live in the linked docs files.

### Idea

`/development:bootstrap` installs a Zero Tolerance toolchain — CI runs ruff,
mypy, semgrep, Sonar, Snyk, CodeQL, and a `coverage-floor` step that fails
the build below 90% new-code coverage; branch protection on `main` requires
every check green plus one approving review before merge. The Approver is
the **final synthesis layer** that decides whether that approving review
can come from Claude rather than (or in addition to) a human.

It is *not* another CI check. It runs **after** every other gate has passed
and asks two judgment questions a checker can't:

- **Risk** — given everything is green, what could still go wrong?
- **Confidence** — how sure am I that this PR actually does what it claims,
  with the quality the project expects?

Verdict is one of:

- `APPROVE` — confidence HIGH and risk register has no load-bearing entries.
- `REQUEST_CHANGES` — at least one criterion failed OR confidence below HIGH.
  Findings are emitted both as human-readable markdown *and* a hidden
  machine-readable JSON block so the maintenance pipeline can re-ingest them.
- `COMMENT` with reservations — bot would approve "if X is verified by a
  human"; defers to a human for the binary call.

### How it runs (gating)

The Approver only spends a token once every other signal is clean:

- All required GitHub Actions status checks = SUCCESS
- No new findings from SonarCloud/SonarQube, Snyk Code, Snyk OSS, CodeQL
- All review threads resolved
- All checkboxes in the PR body checked
- PR not in draft; no pending review requests
- HEAD SHA matches the SHA that produced the green checks (no race)

If any gate fails → workflow exits neutral and waits for the next event.
Optional `/approve` PR comment manually re-triggers; `/approve --dry-run`
runs as a non-binding COMMENT.

### Identity (two distinct GitHub Apps)

- **Claude Approver** — its `pull_request_review` calls satisfy branch
  protection's one-approval requirement. Permissions:
  `pull_requests: write`, `contents: read`.
- **Claude Maintenance** — separate App used by `/development:maintenance`
  to open PRs. Distinct identity so the anti-rubber-stamp gate
  ("PR author ≠ approver identity") fires correctly even when maintenance
  PRs are evaluated by the Approver.

One-time per-org setup registers both Apps; per-repo bootstrap installs
them and stores `*_APP_ID` repo variables + `*_PRIVATE_KEY` repo secrets.

### Author allowlist (machine-only by default)

The Approver only evaluates PRs from authors on a configurable allowlist.
Default: `dependabot[bot]`, `github-actions[bot]`, `claude-maintenance[bot]`.
Override per-repo via the `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` repo variable
(set to `["*"]` to opt into reviewing human-authored PRs).

It is the approving half of `python-dependabot-snyk-triage`'s merge flow
for safe patch + minor Dependabot PRs — triage never approves, so its
merges (immediate or via armed auto-merge) wait on the Approver's or a
human's review; when triage defers a PR or CI is red, the Approver picks
it up once everything turns green.

### PR type taxonomy

Detection: conventional-commit prefix in PR title (primary), diff heuristic
(fallback), author hint (tiebreaker). Ambiguity is itself a finding.

| Prefix | Type | Headline risk |
| --- | --- | --- |
| `feat:` | New feature | Implementation matches the story; tests are meaningful, not coverage farming |
| `fix:` | Bug fix | Regression test exists; root cause addressed, not the symptom |
| `refactor:` | Behavior preserved | No public-API change; coverage holds; diff is atomic |
| `chore(deps):` | Patch/minor dep bump | Changelog scanned; supplements `python-dependabot-snyk-triage` |
| `chore(deps-major):` | Major dep bump | Migration notes verifiably addressed |
| `chore(runtime):` | Python / Docker base-image bump | Structured commit body from `python-runtime-upgrade` matches the diff |
| `security:` | CVE / finding fix | Test demonstrates the unsafe input no longer succeeds |
| `docs:` | Documentation only | Claims cross-checked against the code described |
| `test:` | Tests only | Assertions are meaningful, not line-touching |
| `ci:` / `build:` | Workflows / config | No required gate weakened |
| `chore:` | Cleanup / maintenance | Dead-code removal verified including dynamic references |
| `revert:` | Clean revert | Dependents since the original commit checked |
| `hotfix:` | Emergency | Always REQUEST_CHANGES with "human review required" |

Full criteria per type live in the in-repo policy file.

### Policy file (in target repo)

Bootstrap generates `.claude/approver-policy.md` from the language-matched
template. The policy is the source of truth for "ready to approve" —
versioning it in-repo means changes to the criteria themselves go through
code review. A policy-change PR is evaluated by the *previous* policy; the
new policy applies to PRs opened after it merges.

Policy file content:

- Type detection rules (primary / fallback / tiebreaker)
- Baseline criteria (apply to every type)
- Per-type must-have criteria
- Per-type risk factors to weigh
- Confidence calibration rules

### PR description template

Bootstrap also generates `.github/pull_request_template.md` mirroring the
structure the Approver expects:

```markdown
## Type
<!-- feat | fix | refactor | chore(deps) | chore(deps-major) |
     chore(runtime) | security | docs | test | ci | chore | revert | hotfix -->

## Linked issue
<!-- #123 or Closes #123 — GitHub issue body is read by the Approver for `feat:` -->

## Risk
<!-- What could go wrong? Edge cases not exercised? Anything load-bearing untested? -->

## Test plan
<!-- How was this verified beyond `pytest`? -->

## Checklist
- [ ] ...
```

### REQUEST_CHANGES feedback loop

The Approver's findings include a hidden machine-readable JSON block —
**this is shipped** (Phase 3); the schema lives in
[`development-python/docs/python-approver.md`](./development-python/docs/python-approver.md).
**v1** *(Phase 4, pending)*: the user re-runs `/development:maintenance`,
which reads the JSON block from the most recent Approver review,
dispatches the relevant triage agents (ruff, semgrep, snyk, sonar, etc.),
pushes fixes, and the Approver re-runs on workflow synchronize.
**v2** closes the loop in CI via a `pull_request_review`-triggered
workflow. v1's JSON bridge is the load-bearing primitive; v2 is just a
different trigger on top of it.

### How to adopt

1. **Per-org (one-time)** — register both GitHub Apps (Claude Approver +
   Claude Maintenance); capture App IDs and private keys. The
   `development/skills/bootstrap/scripts/register-claude-apps.zsh` script
   walks the manifest flow; see
   [`development/skills/bootstrap/docs/CLAUDE-APPS.md`](./development/skills/bootstrap/docs/CLAUDE-APPS.md)
   for the design and the manual fallback.
2. **Per-repo** — `/development:bootstrap --claude-approver true`. Bootstrap
   stores credentials (via `install-claude-apps.zsh`), installs the Apps on
   the repo, generates the workflow + policy + PR template.
3. **Per-policy** — amend `.claude/approver-policy.md` as your team's norms
   evolve. Changes go through normal PR review.

### Local dry-run

`python-approver` runs locally too: invoke the agent in your worktree and
it executes the same logic without posting a review. Useful for predicting
what CI's Approver will say before pushing.

### Languages

Python, Java, and Swift ship `<lang>-approver` agents (fable) + policy
templates today (`python-approver`, `java-approver`, `swift-approver`); the
bootstrap wires the per-language approver via `{{APPROVER_LANG}}`. Future
plugins (`development-node`, `development-go`, etc.) follow the same pattern.
Bootstrap with `--claude-approver true` on a language with no approver warns
and skips.

## Requirements

The plugins are written for **macOS** and assume **Homebrew** is the package
manager. Other platforms may work for some skills but are not tested.

The `/development:bootstrap` skill specifically depends on macOS + Homebrew for
its automation scripts — it offers to `brew install` any missing tooling
(`gh`, `jq`, `pre-commit`, `gitleaks`, `semgrep`, `sonar-scanner`,
`snyk-cli` or `trivy`, plus language-specific linters). The manual setup
documented in the generated `SETUP.md` remains usable on any platform if you
install the equivalent tools by hand.

Additional runtime dependencies:

- `gh` CLI authenticated (`gh auth login`) — for repo metadata, secret storage,
  branch protection, and self-hosted runner registration.
- Docker (private-repo bootstrap only) — runs SonarQube CE locally via
  `docker compose`. The preflight script detects three setups:
  - **Docker Desktop** — recommended for most users; offered as a brew cask
    (`brew install --cask docker`). Bundles the compose v2 plugin. Free for
    personal use; check Docker's license at companies >250 employees /
    >$10M revenue.
  - **CLI-only (Colima / OrbStack / Rancher Desktop / Podman)** — preflight
    accepts any setup that provides a working `docker` CLI + daemon. If the
    `docker compose` plugin is missing, preflight offers
    `brew install docker-compose`.
  - **Absent** — preflight prompts: install Docker Desktop via brew, install
    manually from docker.com, or set up an alternative yourself.

## Usage

Load plugins locally during development:

```sh
claude --plugin-dir ./development --plugin-dir ./development-swift --plugin-dir ./development-python
```

Then use the slash commands:

```bash
# Development workflow
/development:commit              # format, lint, generate message, commit
/development:commit "Fix auth"   # format, lint, commit with given message

# Swift code review
/development-swift:review                # review all Swift files
/development-swift:review Sources/       # review a specific directory
```

## Maintaining this repo

The bootstrap skill pins versions inside `.tmpl` files (GitHub Actions
versions, pre-commit hook revs, Docker image tags, language runtime
versions). Standard Dependabot can't update those — see
[MAINTAINING.md](./MAINTAINING.md) for the quarterly refresh checklist
that keeps the templates current. ~20 minutes per quarter.

**Feeding real runs back into the plugins.** Improving these plugins from
actual `/development:maintenance` runs is the core loop of this repo — but
a Claude Code session stores the main transcript and each subagent's
transcript in separate files, so handing over only the main `.jsonl`
loses the dispatcher/triage/planner/ci-fixer detail. Run
[`scripts/capture-session-log.zsh`](./scripts/capture-session-log.zsh)
with no arguments after a run: it offers the most recent project and
session (just press Enter twice) and bundles the main transcript **plus**
the `subagents/` directory into one `.tgz` to hand back for analysis.

### Repo scripts

Three helper scripts live in [`scripts/`](./scripts):

| Script | What it does |
| --- | --- |
| [`capture-session-log.zsh`](./scripts/capture-session-log.zsh) | Bundles a Claude Code run's main transcript **and** its subagent transcripts (plus any worktree / headless `plugin-test` sessions it spawned) into one `.tgz` for handing a real run back to the plugins. Interactive by default (no arguments — defaults to the newest project + session); supports `--list`, `--project`, `--session`, `--out`, `--dry-run`, `--main-only`, and `--related`. See the "Feeding real runs back" note above. |
| [`check-marketplace-sync.zsh`](./scripts/check-marketplace-sync.zsh) | Verifies that every per-plugin version in `.claude-plugin/marketplace.json` matches the corresponding `plugin.json`. Exits `0` when in sync, `1` on any mismatch, `2` on usage errors (missing `jq` or marketplace file). Takes no arguments; run it locally before pushing. Also runs in CI via `marketplace-sync.yml` on every PR that touches a `plugin.json` or `marketplace.json` (issue #188). |
| [`refresh-local-install.zsh`](./scripts/refresh-local-install.zsh) | Fully refreshes your local install: updates the Claude Code CLI (Homebrew cask or `claude update`), hard-purges every on-disk cache for the `timos-claude-code-plugins` marketplace (per-plugin cache, marketplace clone, plugin data dir, shared catalog cache), then re-adds the marketplace and reinstalls every plugin it publishes — so local state matches the latest published marketplace. Only the timos marketplace is touched. Destructive: prints the plan and prompts once; `-y`/`--yes` skips the prompt, `--dry-run` prints the plan and changes nothing. Restart Claude Code afterwards to apply. Requires `jq` + the `claude` CLI. |

## Contributing

`main` is protected: PRs only, 1 approving review, all required checks
green, and **cryptographically signed commits required** (GPG or SSH; see
[GitHub's signing guide](https://docs.github.com/en/authentication/managing-commit-signature-verification)).
Squash-merges via the GitHub UI/CLI are signed automatically by GitHub,
so the main constraint applies to any direct pushes — those will be
rejected unless your local commits are signed.

To set up SSH signing locally (matches the bootstrap's recommended path
in `templates/common/SETUP.md.tmpl` Section 3g):

```sh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub  # or your key
git config --global commit.gpgsign true
```

Then add the **same public key** to GitHub as a *signing key* (Settings
→ SSH and GPG keys → New SSH key → Key type: **Signing**). It's a
separate registration from authentication keys, even when the key file
is the same.

## License

MIT
