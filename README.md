# Claude Code Plugins

A collection of plugins for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Plugins

### development

Language-agnostic workflow tooling for git operations, committing, and branch management.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| Bootstrap | `/development:bootstrap` | Sets up the full quality + security toolchain for a project. Public repos get SonarCloud + Snyk + CodeQL; private repos get self-hosted SonarQube + Trivy + a self-hosted runner. Generates pre-commit hooks, Dependabot config, issue/PR templates, branch protection, and the Zero Tolerance Quality Gate (≥90% coverage on new code, 0 code smells, all A ratings). On macOS, automation scripts handle SonarCloud / SonarQube / Snyk setup, secret storage, Quality Gate creation, and runner registration. Idempotent — safe to re-run. **Requires macOS + Homebrew** (see Requirements below). |
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

### dev-swift

Swift-specific development tooling — code review and formatting/linting.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| Review | `/dev-swift:review [paths]` | Spawns 6 specialized agents in parallel to analyze bugs, security, performance, Swift 6 compliance, code quality, and test coverage |

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
claude --plugin-dir ./development --plugin-dir ./dev-swift
```

Then use the slash commands:

```
# Development workflow
/development:commit              # format, lint, generate message, commit
/development:commit "Fix auth"   # format, lint, commit with given message

# Swift code review
/dev-swift:review                # review all Swift files
/dev-swift:review Sources/       # review a specific directory
```

## Maintaining this repo

The bootstrap skill pins versions inside `.tmpl` files (GitHub Actions
versions, pre-commit hook revs, Docker image tags, language runtime
versions). Standard Dependabot can't update those — see
[MAINTAINING.md](./MAINTAINING.md) for the quarterly refresh checklist
that keeps the templates current. ~20 minutes per quarter.

## License

MIT
