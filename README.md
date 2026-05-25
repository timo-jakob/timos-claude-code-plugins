# Claude Code Plugins

A collection of plugins for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Plugins

### development

Language-agnostic workflow tooling for git operations, committing, and branch management.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| Bootstrap | `/development:bootstrap` | Sets up the full quality + security toolchain for a project. Public repos get SonarCloud + Snyk + CodeQL; private repos get self-hosted SonarQube + Trivy + a self-hosted runner. Generates pre-commit hooks, Dependabot config, issue/PR templates, branch protection, and the Zero Tolerance Quality Gate (≥90% coverage on new code, 0 code smells, all A ratings). On macOS, automation scripts handle SonarCloud / SonarQube / Snyk setup, secret storage, Quality Gate creation, and runner registration. Idempotent — safe to re-run. **Requires macOS + Homebrew** (see Requirements below). |
| Maintenance | `/development:maintenance [--dry-run] [--no-merge]` | Orchestrator. Runs detection + per-tool findings gathering + coverage measurement, constructs the v1 JSON payload, dispatches to the language plugin (currently only `development-python`), collects results, and merges worktree branches back to the user's current branch. Effective entry point for "go fix everything safely fixable on this project." `--dry-run` prints the payload without dispatching; `--no-merge` leaves the worktree branches available for manual merge. |
| Commit | `/development:commit [message]` | Runs formatting/linting (delegates to language-specific plugin), generates a commit message, ensures a feature branch, and commits |
| Git Branch Naming | `/development:git-branch-naming` | Defines the branch naming convention (`<type>/<issue>-<description>`) and creates properly named branches |

**Agents:**

| Agent | Model | Focus |
|-------|-------|-------|
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
|-------|---------|-------------|
| Review | `/development-swift:review [paths]` | Spawns 6 specialized agents in parallel to analyze bugs, security, performance, Swift 6 compliance, code quality, and test coverage |

**Agents:**

| Agent | Model | Focus |
|-------|-------|-------|
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
|-------|---------|-------------|
| Maintenance dispatcher | `/development-python:maintenance <json>` | Parses input, runs coverage pre-flight, spawns per-tool agents in parallel worktrees, aggregates results. Standalone invocation prints usage and stops. |

**Agents:**

| Agent | Model | Focus |
|-------|-------|-------|
| python-ruff-fixer | haiku | `ruff check --fix` (safe) + `ruff format` + `--unsafe-fixes` with test verification |
| python-semgrep-triage | sonnet | Per-finding: fix (refactor) / suppress (`# nosemgrep` + reason); LSP-driven scope check; only escalates when public API changes |
| python-snyk-triage | sonnet | Snyk Code + Snyk OSS; auto-bumps patch + minor versions in pyproject.toml/requirements.txt; distro CVEs → 90-day `.snyk` ignore |
| python-sonar-triage | sonnet | SonarCloud bugs/smells/vulns; security hotspots investigated context-first, not punted by default |
| python-major-upgrade | opus | Reads official release notes via WebFetch; maps breaking changes to call sites via LSP; applies migration; iterates up to 3 times on test failures |
| python-coverage-improver | opus | Brings under-covered modules up to threshold by writing meaningful behavior tests; never modifies production code |
| python-dependabot-triage | sonnet | Reviews each open Dependabot PR; auto-approves + merges patch + minor bumps with green CI (after scanning release notes for breaking-change flags); defers majors and red-CI PRs to human-review |

All worktree-modifying agents run their fixes through the project's
test suite locally before declaring success. CI is the secondary
safety net, not the primary verification loop.

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

```
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

## License

MIT
