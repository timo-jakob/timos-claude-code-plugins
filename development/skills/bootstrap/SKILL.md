---
name: bootstrap
description: >
  Bootstraps a project with the full quality + security toolchain. Detects repo
  visibility (public vs private), languages, and Docker presence, then generates
  GitHub Actions workflows, scanner configs, pre-commit hooks, branch protection,
  Dependabot, templates, and developer docs. Public repos use SonarCloud + Snyk;
  private repos use self-hosted SonarQube + Trivy. Enforces a Zero Tolerance
  Quality Gate (≥90% coverage on new code, 0 code smells, all A ratings).
  Idempotent — safe to re-run on partially configured repos.
disable-model-invocation: false
---

You are a project bootstrap orchestrator. The user wants to set up the full
quality + security surroundings for a project.

**User input:** $ARGUMENTS (usually empty — all configuration is detected or asked)

## Guiding Principles

- **Shift-left first**: every check that runs in CI must also run locally before
  the commit. Pre-commit hooks + agent-guided scans during implementation are
  the primary lines of defence; CI is the safety net.
- **Zero Tolerance Quality Gate** on *new code*: ≥90% line coverage, 0 code
  smells, 0 bugs, 0 vulnerabilities, all Sonar ratings = A, ≤3% duplications,
  100% security hotspots reviewed. Existing-code debt is out of scope (tracked
  separately by the maintenance skill — GitHub issue #5).
- **Idempotent**: never overwrite a user file without confirmation. Always
  detect what already exists and skip or diff before writing.
- **Public vs private paths are strictly separated**: SonarCloud + Snyk for
  public repos, self-hosted SonarQube + Trivy for private. Do not mix.

## Step 1: Detect Repo State

Run the stack detection script and capture its JSON output:

```bash
chmod +x <skill-base-dir>/scripts/detect-stack.sh
<skill-base-dir>/scripts/detect-stack.sh
```

The script reports:
- `git_initialized` — is this a git repo
- `has_github_remote` — is there an `origin` pointing at github.com
- `visibility` — `public`, `private`, or `unknown` (via `gh repo view`)
- `languages` — array of detected languages (`swift`, `typescript`, `python`, `go`)
- `has_dockerfile` — whether a Dockerfile exists at the repo root or in common locations
- `existing_artifacts` — map of well-known config files already present, so we
  can skip or diff them

### Decision tree (handle these in order — each step builds on the prior)

Decide the starting state from the detection output, then run the matching
flow. Stop and ask for input wherever marked; do not guess.

#### State A: empty folder, no `.git` directory

`git_initialized=false`, `languages=[]`, `existing_artifacts={}`.

1. Ask: **"This directory isn't a git repository yet. Initialize one here?"**
   (yes / no — if no, stop.)
2. Run `git init -b main`.
3. Continue to **shared questions** below.

#### State B: git repo, no GitHub remote

`git_initialized=true`, `has_github_remote=false`. Files may or may not exist.

1. If `git remote -v` shows a non-GitHub remote (GitLab, Bitbucket, etc.) →
   inform the user: **"Your remote points at <host>. The workflows I generate
   target GitHub Actions, which won't run there. Add a GitHub remote anyway,
   or stop?"** If they want to stop, do so.
2. Continue to **shared questions** below.

#### State C: git repo with GitHub remote, but `gh` not authenticated

`has_github_remote=true`, `visibility=unknown`.

1. Inform: **"I see a GitHub remote but `gh` isn't authenticated. I need to
   know the repo's visibility (public vs private) since they take different
   bootstrap paths."**
2. Suggest the user run `gh auth login` once, then re-run the skill. If they
   prefer to proceed without authenticating, fall through to the **shared
   questions** to ask visibility manually.

#### State D: git repo with GitHub remote, `gh` authenticated

`has_github_remote=true`, `visibility ∈ {public, private}`.

1. Skip the GitHub repo creation questions — already done.
2. Skip the visibility question — already known.
3. Continue to **shared questions** below (language detection may still need
   user input if `languages=[]`).

### Shared questions

Ask each only if the detection didn't already answer it. Use the canonical
wording so behavior stays consistent:

| Q | When to ask | Canonical wording | Effect |
|---|---|---|---|
| **Q1: Create GitHub repo now?** | State A, or State B without a GitHub remote | "Do you want me to create a GitHub repo for this and connect it as `origin` now?" | If yes → Q2 + Q3 + run `gh repo create <name> --<vis> --source=. --remote=origin`. If no → Q3 only. |
| **Q2: Repo name** | Only if Q1=yes | "What should the GitHub repo be named? (default: `<current-directory-name>`)" | Used in `gh repo create`. |
| **Q3: Visibility** | Whenever `visibility=unknown` (including Q1=no path) | "Will this be a **public** or **private** repository? This selects the toolchain path — public uses SonarCloud + Snyk, private uses self-hosted SonarQube + Trivy." | Locks the path for the rest of the skill. |
| **Q4: Languages** | Whenever detected `languages=[]` | "I couldn't detect any languages from existing files. Which languages will this project use? (swift / typescript / python / go — choose one or more)" | Selects per-language fragments and CodeQL matrix. |
| **Q5: Dockerfile incoming?** | Whenever `has_dockerfile=false` and the user mentioned containers, OR proactively only if Q4 implies an image build | "Will this project ship a Dockerfile / container image? If yes, I'll wire up Snyk container / Trivy image scans now." | Determines whether to keep the `DOCKER` blocks in workflow templates. Default to "no, skip for now" if the user is unsure — they can re-run the skill later when they add a Dockerfile. |

### After the decision tree

You now have, with certainty:
- A git repository (either pre-existing or just initialized).
- A visibility (`public` or `private`).
- Optionally, a GitHub remote (created or pre-existing).
- A non-empty languages list.
- A Docker scanning flag.

If any of these is still missing, stop and ask. Never proceed with a missing
value or a guessed default.

## Step 2: Show the Plan and Get Confirmation

Before writing anything, present a clear summary:

```
Bootstrap plan:
  Visibility:       <public | private>
  Languages:        <swift, typescript, ...>
  Docker scanning:  <yes | no>
  Coverage gate:    90% line coverage on new code
  Quality gate:     Zero Tolerance (0 smells, all A ratings)
  CI runner:        <github-hosted | self-hosted>
  Will create:
    - <list of files to create>
  Will skip (already present):
    - <list of files left alone>
  Will offer diff for (mismatched existing files):
    - <list of files that exist but differ from template>
```

Ask for confirmation. Do not proceed until the user explicitly approves.

## Step 3: Generate Files

Use the templates in `<skill-base-dir>/templates/`. Fill placeholders by simple
text replacement before writing:

| Placeholder | Value |
|---|---|
| `{{PROJECT_NAME}}` | repo name from `gh repo view --json name` or the directory name |
| `{{PROJECT_KEY}}` | for Sonar — usually `<github-org>_<repo>` (SonarCloud convention) or `<repo>` (SonarQube) |
| `{{ORG_KEY}}` | for SonarCloud — `<github-org>` |
| `{{DEFAULT_BRANCH}}` | from `gh repo view --json defaultBranchRef` or `main` |
| `{{LANGUAGES}}` | space-separated detected languages |
| `{{COVERAGE_THRESHOLD}}` | always `90` |
| `{{CODEQL_LANGUAGES}}` | comma-separated CodeQL language identifiers — map detected languages: `typescript` → `javascript-typescript`, `python` → `python`, `go` → `go`, `swift` → `swift`. Drop the codeql workflow entirely if the only detected language is one CodeQL does not support. |

### Block stripping in templates

Several templates carry conditional blocks delimited by `# --- TAG-START ---`
and `# --- TAG-END ---` markers (including the surrounding comment lines).
Strip blocks where the tag does not apply:

| Tag | Keep when |
|---|---|
| `TYPESCRIPT` | typescript detected |
| `PYTHON` | python detected |
| `GO` | go detected |
| `SWIFT` | swift detected |
| `DOCKER` | Dockerfile detected |
| `PRIVATE` | visibility == private |

If a tag does not apply, delete the START line, the END line, and everything
between them.

### 3a. Common artifacts (both paths)

Copy from `templates/common/`:
- `.pre-commit-config.yaml` (merge language-specific hooks based on detected languages)
- `.github/dependabot.yml` (add an `updates:` entry per detected language ecosystem)
- `.github/ISSUE_TEMPLATE/bug.yml`
- `.github/ISSUE_TEMPLATE/feature.yml`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `CONTRIBUTING.md`
- `SETUP.md` (manual steps the user must do after bootstrap)
- `CLAUDE.md` (shift-left agent guidance — append a section if one already exists)
- `.gitignore` (merge language fragments from `templates/languages/<lang>/gitignore`)
- `LICENSE` — only if missing, ask which license (default MIT)

### 3b. Public path (SonarCloud + Snyk)

Copy from `templates/public/`:
- `.github/workflows/quality-public.yml`
- `.github/workflows/codeql.yml`
- `sonar-project.properties`
- `.snyk`

The `image` job (build → scan → conditional GHCR push) is only kept if
`has_dockerfile=true` — see "Container image publishing" below.

### 3c. Private path (SonarQube + Trivy)

Copy from `templates/private/`:
- `.github/workflows/quality-private.yml` (runs on `self-hosted`)
- `sonar-project.properties`
- `trivy.yaml`
- `infra/sonarqube/docker-compose.yml`
- `infra/sonarqube/README.md`
- `infra/github-runner/README.md`

The `image` job (build → Trivy scan → conditional GHCR push) is only kept if
`has_dockerfile=true` — see "Container image publishing" below.

### Container image publishing (both paths, if Dockerfile present)

The generated `image` job follows a single shape regardless of public/private:

| Step | Always | On merge to `main` / release |
|---|---|---|
| Build image with Buildx | ✓ | ✓ |
| Compute tags via `docker/metadata-action` (semver + `sha-<7>` + `latest`) | ✓ | ✓ |
| Scan (Snyk container on public / Trivy image on private) | ✓ | ✓ |
| Login to GHCR with `GITHUB_TOKEN` | | ✓ |
| Push to `ghcr.io/<owner>/<repo>` | | ✓ |

Behaviour summary:
- Scan **always** runs — even on PRs — so contributors know if their image is
  broken before merge.
- Push **only** runs on `push` to the default branch and `release: published`.
- The same Buildx cache is reused between scan and push, so the second build
  is fast.
- **Published images are multi-arch**: `linux/amd64` + `linux/arm64`. The arm64
  build covers Apple Silicon Macs, AWS Graviton, and other ARM hosts. PR
  builds stay amd64-only for fast scan feedback.
- Multi-arch uses QEMU emulation on a single x86 runner (free on
  `ubuntu-latest`). Documented upgrade path: matrix with native
  `ubuntu-24.04-arm` runners if QEMU emulation becomes a bottleneck.
- Image visibility is **inherited from the repo** but requires a one-time
  manual flip in package settings after first publish (GHCR defaults new
  packages to private). The generated `SETUP.md` walks the user through this.

### CI trigger surface

All workflows use:
```yaml
on:
  pull_request:    { branches: ["main"], paths-ignore: [docs + license] }
  push:            { branches: ["main"], paths-ignore: [docs + license] }
  release:         { types: [published] }   # workflows that produce artifacts
  workflow_dispatch:
```

- `pull_request` runs on every PR targeting main — gates merges.
- `push` runs on main — required for SonarCloud/SonarQube to maintain its
  "Clean as You Code" baseline.
- `release: published` runs on tag releases — drives semver image publishing.
- `workflow_dispatch` enables manual reruns from the GitHub UI.
- `paths-ignore` skips doc/license-only changes.

### 3d. Per-language fragments

For each detected language, merge in the appropriate config from
`templates/languages/<language>/`:
- Linter config (e.g., `.eslintrc.json`, `ruff.toml`, `.golangci.yml`)
- Coverage tooling note in `sonar-project.properties` (paths, report format)
- Pre-commit hook entries (already merged into `.pre-commit-config.yaml`)

### Idempotency rules (apply for every file write)

For each target file path:
1. If file does not exist → write the template as-is.
2. If file exists and content matches the template → skip silently.
3. If file exists and differs → show the user a diff, ask: overwrite, skip, or
   merge manually. Default to **skip** if the user does not answer clearly.
4. Never delete files the user has.

## Step 4: Post-Write Actions (each with explicit confirmation)

### 4a. Install pre-commit hooks
If `pre-commit` is installed on the user's machine, run:
```bash
pre-commit install
```
If not installed, tell the user how to install it (`brew install pre-commit` or
`pip install pre-commit`) and skip.

### 4b. Branch protection on `main`
Confirm with the user, then via `gh api`:
- Require PR before merge.
- Require status checks: include all jobs from the generated workflow that just
  got created. Use the exact job IDs.
- Require linear history.
- Block force-push and deletion.

If the user does not yet have any commits with the workflows present, point out
that the check names will not appear in the GitHub UI until at least one workflow
run completes — branch protection rules referencing them are still valid, but
GitHub displays them as "expected" until first run.

If the `gh api` call returns a 403 (user is not a repo admin), do not retry.
Print the equivalent manual setup instructions from `SETUP.md` and continue.

### 4c. Initial commit
Offer to commit the generated files using the `/development:commit` flow with a
suggested message like `Bootstrap project with quality and security toolchain`.
Do not push.

## Step 4.5: Offer Automation (macOS + Homebrew only)

The bootstrap skill ships scripts that automate most of the manual steps in
`SETUP.md`. Offer them whenever the host can support them.

### Preflight check

Run the preflight script to validate the local toolchain and offer to brew-install
anything missing:

```bash
"<skill-base-dir>/scripts/preflight.sh" \
  --visibility "<public|private>" \
  --languages "<space-separated detected languages>" \
  --has-dockerfile "<true|false>"
```

The script will:
1. Refuse to run on non-macOS hosts.
2. Refuse to run without Homebrew.
3. List missing tools (`gh`, `jq`, `pre-commit`, `gitleaks`, `semgrep`,
   `sonar-scanner`, plus path-specific: `snyk` for public, `trivy` + Docker for
   private, plus language-specific linters).
4. Offer to `brew install` all missing pieces in one batch.
5. Verify `gh auth status`; offer to run `gh auth login` if not authenticated.
6. For private path: verify Docker daemon is running; offer to launch
   Docker.app if not.

If preflight fails (user declines installs, or non-macOS host), skip Step 4.5
entirely and go straight to Step 5 (manual checklist).

### Per-path automation

If preflight passed, ask the user whether to run the path-specific automation.

**Public path:**
```bash
"<skill-base-dir>/scripts/automate-public.sh" \
  --project-key "<PROJECT_KEY>" \
  --org-key "<ORG_KEY>" \
  --project-name "<PROJECT_NAME>" \
  --default-branch "<DEFAULT_BRANCH>" \
  --has-dockerfile "<true|false>" \
  --has-codeql "true"
```

This walks the user through:
- Opening SonarCloud, signing in via GitHub, importing the repo (one-time
  human step — the only browser action required).
- Pasting their SonarCloud user token.
- Auto-creating the "Zero Tolerance" Quality Gate and assigning it.
- Running `snyk auth --auth-type=token` (token-mode, not OAuth — required for
  GitHub Actions secrets).
- Storing `SONAR_TOKEN` and `SNYK_TOKEN` as GitHub Actions secrets via `gh`.
- Optional: `snyk monitor` for continuous monitoring on snyk.io.
- Applying branch protection.

**Private path:**
```bash
"<skill-base-dir>/scripts/automate-private.sh" \
  --project-key "<PROJECT_KEY>" \
  --project-name "<PROJECT_NAME>" \
  --default-branch "<DEFAULT_BRANCH>" \
  --has-dockerfile "<true|false>"
```

This handles:
- `docker compose up -d` on the generated `infra/sonarqube/docker-compose.yml`.
- Waiting for SonarQube to become healthy (`/api/system/status` polling).
- Generating a random admin password, storing it in the macOS Keychain
  (`security` command, service `sonarqube-local-admin`).
- Changing the SonarQube admin password from `admin/admin` to the generated
  one via API.
- Creating the project, minting an analysis token, creating + assigning the
  "Zero Tolerance" Quality Gate.
- Setting `SONAR_TOKEN` and `SONAR_HOST_URL` as GitHub Actions secrets.
- Downloading and registering a self-hosted GitHub Actions runner as a
  launchd service.
- Applying branch protection.

If the user declines automation at any step, fall back to the manual
instructions in `SETUP.md` for the remaining steps.

## Step 5: Print the Manual-Setup Checklist

Print a clear, ordered checklist of everything the user **still** has to do
manually — i.e., only the steps that automation didn't cover (or that the user
declined). If automation in Step 4.5 ran end-to-end, this checklist may be very
short ("push a branch and open a PR"). Reference `SETUP.md` for full details. Example for public path:

