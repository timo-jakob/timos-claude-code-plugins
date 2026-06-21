---
name: bootstrap
description: >
  Bootstraps a project with the full quality + security toolchain. Detects repo
  visibility (public vs private), languages, and Docker presence, then generates
  GitHub Actions workflows, scanner configs, pre-commit hooks, branch protection,
  Dependabot, templates, and developer docs. Public repos use SonarCloud + Snyk;
  private repos use self-hosted SonarQube + Trivy. Enforces a Zero Tolerance
  standard via layered CI + pre-push + Sonar enforcement (falls back to `Sonar
  way` on SonarCloud free). Idempotent — safe to re-run on partially configured
  repos. Also reconciles GitHub-side state (branch protection, secrets, Sonar
  project) when files are already in place but Step 4 didn't complete (the
  State D gap-fill mode).
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
- `--claude-approver true|false` — install the two Claude GitHub Apps
  (Claude Approver + Claude Maintenance) on this repo and store the
  per-repo secrets + variables the Approver workflow needs. Defaults to
  `false`. Requires the Apps to be registered on this machine first via
  `scripts/register-claude-apps.zsh` (the preflight in Step 4.5 will offer
  to run it when missing). When `true`, the Approver is wired for the
  repo's Approver-capable language (currently Python or Java); it
  warn-and-skips when neither resolves as the review target (§3e).
