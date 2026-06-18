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
  - policy + PR templates, the `python-approver` opus agent); Phases
  4–6 (maintenance re-ingest, local `/approve`, end-to-end validation)
  remain. The Python library-exports API-stability gate (`griffe` +
  version-bump bypass) is also shipped and couples into the Approver's
  per-type rules. See "Claude Approver" below for the design and the
  current ship-status table.

### Current gaps

Honest list of where the implementation does not yet match the motivation.
Each gap has a tracking issue, and that issue is responsible for updating
this section when it lands.

1. **Approver shipped; live validation in progress.** Phases 0–5 of
   [#89](https://github.com/timo-jakob/timos-claude-code-plugins/issues/89)
   plus [#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174)
   have merged — App registration, bootstrap install, workflow / policy
   / PR templates, the `python-approver` opus agent, maintenance
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
3. **Maintenance language parity.** Only Python has the full triage +
   worktree + autonomous-fix pipeline. Swift is review-only; Java,
   JavaScript / Angular, PowerShell, zsh, Go, and Rust are not yet
   implemented. This is intentional sequencing — Python is the proving
   ground for the dispatch contract; the other languages follow once the
   Python loop is solid. Tracked:
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

## Plugins

### development

Language-agnostic workflow tooling for git operations, committing, and branch management.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Bootstrap | `/development:bootstrap` | Sets up the full quality + security toolchain. Public repos get SonarCloud + Snyk + CodeQL; private repos get self-hosted SonarQube + Trivy + a self-hosted runner. Generates pre-commit hooks, Dependabot config, issue/PR templates, branch protection, and the **Zero Tolerance standard** (≥90% new-code coverage, 0 code smells, all A ratings) enforced via a layered model: a `coverage-floor` CI step + a `diff-cover` pre-push hook + the configured Sonar gate. The Sonar gate uses a custom Quality Gate on paid SonarCloud / self-hosted SonarQube; on SonarCloud free (where custom-gate assignment is paywalled) it falls back to `Sonar way` and the CI step remains the real 90% enforcement. On macOS, automation scripts handle SonarCloud / SonarQube / Snyk setup, secret storage, gate configuration, and runner registration. Idempotent — safe to re-run. **Requires macOS + Homebrew** (see Requirements below). |
| Maintenance | `/development:maintenance [--dry-run] [--no-merge]` | Orchestrator. Runs detection + per-tool findings gathering + coverage measurement, constructs the JSON payload, dispatches to the matching language plugin (`development-python`, `development-java`) and any topic plugins (`development-spring`, `development-claude-plugin`), collects results, and merges worktree branches back to the user's current branch. Effective entry point for "go fix everything safely fixable on this project." `--dry-run` prints the payload without dispatching; `--no-merge` leaves the worktree branches available for manual merge. |
| Commit | `/development:commit [message]` | Runs formatting/linting (delegates to language-specific plugin), generates a commit message, ensures a feature branch, and commits |
| Git Branch Naming | `/development:git-branch-naming` | Defines the branch naming convention (`<type>/<issue>-<description>`) and creates properly named branches |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| Commit Message | sonnet | Generates clear commit messages from diffs, ignoring formatting/linting noise |
| Bootstrap Security Reviewer | opus | Reviews planned workflows for GH Actions permissions, secret refs, self-hosted runner safety, scan-before-push gates |
| Bootstrap Config Consistency | sonnet | Cross-references Sonar keys, workflow job IDs ↔ branch-protection contexts, language fragments ↔ detected languages |
| Bootstrap Idempotency Reviewer | sonnet | For each existing file conflicting with a template, recommends skip/overwrite/merge |
| Bootstrap Validator | haiku | Fast post-write check — YAML/JSON parses, no unresolved placeholders, cross-references resolve |
| Bootstrap Reviewer | opus | Optional senior-engineer review of the full bootstrap output (`--review` flag) |

### development-swift

Swift-specific development tooling — code review and formatting/linting.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Review | `/development-swift:review [paths]` | Spawns 6 specialized agents in parallel to analyze bugs, security, performance, Swift 6 compliance, code quality, and test coverage |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| Bug Hunter | opus | Logic errors, nil crashes, race conditions, stability |
| Security Reviewer | sonnet | Secrets, injection, insecure storage, ATS, keychain |
| Performance Reviewer | sonnet | Retain cycles, allocations, O(n²), main thread blocking |
| Swift 6 Compliance | sonnet | Strict concurrency, typed throws, modern syntax |
| Code Quality | sonnet | Naming, SOLID, readability, dead code, API design |
| Test Reviewer | sonnet | Coverage gaps, assertion quality, flaky tests |
| Swift Lint & Format | sonnet | Runs SwiftFormat and SwiftLint, fixes issues in-place |

### development-python

Python-specific maintenance — triages and fixes findings produced by the
toolchain `/development:bootstrap` installs (ruff, semgrep, Snyk Code,
Snyk Open Source, SonarCloud), and autonomously applies dependency
upgrades (patch + minor + major) with test-based verification.

Pure function of a JSON input per `ARCHITECTURE.md` — it does not run
detection itself; the `/development:maintenance` orchestrator (forthcoming)
constructs the input and dispatches here.

> ⚠️ **Cost expectations**: These agents deliberately favor autonomy
> over speed and token cost. They read code with LSP (find references,
> type info, public-API detection), fetch release notes from the web for
> major upgrades, run the project's test suite in their isolated
> worktrees, and iterate up to 3 times on test failures before escalating.
> A maintenance run on a non-trivial project can consume tens of thousands
> of tokens; on a project with major-version CVEs requiring opus-driven
> migration, more. The trade is intentional — see ARCHITECTURE.md's
> "Maximizing autonomy" section.

**Skills:**

| Skill | Command | Description |
| ------- | --------- | ------------- |
| Maintenance dispatcher | `/development-python:maintenance <json>` | Parses input, runs coverage pre-flight, spawns per-tool agents in parallel worktrees, aggregates results. Standalone invocation prints usage and stops. |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| python-ruff-fixer | haiku | `ruff check --fix` (safe) + `ruff format` + `--unsafe-fixes` with test verification |
| python-semgrep-triage | sonnet | Per-finding: fix (refactor) / suppress (`# nosemgrep` + reason); LSP-driven scope check; only escalates when public API changes |
| python-code-scanning-triage | sonnet | CodeQL + Scorecard alerts: pins GH Actions to commit SHAs (Scorecard `PinnedDependenciesID`), removes unused globals / ineffectual statements (CodeQL `py/unused-*`); defers dataflow rules (`py/path-injection`, `py/sql-injection`, etc.) to human-review with concrete recommendations; surfaces process-policy findings (`MaintainedID`, `CodeReviewID`) as informational. Replaces deprecated `python-snyk-triage` per #87. |
| python-sonar-triage | sonnet | SonarCloud bugs/smells/vulns; security hotspots investigated context-first, not punted by default |
| python-major-upgrade | opus | Reads official release notes via WebFetch; maps breaking changes to call sites via LSP; applies migration; iterates up to 3 times on test failures |
| python-runtime-upgrade | opus | Applies a Python interpreter bump (Dependabot's `python:X.Y → Z.W` Docker base-image PR). Swaps Dockerfile FROM and pyproject.toml `requires-python`; best-effort local verify; **cascade-upgrades dependencies** that need newer versions for the new interpreter, reading their release notes and applying migrations (up to 3 passes). Stops only when a required dep has no version on PyPI supporting the new Python — does NOT search for alternative libraries |
| python-coverage-improver | opus | Brings under-covered modules up to threshold by writing meaningful behavior tests; never modifies production code |
| python-dependabot-snyk-triage | sonnet | Reviews each open Dependabot PR; auto-approves + merges patch + minor bumps with green CI (after scanning release notes for breaking-change flags); defers majors and red-CI PRs to human-review |

All worktree-modifying agents run their fixes through the project's
test suite locally before declaring success. CI is the secondary
safety net, not the primary verification loop.

### development-java

Java/Gradle maintenance — the **full-maintenance tier**, mirroring
`development-python`. Triages and fixes findings from the Gradle toolchain
`/development:bootstrap` installs (Spotless, SonarCloud, CodeQL + Scorecard,
semgrep), reviews Dependabot/Snyk vendor PRs, applies dependency-major and
JDK-LTS upgrades, raises JaCoCo coverage, flags versioning risks, and reviews
PRs as the Claude Approver. Pure function of its JSON input — dispatched by
`/development:maintenance`; it runs no detection of its own. **Adding it
required zero edits to the generic orchestrator** (discovered purely via the
gather-script + dispatch contract).

**Skills:**

| Skill | Command | Description |
| --- | --- | --- |
| Maintenance dispatcher | `/development-java:maintenance <json>` | Validates the payload, runs the JaCoCo coverage pre-flight (may raise coverage first), plans the per-tool groups, returns the plan + `ci_fixer_agent`. |
| Approve (local dry-run) | `/development-java:approve [<pr>]` | Runs the `java-approver` against an open PR locally — prints the verdict instead of posting. |

**Agents:**

| Agent | Model | Focus |
| ------- | ------- | ------- |
| java-format-lint-fixer | haiku | `./gradlew spotlessApply` (google-java-format); behaviour-preserving |
| java-sonar-triage | sonnet | SonarCloud bugs/smells/vulns/hotspots (`java:Sxxxx`); LSP-scoped; `// NOSONAR` for justified accepts |
| java-code-scanning-triage | sonnet | CodeQL (Java) + Scorecard; pins GH Actions to SHAs; dataflow rules → human-review |
| java-semgrep-triage | sonnet | semgrep: fix / `// nosemgrep` suppress / escalate; SQL concat → `PreparedStatement` |
| java-dependabot-snyk-triage | sonnet | Vendor PRs: auto-merge green patch/minor (never self-approves); defers majors + docker to the right handler |
| java-major-upgrade | opus | Gradle dependency majors — release notes + LSP call-site migration + `gradle build` |
| java-runtime-upgrade | opus | JDK LTS bumps (Docker base image) — swaps the Gradle toolchain + wrapper, cascades JDK-sensitive deps |
| java-coverage-improver | opus | Writes meaningful JUnit tests to raise JaCoCo coverage; never edits production code |
| java-versioning-advisor | sonnet | Flags a hardcoded `version` (a SemVer risk); recommends build-driven versioning (nebula-release) |
| java-grpc-advisor | sonnet | Audits gRPC/protobuf code generation — the `com.google.protobuf` Gradle plugin generating Java + gRPC stubs from the authoritative `.proto` contract; recommends excluding generated sources from coverage |
| java-openapi-advisor | sonnet | Audits **non-Spring** contract-first OpenAPI — openapi-generator's `jaxrs-spec` (Jakarta REST) generator from a committed spec, so code/spec drift fails the build (the Spring case is `development-spring`'s `spring-api-advisor`) |
| java-maintenance-planner | sonnet | Ranks + groups findings, routes each to its agent (defers `org.springframework.boot` bumps to `development-spring`) |
| java-ci-fixer | sonnet | Fixes a failing CI run on a maintenance PR (Gradle build/test, Spotless, JaCoCo) |
| java-approver | opus | Synthesis-layer PR reviewer once CI is green (mirrors `python-approver`) |

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
| spring-config-advisor | sonnet | Relocates deprecated/relocated Spring Boot 4 config keys; flags actuator over-exposure (human-review) |
| spring-boot-upgrade | opus | Owns Spring Boot version bumps end-to-end (config relocations + removed-API fixes per the migration guide); `development-java` defers `org.springframework.boot` bumps here |
| spring-container-advisor | sonnet | Audits `bootBuildImage` (Cloud Native / Paketo Buildpacks) config — pinned builder/run-image, image name, publish; JVM mode (native-image deferred) |
| spring-api-advisor | sonnet | Contract-first API drift gate: a committed OpenAPI spec + openapi-generator Spring interfaces, so code/spec drift fails the build |

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
| claude-plugin-skill-validator | sonnet | Triages SKILL.md / agent frontmatter findings (missing/invalid `name`/`description`/`model`/`tools`, empty body); fixes name-to-location mismatches, escalates authored-content gaps |
| claude-plugin-reference-checker | sonnet | Triages orphaned `/<plugin>:<skill>` and agent references; fixes clear typos of a defined name, escalates removed-target / planned-work cases |
| claude-plugin-structure-validator | sonnet | Triages plugin directory-layout findings (missing/misnamed `plugin.json`, wrong `skills/`-`agents/` layout, marketplace `source` mismatch); fixes source paths, escalates file moves / identity renames |
| claude-plugin-script-quality | sonnet | Triages shell-script lint (shellcheck error/warning, `zsh -n` syntax, shebang/extension mismatch); applies verified safe fixes + justified suppressions, escalates renames and behavior-changing rewrites |

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
> the `python-approver` opus agent the workflow invokes is in
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

Python and Java ship `<lang>-approver` agents (opus) + policy templates
today (`python-approver`, `java-approver`); the bootstrap wires the
per-language approver via `{{APPROVER_LANG}}`. Future plugins
(`development-node`, `development-go`, etc.) follow the same pattern.
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
