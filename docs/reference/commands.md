<!-- GENERATED — do not edit. Source: skill/agent frontmatter.
     Regenerate with scripts/generate-docs-reference.py; CI diff-checks it (#757). -->

# Commands

Every plugin's skills, exposed as slash commands. Generated from each
`SKILL.md`'s frontmatter, so this list always matches the installed plugins.
For the narrative overview of what each plugin is for, see the
[Plugin overview](plugins.md).

## development

| Command | Description |
| --- | --- |
| `/development:bootstrap` | Bootstraps a project with the full quality + security toolchain. Detects repo visibility (public vs private), languages, and Docker presence, then generates GitHub Actions workflows, scanner configs, pre-commit hooks, branch protection, Dependabot, templates, and developer docs. Public repos use SonarCloud + Snyk; private repos use self-hosted SonarQube + Trivy. Enforces a Zero Tolerance standard via layered CI + pre-push + Sonar enforcement (falls back to `Sonar way` on SonarCloud free). Idempotent — safe to re-run on partially configured repos. Also reconciles GitHub-side state (branch protection, secrets, Sonar project) when files are already in place but Step 4 didn't complete (the State D gap-fill mode). |
| `/development:cleanup` | Cleans up the local git environment after merging a branch to main. Prunes stale remote-tracking branches and deletes local branches that are already merged into main. Run this after a PR is merged to main. |
| `/development:commit` | Commit code changes after running formatting/linting and generating a commit message |
| `/development:define-personas` | Interactively define (or update) a repo's persona registry — the `personas/v1` artifact at `docs/personas.md` that says who actually uses each surface and what they type into it. A human-facing conductor mirroring `/development:refine-issue`: you gather repo evidence, then loop the `persona-definer` agent (per-turn: candidate personas grounded in the repo, Socratic questions, a draft registry update) relaying between it and the human until they approve, then write back the human-approved prose plus a provenance-stamped `personas/v1` block to `docs/personas.md` in the working tree (the change lands via the normal PR flow; the skill does not push). Two modes: create (no registry yet) and update (refine an existing one — e.g. routed here from refine-issue for a missing persona). The intelligence lives in the agent; this skill conducts. Composes persona-definer (#666); produces the personas/v1 contract (#665). |
| `/development:git-branch-naming` | Defines how git branches must be named at this organization. Use this skill whenever Claude Code is about to create a git branch, suggest a branch name, check out a new branch, or when the user asks "what should I name this branch", "create a branch for...", or "start work on issue #...". Always consult this skill before proposing or creating any branch name — even for quick fixes or experiments. |
| `/development:library-docs` | Ensures the agent works from current, authoritative documentation for any library, framework, CLI tool, or API in scope — not stale training-data guesses. Use whenever writing, reviewing, or explaining code that involves external software, especially when version-specific behaviour matters. |
| `/development:maintenance` | Maintenance orchestrator. Runs detection + per-tool findings gathering + coverage measurement, constructs the v2 JSON payload, dispatches to the matching language plugin and any topic plugins — discovered by gather-script convention, so the orchestrator hardcodes no language — and drives a sequential per-stage PR cycle (push → CI → merge → sync) until the plan is exhausted. The user-facing entry point for "go fix everything you safely can on this project." |
| `/development:open-pr` | Open a pull request for the current branch authored by the Claude-Plugin-Writer identity (the Claude Maintenance GitHub App) instead of by you, so YOU can approve it (GitHub blocks self-approval) and it auto-merges on approval + green CI. Use this to finish work in a Claude-plugin repo (#260): mint the writer token, push as the bot, open the PR as the bot, and arm squash auto-merge with branch deletion. Falls back to a normal user-authored PR (which you'd admin-merge) when the writer App isn't installed. |
| `/development:refine-issue` | Take a GitHub issue the readiness gate sent back (`needs-refinement`) and drive it interactively to READY — the guided path from "no" back to "ready". A human is present throughout: you diagnose the story with `story-readiness`, then loop the `issue-refiner` agent (per-turn: explanation, questions, recommendations, a draft rewrite, a proposed `story-spec/v1` block) relaying between it and the human until they approve a rewrite. Then you write back the human-approved prose plus a provenance-stamped `story-spec` block (a human-authored issue edit, NOT a bot PR), re-gate, remove the `needs-refinement` label only if READY, and post a before/after comment trail. When a session can't converge, take a typed parked exit (needs-decision / split-recommended / deferred) that a later run resumes from (#578). Pointed at an epic, it walks each needs-refinement child through that single-issue flow and posts an epic-level summary (#580). The intelligence lives in the agent, this skill is the conductor. Composes story-readiness (#559) and issue-refiner (#575); consumes the story-spec/v1 contract (#574). |
| `/development:resolve-issue` | Take a GitHub issue — or an epic of issues — and drive it to merge-ready, bot-authored PR(s). Single issue: branch off fresh main, implement, validate (tests must be green), commit, and open a Maintenance-App-authored PR with squash auto-merge armed — the Approver auto-approves on app repos; a human approves on claude-plugin repos. Epic: decompose the children, order them conflict-aware, resolve provably-disjoint ones in parallel worktrees and the rest sequentially off fresh main (each child independently tested), then run a holistic end-to-end test over the merged epic and explicitly close the epic issue (nothing auto-closes it). Repo-type-agnostic (Python / Java / Claude-plugin). Composes git-branch-naming, commit, and open-pr; never pushes to the default branch. When a human is driving, a `BUDGET_EXHAUSTED` / non-converging review-loop exit becomes an interactive extension (offer more rounds, give guidance, ask questions) — see [The local review loop](https://timo-jakob.github.io/timos-claude-code-plugins/explanation/review-loop/). |

## development-claude-plugin

| Command | Description |
| --- | --- |
| `/development-claude-plugin:maintenance` | Claude-plugin maintenance dispatcher. Receives plugin-validation findings from /development:maintenance as a v2 JSON payload (a file path in $ARGUMENTS), validates it, and returns a plan that routes each finding group to a validation agent. A TOPIC plugin: it composes alongside the language plugin, not instead of it. No language *coverage* gate (there's no app test suite) — but a plugin's scripts ARE code; a script-quality gate (lint + behavioral tests) is planned (#263). A single invocation returns the plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection or validation. See ARCHITECTURE.md for the schema and dispatch contract. |
| `/development-claude-plugin:review` | Perform a comprehensive Claude-plugin review using 5 specialized parallel agents |
| `/development-claude-plugin:test` | Test a Claude Code plugin's behaviour end-to-end against a real reference project. Spawns a fresh-context judge subagent that drives a *separate* headless `claude` session — with the LOCAL (uncommitted) plugins loaded via --plugin-dir — against an isolated clone of the target repo, then returns a structured PASS/FAIL verdict plus a transcript digest without flooding the authoring context. Use it to verify a skill/agent/command you just edited actually does what you intend, in any language the family supports. Pass `--target <path>`, `--task "<prompt>"`, and optionally `--expect "<...>"`. |

## development-docs

| Command | Description |
| --- | --- |
| `/development-docs:maintenance` | Documentation-topic maintenance dispatcher. Receives a v2 maintenance payload (a file path in $ARGUMENTS) that /development:maintenance built from the docs topic gather (gather-docs-findings.zsh), validates it, and returns a plan routing each finding group to a documentation agent. A TOPIC plugin: it composes alongside the language plugin, not instead of it, triggered by the docs/architecture/ marker. v1 handles one tool — c4_drift (C4 container-diagram drift, declared vs detected) → docs-c4-drift-advisor. A single invocation returns the plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection or validation. See ARCHITECTURE.md for the schema and dispatch contract. |

## development-go

| Command | Description |
| --- | --- |
| `/development-go:approve` | Review and post approval/rejection to an open PR using the Claude Approver identity. Mints token locally, posts as claude-approver-bot. Same agent as CI. Pass a PR number or use current branch's PR. |
| `/development-go:maintenance` | Go project maintenance dispatcher. Receives findings from /development:maintenance (or equivalent JSON input), validates the payload, runs a coverage pre-flight (may spawn `go-coverage-improver` in a worktree when affected code sits below Required), and otherwise invokes `go-maintenance-planner` to return a PR-grouped plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection. Mirrors development-python / development-java / development-swift. Tool universe so far (#868 epic): format_lint (golangci-lint v2 — one pinned binary doing both `fmt` and `run --fix`, Slice B #871) plus the static-analysis triple sonarcloud + code_scanning + semgrep (Slice D #873 — all three ship, Go's support in each is deep), gated by the per-package coverage pre-flight (Slice E #874), plus govulncheck (the Go vuln source of truth) and the vendor-PR sources dependabot + snyk_prs + renovate (Slice G #876), plus the proto-first config-audit advisors grpc + api_contract (Slice I #878 — buf/protobuf gRPC codegen and the proto-first REST contract pipeline). See ARCHITECTURE.md for the schema and dispatch contract. |
| `/development-go:review` | Perform a comprehensive Go code review using 5 specialized parallel agents |

## development-java

| Command | Description |
| --- | --- |
| `/development-java:approve` | Review and post approval/rejection to an open PR using the Claude Approver identity. Mints token locally, posts as claude-approver-bot. Same agent as CI. Pass a PR number or use current branch's PR. |
| `/development-java:maintenance` | Java/Gradle project maintenance dispatcher. Receives findings from /development:maintenance (or equivalent JSON input), validates the payload, runs a JaCoCo coverage pre-flight (may spawn `java-coverage-improver` in a worktree when affected classes sit below Required — topping up toward Required, or bootstrapping a below-floor (0%) class toward the Floor, #429), and otherwise invokes `java-maintenance-planner` and returns its plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection. Mirrors development-python. Tool universe so far (#296 epic): format_lint (Spotless) + sonarcloud + JaCoCo coverage; semgrep / code_scanning / dependabot land in later slices. See ARCHITECTURE.md for the schema and dispatch contract. |
| `/development-java:review` | Perform a comprehensive Java code review using 5 specialized parallel agents |

## development-python

| Command | Description |
| --- | --- |
| `/development-python:approve` | Review and post approval/rejection to an open PR using the Claude Approver identity. Mints token locally, posts as claude-approver-bot. Same agent as CI. Pass a PR number or use current branch's PR. |
| `/development-python:improve-test-coverage` | Raise test coverage on a Python project toward a target threshold by spawning `python-coverage-improver` agents in parallel worktrees. Brings legacy projects or under-covered modules up to desired coverage as deliberate investment outside the maintenance pipeline. |
| `/development-python:maintenance` | Python project maintenance dispatcher. Receives findings from /development:maintenance (or equivalent JSON input), validates the payload, runs a coverage pre-flight (may spawn `python-coverage-improver` in a worktree when affected modules sit below Required — topping up toward Required, or bootstrapping a below-floor (0%) module toward the Floor, #429), and otherwise invokes `python-maintenance-planner` and returns its plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection. See ARCHITECTURE.md for the schema and dispatch contract. |
| `/development-python:review` | Perform a comprehensive Python code review using 5 specialized parallel agents |

## development-react

| Command | Description |
| --- | --- |
| `/development-react:maintenance` | React-topic maintenance dispatcher. Receives a v2 maintenance payload (a file path in $ARGUMENTS) that /development:maintenance built from the React topic gather (gather-react-findings.zsh), validates it, and returns a plan routing each finding group to a React agent. A TOPIC plugin: it composes alongside development-javascript, not instead of it, triggered by the React marker (`react` in the runtime dependencies of any package.json) and only when javascript is also detected. The v0.1 tool universe is deliberately EMPTY, so a valid payload yields a zero-group plan; tools arrive with #957-#960. CI remediation reuses development-javascript's js-ci-fixer. A single invocation returns the plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection or gather — it validates the payload envelope only. See ARCHITECTURE.md for the schema and dispatch contract. |

## development-spring

| Command | Description |
| --- | --- |
| `/development-spring:maintenance` | Spring maintenance dispatcher. A TOPIC plugin: it composes ALONGSIDE development-java (the Java foundation), not instead of it — and only dispatches when both Java and Spring markers are present (#296 decision #1). Receives a v2 JSON payload (a file path in $ARGUMENTS) built by the orchestrator from gather-spring-findings.zsh, validates it, and returns a plan routing each finding group to a Spring agent. No language coverage gate (a topic has no app test suite of its own); a single invocation returns the plan. The per-group work agents are the orchestrator's job. Pure function of its JSON input; does not run its own detection. See ARCHITECTURE.md for the schema and dispatch contract. |

## development-swift

| Command | Description |
| --- | --- |
| `/development-swift:approve` | Review and post approval/rejection to an open PR using the Claude Approver identity. Mints token locally, posts as claude-approver-bot. Same agent as CI. Pass a PR number or use current branch's PR. |
| `/development-swift:maintenance` | Swift project maintenance dispatcher. Receives findings from /development:maintenance (or equivalent JSON input), validates the payload, runs a coverage pre-flight (may spawn `swift-coverage-improver` in a worktree when affected sources sit below Required), and otherwise invokes `swift-maintenance-planner` to return a PR-grouped plan. The per-group work agents are the orchestrator's job, not the dispatcher's. Pure function of its JSON input; does not run its own detection. Mirrors development-python / development-java. Tool universe so far (#297 epic): format_lint (swift-format + SwiftLint), sonarcloud (Sonar Swift), code_scanning (CodeQL swift + Scorecard), coverage (xccov / llvm-cov, #444), and the vendor-PR sources dependabot + snyk_prs + renovate (Slice F #446 — triage + swift majors). semgrep is deferred for Swift (#443). See ARCHITECTURE.md for the schema and dispatch contract. |
| `/development-swift:review` | Perform a comprehensive Swift code review using 6 specialized parallel agents |