- `--claude-plugin true|false` — bootstrap this repo as a **Claude Code plugin
  repository** (a marketplace of plugins, not an application). Defaults to
  `false`. When `true`:
  - sets `primary: claude-plugin` in `.maintenance.yml` (overrides `{{PRIMARY}}`
    inference);
  - uses **Renovate** instead of Dependabot — plugin repos are templates, not
    production dependency manifests (renders `renovate.json`, **skips**
    `.github/dependabot.yml`);
  - installs the **plugin-repo lint** pre-commit hooks (shellcheck / shfmt /
    markdownlint) — the `CLAUDE_PLUGIN` block in `.pre-commit-config.yaml`;
  - **does NOT install the Approver.** A plugin repo is the origin of every other
    repo and requires **human-only** approval (no AI auto-approval). If
    `--claude-approver true` is also passed, warn and **skip the Approver** — the
    two are mutually exclusive for a plugin repo.
  See `docs/CLAUDE-APPS.md` for the design and the Apps' permissions.

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
- `languages` — array of detected languages (`swift`, `typescript`, `python`, `go`, `java`)
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
  - Step 4 done" from "files present + Step 4 never ran" — see State D
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
   inform the user: **"Your remote points at `<host>`. The workflows I generate
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
   - `branch_protection.state == "applied"` but
     `branch_protection.required_signatures == false` AND the original
     bootstrap was invoked with `--signed-commits` (or the user asks for
     it now) → offer "Enable required-signatures on the branch protection
     rule." This calls `branch-protection.sh --require-signed-commits true`
     against the existing rule; no contexts list rebuild needed. The
     signing-key contributor warning applies as in Step 4b.
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
   THEN fall through to the **template-drift check** — deterministic first,
   the reviewer only when there's something to classify:

   a. **Run the drift detector** — the same marker-sha256 mechanism
      `/development:maintenance` uses. Don't re-roll the comparison by hand,
      and don't run the heavy `bootstrap-idempotency-reviewer` blind across
      every file:

      ```bash
      "<skill-base-dir>/../maintenance/scripts/detect-template-drift.zsh" "<repo-path>"
      ```

      It reads each stamped file's marker and compares the **recorded
      template sha256 against the current template's sha256**, emitting a JSON
      array: `drifted` (the template changed since this file was rendered — a
      stale toolchain, the #166 bug) and `unknown_provenance` (no marker —
      rendered pre-#213 or hand-made). An **empty array means no drift** —
      report "toolchain is current" and stop; there is nothing to reconcile.

      > **The sha256 is the drift signal — not the version label.** A marker
      > records both the template hash AND the plugin version at render time.
      > A template whose *content* didn't change across a plugin bump keeps its
      > **old version label** (e.g. a marker reads `@ v1.43.0` on a `v1.48.x`
      > plugin) even though there is no drift. The detector compares hashes and
      > ignores the label, and so must you: a stale version label **alone is
      > not drift** — don't chase it. Only a sha256 mismatch is drift.

   b. **Only for the files the detector flags**, invoke
      `bootstrap-idempotency-reviewer` to classify each and recommend apply /
      skip / cherry-pick — passing the on-disk content AND the rendered
      template content (after substitution). The reviewer is the only contract
      that distinguishes:
      - **user customization** (skip-default — user edits the template would
        overwrite)
      - **template-add drift** (merge-default — template added new sections
        the user file lacks, with no conflicting user edits)
      - **outdated patterns** (overwrite-default — pinned versions or
        deprecated actions the template explicitly upgrades)

      Without that classification, template additions silently look like "no
      change" and propagate stale toolchains to existing repos — exactly the
      bug captured in issue #166. Surface the recommendations for per-file
      apply / skip / cherry-pick.

   c. **`unknown_provenance` shortcut — stamp if byte-identical.** A flagged
      file with no marker is often just an older render that's still identical
      to the current template; it only lacks a marker. So before sending an
      `unknown_provenance` file to the reviewer, **byte-compare** it against the
      rendered template (substitute placeholders + strip the same conditional
      blocks bootstrap strips):
      - **byte-identical → just stamp** the provenance marker (non-destructive
        metadata; the file is now tracked) and treat it resolved — **don't**
        invoke the reviewer, there is nothing to classify.
      - **differs → the reviewer** (step b).

      This shortcut is for `unknown_provenance` only. A `drifted` finding (a
      *stamped* file whose recorded template hash changed) always goes to the
      reviewer — a hash mismatch means the template genuinely moved.

5. Continue to **shared questions** below if any answer is still unknown
   (language detection may still need user input if `languages=[]`).

### Shared questions

Ask each only if the detection didn't already answer it. Use the canonical
wording so behavior stays consistent:

| Q | When to ask | Canonical wording | Effect |
| --- | --- | --- | --- |
| **Q1: Create GitHub repo now?** | State A, or State B without a GitHub remote | "Do you want me to create a GitHub repo for this and connect it as `origin` now?" | If yes → Q2 + Q3 + run `gh repo create <name> --<vis> --source=. --remote=origin`. If no → Q3 only. |
| **Q2: Repo name** | Only if Q1=yes | "What should the GitHub repo be named? (default: `<current-directory-name>`)" | Used in `gh repo create`. |
| **Q3: Visibility** | Whenever `visibility=unknown` (including Q1=no path) | "Will this be a **public** or **private** repository? This selects the toolchain path — public uses SonarCloud + Snyk, private uses self-hosted SonarQube + Trivy." | Locks the path for the rest of the skill. |
| **Q4: Languages** | Whenever detected `languages=[]` | "I couldn't detect any languages from existing files. Which languages will this project use? (swift / typescript / python / go / java — choose one or more)" | Selects per-language fragments and CodeQL matrix. |
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

```text
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

## Step 2.4: Gather workflow-replacement candidates

If the target repo already has workflows in `.github/workflows/` (e.g., a
hand-rolled `test.yml`, `ci.yml`, `lint.yml`) that are not part of the
planned generation set, the user usually wants the new workflow to subsume
them — but only after seeing what would be lost. Custom Python version
pins, apt-get system-dep installs, `timeout-minutes`, env vars, container
service definitions, etc., all live in user-authored workflows and DO NOT
live in our templates. Silently deleting them is the most expensive
bootstrap regret.

**Required action:** list every file under `.github/workflows/` in the
target repo. For each that is not part of the planned generation set:

1. Read its full content.
2. Tag it as `[REPLACE-CANDIDATE: <filename> — <one-line summary>]`.

The tagged set is fed into Step 2.5's idempotency-reviewer prompt; user
confirmation happens after the review surfaces what's at risk (see Step
2.5's aggregation step).

## Step 2.5: Plan Review (parallel agents)

Before writing any files, fan out three review agents **in parallel** in a
single message. They run against the **planned** output (template content
after placeholder substitution, but not yet written to disk).

Spawn all three in a single assistant turn with multiple `Task` tool calls:

| Agent | Model | What it reviews |
| --- | --- | --- |
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
  template content. **Also pass the tagged `[REPLACE-CANDIDATE: ...]` set
  from Step 2.4.** Those won't appear in `existing_artifacts` because
  their filenames don't match our templates, but they're the most common
  source of "we silently lost a custom step" regret. The reviewer compares
  each candidate semantically against the planned `quality-*.yml` and
  surfaces what would be lost: Python version pins, system deps, custom
  timeouts, env vars, secret refs, container services.

Block on all three agents finishing. Aggregate their reports:

1. If any agent returns `Verdict: BLOCK` → present findings to the user, fix
   or override. Do not proceed to Step 3 without explicit user override.
2. If all return `PROCEED` or `PROCEED WITH WARNINGS` → surface a short
   summary to the user ("Plan review: 0 blockers, 2 warnings — proceeding").
3. For idempotency findings (including each replace-candidate from Step
   2.4): present per-file recommendations and confirm each `overwrite`,
   `merge`, or `delete` with the user before applying. **Default to
   keep-both for replace-candidates unless the user explicitly chose merge
   or delete** — least-destructive option. Example confirmation:
   *"Found `test.yml` with: Python 3.13, `apt-get install tesseract-ocr poppler-utils`, `timeout-minutes: 20`. Delete
   it, fold these into the new `quality-public.yml`, or keep both?"*

## Step 3: Generate Files

Use the templates in `<skill-base-dir>/templates/`. Fill placeholders by simple
text replacement before writing:

| Placeholder | Value |
| --- | --- |
| `{{PROJECT_NAME}}` | display name — repo name from `gh repo view --json name` or the directory name. Use in titles, prose ("Contributing to X", "vulnerability in X"), and Sonar's `sonar.projectName`. |
| `{{PROJECT_SLUG}}` | `<owner>/<repo>` — full GitHub path. Use in URL contexts (`ghcr.io/<slug>`, `github.com/<slug>/security/advisories/new`, `scorecard.dev/viewer/?uri=github.com/<slug>`, cosign `--certificate-identity-regexp`). From `gh repo view --json nameWithOwner` or `<github_repo>` field of `detect-stack.sh`. |
| `{{PROJECT_KEY}}` | for Sonar — usually `<github-org>_<repo>` (SonarCloud convention) or `<repo>` (SonarQube) |
| `{{ORG_KEY}}` | initial value: `<github-org>`. **`automate-public.sh` auto-detects the real SonarCloud org slug after token paste** (some accounts have a `-github` suffix) and patches `sonar-project.properties` in place. The placeholder here is the best-effort initial value; the script overrides it during automation. |
| `{{DEFAULT_BRANCH}}` | from `gh repo view --json defaultBranchRef` or `main` |
| `{{LANGUAGES}}` | space-separated detected languages |
| `{{PRIMARY}}` | the repo's **primary** type (its reason to exist) for `.maintenance.yml` — a language (`python`) or a topic (`claude-plugin`). Determine: **(0)** if `--claude-plugin true` → `claude-plugin` (the flag is the explicit declaration); **(1)** else if `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json` is present → `claude-plugin`; **(2)** else if exactly one language was detected → that language; **(3)** else (multiple languages) → **ask** the user which is primary (`AskUserQuestion`, options = the detected languages). Surface the chosen primary in the Step 2 plan ("Primary type: X") so the user confirms it there — it's a *declaration*, not a silent inference. |
| `{{COVERAGE_THRESHOLD}}` | always `90` |
| `{{PYTHON_VERSION}}` | from `detect-stack.sh` (`language_meta.python.version`) — parsed from `pyproject.toml`'s `requires-python`. Defaults to `3.12` when Python isn't detected or no `requires-python` is set. Substitute as-is (e.g., `3.13`). |
| `{{PYTHON_VERSION_COMPACT}}` | same as `{{PYTHON_VERSION}}` but with the dot stripped (e.g., `313`). Used in `ruff.toml`'s `target-version = "py{{PYTHON_VERSION_COMPACT}}"`. Compute as `language_meta.python.version.replace('.', '')`. |
| `{{JAVA_VERSION}}` | from `detect-stack.sh` (`language_meta.java.version`) — the JDK major (e.g. `21`, `17`). Defaults to the current LTS `21` when Java isn't detected or the build declares no toolchain (`language_meta.java.version_source == "default"`). Used in `setup-java`'s `java-version`. Substitute as-is. |
| `{{CODEQL_LANGUAGES}}` | comma-separated CodeQL language identifiers — map detected languages: `typescript` → `javascript-typescript`, `python` → `python`, `go` → `go`, `swift` → `swift`, `java` → `java`. Drop the codeql workflow entirely if the only detected language is one CodeQL does not support. |
| `{{SECURITY_CONTACT_BLOCK}}` | substitute one of two blocks based on Q6 answer (security contact email). See below. |

### Python-specific recommendation (when applicable)

If `language_meta.python.has_cov=false` from detection AND Python is in the detected languages,
surface a TODO to the user during Step 5 (manual checklist):

> 🐍 **Add `pytest-cov` to your project's dev deps.** The generated workflow
> installs it inline in CI so coverage works there, but for local
> `pytest --cov` to work you need it in `[project.optional-dependencies].dev`
> in `pyproject.toml`, or in your `requirements-dev.txt`. Recommended pin:
> `pytest-cov>=5.0.0`.

Do not modify the user's `pyproject.toml` automatically — that's their file.
Just call it out.

### Java-specific recommendation (when applicable)

> **Kotlin DSL only (family policy).** The Java/Spring plugins standardize
> on **`build.gradle.kts`** — one blessed build format, nothing to choose.
> Maven is not accepted, and a Groovy `build.gradle` must be converted to
> Kotlin DSL to be maintained (Step 4c offers the conversion). All wiring
> below is Kotlin DSL.

**Java build-system gate (do this first, from detection).** Read
`language_meta.java.build_system` and `language_meta.java.gradle_dsl`:

- **`build_system == "maven"`** → **reject the Java setup** with a clear
  message and skip all Java-specific generation + Step 4c: "This family is
  **Gradle + Kotlin DSL only** — Maven (`pom.xml`) isn't supported. Migrate
  to Gradle with a `build.gradle.kts`, then re-run /development:bootstrap."
  (Any non-Java languages detected still bootstrap normally.) Carry the
  rejection into the Step 5 checklist as a blocking item.
- **`gradle_dsl == "groovy"`** → Java is supported, but the build must be
  converted; **Step 4c** offers the Groovy→Kotlin conversion.
- **`gradle_dsl == "kotlin"`** → proceed normally.

If `java` is in the detected languages, the generated Gradle CI
(`./gradlew build jacocoTestReport`) and the pre-commit Spotless +
coverage-floor hooks **depend on `build.gradle.kts` applying the Spotless
and JaCoCo plugins**. Those plugins live in the build script — so without
them the **first CI run and the first `git push` both fail**
(`spotlessApply` / `jacocoTestReport` are unknown tasks; the coverage-floor
hook finds no JaCoCo XML). This is not optional polish: it's a prerequisite
for the very pipeline bootstrap just generated. So bootstrap **wires it for
you** — see **Step 4c**, a confirmed (you approve first), idempotent edit.
The canonical wiring 4c applies (Kotlin DSL):

```kotlin
plugins {
    id("com.diffplug.spotless") version "7.0.2"
    jacoco
}
spotless {
    java { googleJavaFormat() }
    // For Kotlin sources, also: kotlin { ktlint() }
}
tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports { xml.required = true }   // required by Sonar + diff-cover
}
tasks.test { finalizedBy(tasks.jacocoTestReport) }
```

**When the project uses gRPC / Protocol Buffers** (has `.proto` files),
Step 4c also adds the generated-sources coverage exclude so stubs don't
skew the gate:

```kotlin
// Top-level afterEvaluate — NOT nested inside `tasks.jacocoTestReport { }`.
// `tasks.test { finalizedBy(tasks.jacocoTestReport) }` realizes the report task
// after the project is evaluated; registering an afterEvaluate from inside a
// realized task block then fails ("project already evaluated"). At project scope
// it runs in the valid context, after the source-set class dirs are populated.
afterEvaluate {
    tasks.jacocoTestReport {
        classDirectories.setFrom(classDirectories.files.map {
            fileTree(it) { exclude("**/build/generated/**") }
        })
    }
}
// The Sonar side (sonar.coverage.exclusions=**/build/generated/**) is
// already in the generated sonar-project.properties.
```

Whether `build.gradle.kts` may be edited at all is the one line the rest of
bootstrap won't cross — **application logic and custom build config stay
the user's**. Step 4c's edit is scoped narrowly to the CI-prerequisite
plugins above, only with explicit confirmation, and it **skips anything
already applied** (so a repo that already has Spotless/JaCoCo gets no edit
and no prompt — a satisfied check produces nothing, not a TODO).

The remaining items below are **recommendations**, surfaced in Step 5 only
when genuinely outstanding — bootstrap does *not* auto-apply them (each is a
structural / architectural choice the user owns). **Gate every one on what
is actually missing; never print a recommendation for something already in
place.**

- **Build-driven versioning (nebula-release).** The generated
  `.github/workflows/release.yml` derives the version from git tags via the
  nebula plugin and assumes **no hardcoded `version = '...'`**. Recommend
  this **only when nebula isn't already applied** (check the build script;
  `language_meta` / the gather may also report it). When it's already wired,
  print **nothing** — it is not a follow-up.

  > ☕ **Adopt build-driven versioning (nebula-release).** Remove any
  > hardcoded `version = "..."` and apply the plugin (Kotlin DSL):
  >
  > ```kotlin
  > plugins {
  >     id("com.netflix.nebula.release") version "<latest>"
  > }
  > ```
  >
  > Then `./gradlew final -Prelease.scope=minor` cuts a release;
  > `./gradlew currentVersion` shows the derived version.

- **Full gRPC/protobuf code generation** (only when `.proto` files exist
  *and* the `com.google.protobuf` plugin isn't already wired). This is a
  structural choice (protoc + the gRPC plugin, transport deps) — recommend,
  don't auto-apply. The `java-grpc-advisor` audits it on each maintenance
  run. When the project already wires it (like tick-client-snapper), print
  nothing.

  > ☕ **Wire gRPC/protobuf code generation** via the `com.google.protobuf`
  > Gradle plugin (`protoc` + the gRPC plugin) so the generated stubs are
  > produced by the build from your authoritative `.proto` contract. See
  > `java-grpc-advisor` for the canonical block.

- **Optional — Gradle dependency locking** (the "built-in" half of
  dependency hygiene, alongside the Snyk App): add
  `dependencyLocking { lockAllConfigurations() }` and run
  `./gradlew dependencies --write-locks` to commit a `gradle.lockfile`.

### `{{SECURITY_CONTACT_BLOCK}}` substitution

If the user provided an email in Q6, substitute the following block (4-space indented to fit the existing markdown list
level):

```text
   Email **<email-from-Q6>**. For sensitive material, include the line
   "Please respond via a private channel" in your subject so we route the
   reply appropriately.
