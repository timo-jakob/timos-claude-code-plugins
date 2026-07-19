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

- `--signed-commits` — additionally enforce cryptographically signed commits
  (GPG or SSH) on the default branch. Off by default because every
  contributor must register a signing key. When set, the orchestrator
  invokes `branch-protection.sh --require-signed-commits true` in Step 4b.
- `--claude-approver true|false` — install the two Claude GitHub Apps
  (Claude Approver + Claude Maintenance) on this repo and store the
  per-repo secrets + variables the Approver workflow needs. **The default is
  auto-detected**: `true` when both Claude Apps are already registered on this
  machine (`~/.config/claude-plugins/apps.json` plus the matching Keychain
  private keys — the same check `register-claude-apps.zsh` and the Step 4.5
  preflight use), else `false`. Rationale: the user who registered the Apps has
  already opted into the Approver ecosystem, so it is the blessed default *for
  them*; nobody else pays the App-install + credential-storage commitment by
  default. An explicit `--claude-approver true|false` overrides the
  auto-detected default (the preflight still offers `register-claude-apps.zsh`
  when the resolved value is `true` but the Apps aren't registered yet). When the
  resolved value is `true`, the Approver is wired for the repo's Approver-capable
  language (currently Python, Java, or Swift); it warn-and-skips when neither
  resolves as the review target (§3e). A **plugin repo** never installs the
  Approver regardless (see `--claude-plugin` — the two are mutually exclusive),
  so the resolved value is forced to `false` there. **Throughout this skill,
  "`--claude-approver true`" (and "with the flag" / "was set") means the
  *resolved* value — the explicit flag or the auto-detected default — not the
  literal invocation; the off-switch on an Apps-registered machine is an explicit
  `--claude-approver false`.**
- `--claude-plugin true|false` — bootstrap this repo as a **Claude Code plugin
  repository** (a marketplace of plugins, not an application). **The default is
  auto-detected** from the repo: `true` when `.claude-plugin/plugin.json` or
  `.claude-plugin/marketplace.json` is present (the same signal the `{{PRIMARY}}`
  inference uses), else `false`. Pass `--claude-plugin true|false` only as a
  **rare override** — a greenfield plugin repo that has no markers yet, or to
  force it off. **Throughout this skill, "`--claude-plugin true`" means the
  *resolved* plugin-repo mode** (the explicit flag, or the auto-detected marker
  signal). When the resolved value is `true`:
  - sets `primary: claude-plugin` in `.maintenance.yml` (overrides `{{PRIMARY}}`
    inference);
  - uses **Renovate** instead of Dependabot — plugin repos are templates, not
    production dependency manifests (renders `renovate.json`, **skips**
    `.github/dependabot.yml`);
  - installs the **plugin-repo lint** pre-commit hooks (shellcheck / shfmt /
    markdownlint) — the `CLAUDE_PLUGIN` block in `.pre-commit-config.yaml`;
  - **does NOT install the Approver.** A plugin repo is the origin of every other
    repo and requires **human-only** approval (no AI auto-approval). Whatever
    `--claude-approver` resolved to, **skip the Approver** — the two are mutually
    exclusive for a plugin repo. Warn only when `--claude-approver true` was
    passed **explicitly** (an auto-detected `true` needs no warning — nothing was
    requested).
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
- `interfaces` — the runtime interface(s) a deployed build is exercised through,
  each with its detection evidence: `[{"interface": "...", "evidence": "..."}]`,
  `interface ∈ {cli, rest, web-ui, library}` (issue #242). This is the signal that
  lets bootstrap render **interface-appropriate acceptance tests** (#243) — `cli`
  is exercised by running the built entry point, `rest`/`web-ui` by deploying and
  hitting the service, and `library` renders **no** acceptance workflow. Detection
  is **advisory** and Python-only in v1 (`interfaces` is `[]` when Python isn't
  detected; other languages emit their own set under their plugins). Present the
  detected set to the user and let them confirm/correct — a web framework serving
  templates/static is classed `web-ui`, one serving neither is `rest`, and the
  heuristic can't always tell them apart. To override detection outright, re-run
  with `--interfaces`:

  ```bash
  <skill-base-dir>/scripts/detect-stack.sh --interfaces cli,rest
  ```

  Every named interface then carries `"user override"` as its evidence.
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
2. **Offer to run `gh auth login` inline** — the same install-the-prerequisite
   mindset as the Step 4.5 preflight, which already offers it (`gh auth status`
   check). On success, **continue this same run**: `gh` is now authenticated, so
   **re-run `detect-stack.sh`** — the Step 1 output's `github_state` is empty and
   its `missing_artifacts` was computed with `visibility=unknown` (path-scoped
   files omitted), so both are stale and must be regenerated now that `gh` is
   authenticated (normalize the resolved visibility to lowercase
   `public`/`private`) — then **proceed as State D** on the fresh detection
   output. Do **not** ask the user to re-invoke the skill.
3. If the user **declines** the offer, the login **fails**, or visibility still
   can't be resolved after a successful login, fall through to the **shared
   questions** to ask visibility manually, with a clear one-line reason — that is
   the fallback, not the default path. On this unauthenticated continuation the
   GitHub-side Step 4 actions (4b branch protection, 4b.5 labels, secret storage)
   will fail without auth: degrade each to its `SETUP.md` manual instruction
   rather than re-prompting mid-run — the Step 4.5 preflight makes one more
   `gh auth login` offer before the setup automation.

#### State D: git repo with GitHub remote, `gh` authenticated

`has_github_remote=true`, `visibility ∈ {public, private}`.

1. Skip the GitHub repo creation questions — already done.
2. Skip the visibility question — already known.
3. **Inspect `github_state` before deciding what to offer the user.** If
   `missing_artifacts` is empty (every expected file present) AND
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

4. **Missing-file gap-fill — run this BEFORE the drift check whenever
   `missing_artifacts` is non-empty.** `detect-stack.sh` emits
   `missing_artifacts`: the templates this repo's actual conditions
   (visibility, languages, dependency-bot path) expect but that are **absent
   on disk** — a newly-added template (added to the suite after this repo was
   bootstrapped) or an incomplete prior run. The drift detector **cannot see
   these** — it only compares the recorded sha256 of files that already carry
   a provenance marker, so a file that was never rendered has no marker to
   compare and is invisible to it. An empty `existing_artifacts` map looking
   "all true" is **not** evidence of completeness; `missing_artifacts` is the
   only completeness signal.

   For each path in `missing_artifacts`, **render it from its template and
   stamp the provenance marker** (Step 3 + Step 3.6), writing into the working
   tree. This working-tree delta flows on through the plan (Step 2) to Step 4d
   (commit) and the **Step 4e finishing flow**, which lands it as a bot PR —
   don't stop at rendered files. These are the unconditionally-expected gaps
   only — `detect-stack.sh` deliberately **holds out** files whose render is
   gated by a signal it can't observe (the `--claude-approver` Approver pair,
   the language-spec-gated `api-stability.yml`, the non-selected
   `renovate.json`/`dependabot.yml`), so the list is safe to render blind. Two
   list members keep their existing special paths and are never in the list
   anyway: `LICENSE` (ask which license) and `.gitignore` (merge, don't copy).

   **One exception to "render blind": the acceptance stage (#714).** When
   `missing_artifacts` contains `.github/workflows/acceptance.yml` (and/or
   `tests/acceptance/cli/test_smoke.py`), it is there because `detect-stack.sh`
   found a runtime interface this repo lacks the stage for — this is how an
   **already-bootstrapped** repo adopts the acceptance stage (§3g) on
   re-bootstrap. Their render is NOT blind: pass the interface values
   `detect-stack.sh`'s own output already supplies — `--acceptance-interfaces`
   set to the `interfaces` names minus `library` (e.g. `cli, web-ui`) for the
   workflow, and `--cli-entry-point` set to the first `[project.scripts]` name
   (or `python -m PACKAGE`) for the smoke test. (Rendering either blind trips
   `render.zsh`'s leftover check by design, so this never fails silently.)

   **The docs machinery (#766) is the second not-blind set.** An
   already-bootstrapped repo that predates the docs templates reports the
   whole §3h set in `missing_artifacts` (`mkdocs.yml`, `docs/…`, the three
   docs workflows, `Dockerfile.docs`, `requirements-docs.txt`,
   `scripts/docs-nav-to-chapters.zsh`) — this is how existing repos adopt
   end-user docs on re-bootstrap. Render them per §3h: pass `--project-name`
   and `--project-slug` (both already known in State D) plus
   `--acceptance-interfaces` from the detected `interfaces` minus `library`
   (omit when there are none), so `mkdocs.yml`'s surface-conditional nav and
   the per-surface how-to stubs (conditionally listed in `missing_artifacts`,
   like the acceptance pair) land in lockstep. Skip-if-present per file keeps
   the adoption idempotent — an immediate re-run finds no docs gaps and
   renders nothing. Then enable the Pages source (§3h's
   `gh api … build_type=workflow` call, also idempotent).

   **The two C4 pages are the exception within this set — SEED them, don't
   render them.** `missing_artifacts` also lists
   `docs/architecture/c4-context.md` and `docs/architecture/c4-container.md`
   (#791), but these have **no `.md.tmpl`** and carry **no provenance marker**
   (they are analysis output, #793 polices them by content). Do **not** hunt for
   a template or stamp them — satisfy these two gaps by running
   `seed-c4-diagrams.zsh` exactly as §3h describes (from the final detect-stack
   JSON), and gate the seed on `mkdocs.yml`'s C4 nav entries the same way §3h
   does. Skip-if-present keeps it idempotent.

   **Docs adoption must also reconcile pre-existing configs (#777, #781)** —
   the hook reconciler only appends missing providers, never edits hook args,
   so apply these edits directly (each idempotent — skip when already
   present): the repo's `.pre-commit-config.yaml` `check-yaml` hook gains
   `exclude: ^mkdocs\.yml$` (MkDocs' custom YAML tags break the safe
   loader); the `yamllint` hook gains `args: [--strict]` (zero-warnings
   policy); and the repo's `.yamllint` gains both `mkdocs.yml` in the
   `line-length.ignore` list (the provenance marker line exceeds 120 and
   cannot wrap — the same exemption the stamped workflows already have) and
   `comments: {min-spaces-from-content: 1}` (Renovate writes one-space
   `sha # vN` pin comments; strict mode must stay green across bot updates —
   apply the rule **before** or together with `--strict`, never strict
   alone). Without these the adopted docs set fails the repo's own
   pre-commit. Fresh bootstraps get all of it from the current templates;
   this reconcile is for repos rendered before the docs stack existed.

   After rendering, continue to the drift check below for the files that WERE
   already present.

   **Then reconcile `.pre-commit-config.yaml` hooks — whole-file presence is
   the wrong unit (#409).** A shipped config is only load-bearing if the
   pre-commit hook that consumes it is also wired. On an older repo, gap-fill
   can drop in `.yamllint` while the repo's `.pre-commit-config.yaml`
   *predates* the `yamllint` hook — the file is "present" so it's never in
   `missing_artifacts`, and it carries no provenance marker so the drift check
   is blind to it. The config then sits orphaned (yamllint never runs; false
   assurance). So whenever `.pre-commit-config.yaml` already exists, render the
   template the normal way (substitute `{{DEFAULT_BRANCH}}`, keep only the
   detected-language / scope blocks) to a temp file and reconcile the on-disk
   config against it:

   ```bash
   "<skill-base-dir>/scripts/reconcile-precommit-hooks.zsh" --scan \
     "<repo-path>/.pre-commit-config.yaml" "<rendered-precommit-temp>"
   ```

   It additively appends any hook *provider* (a `- repo:` block — `yamllint`,
   `gitleaks`, `semgrep`, …) whose hook ids are entirely absent on disk, and is
   purely additive + idempotent (it never overwrites a user's pinned rev or
   re-adds a present provider). Surface what it wired. (When
   `.pre-commit-config.yaml` itself was absent it's a normal
   `missing_artifacts` whole-file render above and this reconcile is a no-op.)

   It **also migrates a stale `coverage-floor*` pre-push hook in place (#713)**:
   the canonical hook now guards run/skip *inside* `entry` on the
   `origin/<default>...HEAD` diff (`always_run: true`, no `files:`), because a
   `files:` filter over-fires on a brand-new branch push — git reports the remote
   ref as all-zeros, so pre-commit diffs against the empty tree and every source
   file counts as "added", blocking a docs/config-only push on a vacuous report.
   The reconciler replaces any on-disk `coverage-floor*` block whose `entry` lacks
   that diff guard (both the pre-#379 unguarded `always_run` shape and the #379
   `files:` shape) with the rendered template's canonical block — a surgical,
   per-hook swap that leaves sibling user hooks untouched, and a no-op once the
   hook already carries the guard. This is what makes an older repo stop
   over-firing on new-branch pushes without a whole-file re-render.

   **`--scan` proactively runs each newly-wired hook repo-wide before you
   commit (#410).** Introducing a repo-wide *enforcing* hook (yamllint,
   gitleaks, …) on a non-greenfield repo almost always hits a pre-existing
   violation — and discovering it at *push* time (the bot push blocked
   mid-flow on ai-doc-organizer PR #86) or in CI is late and disruptive. With
   `--scan` the reconciler runs `pre-commit run <id> --all-files` for the hooks
   it just wired: auto-fixers (`trailing-whitespace`, `ruff`, …) fix in place,
   enforcers (`yamllint`) surface what they can't. **Exit 3** means a scanned
   hook auto-fixed files or surfaced violations on pre-existing content — fix
   the mechanical ones and stage them (or surface the judgement calls to the
   user) **before** committing, then continue; don't let the first push be the
   discovery mechanism. Exit 0 = newly-wired hooks pass repo-wide, safe to
   commit. (If `pre-commit` isn't installed the scan is skipped with a notice;
   run it by hand before committing.)

5. When `missing_artifacts` is empty AND `github_state` shows no gaps,
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
      report "toolchain is current" and stop; there is nothing to reconcile,
      nothing to commit, and so no Step 4e finishing flow runs. (If this run
      *also* rendered gap-fill files above, that delta still flows to Step 4d/4e
      as usual — "no drift" only means the already-present files are current.)

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

6. Continue to **shared questions** below if any answer is still unknown
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
  Docker pre-flight: <clean | artifact build steps planned (<command>) | base image stale → bump to <tag> proposed>   # Dockerfile repos only
  Coverage gate:    90% on new code, enforced by CI `coverage-floor` step + pre-push hook
  Sonar gate:       "Zero Tolerance" custom gate (paid plan / self-hosted) or `Sonar way` fallback (SonarCloud free)
  CI runner:        <github-hosted | self-hosted>
  Will create:
    - <list of files to create>
  Will skip (already present):
    - <list of files left alone>
  Will offer diff for (mismatched existing files):
    - <list of files that exist but differ from template>
  Finish:           commit the delta → open a bot-authored PR, squash auto-merge
                    armed. On an Approver-wired repo bootstrap then runs the
                    local approve and merges in-session (Step 4f); on a
                    human-only repo the armed PR waits for your approval. No
                    further prompt guards the finish; confirming the plan
                    authorizes it.
  Setup automation: on this macOS + Homebrew host, runs after the finish
                    (Step 4.5) — SonarCloud/Snyk (or local SonarQube) setup,
                    GitHub Actions secrets, branch protection[, self-hosted
                    runner on the private path]. Prompts only for its remaining
                    interactive steps — browser imports/auth, token pastes, and
                    the scripts' per-step Y/N confirmations (e.g. runner
                    registration, branch protection)[, plus the Claude
                    App-install click when --claude-approver]; degrades to
                    SETUP.md on failure. Confirming the plan authorizes it too.
                    (Omit this line on a non-macOS host — automation can't run
                    there; the manual SETUP.md checklist covers it.)
```

Ask for confirmation. Do not proceed until the user explicitly approves.
Confirming this plan **is** the consent for the Step 4e/4f finishing flow — which
is why the finish line is disclosed here: it is the single gate for the
commit/push/PR **and the approve → merge drive**, so it must name the commit, the
bot PR, the armed auto-merge, **and** that on an Approver-wired repo the flow
runs the local approver and merges in-session (Step 4f) rather than waiting. It
does **not** waive the per-action prompts elsewhere: the Step 4c build-file
confirmations (Java's `build.gradle.kts` edit and Groovy→Kotlin offer, and
Python's `pyproject.toml`/`requirements-dev.txt` pytest-cov edit), the Step 4e
writer-App install offer, and 4a's `brew install pre-commit` still apply — "no
further prompt" scopes to the finish, not to those (see the Step 4 intro for the
authoritative retained set). The Step
4.5 setup automation, by contrast, **is** covered by this approval: it runs by
default on a supported host, prompting only for its own irreducible steps (e.g.
the SonarCloud import / token paste on the public path, the App-install click
under `--claude-approver`, and the scripts' per-step Y/N confirmations), not for
a separate "whether to run automation" opt-in.

### Docker pre-flight (when a Dockerfile is present — run BEFORE presenting the plan)

Two first-CI failure classes come from the Dockerfile itself, not the
generated workflows (#545). Check both while assembling the plan, fold the
findings into the plan summary above, and confirm them with everything else:

1. **Does the Dockerfile COPY build outputs?** Inspect every `COPY`/`ADD`
   source. If any points into a build-output directory (`build/`, `dist/`,
   `target/`, `out/`, `distributions/`, …), the CI image build fails with
   `lstat ...: no such file or directory` unless the artifacts are built
   first — the `image` job runs `docker build` on a fresh checkout. Plan
   **artifact build steps** for the workflow (e.g. `setup-java` +
   `setup-gradle` + `./gradlew :app:distTar` for a Gradle dist), inserted at
   the marked anchor in **both** the `image` (scan) job — gated on
   `scan_decision` like the build they feed — and the `push-and-sign` job
   (both jobs build the image; step outputs and workspaces don't cross job
   boundaries). Include the planned steps in the workflow text that Step
   2.5's reviewers see.
2. **Is the pinned base image stale?** A pinned tag/digest ages: the Snyk /
   Trivy container gate this bootstrap installs scans the *pinned* bytes,
   so a months-old digest often fails the very first run on
   already-patched CVEs. Compare the `FROM` tag/digest against the
   registry's current tags (Docker Hub tags API for Hub images; if the
   registry can't be queried anonymously, skip the check and warn). If a
   newer same-line tag exists, **propose the bump as part of the bootstrap
   plan** — the user decides. If they decline (or the check was skipped),
   carry a prominent warning into the Step 5 checklist: the first image
   scan will likely fail on the stale base.

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
| `bootstrap-security-reviewer` | fable | GH Actions permissions, secret references, runner-event safety, scan-gates-push, unpinned third-party actions |
| `bootstrap-config-consistency` | opus | Cross-references: Sonar keys, workflow job IDs ↔ branch-protection contexts, secret refs ↔ SETUP.md, language fragment ↔ detected languages |
| `bootstrap-idempotency-reviewer` | opus | For each existing file conflicting with a template, recommends skip/overwrite/merge |

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

Use the templates in `<skill-base-dir>/templates/`. **Do NOT hand-write a
renderer** — the mechanical rendering (placeholder substitution + conditional
block stripping + leftover check) is done by the shipped, tested script
(#546):

```bash
"<skill-base-dir>/scripts/render.zsh" \
  --templates "<skill-base-dir>/templates" --out "<staging-dir>" \
  --project-name "<name>" --project-slug "<owner/repo>" \
  --project-key "<key>" --org-key "<org>" \
  --default-branch "<branch>" --languages "<a b c>" --primary "<primary>" \
  --python-version "<x.y>" --java-version "<n>" \
  --security-contact-email "<email-or-empty>" \
  --visibility "<public|private>" --docker "<true|false>" \
  --claude-plugin "<true|false>" --swift-build-system "<swiftpm|xcode>" \
  <template-relpath>...
```

Render into a **staging directory**, then apply the Step 2.5 idempotency
decisions when copying files into the repo. Pass only the flags whose
values you have — an unprovided value is never silently blanked: if a
selected template needs it, the script exits 1 listing the exact surviving
placeholder (GitHub `${{ ... }}` expressions and docker-metadata literals
like `{{version}}` are exempt by design). Spec defaults are built in
(`PYTHON_VERSION=3.12`, `JAVA_VERSION=21`, `COVERAGE_THRESHOLD=90`,
`DEFAULT_BRANCH=main`); `{{PYTHON_VERSION_COMPACT}}` and
`{{CODEQL_LANGUAGES}}` are derived automatically. Output is byte-identical
across sessions for the same inputs.

**What stays your judgment:** WHICH templates apply (3a–3f below,
dependabot-vs-renovate, per-language fragments), the idempotency decisions,
the `{{XCODE_SCHEME}}` resolution (`xcodebuild -list`, ask if ambiguous —
pass it via `--xcode-scheme`), `.gitignore` merging, the Swift `needs:`
rewiring below, and the #545 artifact-build-step insertion at the template
anchors (edit the rendered file after rendering).

The table below documents where each placeholder's **value** comes from:

| Placeholder | Value |
| --- | --- |
| `{{PROJECT_NAME}}` | display name — repo name from `gh repo view --json name` or the directory name. Use in titles, prose ("Contributing to X", "vulnerability in X"), and Sonar's `sonar.projectName`. |
| `{{PROJECT_SLUG}}` | `<owner>/<repo>` — full GitHub path. Use in URL contexts (`ghcr.io/<slug>`, `github.com/<slug>/security/advisories/new`, `scorecard.dev/viewer/?uri=github.com/<slug>`, cosign `--certificate-identity-regexp`). From `gh repo view --json nameWithOwner` or `<github_repo>` field of `detect-stack.sh`. |
| `{{PAGES_URL}}` | the repo's GitHub Pages site URL — **derived automatically** from `{{PROJECT_SLUG}}` (`owner/repo` → `https://owner.github.io/repo/`), never passed as a flag. Used by `mkdocs.yml.tmpl`'s `site_url` (§3h). |
| `{{PROJECT_KEY}}` | for Sonar — usually `<github-org>_<repo>` (SonarCloud convention) or `<repo>` (SonarQube) |
| `{{ORG_KEY}}` | initial value: `<github-org>`. **`automate-public.sh` auto-detects the real SonarCloud org slug after token paste** (some accounts have a `-github` suffix) and patches `sonar-project.properties` in place. The placeholder here is the best-effort initial value; the script overrides it during automation. |
| `{{DEFAULT_BRANCH}}` | from `gh repo view --json defaultBranchRef` or `main` |
| `{{LANGUAGES}}` | space-separated detected languages |
| `{{PRIMARY}}` | the repo's **primary** type (its reason to exist) for `.maintenance.yml` — a language (`python`) or a topic (`claude-plugin`). Determine: **(0)** if `--claude-plugin` resolves to `true` — the explicit flag, or its auto-detected default when `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json` is present → `claude-plugin`; **(1)** else if exactly one language was detected → that language; **(2)** else (multiple languages) → **ask** the user which is primary (`AskUserQuestion`, options = the detected languages). Surface the chosen primary in the Step 2 plan ("Primary type: X") so the user confirms it there — it's a *declaration*, not a silent inference. |
| `{{COVERAGE_THRESHOLD}}` | always `90` |
| `{{PYTHON_VERSION}}` | from `detect-stack.sh` (`language_meta.python.version`) — parsed from `pyproject.toml`'s `requires-python`. Defaults to `3.12` when Python isn't detected or no `requires-python` is set. Substitute as-is (e.g., `3.13`). |
| `{{PYTHON_VERSION_COMPACT}}` | same as `{{PYTHON_VERSION}}` but with the dot stripped (e.g., `313`). Used in `ruff.toml`'s `target-version = "py{{PYTHON_VERSION_COMPACT}}"`. Compute as `language_meta.python.version.replace('.', '')`. |
| `{{JAVA_VERSION}}` | from `detect-stack.sh` (`language_meta.java.version`) — the JDK major (e.g. `21`, `17`). Defaults to the current LTS `21` when Java isn't detected or the build declares no toolchain (`language_meta.java.version_source == "default"`). Used in `setup-java`'s `java-version`. Substitute as-is. |
| `{{XCODE_SCHEME}}` | Swift/Xcode only (`language_meta.swift.build_system == "xcode"`) — the scheme `xcodebuild test` runs. Resolve at render time via `xcodebuild -list -json` (take the single shared scheme; if several, ask the user which one carries the tests). Not used on SwiftPM repos — there the `SWIFT_XCODE` block is stripped and `swift test` needs no scheme. |
| `{{CODEQL_LANGUAGES}}` | comma-separated CodeQL language identifiers — map detected languages: `typescript` → `javascript-typescript`, `python` → `python`, `go` → `go`, `swift` → `swift`, `java` → `java`. Drop the codeql workflow entirely if the only detected language is one CodeQL does not support. |
| `{{ACCEPTANCE_INTERFACES}}` | comma-joined runtime interfaces from `detect-stack.sh`'s `interfaces` (#242), **minus `library`** — e.g. `cli` or `cli, web-ui`. Rendered inside literal brackets in the template (`interface: [{{ACCEPTANCE_INTERFACES}}]`, the `{{CODEQL_LANGUAGES}}` pattern) → a matrix leg per interface. Pass via `render.zsh --acceptance-interfaces`; **only** when rendering `acceptance.yml` (§3g). No default — omit it and the placeholder trips the leftover check, so the acceptance workflow is never rendered with an empty interface set. |
| `{{SECURITY_CONTACT_BLOCK}}` | substitute one of two blocks based on Q6 answer (security contact email). See below. |
| `{{APPROVER_LANG}}` | the resolved Approver language from Step 3e (`python` / `java` / `swift`) — used by `common/approver-policy-core.md.tmpl` for the `/development-<lang>:approve` and `<lang>-approver` references. Pass via `render.zsh --approver-lang`; only needed when rendering the Approver policy (#241). |

### Python-specific recommendation (when applicable)

If `language_meta.python.has_cov=false` from detection AND Python is in the
detected languages, **offer a confirmed, idempotent edit** to wire the coverage
prerequisite — the Python analogue of Step 4c's `build.gradle.kts` edit (a
CI/hook prerequisite the generated workflow and the coverage pre-push hook
depend on). Apply it **during Step 4, before the 4d bootstrap commit** (so the
dependency lands in that commit, exactly as 4c's does), following the same
confirmed-edit model:

1. **Determine what's missing.** If `pytest-cov` is already declared (in
   `[project.optional-dependencies].dev`, a `[dependency-groups].dev`, or
   `requirements-dev.txt`), print one line ("pytest-cov already declared —
   nothing to do") and skip — **do not** turn a satisfied check into a prompt
   or a TODO.
2. **Pick the edit target from what the project already uses**, then confirm
   before editing — show exactly what you'll add (`pytest-cov>=5.0.0`) and ask
   (a confirmed edit to the user's file, exactly as Step 4c is for
   `build.gradle.kts`):
   - `[dependency-groups].dev` (PEP 735) when the project declares dev deps
     there;
   - else `[project.optional-dependencies].dev` when `pyproject.toml` exists
     **and already has a `[project]` table**;
   - else append to `requirements-dev.txt` when it exists;
   - else **do not create a file or a `[project]` table** — this covers both a
     no-manifest repo and a `[build-system]`-only `pyproject.toml` (setup.py-
     driven) with no `requirements-dev.txt`, where adding
     `[project.optional-dependencies]` would introduce a `[project]` table with
     no `name` and break pip/build on a previously-working repo. Skip the edit
     and surface the Step 5 TODO below.
3. **Apply the missing entry only**, preserving the file's existing formatting;
   create the chosen dev-deps table only when its parent file already exists.
   **Capture the target file's exact pre-edit content first** — Step 4a.5 runs
   before this and may have left its own uncommitted fixups in `pyproject.toml`,
   so a failure must restore *that snapshot*, not `git checkout -- pyproject.toml`
   (which would discard the 4a.5 fixups the 4d commit still needs).
4. **Validate the file still parses** (for `pyproject.toml`) — `python3 -c
   "import tomllib, pathlib;
   tomllib.loads(pathlib.Path('pyproject.toml').read_text())"` (tomllib is stdlib
   on 3.11+; on an older interpreter, skip the parse check). No parse check is
   needed for a `requirements-dev.txt` append. If it fails, **restore the
   captured pre-edit content** and surface the wiring as the Step 5 TODO below
   instead of leaving the file malformed.

If the user **declines** the edit (or it was rolled back), surface it as a Step 5
(manual checklist) TODO instead:

> 🐍 **Add `pytest-cov` to your project's dev deps.** The generated workflow
> installs it inline in CI so coverage works there, but for local
> `pytest --cov` to work you need it in `[project.optional-dependencies].dev`
> or `[dependency-groups].dev` in `pyproject.toml`, or in your
> `requirements-dev.txt`. Recommended pin: `pytest-cov>=5.0.0`.

This mirrors Step 4c: the Java and Python coverage-prerequisite wiring now use
one consistent confirmed-edit model, rather than Java editing its build file
while Python only printed a TODO.

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

Handled by `render.zsh` from `--security-contact-email` (pass the flag with
an empty value when Q6 was left blank — omitting it entirely leaves the
placeholder to the leftover check). If the user provided an email in Q6, it
substitutes the following block (4-space indented to fit the existing
markdown list level):

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
`render.zsh` strips them mechanically from its flags (this table is the
keep-rule reference it implements; tag spellings normalize `-` to `_`, so
the pre-commit template's `CLAUDE-PLUGIN` matches `CLAUDE_PLUGIN`). Kept
blocks retain their marker lines. The script **fails loudly on a tag it
doesn't know** — when adding a new tag to a template, teach
`render.zsh`'s `keep_block` its rule (and `tests/render.bats` the case)
in the same PR:

| Tag | Keep when |
| --- | --- |
| `TYPESCRIPT` | typescript detected |
| `PYTHON` | python detected |
| `GO` | go detected |
| `JAVA` | java detected |
| `LINUX_TESTS` | any of typescript / python / go / java detected (the Linux `test-and-coverage` job — Swift has its own macOS job instead) |
| `SWIFT` | swift detected (in the quality workflows this is the whole macOS `test-and-coverage-swift` job) |
| `SWIFT_SWIFTPM` | swift detected AND `language_meta.swift.build_system == "swiftpm"` |
| `SWIFT_XCODE` | swift detected AND `language_meta.swift.build_system == "xcode"` |
| `DOCKER` | Dockerfile detected |
| `PRIVATE` | visibility == private |
| `CLAUDE_PLUGIN` | `--claude-plugin true` |
| `SURFACE_CLI` | `cli` in `--acceptance-interfaces` |
| `SURFACE_REST` | `rest` in `--acceptance-interfaces` |
| `SURFACE_WEB_UI` | `web-ui` in `--acceptance-interfaces` |
| `SURFACE_GRPC` | `grpc` in `--acceptance-interfaces` |

The `SURFACE_*` tags (#766) gate the docs templates' per-interface nav/MOC
entries (§3h); when `--acceptance-interfaces` isn't passed at all, every
`SURFACE_*` block is stripped. **Markdown templates** spell the markers as
HTML comments — `<!-- --- TAG-START --- -->` / `<!-- --- TAG-END --- -->` —
because a `# --- … ---` line would render as a Markdown heading; the
stripping rules are identical, and a kept block's HTML-comment markers are
invisible on the rendered page.

If a tag does not apply, the script deletes the START line, the END line,
and everything between them, then collapses any run of 3+ consecutive blank
lines down to one — adjacent stripped blocks otherwise leave a blank-line
pileup that fails the repo's yamllint (`empty-lines: max 2`).

**Swift job wiring (quality workflows).** Swift's lane is a separate
`test-and-coverage-swift` job on a macOS runner (`macos-latest` public;
a self-hosted runner labelled `macos` private) rather than steps in the
Linux job — `xcodebuild`/`xcrun` don't exist on Linux. Its `name:` is
`test-and-coverage`, so branch protection's required contexts are
unchanged. Render rules:

- **Swift-only repo**: the `LINUX_TESTS` block is stripped; update the
  `sonarcloud` (public) / `sonarqube` (private) job's
  `needs: test-and-coverage` to `needs: test-and-coverage-swift`.
- **Swift + another test-lane language** (rare): keep both jobs, extend
  `needs:` to both, rename the Swift job's uploaded artifact (e.g.
  `coverage-reports-swift`) and add a matching second download step —
  two uploads must not share one artifact name.
- macOS minutes are free on public repos but bill at 10× Linux on
  private ones — say so in the Step 2 plan when the private path + Swift
  combine, so the runner cost is a conscious choice.
- The app-vs-container check separation applies unchanged: the `image`
  job stays path-conditional, so a Swift app PR is never blocked by
  Docker base-image findings.

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
- `scripts/update-claude-plugins.zsh` (static copy from `common/scripts/`, `chmod +x`). A one-command helper that
  refreshes the `timos-claude-code-plugins` marketplace and updates its installed plugins to the latest version
  **without changing which plugins are enabled/disabled** (#404). Run it before a `/development:maintenance` run to be
  sure you're on the latest maintenance behavior + templates. Static (no substitution); not drift-tracked.
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

The container pipeline is **two jobs** regardless of public/private (#547 —
job permissions can't be gated per-step, so the write grants live in a job
PR runs never execute):

| Job | Events | Permissions | Steps |
| --- | --- | --- | --- |
| `image` (scan) | PR + push + release | `contents: read` only | Buildx build (amd64), tags via `docker/metadata-action` (semver + `sha-<7>` + `latest`), scan (Snyk container on public / Trivy image on private) |
| `push-and-sign` | push / release only (`needs: image`) | `packages: write` + `id-token: write` | GHCR login with `GITHUB_TOKEN`, multi-arch push to `ghcr.io/<owner>/<repo>`, SBOM, provenance, cosign |

Behaviour summary:

- Scan **always** runs — even on PRs — so contributors know if their image is
  broken before merge. PR runs execute **no** job holding write/id-token
  permissions.
- Push **only** runs on `push` to the default branch and `release: published`,
  in `push-and-sign`; `needs: image` makes the scan gate the push. The job is
  never a required branch-protection check (it produces no PR check) and
  needs no noop mirror.
- The same Buildx cache (`type=gha`) is reused between the scan job's build
  and the push job's, so the second build is fast.
- **When the Dockerfile COPYs build outputs** (the Step 2 Docker pre-flight
  detected sources under `build/`, `dist/`, `target/`, …), insert the
  planned artifact build steps at the `ARTIFACT BUILD STEPS` anchor comment
  in **both** jobs — gated on `scan_decision` in `image`, unconditional in
  `push-and-sign`. A `docker build` on a fresh checkout fails its COPY
  otherwise (#545).
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
- Image visibility: GHCR defaults new packages to **private**, and GitHub offers
  **no API or CLI to change package visibility** — it is web-UI-only (and making
  a package public is **irreversible**). So this stays a one-time **manual** step
  after first publish; the generated `SETUP.md` (§5.2) gives the exact Danger-Zone
  path for both user- and org-owned repos. Do **not** attempt to automate it via
  `gh api` — no such endpoint exists (unlike the §3h Pages source, which is
  API-settable).

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

Because this job runs with `--all-files` while local commits only check
staged files, it is *stricter* than the local hooks: pre-existing files the
bootstrap never touched can fail it. Step 4a.5 normalizes them before the
first push.

### 3d. Per-language fragments

For each detected language, merge in the appropriate config from
`templates/languages/<language>/`:

- Linter config (e.g., `.eslintrc.json`, `ruff.toml`, `.golangci.yml`)
- Coverage tooling note in `sonar-project.properties` (paths, report format)
- Pre-commit hook entries (already merged into `.pre-commit-config.yaml`)
- **Swift only:** render `templates/languages/swift/swiftlint.yml.tmpl` →
  `.swiftlint.yml` and `templates/languages/swift/swift-format.tmpl` →
  `.swift-format` (no placeholders in either — both encode the org-wide
  120-column line-length policy). The pre-commit SWIFT block's SwiftLint /
  swift-format hooks and the maintenance pipeline's
  `swift-format-lint-fixer` agent read exactly these files.
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
entirely** — render no Approver workflow or policy, regardless of how
`--claude-approver` resolved. A plugin repo is the origin of every other repo and
is **human-only approval** (no AI auto-approval). Warn that the Approver flag was
ignored because of `--claude-plugin` **only when `--claude-approver true` was
passed explicitly**; an auto-detected `true` needs no warning (nothing was
requested). Set up human approval the normal way (Step 4b branch protection
requires 1 review; no Approver bot to satisfy it).

When the orchestrator was invoked with `--claude-approver true` **and**
an **Approver-capable language** is in scope (currently `python`,
`java`, or `swift` — the languages that ship a `<lang>-approver`
agent), render the
Approver policy file. **No workflow is rendered** — since epic #476 the
Approver is user-invoked locally via `/development-{{APPROVER_LANG}}:approve`,
which mints its App token from the Keychain; there is no GitHub Actions
approver anymore (the old `claude-approver.yml.tmpl` was removed in #479).

**Resolve `{{APPROVER_LANG}}`** — the language whose approve skill will
review this repo's PRs:

1. If `{{PRIMARY}}` is an Approver-capable language (`python` /
   `java` / `swift`) →
   use it.
2. Else if exactly one detected language is Approver-capable → use it.
3. Else (primary is a topic or a no-approver language, and zero or
   multiple Approver-capable languages are detected) → **skip** the
   Approver, per the skip note below.

The policy is **core + overlay** (#241): a language-independent core
carrying the judgment criteria (type detection, baseline, test
representativeness, per-type must-haves/risks, calibration, verdict
protocol) and a per-language overlay carrying only fluency (paths,
tools, idioms, agent vocabulary). A new language plugin therefore needs
only an overlay file + an approver agent — never a policy re-write.
`{{APPROVER_LANG}}` selects the overlay:

| Template | Target path in repo | Placeholders to substitute |
| --- | --- | --- |
| `templates/common/approver-policy-core.md.tmpl` | `.claude/approver-policy.md` (first part) | `{{APPROVER_LANG}}` |
| `templates/languages/{{APPROVER_LANG}}/approver-policy-overlay.md.tmpl` | `.claude/approver-policy.md` (appended) | (none) |

Render both via `render.zsh --approver-lang {{APPROVER_LANG}}`, then
concatenate — core first, overlay second — into the single target file:

```bash
cat "<staging>/common/approver-policy-core.md" \
    "<staging>/languages/{{APPROVER_LANG}}/approver-policy-overlay.md" \
    > .claude/approver-policy.md
```

The **agent contract is unchanged**: the approve skill still reads ONE
policy file, whose marked sections (`<!-- approver-policy: core -->` /
`<!-- approver-policy: overlay (<lang>) -->`) come from the two
templates.

The policy file (`.claude/approver-policy.md`) is the source of truth for
the Approver's per-PR-type criteria — it defines what the approve skill
considers approvable. If it already exists at bootstrap time, default to
**skip** and tell the user that policy changes go through the normal
code-review process (a policy-change PR is evaluated by the *previous*
version of the policy). On a re-bootstrap where the user opts to
regenerate, the core/overlay render replaces the old single-template
render equivalently (same criteria, reorganized) — surface the diff via
the idempotency reviewer as usual.

Also confirm the existing `.github/PULL_REQUEST_TEMPLATE.md` (rendered in
3a) carries the `## Type` and `## Risk` sections that the Approver reads.
The shipped template already has them; if a user-customised template
exists and is missing either section, surface a finding via the
`bootstrap-idempotency-reviewer` agent rather than overwriting.

**No-approver-language skip.** If `--claude-approver true` was set but
`{{APPROVER_LANG}}` couldn't be resolved (no `python`/`java`/`swift` in scope, or
the primary is a topic / no-approver language with no single
Approver-capable language to fall back to), do **not** render the
policy file. Warn the user:

> `--claude-approver` resolved `true` (explicitly or auto-detected), but no
> Approver-capable language (currently Python, Java, or Swift) resolves as this
> repo's review target. The
> Claude Approver ships per-language; for other languages the policy file
> would be a no-op. Re-run with `--claude-approver false` (on a machine where the
> Apps are registered the default otherwise resolves `true` again), or wait for
> that language's Approver agent to ship.

Offer to continue with the Approver skipped (or re-run with
`--claude-approver false`), or abort. The Step 4.5 install path
also skips when no Approver-capable language resolves — the Approver App
would be installed with no approve skill to serve it.

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

### 3g. Acceptance-test workflow (when a runtime interface is detected)

Unit + integration tests and a coverage number don't prove the *shipped
artifact* works. `acceptance.yml` (the spine from #697,
`common/.github/workflows/acceptance.yml.tmpl`) adds the missing CI stage:
deploy/run the built artifact and exercise it through the interface a user
actually touches. It is a normal check, **not** an
Approver capability — the Approver later judges the evidence this stage produces,
and the #232 wait-for-CI gate picks the new check up automatically.

**Renders when** `detect-stack.sh`'s `interfaces` (#242) is non-empty **and not
solely `["library"]`** — a `library` project has no runtime interface, so it
renders **no** acceptance workflow. Pass the detected interfaces **minus
`library`**, comma-joined, via `--acceptance-interfaces`:

```bash
"<skill-base-dir>/scripts/render.zsh" \
  --templates "<skill-base-dir>/templates" --out "<staging-dir>" \
  --default-branch "<branch>" \
  --acceptance-interfaces "cli, web-ui" \
  common/.github/workflows/acceptance.yml.tmpl
```

Detection is **advisory** — present the detected set in the Step 2 plan and let
the user confirm/correct (a web framework serving templates is `web-ui`, one
serving neither is `rest`; the heuristic can't always tell), then render the
confirmed set. (An **already-bootstrapped** repo that predates the acceptance
stage gets it on re-bootstrap: `detect-stack.sh` lists `acceptance.yml` in
`missing_artifacts` when a non-`library` interface is detected (#714), and the
State-D gap-fill renders it with the interface flags — see State D step 4. It is
held out only when no interface warrants it.)

**The contract this spine establishes** (consumed by follow-up epic #704's
Approver-consumption child — keep it stable):

- **Check name** — the job is a matrix over `interface`, so the check surfaces as
  **`acceptance (<interface>)`** (`acceptance (cli)`, `acceptance (web-ui)`, …),
  one leg per detected interface.
- **Report artifact** — each leg uploads **`acceptance-report-<interface>`**
  (`if: always()`, so the evidence survives a failing exercise) containing
  **JUnit XML**. `acceptance-report-` is the stable prefix consumers glob.

The spine (#697) ships the structure; the exercise step is a **green-but-minimal
skeleton** for interfaces whose harness hasn't shipped yet (rest / web-ui, in
epic #704) — it writes a passing JUnit report so the check + report contract are
live.

**cli harness (#698).** When `cli` is in the interface set, also render the
`tests/acceptance/cli/` convention — a green-but-minimal pytest **smoke test**
that runs the built entry point and asserts exit code + output. The workflow's
cli leg installs the package and runs `pytest tests/acceptance/cli/
--junitxml=acceptance-report/acceptance-cli.xml`, so a failing acceptance test
fails the `acceptance (cli)` check. Pass the built command via
`--cli-entry-point` — the `[project.scripts]` name (e.g. `aido`) or `python -m
<package>` for a `__main__`-only cli:

```bash
"<skill-base-dir>/scripts/render.zsh" \
  --templates "<skill-base-dir>/templates" --out "<staging-dir>" \
  --cli-entry-point "aido" \
  languages/python/tests/acceptance/cli/test_smoke.py.tmpl
```

(v1's cli harness is Python — interface detection is Python-only, #242. Like
`acceptance.yml`, the smoke test is surfaced in `missing_artifacts` when `cli` is
detected and it's absent (#714) — so an existing repo adopts it on re-bootstrap —
and held out otherwise; State D step 4 renders it with `--cli-entry-point`.)
Projects grow real acceptance cases (fixture inputs → expected output + exit
code) into `tests/acceptance/cli/` alongside the seed. rest / web-ui harnesses
land with epic #704. See `docs/ACCEPTANCE-CLI-VALIDATION.md` for end-to-end
evidence on ai-doc-organizer and a fresh-reader guide to adding cli acceptance
tests (#699).

### 3h. End-user docs machinery (every repo — #766, epic #745)

Every bootstrapped repo gets the Diátaxis docs machinery the plugin repo
proved in epic #744: a seeded `docs/` tree, `mkdocs.yml`, and three
path-conditional workflows (strict PR gate → Pages deploy → `docs-latest`
PDF/ePub assets + OCI `ghcr.io/<owner>/<repo>-docs` image). Docs that don't
compile don't merge; docs that merge publish themselves.

Render the whole set in one call — `{{PAGES_URL}}` derives from the slug, and
`--acceptance-interfaces` (the same value §3g uses, omit it when no interface
was detected) drives the `SURFACE_*` blocks in `mkdocs.yml`'s nav and the MOC
pages:

```bash
"<skill-base-dir>/scripts/render.zsh" \
  --templates "<skill-base-dir>/templates" --out "<staging-dir>" \
  --project-name "<name>" --project-slug "<owner/repo>" \
  --default-branch "<branch>" \
  --acceptance-interfaces "cli, web-ui" \
  common/mkdocs.yml.tmpl \
  common/docs/index.md.tmpl \
  common/docs/tutorials/index.md.tmpl \
  common/docs/tutorials/getting-started.md.tmpl \
  common/docs/how-to/index.md.tmpl \
  common/docs/reference/index.md.tmpl \
  common/docs/explanation/index.md.tmpl \
  common/docs/architecture/index.md.tmpl \
  common/.github/workflows/docs.yml.tmpl \
  common/.github/workflows/docs-deploy.yml.tmpl \
  common/.github/workflows/docs-publish.yml.tmpl \
  common/Dockerfile.docs \
  common/requirements-docs.txt \
  common/scripts/docs-nav-to-chapters.zsh
```

- **Per-surface how-to stubs** — additionally render
  `common/docs/how-to/use-the-cli.md.tmpl` / `use-the-rest-api.md.tmpl` /
  `use-the-web-ui.md.tmpl` for **exactly** the detected interfaces (§3g's
  confirmed set, minus `library`). The stub files and the surface-conditional
  nav/MOC entries must agree: a stub without its nav line fails the strict
  build as an omitted page, a nav line without its stub as a broken link —
  render both from the same interface set and the gate proves the seed
  coherent.
- `chmod +x scripts/docs-nav-to-chapters.zsh` after copying (like
  `update-claude-plugins.zsh`). Stamping preserves file modes (#783), so
  chmod-then-stamp and stamp-then-chmod both work.
- The docs checks are **path-conditional** — never add them to branch
  protection's required contexts (Step 4b), or every non-docs PR wedges.
- **Seed the C4 architecture diagrams** (#746 child (b), #791). After rendering
  the docs set above, generate `docs/architecture/c4-context.md` and
  `docs/architecture/c4-container.md` from the **detected structure** — the
  **final, user-confirmed** `detect-stack.sh` JSON from Step 1 (the one whose
  `interfaces` reflect the confirmed/overridden set, not a superseded first pass;
  it carries `containers`, `detection_confidence`, `interfaces`, `language_meta`,
  #799). These are analysis **output**, not templates, and carry **no provenance
  marker** (so #793's content-policed drift check ignores them).
  `architecture/index.md` (rendered above) links the two pages instead of being a
  placeholder.

  ```bash
  # detect.json is a WORKING INPUT — write it to a scratch path OUTSIDE the
  # staging dir so it is never copied into the target repo. Re-run with the SAME
  # --interfaces override the user confirmed in §3g if you regenerate it here.
  "<skill-base-dir>/scripts/detect-stack.sh" [--interfaces "<confirmed set>"] > "<scratch>/detect.json"
  "<skill-base-dir>/scripts/seed-c4-diagrams.zsh" \
    --project-name "<name>" \
    --detect-json "<scratch>/detect.json" \
    --out "<staging-dir>"
  ```

  The Container diagram conforms to the c4/v1 declared-container shape (#790), so
  `extract-declared-containers.zsh` parses it and #793's `c4_drift` can compare it
  to reality. Seeding is honest about detection: a `complete` detection with no
  container gets exactly one container (project + primary interface); an
  `inconclusive` detection seeds **no** fabricated container — it seeds what it can
  evidence and leaves a note.
  - **The seed is mandatory once its nav is rendered — handle a non-zero exit.**
    The two pages are registered in `mkdocs.yml`'s nav and the `docs/index.md` MOC
    (both rendered above), so once the docs set is rendered the strict build
    **requires** both pages. If `seed-c4-diagrams.zsh` exits non-zero (1 = no/absent
    `--detect-json`; 2 = usage error — fix the invocation; 3 = unreadable/invalid
    JSON, jq missing, or a write failure), do **not** proceed with the docs commit —
    fix the cause and re-run until it exits 0.
  - **The seed is gated on `mkdocs.yml`'s C4 nav entries, and the two files move as
    one unit.** On a **re-bootstrap of a pre-#791 repo** the existing `mkdocs.yml` /
    `docs/index.md` differ (they lack the C4 entries) → idempotency rule 3,
    diff-and-ask; the C4 pages don't exist → rule 1, write. Accept or skip
    `mkdocs.yml` and `docs/index.md` **together as one unit** (never one without the
    other). **Seed the C4 pages iff the C4 nav entries land in `mkdocs.yml`** — if
    that update is skipped, skip the seed too (a seeded page with no nav entry is an
    orphan that fails the strict build); if it is accepted, the seed is mandatory
    (a nav entry with no page is a broken link). The `docs/index.md` MOC link
    follows the same accept/skip answer but does not itself gate the seed.
  - Apply the same **idempotency rules** as every other file write (skip if
    identical, diff-and-ask if it differs) — an immediate re-bootstrap is a no-op.
- **Enable the Pages source** so `docs-deploy.yml`'s first run doesn't fail
  (idempotent — POST 409s when Pages already exists, then verify/fix the
  build type):

  ```bash
  gh api "repos/<owner/repo>/pages" -X POST -f build_type=workflow 2>/dev/null ||
    gh api "repos/<owner/repo>/pages" -X PUT -f build_type=workflow
  ```

  If the token lacks admin on the repo, surface it in the Step 5 checklist
  instead (Settings → Pages → Source: GitHub Actions).

### 3i. API contracts machinery (when an OpenAPI surface is detected — #692, #693)

A backend's API contract must be a **published, versioned artifact**, not a file
consumers reach into the repo for. When `detect-stack.sh`'s `contracts` array
carries a `type: "openapi"` entry, install the contract-lifecycle foundation
(the npm machine channel — consumer pinning + Renovate bumps; drift is
structurally impossible, not policed):

Detection here is **advisory** (mirror §3g): present the detected contract
entry (type + evidence path) in the Step 2 plan and render §3i only for a
confirmed genuine API surface — a vendored or fixture `openapi.yaml` is not one.
The installed set:

- `contracts/v1/openapi.yaml` — the **per-major layout** SEED (one directory per
  live major; old majors frozen by convention here, mechanically with #693). A
  **scaffold**, not a drift-tracked artifact — never provenance-stamped.
- `.spectral.yaml` — a **replaceable** starter ruleset; the org styleguide epic
  (#689) later swaps its *content* only. Scaffold — never stamped.
- `.github/workflows/contracts-lint.yml` — Spectral lints `contracts/` in CI,
  referencing `.spectral.yaml` **by path** so a ruleset swap never touches the
  wiring. Its check is **path-conditional** (`paths: contracts/**`) — like the
  docs checks (§3h), **never add it to branch protection's required contexts**,
  or every PR that doesn't touch `contracts/` wedges.
- `.github/workflows/spec-publish.yml` — publishes **each live major** as its own
  npm spec package (version = the spec's `info.version`, dist-tag `major-vN`).
  Its APIM governance step (#706) is a clean extension point: it runs only when
  an `apim/` directory exists and **skips with no failure otherwise**, so a repo
  without APIM gets the full drift guarantee from the npm channel alone.
- `.github/workflows/contracts-semver.yml` + `.github/scripts/check-contracts-semver.sh`
  (#693) — the **mechanical API-semver gate**: the version triangle (info.version
  major == `vN` directory == `servers:` URL major) plus an oasdiff
  bump-classification per **changed** major (breaking → ship a **new major
  directory**, never an in-place edit; additive → at least a minor bump;
  editorial → at least a patch bump so the spec republishes). **Old majors are
  frozen** (editorial-only), and deleting a live major is rejected (retirement is
  #708). Also **path-conditional** (`paths: contracts/**` plus its own wiring
  files) — never a required context, same as contracts-lint.

```bash
"<skill-base-dir>/scripts/render.zsh" \
  --templates "<skill-base-dir>/templates" --out "<staging-dir>" \
  --project-name "<name>" --default-branch "<branch>" \
  common/contracts/v1/openapi.yaml.tmpl \
  common/.spectral.yaml \
  common/.github/scripts/check-contracts-semver.sh \
  common/.github/workflows/contracts-lint.yml.tmpl \
  common/.github/workflows/spec-publish.yml.tmpl \
  common/.github/workflows/contracts-semver.yml.tmpl
```

`spec-publish.yml` needs an `NPM_TOKEN` repository secret with publish rights —
surface it in the Step 5 checklist (and, on State-D adoption, expect it in the
secrets gap check alongside `SONAR_TOKEN`/`SNYK_TOKEN`).

**Seed the layout only when the repo has no per-major spec yet.** Do not clobber
an existing `contracts/vN/openapi.yaml` (idempotency rule 3), and do not seed a
second spec: if the repo's detected spec lives elsewhere (e.g. `api/openapi.yaml`)
or a different major is already live, **omit `common/contracts/v1/openapi.yaml.tmpl`
from the render** and instead recommend a confirmed `git mv` of the real spec
under `contracts/v<major-of-its-info.version>/` (the #693 version triangle
requires the directory major to match `info.version`). The ruleset + the
lint/publish/semver workflows still install — they no-op cleanly on an empty
`contracts/`, so the pipeline is inert (not failing) until a spec lands; note
that in the Step 5 checklist.

(An **already-bootstrapped** repo that predates this stage adopts it on
re-bootstrap: `detect-stack.sh` lists `.spectral.yaml`, the three workflows, and
`check-contracts-semver.sh` in `missing_artifacts` when an OpenAPI surface is
detected — the **seed spec is held out unconditionally**, so gap-fill never
blind-installs a stub contract — and State-D renders that set with the core flags
above. This set is **not** a blind gap-fill: apply the advisory confirmation
first — a vendored or fixture `openapi.yaml` (e.g. under `tests/fixtures/`) is a
detected surface but not a genuine one, so confirm the contract's type + evidence
path before adopting. The deprecation lifecycle spans issues #695, #707, and #708
(the APIM portal + `apim/` deploy is #706).)

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
- When `.claude/approver-policy.md` was rendered (3e): it has the
  load-bearing sections (`## Type detection`, `## Baseline criteria`,
  `## Per-type criteria`, `## Confidence calibration`).
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

Pass the template path you used in Step 3 (e.g., `common/.github/dependabot.yml.tmpl`
— relative to `<skill-base-dir>/templates/`).

Tracked target/template pairs (only stamp the targets that were
actually rendered in 3a–3f):

| Target | Template |
| --- | --- |
| `.github/dependabot.yml` | `common/.github/dependabot.yml.tmpl` |
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

## Step 4: Post-Write Actions (covered by the Step 2 plan approval)

Once the Step 2 plan is approved, the pure-automation sub-steps below run
**without a second confirmation** — the plan approval is their consent, the same
one-gate model as the Step 4e/4f finishing flow and the Step 4.5 setup
automation. That covers **4a** hook installation, **4a.5** normalization,
**4b** branch protection, **4b.5** labels, and the **4d** commit.

A discrete confirmation is retained **only** where a real user asset or the
user's machine is at stake (this list is authoritative — the Step 2 and Step 4.5
restatements defer to it):

- **Tool / App installs on the user's machine** — 4a's `brew install pre-commit`
  when it's missing, and the **4e** writer-App install offer
  (`register-claude-apps.zsh` / `install-claude-apps.zsh`) — the same class as
  the Step 4.5 preflight's own install offers.
- **The 4c build-file edits** — Java's `build.gradle.kts` (and the Groovy→Kotlin
  offer) and Python's `pyproject.toml` / `requirements-dev.txt` pytest-cov edit.
- **The idempotency file-overwrite rule** — never *render a template over* a
  user's existing file without confirmation (the Step 2.4 per-file review).
  Mechanical 4a.5 fixer-hook normalization is **not** an overwrite and stays
  folded (its fixups ride the 4d commit and are visible in the PR).

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

If `pre-commit` is not installed, **install it** before running this step —
offer a confirmed `brew install pre-commit` (consistent with the macOS +
Homebrew scope; the Step 4.5 preflight batch-installs it the same way) — then
run the hook installation above, so the hooks and the 4a.5 normalization
actually execute rather than silently not firing until the first push. Only a
genuine failure to install *pre-commit itself* degrades: a declined install, a
failed `brew install`, or Homebrew/macOS being unavailable (the same host
refusal the Step 4.5 preflight makes — never fall back to `pip`/`apt`, which is
out of the macOS + Homebrew scope). On any of those, surface a one-line reason
and skip. (A failure of the hook-installation script itself is different —
surface it, but still run 4a.5, which works without wired hooks.)

Run this step again whenever `.pre-commit-config.yaml` changes — the
script is idempotent, and a refresh that adds a new stage won't fire
on push until the corresponding hook type is installed.

### 4a.5. Normalize pre-existing files: `pre-commit run --all-files` until clean

The CI backstop job runs the hooks with `--all-files`, but local commits
only check *staged* files — so pre-existing repo files the bootstrap never
touched (a `Dockerfile` missing its trailing newline, a `.proto` with
trailing whitespace, …) will fail the first CI run even though every
bootstrap commit was hook-clean. Close that gap now, before anything is
committed or pushed:

1. Run `pre-commit run --all-files`.
2. If any hook failed by *modifying* files (the fixer hooks:
   `end-of-file-fixer`, `trailing-whitespace`, formatters), those fixes are
   already in the working tree — re-run until the pass is fully clean.
3. Leave the fixups in the working tree: Step 4d includes them in the
   bootstrap commit. If the bootstrap commit has already been made on a
   re-run, commit them separately as
   `chore: normalize pre-existing files for pre-commit`.
4. If a hook fails *without* auto-fixing (e.g. a real gitleaks or yamllint
   finding in a pre-existing file), surface it to the user instead of
   guessing a fix — that's a genuine finding, not normalization.

Skip only when `pre-commit` couldn't be installed in 4a (a genuine install
failure, the user declined, or Homebrew/macOS was unavailable — so 4a was
skipped too); in that case warn the user that the first CI run may fail on
pre-existing files and that running these commands after installing pre-commit
closes the gap. **If the Step 4.5 preflight later installs `pre-commit`** (it
batch-installs the missing tools, pre-commit among them), return to 4a (hook
installation) and here (normalization) **immediately after that batch-install,
before the per-path automation and its CI re-trigger** — so the normalization
fixups ride the bot PR the re-trigger then drives green. Push those fixups to
the open bot PR branch; if the PR has already merged (the gap-fill case where
the drive ran right after 4e), land them through the normal 4d/4e finishing flow
as a `chore/` delta **on a fresh branch off up-to-date `origin/main` — never by
reusing the merged PR's branch (the squash rewrote its SHAs, so a PR from it
would replay the whole merged delta)**. The skip is only permanent if pre-commit
is still absent when bootstrap ends.

### 4b. Branch protection on `main`

Call the helper script (no separate prompt — covered by the Step 2 plan
approval):

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

### 4b.5. Workflow labels (`blocked`)

Create the `blocked` label the `/development:resolve-issue` dependency
precheck applies when it rejects an issue with open GitHub-native blockers
(#583/#585), so a bootstrapped repo carries it from day one:

```bash
gh label create blocked --color b60205 \
  --description "Rejected by the dependency precheck — open blockers in its blocked-by graph" \
  2>/dev/null || true   # idempotent: ignore "already exists"
```

The other workflow labels (`needs-refinement`, `needs-human-decision`) stay
use-time-created by their skills via the same ensure-label idiom — this step
exists because an autonomous rejection should not depend on label-creation
permissions at rejection time.

### 4c (Java). Build script — enforce Kotlin DSL, then wire Java build plugins (Java only)

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

These are the **only** edits bootstrap makes to a hand-authored
`build.gradle.kts`, and only because the family policy (Kotlin DSL) and the
artifacts it just generated require them. The nebula / full-gRPC /
dependency-locking items stay recommendations (Step 5) — never auto-applied.

### 4c (Python). Coverage prerequisite — offer the confirmed `pytest-cov` edit (Python only)

The Python analogue of Part 2 above. When Python is detected and
`language_meta.python.has_cov=false`, apply the confirmed, idempotent edit
described under *Python-specific recommendation* — adding `pytest-cov>=5.0.0` to
`pyproject.toml`'s dev deps (or `requirements-dev.txt`) so local `pytest --cov`
and the coverage pre-push hook work. Same model as the Java 4c edit: idempotent
skip when already declared, confirm before editing, validate `pyproject.toml`
still parses (not needed for a `requirements-dev.txt` append), restore the
pre-edit snapshot + Step 5 TODO on failure or decline. Skip entirely for
non-Python repos, and never create a manifest that doesn't already exist. This is
the **only** edit bootstrap makes to a hand-authored
`pyproject.toml` / `requirements-dev.txt`.

### 4c.5. Docker build smoke test (when a Dockerfile is present)

Prove the CI image build will work **before** the first push, locally
(#545):

1. If the Step 2 Docker pre-flight planned artifact build steps, run their
   local equivalent first (e.g. `./gradlew :app:distTar`) — the Dockerfile's
   COPY needs the artifacts on disk, exactly as in CI.
2. Run `docker build .` (a plain single-arch build; no push, no scan).
3. If it fails, fix the cause before proceeding — a failing COPY here means
   the pre-flight missed a build output; add the missing steps at the
   template anchors and re-run.

If Docker isn't available locally, skip with a warning that the `image`
check is unverified until the first CI run.

### 4d. Initial commit

**Before committing — land on a convention-conforming branch (#835).** The
commit and its PR must come from a branch named per `/development:git-branch-naming`.
Check HEAD first:

- HEAD is **already a convention-conforming feature branch** (a real
  `<type>/<...>` name) → use it as-is.
- **Anything else → branch first.** That covers the **default branch**
  (`main`/`master`), a harness **`worktree-*`** branch (the auto-generated
  `EnterWorktree` name — it slips past a naive "not the default branch" check),
  **any other nonconforming name**, and a **detached HEAD**. Create a
  `<type>/<short-description>` branch (the no-issue form; `type` from the delta —
  `docs` for a docs-only delta like seeding the C4 pages, else `chore`, e.g.
  `chore/bootstrap-gap-fill`) and commit from it. In a worktree do this **in
  place** — the worktree stays (isolation is fine), only the branch is corrected:

  ```bash
  git switch -c "<type>/<short-description>"
  ```

Never commit or open the PR from anything but a convention-conforming feature
branch — in particular never from `main`/`master` or a `worktree-*` branch.

Then **commit** the generated files (and any 4c (Java) build-script wiring, any
4c (Python) `pyproject.toml`/`requirements-dev.txt` edit, plus the
4a.5 normalization fixups to pre-existing files) using the `/development:commit`
flow with a suggested message like `Bootstrap project with quality and
security toolchain`. Whether pushing follows is the **Step 4e finishing
flow**'s decision — do not push here.

**Skip 4d when nothing was written.** If this run rendered, repaired, or
generated nothing in the working tree — a **GitHub-side-only gap-fill**
(branch protection, secrets) or a no-drift **"toolchain is current"** run —
there is nothing to commit: skip 4d (don't launch the commit flow against a
clean tree) and, consequently, skip 4e (its precondition, below, fails too).

### 4e. Finishing flow — open the bot-authored PR

The blessed way to land the work is a **bot-authored PR with squash
auto-merge armed**, exactly as `/development:resolve-issue` finishes. This
mirrors that mindset for bootstrap deltas: after the Step 2 plan
confirmation, drive to an open PR without further per-step prompts.

**When this step runs — always, whenever there is a committable delta.** There
is no opt-in and no manual-PR path: a bootstrap that changed anything finishes
by opening the bot PR itself. This holds for **every** delta — a full initial
bootstrap the same as a State D gap-fill or a template-drift repair. The **Step
2 plan confirmation is the single consent gate**; after it, drive to the bot PR
with no further prompts. (A first bootstrap's larger blast radius needs no extra
gate here: the finishing flow only *opens* a bot PR with auto-merge *armed* —
auto-merge fires solely on green CI **and** approval, so shaky first-run CI
simply keeps it waiting; nothing merges recklessly, and nothing is ever handed
back for the user to push by hand.)

- **Precondition — a committable delta must exist.** 4e opens a PR only when
  Step 4d produced a commit (files were rendered, repaired, or generated in the
  working tree). A **GitHub-side-only gap-fill** (branch protection, secrets —
  which by design *do not touch the working tree*) and a no-drift **"toolchain
  is current"** run commit nothing, so there is no PR to open: **skip 4e** and
  just report the GitHub-side reconciliation. Never manufacture an empty commit
  or a no-delta PR to satisfy this step.

**How it runs — delegate to `/development:open-pr`, never a hand-rolled PR:**

Follow the `/development:open-pr` procedure — mint the writer token, push the
branch **as the bot**, open the PR **as the bot**, then arm squash auto-merge
with branch deletion (`gh pr merge <n> --auto --squash --delete-branch` under
the bot token). The PR body follows open-pr's template (Type / Summary / Test
plan) and summarizes the bootstrap delta.

> **Never open the PR by hand.** Do **not** run a plain `gh pr create` under
> your own identity — that PR is self-authored (you can't approve it) and
> **auto-merge is never armed**, which is exactly the failure this step exists
> to prevent. The *only* PR-opening path is `/development:open-pr`. (open-pr
> itself calls `gh pr create` under the **bot** token with auto-merge arming —
> that is the delegated call, not a hand-rolled one.)

**The finishing flow lands a bot PR or nothing — never a user-authored PR.**
The writer App (the Claude Maintenance App) is the **prerequisite** of the
finishing flow, not an optional nicety: a bot-authored, auto-merge-armed PR is
the entire point, and a user-authored PR silently re-introduces the exact manual
merge this step exists to remove. So `/development:open-pr`'s own
degrade-to-user-authored fallbacks (writer App absent, and the #750
`workflows`-grant push rejection) are **not** acceptable outcomes here — when
open-pr would degrade, bootstrap fixes the prerequisite or stops. Handle each
bot-path blocker, in order:

1. **Writer App not registered / installed** → **offer to install it** with the
   same machinery the rest of bootstrap uses: `register-claude-apps.zsh`
   (registers the App on this machine — the Step 4.5 preflight offers it too)
   and `install-claude-apps.zsh --writer-only` (installs it on the repo, the
   `--claude-plugin` extension). Once installed, the finishing flow takes the
   bot path.
2. **Push rejected with the #750 stale `workflows` grant** → the App is
   installed but the installation hasn't accepted `workflows: write`; point the
   user at `install-claude-apps.zsh --verify` (it prints the re-accept steps).
   A re-accept, not a fresh install.
3. **The user declines / can't install, or any step through *opening* the PR
   still fails** → **stop and report the specific blocker as the outstanding
   action**, leaving the branch at the 4d commit. That committed delta lands
   later via **`/development:open-pr` on this branch** (which opens the bot PR
   straight from the existing commit) — never via a user-authored PR.

**Report the actual outcome — three cases (mind whether a PR now exists):**

- **Bot PR, auto-merge armed** (the blessed, expected outcome) → report the PR
  URL, that it's bot-authored, and that auto-merge is armed, then **continue to
  Step 4f**, which drives the cycle to merged: on an Approver-capable repo 4f
  awaits green CI and runs the local approver; on a human-only repo 4f skips and
  a human approves + merges.
- **Bot PR opened, but arming failed** (the PR exists — e.g. `allow_auto_merge`
  was never enabled because Step 4b's `branch-protection.sh` hit a 403 and
  continued) → report the PR URL and that auto-merge is **not** armed; the fix
  is to enable `allow_auto_merge` (re-run `branch-protection.sh` or the repo
  setting) and re-arm with `gh pr merge <n> --auto --squash --delete-branch`,
  or just approve + merge it. Do **not** send the user to re-run open-pr — the
  commit is already pushed, so its "no commits to PR" precondition would fail.
- **Blocked before a PR exists** (writer App not installed, #750 grant not
  re-accepted, or a push/create failure) → no PR was opened; name the specific
  blocker and its fix (install / `--verify` / the reported error), and say the
  4d commit stays on the branch to be landed via `/development:open-pr` once the
  blocker clears. Never report success when no bot PR exists, and never
  substitute a user-authored PR.

> **First-run CI vs secrets — the PR opens before the secrets exist, so
> re-trigger CI once they land.** On a **full initial bootstrap** the bot PR's
> first CI run happens here, *before* Step 4.5 stores `SONAR_TOKEN` /
> `SNYK_TOKEN` (or before the user completes the manual Step 5 secret steps), so
> the token-gated checks (Sonar, Snyk) will be **red on that first run**. This
> is expected and correct: the bot PR is open with auto-merge armed (the right
> end state), and armed auto-merge simply **waits** — nothing merges red. But a
> stored secret does **not** retroactively re-run a failed check, so whenever
> the secrets land (Step 4.5 automation below, or a manual Step 5 step)
> **re-trigger the PR's CI** so the now-available secrets take effect:
>
> ```bash
> "<skill-base-dir>/../maintenance/scripts/retrigger-pr-ci.zsh" --grace 0 <pr-number>
> ```
>
> Report this explicitly — "bot PR open, auto-merge armed; token-gated checks
> are red until you add the secrets in the checklist, then CI is re-triggered
> and it merges itself" — never a bare "it merges itself" that hides the
> secrets-then-retrigger dependency. (A **State D re-bootstrap** on an
> already-configured repo already has its secrets, so its first run is normally
> green and no re-trigger is needed.)

### 4f. Drive the approve → merge cycle (Approver-capable repos)

4e ends at "bot PR open, auto-merge armed" — but an armed PR still needs its
approving review, and on an **Approver-decentralized** repo the Approver runs
**locally** (the CI Approver was removed in #479), so a human-present bootstrap
session is the only place that review can happen. Bootstrap owns the drive here
— the same one the maintenance orchestrator's `merge-pr-cycle.zsh` performs — so
the run reaches a **merged** PR with no input after the Step 2 plan confirmation.

**Runs only when the Approver is WIRED for this repo — detected from repo
state, not this invocation's flag.** The repo is wired when the Approver
policy/App is installed (**`.claude/approver-policy.md` present** — from this
run's `--claude-approver true` **or** a prior bootstrap) **and** an
`{{APPROVER_LANG}}` resolves (§3e: `python`/`java`/`swift`). This is the same
condition 4e calls an "Approver-capable repo" — one definition, not three.
**Otherwise skip cleanly, no drive** — a **human-only repo** (a plugin repo, or
one with no Approver policy / no-or-multiple Approver-capable language) has a
human approve, so report that the armed PR merges on their approval and move on.
Keying on the repo's **wiring** rather than `--claude-approver` on *this* run is
deliberate: a **State D re-bootstrap** of an already-wired repo re-runs with
`--claude-approver` resolving to whatever this machine/flags yield now — not
necessarily what wired the repo originally — and it must still drive its PR home. It also needs 4e to
have actually opened a bot PR with auto-merge **armed** (not the arming-failed or
blocked-before-a-PR cases — there's nothing to drive there). Never drive an
approver that isn't installed.

**When to run it** — the drive needs **green** CI, so run it at the point CI can
actually be green, which turns on whether **this run stored secrets *after* the
PR opened** (not on gap-fill vs full bootstrap):

- **CI can already go green** — the token-gated secrets (`SONAR_TOKEN` /
  `SNYK_TOKEN`) were already present when the PR opened (the common State D
  gap-fill case) → run it **now**, right after 4e.
- **This run stores secrets after the PR opened** — a full initial bootstrap,
  **or** a State D run whose gaps included **missing secrets** (State D's gap
  list explicitly can — see Step 1) → the bot PR's token-gated checks are red
  until those secrets land and CI is re-triggered, so **defer**: do not fail
  here; continue the bootstrap. The drive resumes once the secrets land and the
  re-trigger makes CI green — from **Step 4.5's re-trigger step** when its
  automation ran, or, if Step 4.5 didn't store secrets (preflight failed /
  non-macOS / automation degraded before storing secrets), from the
  **Step 5 checklist's secret + re-trigger item**, which surfaces the drive
  (`/development-<APPROVER_LANG>:approve <pr>` after green) as outstanding work.
  Either entry runs the same procedure below.

The procedure is the same from either entry point:

**1. Await CI settle — reuse the poller, never hand-roll `gh pr checks`:**

```bash
"<skill-base-dir>/../maintenance/scripts/await-pr-checks.zsh" <pr-number>
```

Exit 0 = settled (prints `… — GREEN|NOT-GREEN`, CANCELLED/STALE **neutral** per
the CLAUDE.md "green CI" definition — never re-derive it); 3 = timeout; 1 = gh
error.

- **GREEN** → go to step 2.
- **NOT-GREEN** → do **not** approve a red PR, and note that on an Approver repo
  **auto-merge will not fire on its own** — it still needs step 2's approval, so
  the drive must **return to step 1 once CI is green**. If the red is the
  token-gated checks still awaiting secrets (full initial bootstrap), this is the
  *defer* case: report "waiting on secrets — the drive resumes after Step
  4.5/Step 5 and the re-trigger," and **continue the bootstrap** (do not end the
  session). Otherwise (a genuine failure) report the failing check as the blocker.
- **timeout (3) / gh error (1)** → report it and stop the drive (not the
  session); the resume command is **re-running this step** — `await-pr-checks.zsh
  <pr-number>`, then the approve in step 2. Do not loop.

**2. On GREEN, invoke the local approve skill, then verify the merge:**

```text
/development-<APPROVER_LANG>:approve <pr-number>
```

Its APPROVE verdict is the review the armed auto-merge is waiting for. **Then
confirm the merge actually completed** — but give armed auto-merge a moment: it
fires up to ~1 minute *after* the approving review lands, so an immediate check
usually catches it mid-merge. Re-check `gh pr view` a few times over that window:

```bash
gh pr view <pr-number> --json state,mergeStateStatus -q '.state + " / " + .mergeStateStatus'
```

- `state == "MERGED"` → report the PR **merged** (the blessed outcome).
- `OPEN` with `mergeStateStatus` **`CLEAN`/`UNKNOWN`** → not a hold — auto-merge
  is still computing/firing; **keep waiting** and re-check, don't report a
  phantom hold.
- `OPEN` with a **genuine hold** (`BEHIND`/`BLOCKED`/`DIRTY`/`UNSTABLE`, or it
  stays put past the window) → report that exact hold and the one action that
  clears it (`gh pr update-branch <pr-number>` for `BEHIND`; the failing/pending
  required check for `BLOCKED`/`UNSTABLE`; a conflict for `DIRTY`; and for a
  persisted `CLEAN`/`UNKNOWN` that never fired, verify the approving review
  landed and, if needed, re-arm `gh pr merge <pr-number> --auto --squash
  --delete-branch`). **Never report "merged" for an open PR.**

**3. Graceful degradation — distinguish the credits gate from a review verdict:**

- **Credits/billing gate** — the approve agent spawn dies with a *terminal API
  error* (e.g. `Usage credits are required for this model`) **before** any
  verdict. **Retry once.** If it fails the same way again, **stop the drive and
  report** the exact blocker and the one-line resume command
  (`/development-<APPROVER_LANG>:approve <pr-number>`) — never a silent stop.
- **Approver App not installed** — the wiring test keys on the **policy**
  (`.claude/approver-policy.md`), but the App install (Step 4e writer / Step 4.5
  approver) can have been declined, so a policy-present repo may still lack the
  App the approve skill needs to mint its token; the spawn then dies for lack of
  the App, not credits. **Do not retry** — report it as the blocker with the
  install action (`install-claude-apps.zsh`), then the resume command. (Same
  shape as the credits gate: stop the drive, report, resume once installed.)
- **REQUEST_CHANGES** — a genuine review verdict, **not** a spawn error. Do
  **not** retry. Report the requested changes; the PR stays open for the human,
  auto-merge still armed for when the fix lands and re-approval passes.

**"Stop the drive" ≠ end the session** — it means stop *this cycle* with a report
and continue the rest of bootstrap (Step 4.5/Step 5). Terminal states of the
drive: **merged**, or a **precise, actionable blocker report** (red CI + which
check, a merge hold + the clearing action, the credits gate + resume command, or
REQUEST_CHANGES + what to fix) — never a silent stop, never an approve on a red
PR, and never a "merged" claim without verifying `state`.

### 4g. Post-merge workspace closure (worktree runs) (#835)

When bootstrap ran inside a harness **worktree** (the `EnterWorktree` case), a
merged PR leaves a worktree and its main checkout behind — closing them was a
manual step the user had to ask for. The flow closes the workspace itself.

**Applies only when the run is in a worktree** (`git rev-parse
--git-common-dir` is outside the current toplevel — the #833 signal). In the
**main checkout** there is nothing to close: skip 4g.

**Runs once the PR has actually merged — from whichever step completed the
merge**, so it's reachable on every path: 4f driving it in-session
(Approver-wired gap-fill); 4f's **deferred** drive completing after Step
4.5/Step 5 stored the secrets and re-triggered CI (full initial bootstrap — the
deferred-4f step there ends by returning here); or a **human-only** approval
merging it later. Confirm the merge first (`gh pr view <pr> --json state` →
`MERGED`); **never close the workspace on an unmerged PR** — if you reach 4g in
sequence with the PR still open (deferred, or human-only), do **not** block:
leave the closure as the step that runs when the merge is confirmed (the
deferred-4f step reaches it, and a re-run performs it). On a re-run that opened
no PR of its own, find the PR by its branch (`gh pr list --head <branch> --state
all`).

Then, **operating from the main checkout** (you cannot remove the worktree you
are standing in — `cd` to the main checkout, `dirname` of `git rev-parse
--git-common-dir`, first):

1. **Sync the main checkout** to the merged commit:

   ```bash
   git -C "<main-checkout>" switch "<default-branch>"
   git -C "<main-checkout>" pull --ff-only
   ```

   If either fails — the main checkout has **uncommitted changes** (switch
   refuses) or its local default branch has **diverged** (`--ff-only` refuses) —
   **stop and report it**; do not `--force`, reset, or proceed to the removal
   against an unsynced main. The merge is safe on the remote; closure just needs
   a clean main the user resolves.

2. **Remove the worktree** (the squash merge's `--delete-branch` removed the
   **remote** branch; the local branch may linger harmlessly — `worktree remove`
   still succeeds, and you may `git -C "<main-checkout>" branch -D` it after):

   ```bash
   git -C "<main-checkout>" worktree remove "<worktree-path>"
   ```

   If the worktree still holds **uncommitted changes** (there should be none
   after a clean finish), do **not** `--force` silently — report them and let
   the user decide. Report the closed workspace: main synced, worktree removed.

## Step 4.5: Run Setup Automation (macOS + Homebrew only)

The bootstrap skill ships scripts that automate most of the manual steps in
`SETUP.md`. On a supported host they **run by default** — the Step 2 plan
approval is their consent, exactly as it is for the Step 4e/4f finishing flow
(the Step 2 plan template discloses the automation on its `Setup automation:`
line, so the approval names what it authorizes). There is no separate "do you
want to run the automation?" opt-in: preflight validates the host, and if it
passes, the path automation runs. It is not prompt-free, though — the
interactions that remain are the irreducible ones: the external actions (the
SonarCloud browser import + token paste, the App-install click), the preflight's
own install/auth offers (brew install, `gh auth login`,
`register-claude-apps.zsh`), the automate scripts' own per-step Y/N confirmations
for high-consequence actions (self-hosted runner registration, branch
protection, Snyk auth), and the per-asset confirmations kept elsewhere (the Step
4c build-file edits — Java and Python — the idempotency file-overwrite rule; see
the Step 4 intro for the authoritative retained set). Removing that separate
opt-in is this step's change; tightening the scripts' per-step confirmations is
out of scope here — the automate scripts are unchanged. The manual `SETUP.md`
path is the **degrade-on-failure** fallback, not a co-equal opt-out.

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

Pass the **resolved** `--claude-approver` value (the explicit flag, or the
auto-detected default — see the flag list): `true` whenever it resolved `true`
(so the preflight can verify the two Claude GitHub Apps are registered locally
and offer to run `register-claude-apps.zsh` when they aren't), `false` when it
resolved `false` — including the plugin-repo forced `false`. A flagless run on a
machine where the Apps are already registered resolves `true`, so it passes
`true`, not `false`.

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

If preflight passed, run the path-specific automation — it is covered by the
Step 2 plan approval, not a separate opt-in prompt.

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

If an automation step fails — or the user declines one of the irreducible
external actions (the SonarCloud import / token paste) — degrade to the manual
instructions in `SETUP.md` for the remaining **automate-script** steps, with a
clear one-line reason. Degrading exits the per-path scripts only; it does **not**
skip the re-trigger + deferred-4f-drive blocks below — those still run **iff this
run stored any token-gated secret before failing** (the re-trigger's
precondition). If the failure came *before* any secret was stored, leave both to
the Step 5 checklist (no secrets means nothing to re-trigger). This is the fallback path, not a routine
opt-out: on a supported host the automation otherwise runs to completion.

**After automation stores the secrets, re-trigger the finishing-flow PR's CI.**
If Step 4e already opened the bot PR (the normal case — 4e runs before this
step), its first CI run predates these secrets, so its token-gated checks
(Sonar, Snyk) are red. Now that `SONAR_TOKEN` / `SNYK_TOKEN` are stored,
re-trigger the PR's CI so they re-run green and armed auto-merge can fire:

```bash
"<skill-base-dir>/../maintenance/scripts/retrigger-pr-ci.zsh" --grace 0 <pr-number>
```

(When **no secrets were stored this run** — the common State D re-bootstrap,
where they already existed — the first CI run was already green, so there is
nothing to re-trigger and the 4f drive, if any, already ran right after 4e. This
step applies only when *this run* stored secrets after the PR opened, whatever
the state.)

**Then run the deferred Step 4f drive.** On an **Approver-wired repo** (per 4f's
repo-state test — `.claude/approver-policy.md` present + a resolvable
`{{APPROVER_LANG}}`, *not* `--claude-approver` on this run), Step 4f deferred its
approve → merge cycle until the secrets landed and CI could go green. Now that
the re-trigger has run, **return to Step 4f** and run its await → approve →
verify procedure so the PR reaches **merged**. (This is the completion for any
run that stored secrets after the PR opened — a full initial bootstrap **or** a
State D run whose gaps included missing secrets. A run that stored **no** secrets
already ran 4f right after 4e; a human-only repo has no 4f to run.) Once it
merges, **run Step 4g** if this is a worktree run — the workspace closure belongs
at the end of whichever path completed the merge.

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
- Stores **no repo secrets or variables** (#476/#498) — both identities
  mint their tokens locally from the Keychain. On a repo bootstrapped
  before #476 it flags the leftover CI-era secrets/variables;
  `--verify --fix` deletes the unambiguous ones.

**No-approver-language warning.** If `--claude-approver` resolves `true` but no
Approver-capable language resolves as the review target (no `python`/`java`/`swift`
in scope — see §3e's `{{APPROVER_LANG}}` resolution), warn the user the
flag will be a no-op:

> `--claude-approver` resolved `true` (explicitly or auto-detected) but no
> Approver-capable language (currently Python, Java, or Swift) resolves as this
> repo's review target. The
> Approver ships per-language; the Apps would be installed but no approve
> skill would ever invoke them. Re-run with `--claude-approver false` to skip (on
> a machine where the Apps are registered the default otherwise resolves `true`
> again), or wait for that language's Approver agent to ship.

Offer the user to continue with the Approver skipped (or re-run with
`--claude-approver false`), or abort. Do not silently install Apps that would
never be invoked.

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
manually — i.e., only the steps that automation didn't cover (a step that failed
or degraded to manual, or an irreducible external action not yet done). If
automation in Step 4.5 ran end-to-end, this checklist may be very short.
Reference `SETUP.md` for full details.

> **Key the checklist item on Step 4e's actual outcome — and always point at
> the blessed finish (the bot PR), never a manual "push and open a PR
> yourself."** Five cases:
>
> - **4e opened a bot PR with auto-merge armed, and Step 4f already merged it**
>   (gap-fill, or 4f ran after Step 4.5's re-trigger) → the work landed; omit any
>   PR/merge item.
> - **Bot PR armed but Step 4f hasn't completed** (deferred, or it ran and
>   stopped on a blocker) → key it on the repo's approval model **per 4f's
>   repo-state test** (`.claude/approver-policy.md` present + a resolvable
>   `{{APPROVER_LANG}}`), not this run's `--claude-approver` flag. **Human-only
>   repo** (a plugin repo, or no Approver policy / no-or-multiple Approver
>   language): "approve PR #N — armed auto-merge then merges it." **Approver-wired
>   repo whose 4f drive was deferred** (this run stored secrets after the PR
>   opened — a full initial bootstrap **or** a State D run with missing-secret
>   gaps — and Step 4.5 didn't run the drive): **keep** "after the secrets +
>   re-trigger item below, run the Step 4f drive — `await-pr-checks.zsh <pr>` then
>   `/development-<APPROVER_LANG>:approve <pr>` — so it merges" (an Approver repo
>   does **not** "merge itself" on the arm alone; it needs that local approval).
>   **Approver-wired repo whose 4f drive stopped on a blocker** (credits gate,
>   REQUEST_CHANGES, or a genuine red): carry 4f's own terminal blocker report as
>   the outstanding item (its resume command / the requested changes / the
>   failing check).
> - **Bot PR opened but arming failed** (the PR exists, auto-merge not armed) →
>   **keep** "enable `allow_auto_merge` (re-run `branch-protection.sh`) and
>   re-arm `gh pr merge <n> --auto --squash --delete-branch`, or approve +
>   merge PR #N." (Do not tell the user to re-run open-pr — the PR already
>   exists.)
> - **Blocked before a PR exists** (writer App not installed, #750 grant not
>   re-accepted, or a push/create failure) → **keep** "clear the blocker
>   (install the writer App / re-accept via `install-claude-apps.zsh --verify` /
>   fix the reported error), then run `/development:open-pr` on the bootstrap
>   branch to land the 4d commit as a bot PR." (Never a user-authored-PR item.)
> - **4e was skipped because there was no committable delta** (GitHub-side-only
>   gap-fill, or a no-drift "toolchain is current" run) → nothing was staged
>   and nothing is outstanding on the PR axis; **omit** the item entirely.
>
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
> *Java-specific recommendation*). If the user **declined the base-image
> bump** the Docker pre-flight proposed (or the freshness check couldn't
> run), lead the Docker items with: "⚠️ Base image `<tag>` is stale — the
> first `image` scan will likely fail on already-patched CVEs; bump the
> `FROM` pin to clear it." If the §3h **Pages-source enablement failed**
> (token lacks repo admin), include: "Enable GitHub Pages with Source:
> GitHub Actions (Settings → Pages) — `docs deploy` fails until you do."

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
6. After the secrets above are in place, re-trigger the open bot PR's CI so the
   token-gated checks (Sonar, Snyk) re-run with them:
   `<skill-base-dir>/../maintenance/scripts/retrigger-pr-ci.zsh --grace 0 <pr>`.
7. **Approver-wired repo only** (per 4f's repo-state test — `.claude/approver-policy.md`
   present + a resolvable `<APPROVER_LANG>`, not this run's flag): once that CI is
   green, run the deferred **Step 4f** drive — `/development-<APPROVER_LANG>:approve <pr>`
   — so the armed PR gets its local approval and merges. (Human-only repos skip
   this — a human approves instead.)
8. **Worktree runs only**: once the PR has merged (step 7, or a human's
   approval), run **Step 4g** — sync the main checkout and remove the worktree.
```

> The Step 4e finishing flow already opened the bot PR with auto-merge armed —
> there is **no** "push the branch and open a PR" step. On a first bootstrap the
> token-gated checks are red until the secrets above are added, so step 6
> re-triggers CI once they are. What merges it then depends on the approval
> model: a **human-only** repo merges on the human's approval; an
> **Approver-wired** repo needs step 7's local approve (armed auto-merge alone
> won't merge it). The list is only the secrets/UI setup, the re-trigger, and
> (Approver repos) the approve drive that are genuinely outstanding.

For private path the checklist additionally includes:

- Start SonarQube: `cd infra/sonarqube && docker compose up -d`
- Register self-hosted runner (see `infra/github-runner/README.md`).
- Mint SonarQube project token, store as `SONAR_TOKEN` secret.

## Important Rules

- NEVER overwrite a user's file without explicit confirmation.
- The **only** push bootstrap makes is the Step 4e finishing flow's — **as the
  bot**, to a PR branch, to open the auto-merge-armed PR. It is the normal end
  of every run that produced a committable delta, not an exception: the **Step 2
  plan confirmation is the consent** (it discloses the commit → bot PR →
  auto-merge, so confirming the plan authorizes the push). This *replaces* the
  old "never push unless the user asks" stop-at-staged behavior — confirming the
  plan **is** the ask. The genuine NEVERs are narrower: **never** push under the
  user's identity (the writer App is a prerequisite — installed when absent,
  never bypassed with a user-authored PR); **never** push before the Step 2
  confirmation; and a run with **no committable delta** (a GitHub-side-only
  gap-fill, or a no-drift "toolchain is current" run) pushes nothing, because
  there is nothing to land.
- NEVER commit secrets or tokens to the repo. All credentials go to GitHub
  Actions secrets only.
- If the visibility detection fails or `gh` is not authenticated, ask the user
  directly; do not guess.
- The Zero Tolerance standard is non-negotiable. See *Guiding Principles →
  Zero Tolerance standard* for the layered-enforcement model and `SETUP.md`
  for the Sonar gate API recipe.
- Self-hosted runners are **only** used for private repos. Never configure a
  self-hosted runner for a public repo (forks can run arbitrary code).
