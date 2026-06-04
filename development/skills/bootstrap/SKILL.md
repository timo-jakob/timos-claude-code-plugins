---
name: bootstrap
description: >
  Bootstraps a project with the full quality + security toolchain. Detects repo
  visibility (public vs private), languages, and Docker presence, then generates
  GitHub Actions workflows, scanner configs, pre-commit hooks, branch protection,
  Dependabot, templates, and developer docs. Public repos use SonarCloud + Snyk;
  private repos use self-hosted SonarQube + Trivy. Enforces a Zero Tolerance
  standard (≥90% new-code coverage, 0 code smells, all A ratings) via layered
  enforcement: a `coverage-floor` CI step + a `diff-cover` pre-push hook + the
  Sonar Quality Gate (custom on paid SonarCloud / self-hosted SonarQube; falls
  back to `Sonar way` on SonarCloud free, where the CI step is the real 90%
  gate because custom-gate assignment is paywalled).
  Idempotent — safe to re-run on partially configured repos.
disable-model-invocation: false
---

You are a project bootstrap orchestrator. The user wants to set up the full
quality + security surroundings for a project.

**User input:** $ARGUMENTS

Supported flags:
- `--review` — run the opt-in senior-review agent (Step 6) after the bootstrap
  completes. Adds an opus pass for high-stakes first bootstraps.
- `--signed-commits` — additionally enforce cryptographically signed commits
  (GPG or SSH) on the default branch. Off by default because every
  contributor must register a signing key. When set, the orchestrator
  invokes `branch-protection.sh --require-signed-commits true` in Step 4b.

## Guiding Principles

- **Shift-left first**: every check that runs in CI must also run locally before
  the commit. Pre-commit hooks + agent-guided scans during implementation are
  the primary lines of defence; CI is the safety net.