```

If the user left Q6 blank, substitute this block instead:

```text
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
| --- | --- |
| `TYPESCRIPT` | typescript detected |
| `PYTHON` | python detected |
| `GO` | go detected |
| `SWIFT` | swift detected |
| `DOCKER` | Dockerfile detected |
| `PRIVATE` | visibility == private |
| `CLAUDE_PLUGIN` | `--claude-plugin true` |

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

```text
# <blank line>
# --- added by /development:bootstrap (Python fragment, deduped) ---
<helper output here>
```

If the target repo has no `.gitignore` yet, copy the language fragment
as-is (the helper handles that case too — pass a non-existent path as
the first arg and it emits the fragment unchanged).

### 3a. Common artifacts (both paths)

Copy from `templates/common/`:

- `.pre-commit-config.yaml` (merge language-specific hooks based on detected languages; keep the `CLAUDE_PLUGIN` block
  only when `--claude-plugin true`)
- **Dependency updates — pick ONE:**
  - default → `.github/dependabot.yml` (add an `updates:` entry per detected language ecosystem).
  - `--claude-plugin true` → copy `renovate.json` instead (static, no substitution) and **do NOT render
    `.github/dependabot.yml`**. A plugin repo is templates, not production dependency manifests; Renovate's
    github-actions manager (plus the `.tmpl` customManager in the config) covers its real moving surface.
  - **the repo already has a `renovate.json`** (a downstream app already on
    Renovate) → keep it; ask before adding Dependabot and **don't run both**
    (dueling bots create duplicate PRs). Do **not** render
    `.github/dependabot.yml`. Leave the config's substance alone, but if it
    `extends` the **deprecated `config:base`** preset, **offer a confirmed
    one-line swap** to `config:recommended` (Renovate renamed it; `config:base`
    is deprecated) — safe and opt-in. If declined, surface it as a Step 5 TODO.