```
NEXT STEPS:
1. Create a SonarCloud account → import this repo → copy SONAR_TOKEN.
2. Sign up for Snyk → copy SNYK_TOKEN.
3. In GitHub repo Settings → Secrets and variables → Actions:
   - Add SONAR_TOKEN
   - Add SNYK_TOKEN
4. In SonarCloud, create the "Zero Tolerance" Quality Gate as documented in
   SETUP.md, and assign it to this project.
5. Push the branch and open a PR — CI will run.
```

For private path the checklist additionally includes:
- Start SonarQube: `cd infra/sonarqube && docker compose up -d`
- Register self-hosted runner (see `infra/github-runner/README.md`).
- Mint SonarQube project token, store as `SONAR_TOKEN` secret.

## Important Rules

- NEVER overwrite a user's file without explicit confirmation.
- NEVER push to remote unless the user explicitly asks.
- NEVER commit secrets or tokens to the repo. All credentials go to GitHub
  Actions secrets only.
- If the visibility detection fails or `gh` is not authenticated, ask the user
  directly; do not guess.
- The Quality Gate definition (90/0/A) is non-negotiable and identical between
  SonarCloud and SonarQube — see `SETUP.md` for the API recipe.
- Self-hosted runners are **only** used for private repos. Never configure a
  self-hosted runner for a public repo (forks can run arbitrary code).