- **Zero Tolerance standard** on *new code*: ≥90% line coverage, 0 code
  smells, 0 bugs, 0 vulnerabilities, all Sonar ratings = A, ≤3% duplications,
  100% security hotspots reviewed. Enforced in three layers, not just one:
  the `coverage-floor` CI step (fails the build below 90% on new lines), the
  `diff-cover` pre-push hook (same check locally), and the Sonar Quality Gate
  (custom "Zero Tolerance" gate on paid SonarCloud / self-hosted SonarQube;
  `Sonar way` fallback on SonarCloud free, where the CI step is the real 90%
  gate). Existing-code debt is out of scope (tracked separately by the
  maintenance skill — GitHub issue #5).
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
- `github_state` — **GitHub-side state** the on-disk artifacts don't see:
  - `branch_protection` — `state` is one of `applied | missing | forbidden |
    unknown`; when applied, also includes `applied_contexts` (the
    required-status-check list), `required_reviews`, `linear_history`,
    `force_push`.
  - `secrets.names` — Actions secrets currently set on the repo.
  - `sonar_project_exists` — `true|false|null` (null = couldn't check —
    private repo, no project key in `sonar-project.properties`, or network
    failure).

  Empty `{}` when `has_github_remote=false` or `gh` is not authenticated.
  This block is the load-bearing input for distinguishing "files present
  + Step 4 done" from "files present + Step 4 never ran" — see State D
  handling below.

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
3. **Inspect `github_state` before deciding what to offer the user.** If
   `existing_artifacts` is complete (every expected file present) AND
   `github_state` reports any of the following gaps, the right next action
   is a **gap-fill flow**, not the template-drift menu — Step 4 of a prior
   bootstrap clearly didn't complete:

   - `branch_protection.state == "missing"` → offer "Apply branch protection
     now" as the primary action.
   - `branch_protection.state == "applied"` but `applied_contexts` doesn't
     include every context the rendered workflows would produce → offer
     "Reconcile branch-protection contexts (M missing, N stale)."
   - Expected secrets not in `secrets.names` (public: `SONAR_TOKEN`,
     `SNYK_TOKEN`; private: `SONAR_TOKEN`, `SONAR_HOST_URL`) → offer "Store
     missing secrets: \<list\>."
   - `visibility == "public"` AND `sonar_project_exists == false` → offer
     "Set up the SonarCloud project."

   Gap-fill actions invoke only the specific Step 4 sub-scripts they need
   (e.g., `branch-protection.sh`, `gh secret set`); they do NOT touch files
   in the working tree. If multiple gaps coexist, present them as a
   checkboxed list so the user can pick a subset.

4. When `existing_artifacts` is complete AND `github_state` shows no gaps,
   THEN fall through to the template-drift menu (compare on-disk files
   against current templates and offer per-file apply / skip / cherry-pick).

5. Continue to **shared questions** below if any answer is still unknown
   (language detection may still need user input if `languages=[]`).

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
| **Q6: Security contact email** | Always (no detection signal) | "What email should appear in `SECURITY.md` as a fallback channel for security reports? Leave blank to use GitHub Security Advisories only." | Drives `{{SECURITY_CONTACT_BLOCK}}` substitution in `SECURITY.md`. See substitution rules below. |

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
  Coverage gate:    90% on new code, enforced by CI `coverage-floor` step + pre-push hook
  Sonar gate:       "Zero Tolerance" custom gate (paid plan / self-hosted) or `Sonar way` fallback (SonarCloud free)
  CI runner:        <github-hosted | self-hosted>
  Will create:
    - <list of files to create>
  Will skip (already present):
    - <list of files left alone>
  Will offer diff for (mismatched existing files):
    - <list of files that exist but differ from template>
```

Ask for confirmation. Do not proceed until the user explicitly approves.

## Step 2.5: Plan Review (parallel agents)

Before writing any files, fan out three review agents **in parallel** in a
single message. They run against the **planned** output (template content
after placeholder substitution, but not yet written to disk).

Spawn all three in a single assistant turn with multiple `Agent` tool calls:

| Agent | Model | What it reviews |
|---|---|---|
| `bootstrap-security-reviewer` | opus | GH Actions permissions, secret references, runner-event safety, scan-gates-push, unpinned third-party actions |
| `bootstrap-config-consistency` | sonnet | Cross-references: Sonar keys, workflow job IDs ↔ branch-protection contexts, secret refs ↔ SETUP.md, language fragment ↔ detected languages |
| `bootstrap-idempotency-reviewer` | sonnet | For each existing file conflicting with a template, recommends skip/overwrite/merge |

Inputs to each agent are provided **in the agent's prompt**, not on disk
(files aren't written yet):
- Security reviewer: full text of each planned workflow file + the planned
  permission blocks + the runner choice (`ubuntu-latest` vs `self-hosted`).
- Consistency reviewer: full text of `sonar-project.properties`, the planned
  workflow file, `SETUP.md`, and the `checks` array `branch-protection.sh`
  would use given current detection results.
- Idempotency reviewer: for each entry in `existing_artifacts` from
  detection — the current on-disk content (read it) AND the planned
  template content. **Also pass any pre-existing workflow files in
  `.github/workflows/` that the user is replacing or that overlap
  semantically with the generated workflows** — see "workflow
  replacement diff" below. Those won't appear in `existing_artifacts`
  because their filenames don't match our templates, but they're the
  most common source of "we silently lost a custom step" regret.

### Workflow replacement diff

The orchestrator confirmed with the user which planned workflow file
they want to land (e.g., `quality-public.yml`). If the target repo
already has *other* workflows in `.github/workflows/` (e.g., a hand-
rolled `test.yml`, `ci.yml`, `lint.yml`), the user usually wants the
new workflow to subsume them — but only after seeing what would be
lost. Custom Python version pins, apt-get system-dep installs,
`timeout-minutes`, env vars, container service definitions, etc.,
all live in user-authored workflows and DO NOT live in our templates.
Silently deleting them is the most expensive bootstrap regret.

**Required action:** before Step 3, list every file under
`.github/workflows/` in the target repo. For each that is not part of
the planned generation set:

1. Read its full content.
2. Include it in the idempotency-reviewer prompt with a tag like
   `[REPLACE-CANDIDATE: tests/integration with custom apt-get installs]`.
3. The reviewer compares it semantically against the planned
   `quality-*.yml` and surfaces things that would be lost: Python
   version pins, system deps, custom timeouts, env vars, secret refs,
   container services, etc.
4. Present findings to the user as a confirmation step:
   *"Found `test.yml` with: Python 3.13, `apt-get install tesseract-ocr poppler-utils`, `timeout-minutes: 20`. Delete it, fold these into the new `quality-public.yml`, or keep both?"*
5. **Default to keep-both unless the user explicitly chose merge or delete**
   — that's the least-destructive option. Generating both workflows side-
   by-side wastes a few seconds of CI but loses nothing.

Block on all three agents finishing. Aggregate their reports:

1. If any agent returns `Verdict: BLOCK` → present findings to the user, fix
   or override. Do not proceed to Step 3 without explicit user override.
2. If all return `PROCEED` or `PROCEED WITH WARNINGS` → surface a short
   summary to the user ("Plan review: 0 blockers, 2 warnings — proceeding").
3. For idempotency findings: present per-file recommendations and confirm
   each `overwrite` or `merge` with the user before applying.

## Step 3: Generate Files

Use the templates in `<skill-base-dir>/templates/`. Fill placeholders by simple
text replacement before writing:

| Placeholder | Value |
|---|---|
| `{{PROJECT_NAME}}` | display name — repo name from `gh repo view --json name` or the directory name. Use in titles, prose ("Contributing to X", "vulnerability in X"), and Sonar's `sonar.projectName`. |
| `{{PROJECT_SLUG}}` | `<owner>/<repo>` — full GitHub path. Use in URL contexts (`ghcr.io/<slug>`, `github.com/<slug>/security/advisories/new`, `scorecard.dev/viewer/?uri=github.com/<slug>`, cosign `--certificate-identity-regexp`). From `gh repo view --json nameWithOwner` or `<github_repo>` field of `detect-stack.sh`. |
| `{{PROJECT_KEY}}` | for Sonar — usually `<github-org>_<repo>` (SonarCloud convention) or `<repo>` (SonarQube) |
| `{{ORG_KEY}}` | initial value: `<github-org>`. **`automate-public.sh` auto-detects the real SonarCloud org slug after token paste** (some accounts have a `-github` suffix) and patches `sonar-project.properties` in place. The placeholder here is the best-effort initial value; the script overrides it during automation. |
| `{{DEFAULT_BRANCH}}` | from `gh repo view --json defaultBranchRef` or `main` |
| `{{LANGUAGES}}` | space-separated detected languages |
| `{{COVERAGE_THRESHOLD}}` | always `90` |
| `{{PYTHON_VERSION}}` | from `detect-stack.sh` (`python_version` field) — parsed from `pyproject.toml`'s `requires-python`. Defaults to `3.12` when Python isn't detected or no `requires-python` is set. Substitute as-is (e.g., `3.13`). |
| `{{PYTHON_VERSION_COMPACT}}` | same as `{{PYTHON_VERSION}}` but with the dot stripped (e.g., `313`). Used in `ruff.toml`'s `target-version = "py{{PYTHON_VERSION_COMPACT}}"`. Compute as `python_version.replace('.', '')`. |
| `{{CODEQL_LANGUAGES}}` | comma-separated CodeQL language identifiers — map detected languages: `typescript` → `javascript-typescript`, `python` → `python`, `go` → `go`, `swift` → `swift`. Drop the codeql workflow entirely if the only detected language is one CodeQL does not support. |
| `{{SECURITY_CONTACT_BLOCK}}` | substitute one of two blocks based on Q6 answer (security contact email). See below. |

### Python-specific recommendation (when applicable)

If `has_pytest_cov=false` from detection AND Python is in the detected languages,
surface a TODO to the user during Step 5 (manual checklist):

> 🐍 **Add `pytest-cov` to your project's dev deps.** The generated workflow
> installs it inline in CI so coverage works there, but for local
> `pytest --cov` to work you need it in `[project.optional-dependencies].dev`
> in `pyproject.toml`, or in your `requirements-dev.txt`. Recommended pin:
> `pytest-cov>=5.0.0`.

Do not modify the user's `pyproject.toml` automatically — that's their file.
Just call it out.

### `{{SECURITY_CONTACT_BLOCK}}` substitution

If the user provided an email in Q6, substitute the following block (4-space indented to fit the existing markdown list level):

```
   Email **<email-from-Q6>**. For sensitive material, include the line
   "Please respond via a private channel" in your subject so we route the
   reply appropriately.
```

If the user left Q6 blank, substitute this block instead:

```
   No email channel is configured for this project. If you cannot reach us
   through GitHub Security Advisories, open a public issue *only* with the
   description "request to contact maintainers privately about a security
   matter" — do not include vulnerability details — and a maintainer will
   follow up over a private channel.
```

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

### `.gitignore` merging

When the target repo already has a `.gitignore`, do **not** simply append
the language fragment — that produces a noisy diff full of duplicate
patterns the user already had. Use the deduping helper:

```bash
"<skill-base-dir>/scripts/merge-gitignore.sh" \
  "<target-repo>/.gitignore" \
  "<skill-base-dir>/templates/languages/<lang>/gitignore" \
  > /tmp/to-append.txt
```

`merge-gitignore.sh` reads the existing `.gitignore`, strips out any
pattern lines from the fragment that already match (exact-string
comparison, whitespace-trimmed), and emits the remaining lines —
preserving comments and blank lines from the fragment so the appended
block stays readable.

Wrap the helper's output in a short header comment so a future reader
knows where the appended entries came from:

```
# <blank line>
# --- added by /development:bootstrap (Python fragment, deduped) ---
<helper output here>
```

If the target repo has no `.gitignore` yet, copy the language fragment
as-is (the helper handles that case too — pass a non-existent path as
the first arg and it emits the fragment unchanged).

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
- `.gitignore` (merge language fragments from `templates/languages/<lang>/gitignore` — see `.gitignore` merging below)
- `.editorconfig` (cross-editor whitespace + encoding settings)
- `LICENSE` — only if missing, ask which license (default MIT)
- `trivy.yaml` (shared Trivy config — license + vuln + secret + misconfig scanners; license policy customizable per project)
- `.github/SECURITY.md` (vulnerability disclosure policy — substitute `{{SECURITY_CONTACT_BLOCK}}` per Q6 answer)

### 3b. Public path (SonarCloud + Snyk)

Copy from `templates/public/`:
- `.github/workflows/quality-public.yml`
- `.github/workflows/quality-public-noop.yml` (doc-only PR companion — see below)
- `.github/workflows/codeql.yml`
- `.github/workflows/codeql-noop.yml` (doc-only PR companion for CodeQL)
- `.github/workflows/scorecard.yml` (OpenSSF Scorecard — weekly supply-chain health check; public-only because the score is publicly visible)
- `sonar-project.properties`
- `.snyk`

The `image` job (build → scan → conditional GHCR push) is only kept if
`has_dockerfile=true` in both `quality-public.yml` AND
`quality-public-noop.yml` — see "Container image publishing" below.

The `-noop.yml` companion workflows define dummy jobs with the SAME
names as the required-status-check jobs in their main counterparts,
but trigger only on doc-only PRs (the inverse of the main workflow's
`paths-ignore`). Without these companions, doc-only PRs would sit
unmergeable forever because GitHub leaves a required check in the
`expected` state when its defining workflow is skipped via
`paths-ignore`. See issue #96.

### 3c. Private path (SonarQube + Trivy)

Copy from `templates/private/`:
- `.github/workflows/quality-private.yml` (runs on `self-hosted`)
- `.github/workflows/quality-private-noop.yml` (doc-only PR companion — runs on `self-hosted` too so it also catches runner-down failures on doc PRs)
- `sonar-project.properties`
- `infra/sonarqube/docker-compose.yml`
- `infra/sonarqube/README.md`
- `infra/github-runner/README.md`

(`trivy.yaml` is now common — see 3a — because both paths run Trivy for
license scanning.)

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
- **Every published image carries a CycloneDX JSON SBOM and SLSA provenance
  attestation**, attached as OCI artifacts via Buildx's `sbom: true` and
  `provenance: mode=max`. The SBOM is generated by Syft (BuildKit's bundled
  scanner) — one canonical source regardless of public/private path. The
  SBOM is independently validated with `cyclonedx-cli` after generation and
  also uploaded as a workflow artifact for human inspection.
- **Every published image is signed by cosign** using keyless OIDC against
  GitHub's token-issued identity. No key management. The signature proves
  the image came from this workflow on this repo — defeats the
  same-tag-substitution attack the SBOM and provenance alone don't address.
  Verifiable with `cosign verify --certificate-identity-regexp ... --certificate-oidc-issuer https://token.actions.githubusercontent.com`.
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
  schedule:        { cron: "0 6 * * 1" }    # weekly Monday 06:00 UTC drift
  workflow_dispatch:
```

- `pull_request` runs on every PR targeting main — gates merges.
- `push` runs on main — required for SonarCloud/SonarQube to maintain its
  "Clean as You Code" baseline.
- `release: published` runs on tag releases — drives semver image publishing.
- `schedule` re-runs the full quality pipeline weekly so newly-disclosed
  CVEs and license-database updates surface within ~7 days, even when no
  PR touches the affected area.
- `workflow_dispatch` enables manual reruns from the GitHub UI.
- `paths-ignore` skips doc/license-only changes.

### Pre-commit CI backstop

Both quality workflows include a `pre-commit` job (using
`pre-commit/action@v3.0.1`) that runs the same hooks as locally. This
catches contributors who used `git commit --no-verify` or pushed from a
machine without pre-commit installed — local hooks are an honour system,
the CI job makes it enforced.

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

## Step 3.5: Post-Write Validation

Run the `bootstrap-validator` agent (haiku — fast, cheap). It checks the
files **on disk**:
- All YAML and JSON parse.
- No `{{...}}` placeholders remain.
- Workflow `needs:` and `steps.<id>.outputs.*` references resolve.
- Sonar properties are sane (keys set, coverage paths plausible).
- If `pre-commit` is installed locally, validates the config.

If the agent returns `Verdict: BLOCK`, show errors to the user. Offer to:
- Re-run Step 3 (regenerate the offending files), or
- Manually fix individual files and re-run the validator.

Do not proceed to Step 4 until the validator returns `PROCEED`.

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
- If `--signed-commits` flag was passed at invocation, also pass
  `--require-signed-commits true` to `branch-protection.sh`, which sets
  `required_signatures: true` on the rule. Warn the user that every
  contributor must register a GPG or SSH signing key in their GitHub
  account before they can push to a protected branch; `SETUP.md` has the
  per-contributor setup recipe.

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
  --has-codeql "true" \
  --codeql-languages "<space-separated languages, e.g. 'python typescript'>"
```

`--codeql-languages` must be passed whenever `--has-codeql=true`. CodeQL's
`analyze` job runs as a matrix per language and GitHub reports each one
as `analyze (<lang>)`. Without the language list, the script can't build
the right required-status-check contexts and CodeQL checks would never
register as required.

This walks the user through:
- Opening SonarCloud, signing in via GitHub, importing the repo (one-time
  human step — the only browser action required).
- Pasting their SonarCloud user token.
- Best-effort creating + assigning the "Zero Tolerance" Sonar Quality Gate.
  On SonarCloud free, create/assign returns 403 (custom gates are Team/Enterprise
  features); the script falls back to the default `Sonar way` gate. In either
  case the CI `coverage-floor` step is the real 90% enforcement.
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
  "Zero Tolerance" Sonar Quality Gate (works on self-hosted SonarQube CE
  unlike SonarCloud free — custom gates are unrestricted self-hosted). The
  CI `coverage-floor` step adds belt-and-suspenders enforcement of the same
  90% bar.
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
4. SonarCloud paid plan: create the "Zero Tolerance" Quality Gate as documented
   in SETUP.md and assign it to this project. **SonarCloud free: skip this
   step** — custom-gate assignment is paywalled. The CI `coverage-floor` step
   is the real 90% enforcement on free; the default `Sonar way` gate carries
   the smells / ratings / duplications signals.
5. Push the branch and open a PR — CI will run.
```

For private path the checklist additionally includes:
- Start SonarQube: `cd infra/sonarqube && docker compose up -d`
- Register self-hosted runner (see `infra/github-runner/README.md`).
- Mint SonarQube project token, store as `SONAR_TOKEN` secret.

## Step 6: Final Senior Review (opt-in, only if `--review` was passed)

If the user invoked the skill with `--review`, run the `bootstrap-reviewer`
agent (opus). It reads the full set of generated files and produces a
short senior-engineer critique covering coherence, operability,
maintainability, and first-impression.

This is **opt-in** because the other three review agents already cover the
common-case risks; the senior review is a deeper pass for high-stakes
first bootstraps. Surface the agent's report to the user verbatim.

## Important Rules

- NEVER overwrite a user's file without explicit confirmation.
- NEVER push to remote unless the user explicitly asks.
- NEVER commit secrets or tokens to the repo. All credentials go to GitHub
  Actions secrets only.
- If the visibility detection fails or `gh` is not authenticated, ask the user
  directly; do not guess.
- The Zero Tolerance standard (90/0/A) is non-negotiable. The Sonar gate
  definition encodes it on paid SonarCloud and self-hosted SonarQube. On
  SonarCloud free (where custom-gate assignment is paywalled), the standard is
  carried by the CI `coverage-floor` step + pre-push hook + the default
  `Sonar way` gate for the remaining signals. See `SETUP.md` for the API
  recipe and the layered-enforcement model.
- Self-hosted runners are **only** used for private repos. Never configure a
  self-hosted runner for a public repo (forks can run arbitrary code).