- `.github/workflows/gitleaks.yml` (static copy — secret-scanning CI for **every** repo; defense in depth behind the
  gitleaks pre-commit hook. Note: repos owned by a GitHub Organization need a `GITLEAKS_LICENSE` repo secret — see the
  workflow comment.)
- `.github/workflows/template-drift-watch.yml` (render `common/.github/workflows/template-drift-watch.yml.tmpl` —
  substitute `{{CLAUDE_PLUGINS_REPO}}`). Scheduled (monthly) watcher for **every** repo: checks this repo's rendered
  files against the latest plugin templates and opens a tracking issue naming the fixes a re-bootstrap would deliver
  (#402). Unlike the approver, it tracks the moving `main` tip — drift means "newer templates exist". Stamp a provenance
  marker (Step 3.6) so it is itself drift-tracked.)
- `.gitleaks.toml` (static copy — gitleaks config used by **both** the pre-commit hook and the CI workflow; allowlists
  documented false positives like `curl -u "$VAR"` examples in `SETUP.md`).
- `.github/ISSUE_TEMPLATE/bug.yml`
- `.github/ISSUE_TEMPLATE/feature.yml`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `CONTRIBUTING.md`
- `SETUP.md` (manual steps the user must do after bootstrap)
- `CLAUDE.md` (shift-left agent guidance — append a section if one already exists)
- `.gitignore` (merge language fragments from `templates/languages/<lang>/gitignore` — see `.gitignore` merging
  below)
- `.editorconfig` (cross-editor whitespace + encoding settings)
- `.yamllint` (YAML lint config — line-length 120, GitHub Actions `on:` allowed; used by the `yamllint` pre-commit
  hook and any YAML CI). Static copy, no substitution.
- `.maintenance.yml` (render `.maintenance.yml.tmpl` — substitute `{{PRIMARY}}`). Declares the repo's primary type so
  `/development:maintenance` treats it as primary and everything else as auxiliary (see ARCHITECTURE.md "Primary /
  auxiliary model").
- `LICENSE` — only if missing, ask which license (default MIT)
- `trivy.yaml` (shared Trivy config — license + vuln + secret + misconfig scanners; license policy customizable per project)
- `.github/SECURITY.md` (vulnerability disclosure policy — substitute `{{SECURITY_CONTACT_BLOCK}}` per Q6 answer)

### 3b. Public path (SonarCloud + Snyk)

Copy from `templates/public/`:

- `.github/workflows/quality-public.yml`
- `.github/workflows/quality-public-noop.yml` (doc-only PR companion — see below)
- `.github/workflows/codeql.yml`
- `.github/workflows/codeql-noop.yml` (doc-only PR companion for CodeQL)
- `.github/workflows/scorecard.yml` (OpenSSF Scorecard — weekly supply-chain health check; public-only because the
  score is publicly visible)
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
- `.github/workflows/quality-private-noop.yml` (doc-only PR companion — runs on `self-hosted` too so it also catches
  runner-down failures on doc PRs)
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
| --- | --- | --- |
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
- **Java only:** render
  `templates/languages/java/.github/workflows/release.yml.tmpl` →
  `.github/workflows/release.yml` (substitute `{{JAVA_VERSION}}`) **and copy**
  `templates/languages/java/scripts/derive-release-scope.zsh` →
  `scripts/derive-release-scope.zsh` (verbatim, `chmod +x`; no substitution) —
  the build-driven semantic-versioning release workflow (nebula-release) plus
  its SemVer-scope deriver. The workflow's default `auto` scope runs the
  script to derive `major`/`minor`/`patch` from the Conventional Commits since
  the last tag, so releases **obey SemVer automatically**. Pair them with the
  nebula versioning TODO in the Java-specific recommendation above (the
  workflow assumes the plugin is applied + no hardcoded `version`). Apply the
  standard idempotency rules (skip/diff if either exists).

### 3e. Claude Approver artifacts (when `--claude-approver true`)

**Plugin-repo exclusion:** if `--claude-plugin true` was set, **skip this section
entirely** — render no Approver workflow or policy, even if `--claude-approver
true` was also passed. A plugin repo is the origin of every other repo and is
**human-only approval** (no AI auto-approval); warn the user that the Approver
flag was ignored because of `--claude-plugin`. Set up human approval the normal
way (Step 4b branch protection requires 1 review; no Approver bot to satisfy it).

When the orchestrator was invoked with `--claude-approver true` **and**
an **Approver-capable language** is in scope (currently `python` or
`java` — the languages that ship a `<lang>-approver` agent), render the
two Approver-specific files.

**Resolve `{{APPROVER_LANG}}`** — the language whose approver runs in CI:

1. If `{{PRIMARY}}` is an Approver-capable language (`python` / `java`) →
   use it.
2. Else if exactly one detected language is Approver-capable → use it.
3. Else (primary is a topic or a no-approver language, and zero or
   multiple Approver-capable languages are detected) → **skip** the
   Approver, per the skip note below.

`{{APPROVER_LANG}}` drives the agent name (`{{APPROVER_LANG}}-approver`)
and the plugin dir (`development-{{APPROVER_LANG}}`) in the workflow, and
selects the policy template:

| Template | Target path in repo | Placeholders to substitute |
| --- | --- | --- |
| `templates/common/.github/workflows/claude-approver.yml.tmpl` | `.github/workflows/claude-approver.yml` | `{{CLAUDE_PLUGINS_REPO}}`, `{{CLAUDE_PLUGINS_REF}}`, `{{APPROVER_LANG}}` |
| `templates/languages/{{APPROVER_LANG}}/approver-policy.md.tmpl` | `.claude/approver-policy.md` | (none) |

Default substitutions:

- `{{CLAUDE_PLUGINS_REPO}}` → `timo-jakob/timos-claude-code-plugins` (the
  canonical plugin family). Users who fork the family can override after
  bootstrap by hand-editing the generated workflow.
- `{{CLAUDE_PLUGINS_REF}}` → the **current commit SHA** of the plugin
  family's `main` branch, resolved at render time:

  ```bash
  git ls-remote https://github.com/timo-jakob/timos-claude-code-plugins main | awk '{print $1}'
  ```

  Pin the literal SHA into the workflow, not the moving `main` ref.
  Why: a breaking change in the plugin family's `main` would otherwise
  silently break every downstream Approver workflow with no commit in
  the downstream repo to bisect. Users opt into upstream changes by
  re-running `/development:bootstrap`, which re-resolves the SHA and
  regenerates the workflow as a normal PR. Once the plugin family ships
  versioned releases, this substitution moves to the latest release tag.
  See #199.

The workflow file applies the standard idempotency rules below. The
policy file (`.claude/approver-policy.md`) is the source of truth for
the Approver's per-PR-type criteria — if it already exists at bootstrap
time, default to **skip** and tell the user that policy changes go through
the normal code-review process (a policy-change PR is evaluated by the
*previous* version of the policy).

Also confirm the existing `.github/PULL_REQUEST_TEMPLATE.md` (rendered in
3a) carries the `## Type` and `## Risk` sections that the Approver reads.
The shipped template already has them; if a user-customised template
exists and is missing either section, surface a finding via the
`bootstrap-idempotency-reviewer` agent rather than overwriting.

**No-approver-language skip.** If `--claude-approver true` was set but
`{{APPROVER_LANG}}` couldn't be resolved (no `python`/`java` in scope, or
the primary is a topic / no-approver language with no single
Approver-capable language to fall back to), do **not** render either
Approver file. Warn the user:

> `--claude-approver true` was requested, but no Approver-capable language
> (currently Python or Java) resolves as this repo's review target. The
> Claude Approver ships per-language; for other languages the workflow and
> policy file would be no-ops. Re-run without the flag, or wait for that
> language's Approver agent to ship.

Offer to drop the flag and continue, or abort. The Step 4.5 install path
also skips when there's no Approver workflow to consume the App
credentials.

### 3f. Language-specific bootstrap artifacts

For each detected language, check whether the language plugin publishes
a bootstrap-artifacts spec and render whatever it lists. The spec is
authoritative for the artifact set: file list with target paths,
placeholder substitutions, branch-protection stance, validator checks,
and idempotency notes. This SKILL only dispatches — the *what* lives in
the language plugin per the language-first principle in
`ARCHITECTURE.md`.

| Language | Plugin spec file | Renders when |
| --- | --- | --- |
| Python | `development-python/docs/api-stability.md` | `pyproject.toml` has a `[project]` table with `name` |
| *(future)* TypeScript / Go / Rust / Swift | *(per the plugin once it ships)* | … |

The Python plugin's API-stability spec is independent of
`--claude-approver`: it renders for any Python project that publishes a
package, regardless of whether the Approver is also enabled. When both
are enabled, the spec describes how the gate's artifact couples with
the Approver's per-type criteria.

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
- When `.github/workflows/claude-approver.yml` was rendered (3e):
  - The workflow YAML parses.
  - No `{{CLAUDE_PLUGINS_*}}` placeholders remain (i.e. the substitution
    ran).
  - `.claude/approver-policy.md` has the load-bearing sections
    (`## Type detection`, `## Baseline criteria`, `## Per-type criteria`,
    `## Confidence calibration`).
- Language-specific bootstrap-artifact checks per each language
  plugin's spec file (see Step 3f). For Python, the spec is
  `development-python/docs/api-stability.md`.

If the agent returns `Verdict: BLOCK`, show errors to the user. Offer to:

- Re-run Step 3 (regenerate the offending files), or
- Manually fix individual files and re-run the validator.

Do not proceed to Step 4 until the validator returns `PROCEED`.

## Step 3.6: Stamp provenance markers on tracked files

Once the validator returns `PROCEED`, stamp each tracked rendered file
with a provenance marker. The marker captures which template the file
was rendered from, the `development` plugin version at render time,
and the template's sha256 at render time. `/development:maintenance`
reads the marker on subsequent runs to detect upstream template drift
(#213).

For each tracked target path that you actually rendered above, run:

```bash
"<skill-base-dir>/scripts/stamp-marker.zsh" \
  --repo "<repo-path>" \
  --target "<target-relpath>" \
  --template "<template-relpath>"
```

Pass the template path you used in Step 3 (e.g., `common/.github/workflows/claude-approver.yml.tmpl`
— relative to `<skill-base-dir>/templates/`).

Tracked target/template pairs (only stamp the targets that were
actually rendered in 3a–3f):

| Target | Template |
| --- | --- |
| `.github/dependabot.yml` | `common/.github/dependabot.yml.tmpl` |
| `.github/workflows/claude-approver.yml` | `common/.github/workflows/claude-approver.yml.tmpl` (only when `--claude-approver true`) |
| `.github/workflows/api-stability.yml` | `common/.github/workflows/api-stability.yml.tmpl` |
| `.github/workflows/codeql.yml` | `public/.github/workflows/codeql.yml.tmpl` |
| `.github/workflows/codeql-noop.yml` | `public/.github/workflows/codeql-noop.yml.tmpl` |
| `.github/workflows/quality-public.yml` | `public/.github/workflows/quality-public.yml.tmpl` |
| `.github/workflows/quality-public-noop.yml` | `public/.github/workflows/quality-public-noop.yml.tmpl` |
| `.github/workflows/quality-private.yml` | `private/.github/workflows/quality-private.yml.tmpl` |
| `.github/workflows/quality-private-noop.yml` | `private/.github/workflows/quality-private-noop.yml.tmpl` |
| `.github/workflows/scorecard.yml` | `public/.github/workflows/scorecard.yml.tmpl` |
| `.github/workflows/release.yml` | `languages/java/.github/workflows/release.yml.tmpl` (only when `java` is detected) |
| `.github/workflows/template-drift-watch.yml` | `common/.github/workflows/template-drift-watch.yml.tmpl` |
| `trivy.yaml` | `common/trivy.yaml.tmpl` |

The `*-noop.yml` companions and `release.yml` are tracked, rendered files just
like their main counterparts — each renders from its **own** template (the
main file is never rendered from a noop template), so stamp each separately
(#371). That way `/development:maintenance`'s drift detector tracks them too.
The `.yamllint` `line-length` exemption (#356) already covers
`.github/workflows/*.yml`, so the new markers won't trip yamllint.

**Scaffold files are intentionally NOT stamped** — `CLAUDE.md`,
`CONTRIBUTING.md`, `SETUP.md`, `SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md`,
`.github/ISSUE_TEMPLATE/*`, `.gitignore`, `.editorconfig`, `.yamllint`,
`.maintenance.yml`, `renovate.json`, `.gitleaks.toml`, `LICENSE`, `sonar-project.properties`,
`.snyk`, `.pre-commit-config.yaml`, `ruff.toml`, the Approver policy at
`.claude/approver-policy.md`. The
maintenance pipeline expects user customization on these and would
emit noisy drift findings every run.

The stamper is idempotent — running it a second time on an
already-stamped file is a silent no-op. Safe to call unconditionally
on every re-bootstrap.

## Step 4: Post-Write Actions (each with explicit confirmation)

### 4a. Install pre-commit hooks

If `pre-commit` is installed on the user's machine, run:

```bash
"<skill-base-dir>/scripts/install-precommit-hooks.zsh"
```

This installs the default `pre-commit` git hook AND every additional
hook type referenced by `stages:` entries in the rendered
`.pre-commit-config.yaml` (e.g., `pre-push` for the coverage-floor
hook). Running a plain `pre-commit install` would only install the
default type and silently leave pre-push (and any other stage) wired
up in config but missing from `.git/hooks/`.

If `pre-commit` is not installed, tell the user how to install it
(`brew install pre-commit` or `pip install pre-commit`) and skip.

Run this step again whenever `.pre-commit-config.yaml` changes — the
script is idempotent, and a refresh that adds a new stage won't fire
on push until the corresponding hook type is installed.

### 4b. Branch protection on `main`

Confirm with the user, then call the helper script:

```bash
"<skill-base-dir>/scripts/branch-protection.sh" \
  --visibility "<public|private>" \
  --has-dockerfile "<true|false>" \
  --has-codeql "<true|false — whether codeql.yml was generated>" \
  --codeql-languages "<comma-separated CodeQL language list, when has-codeql=true>" \
  --default-branch "<DEFAULT_BRANCH>" \
  --require-signed-commits "<true if --signed-commits was passed at invocation, else false>"
```

The script applies a single protection rule that:

- Requires PR before merge.
- Requires status checks — the script computes the exact contexts from
  the flags above (visibility, has-dockerfile, has-codeql, codeql-languages),
  so they line up with the jobs the generated workflow produces.
- Requires linear history.
- Blocks force-push and deletion.
- When `--require-signed-commits true` is set, also enables
  `required_signatures: true`. Warn the user that every contributor must
  register a GPG or SSH signing key in their GitHub account before they
  can push to a protected branch; `SETUP.md` has the per-contributor
  setup recipe.

It also PATCHes two repo-level merge settings (#226):

- `allow_auto_merge: true` — the maintenance approval gate (plugins#224)
  arms GitHub native auto-merge when no approving review has landed yet;
  without this setting the arming fails and gated PRs degrade to
  leave-open + escalate.
- `delete_branch_on_merge: true` — head-branch cleanup for armed merges,
  which happen later when no gh process is around to `--delete-branch`.

In State D gap-fill mode, treat `github_state.merge_settings` from
detect-stack with either field `false` (or the object `null`) as a gap
that re-running `branch-protection.sh` closes.

If the user does not yet have any commits with the workflows present, point out
that the check names will not appear in the GitHub UI until at least one workflow
run completes — branch protection rules referencing them are still valid, but
GitHub displays them as "expected" until first run.

If the script exits non-zero with a 403 (user is not a repo admin), do not
retry. Print the equivalent manual setup instructions from `SETUP.md` and
continue.

### 4c. Build script — enforce Kotlin DSL, then wire Java build plugins (Java only)

**Only when `java` is in the detected languages.** Two parts: first the
family's **Kotlin-DSL-only** policy is enforced on the build script, then the
CI-prerequisite plugins are wired into `build.gradle.kts`.

**Part 1 — Kotlin DSL gate.** The Java/Spring plugins maintain only
`build.gradle.kts`; this is deliberate (one blessed format — see
*Java-specific recommendation*). Branch on `language_meta.java.gradle_dsl`
(and `.build_system`) from detect-stack:

- **`gradle_dsl == "kotlin"`** → good, proceed to Part 2.
- **`gradle_dsl == "groovy"`** (a Groovy `build.gradle`, no `.kts`) →
  **offer to convert it** (confirmed action). Explain: the family
  standardizes on Kotlin DSL, and maintenance (`/development:maintenance`)
  will **refuse to run** on a Groovy build. On approval, rewrite
  `build.gradle` → `build.gradle.kts` (translate the plugins block,
  dependencies, `version`/config to Kotlin DSL syntax), `git rm` the old
  `build.gradle`, and **validate** with `./gradlew --no-daemon help -q`; if
  it fails, roll back the conversion (`git checkout -- build.gradle &&
  git rm -f build.gradle.kts`) and surface it as a blocking Step 5 TODO. If
  the user **declines**, stop here and record a blocking TODO ("convert
  build.gradle to build.gradle.kts — maintenance won't run until you do");
  skip Part 2.
- **`build_system == "maven"`** → out of scope; this is rejected at the
  Java build-system gate (see *Java-specific recommendation*). Do not wire
  anything.

**Part 2 — wire Spotless + JaCoCo into `build.gradle.kts`** (confirmed,
idempotent). The generated CI + hooks depend on these (without them the first
CI run and push fail):

1. **Determine what's missing.** Read `build.gradle.kts`. Skip each piece
   already present — check for the `com.diffplug.spotless` plugin, the
   `jacoco` plugin + `jacocoTestReport`, and (when `.proto` files exist) a
   generated-sources coverage exclude. `language_meta.java.has_cov` is a hint
   for JaCoCo. If **all** are already applied, print one line ("Spotless +
   JaCoCo already wired — nothing to do") and skip the rest — **do not** turn
   a satisfied check into a prompt or a TODO.
2. **Confirm before editing — and warn about the first Spotless run.** Show
   exactly what you'll add (the canonical Kotlin-DSL blocks from *Java-specific
   recommendation*) and ask. When the project already has Java sources, **warn
   upfront**: wiring Spotless means the first `spotlessApply` (the pre-commit
   hook, or the bootstrap commit if you run it) **reformats every existing file
   in `src/` to google-java-format** — a large but purely mechanical diff. It's
   expected, and including it in the bootstrap commit means the first PR won't
   fail the Spotless check. Tell the user so the big diff isn't a surprise. If
   the user declines the wiring, carry it into the Step 5 checklist as a TODO.
3. **Apply (Kotlin DSL).** Add the missing plugin entries into the existing
   `plugins { }` block (don't create a second one); append the `spotless` /
   `jacocoTestReport` / generated-sources-exclude blocks. Pin Spotless to a
   current version. Add **only** the missing pieces.
4. **Validate the script still parses** — a DSL slip breaks every Gradle
   invocation:

   ```bash
   ./gradlew --no-daemon help -q 2>&1 | tail -20
   ```

   If it fails, roll the edit back (`git checkout -- build.gradle.kts`) and
   surface the wiring as a Step 5 TODO instead of leaving the build broken.
   Do **not** run the full build here.

These are the **only** edits bootstrap makes to a hand-authored build file,
and only because the family policy (Kotlin DSL) and the artifacts it just
generated require them. The nebula / full-gRPC / dependency-locking items
stay recommendations (Step 5) — never auto-applied.

### 4d. Initial commit

Offer to commit the generated files (and any 4c build-script wiring) using
the `/development:commit` flow with a suggested message like `Bootstrap
project with quality and security toolchain`. Do not push.

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
  --has-dockerfile "<true|false>" \
  --claude-approver "<true|false>"
```

Pass `--claude-approver true` whenever the orchestrator was invoked with
`--claude-approver true` (so the preflight can verify the two Claude
GitHub Apps are registered locally and offer to run `register-claude-apps.zsh`
when they aren't). When the orchestrator was invoked without the flag, pass
`false` or omit it.

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
7. When `--claude-approver true`: verify `python3` is present, verify both
   Claude Apps are registered locally (apps.json + Keychain entries), and
   offer to run `register-claude-apps.zsh` when missing.

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
  --codeql-languages "<space-separated languages, e.g. 'python typescript'>" \
  --claude-approver "<true|false>"
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
- Best-effort creating + assigning the "Zero Tolerance" Sonar Quality Gate;
  falls back to `Sonar way` on SonarCloud free (custom-gate assignment is
  paywalled). See *Guiding Principles → Zero Tolerance standard* for the
  layered-enforcement model.
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
  --has-dockerfile "<true|false>" \
  --claude-approver "<true|false>"
```

This handles:

- `docker compose up -d` on the generated `infra/sonarqube/docker-compose.yml`.
- Waiting for SonarQube to become healthy (`/api/system/status` polling).
- Generating a random admin password, storing it in the macOS Keychain
  (`security` command, service `sonarqube-local-admin`).
- Changing the SonarQube admin password from `admin/admin` to the generated
  one via API.
- Creating the project, minting an analysis token, creating + assigning the
  "Zero Tolerance" Sonar Quality Gate (custom gates are unrestricted on
  self-hosted SonarQube CE).
- Setting `SONAR_TOKEN` and `SONAR_HOST_URL` as GitHub Actions secrets.
- Downloading and registering a self-hosted GitHub Actions runner as a
  launchd service.
- Applying branch protection.

If the user declines automation at any step, fall back to the manual
instructions in `SETUP.md` for the remaining steps.

### `--claude-approver true` extension

When the orchestrator was invoked with `--claude-approver true`, both
automate scripts run an additional Claude Apps install step **after
branch protection and before printing the summary** (no extra flag plumbing
needed by the orchestrator — the scripts pick up the flag passed at the
top). The step delegates to:

```bash
"<skill-base-dir>/scripts/install-claude-apps.zsh"
```

which (idempotent):

- Reads App IDs from `~/.config/claude-plugins/apps.json` and private keys
  from macOS Keychain (populated by `register-claude-apps.zsh` in Phase 0).
- Opens `https://github.com/apps/<slug>/installations/new` per App so the
  user installs both Apps on the current repo.
- Captures `ANTHROPIC_API_KEY` from the environment, or prompts.
- Stores per-repo variables (`CLAUDE_APPROVER_APP_ID`,
  `CLAUDE_MAINTENANCE_APP_ID`, `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` defaulting
  to the machine-only list) and secrets (`CLAUDE_APPROVER_PRIVATE_KEY`,
  `CLAUDE_MAINTENANCE_PRIVATE_KEY`, `ANTHROPIC_API_KEY` — all in Actions
  AND Dependabot scopes via `gh_secret_set_both`).

**No-approver-language warning.** If `--claude-approver true` is set but no
Approver-capable language resolves as the review target (no `python`/`java`
in scope — see §3e's `{{APPROVER_LANG}}` resolution), warn the user the
flag will be a no-op:

> `--claude-approver true` requested but no Approver-capable language
> (currently Python or Java) resolves as this repo's review target. The
> Approver ships per-language; the secrets and Apps would be installed but
> no workflow would consume them. Re-run without the flag to skip, or wait
> for that language's Approver agent to ship.

Offer the user to drop the flag and continue, or abort. Do not silently
install Apps that would never be invoked.

**Forward pointer.** Phase 1 ships the credentials only. The Approver
workflow + policy template + PR description template arrive in **Phase 2**
of #89; the `python-approver` agent itself in Phase 3. Until then, the
secrets and variables installed here sit unused but ready.

### `--claude-plugin true` extension — install the WRITER App

When `--claude-plugin true` was set, the repo is **human-only approval** (no
Approver — §3e was skipped). Instead, install just the **writer** (the Claude
Maintenance App) so Claude's PRs are bot-authored and the human can approve them.
After branch protection, delegate to:

```bash
"<skill-base-dir>/scripts/install-claude-apps.zsh" --writer-only
```

which installs **only** the Maintenance App on the repo (no Approver, no
`ANTHROPIC_API_KEY`, no repo secrets — `/development:open-pr` mints the writer
token locally from the Keychain). Mutually exclusive with `--claude-approver`:
if both flags were passed, the Approver was already dropped (§3e), and only this
writer install runs.

The result: `/development:open-pr` opens PRs authored by
`claude-maintenance-<owner>[bot]`; the human approves; squash auto-merge +
branch deletion (the repo settings Step 4b configured). If the Maintenance App
isn't registered yet, the Step 4.5 preflight offers `register-claude-apps.zsh`
first.

## Step 5: Print the Manual-Setup Checklist

Print a clear, ordered checklist of everything the user **still** has to do
manually — i.e., only the steps that automation didn't cover (or that the user
declined). If automation in Step 4.5 ran end-to-end, this checklist may be very
short ("push a branch and open a PR"). Reference `SETUP.md` for full details.

> **Only list genuinely outstanding work.** A checklist item is a TODO the
> user must act on — never a status report. Do **not** render an
> already-satisfied check (e.g. "nebula-release already applied ✅",
> "Spotless + JaCoCo already wired") as a `☕` follow-up; if it's done,
> it doesn't belong here at all. In particular: the Java build-plugin
> wiring (Spotless + JaCoCo + generated-sources exclude) is handled by
> **Step 4c** — include it here **only** when the user *declined* 4c or it
> was rolled back, as: "☕ Wire Spotless + JaCoCo into `build.gradle.kts`
> (CI + the pre-push coverage hook fail until you do)." If the user declined
> the Step 4c **Groovy→Kotlin conversion**, lead with that as a *blocking*
> item: "⛔ Convert `build.gradle` → `build.gradle.kts` —
> `/development:maintenance` will refuse to run until you do (family policy:
> Kotlin DSL only)." The nebula / full-gRPC / dependency-locking
> recommendations appear here only when actually missing (per the gating in
> *Java-specific recommendation*).

Example for public path:

```text
NEXT STEPS:
1. Create a SonarCloud account → import this repo → copy SONAR_TOKEN.
2. Sign up for Snyk → copy SNYK_TOKEN.
3. In GitHub repo Settings → Secrets and variables → Actions:
   - Add SONAR_TOKEN
   - Add SNYK_TOKEN
4. SonarCloud paid plan: create the "Zero Tolerance" Quality Gate (see
   SETUP.md) and assign it. **SonarCloud free: skip this step** — custom-gate
   assignment is paywalled; the CI `coverage-floor` step + `Sonar way` gate
   together carry the standard (see *Guiding Principles* for details).
5. Enable Snyk auto-Fix-PRs in the Snyk UI (SETUP.md section 2.6) — one-time
   UI step (Snyk org → Integrations → GitHub → Edit Settings → toggle on).
   Required because Snyk's API gates this behind paid plan; UI is the only
   path on free.
6. Push the branch and open a PR — CI will run.
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
- The Zero Tolerance standard is non-negotiable. See *Guiding Principles →
  Zero Tolerance standard* for the layered-enforcement model and `SETUP.md`
  for the Sonar gate API recipe.
- Self-hosted runners are **only** used for private repos. Never configure a
  self-hosted runner for a public repo (forks can run arbitrary code).
