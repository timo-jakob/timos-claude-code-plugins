# Language bootstrap paths — the single gate command

> Design for bringing the `development` bootstrap skill's language paths
> (Python, Go, Java, Swift, JavaScript) onto the single gate command model
> the IaC path adopted in epic #1602
> (`2026-09-09-iac-gate-command-design.md`). Epic: #1608; children listed
> in §9.

## 1. Motivation

The consuming platform's `PLATFORM-CONTRACT.md` §12 ("Delivery Gate") asks
for one validation command that runs on a developer machine. CI must invoke
that same command, and so must a version-controlled pre-push hook. No check
may exist only in CI. #1602 brought the IaC path into line. The language paths
still break every one of those rules:

- **Checks are spread across workflow jobs.** `quality-public.yml` /
  `quality-private.yml` run per-language test and coverage blocks in a
  `test-and-coverage` job. Beside it are `semgrep`, `trivy-fs`, `license-fs`,
  `image`, and a `pre-commit` CI backstop. Further jobs come from separate
  workflows: `gitleaks.yml`, contracts lint, contracts drift, API stability,
  no-cluster-deploy, and the web-UI quality jobs. A developer cannot run this
  set locally without reading the workflows.
- **The hooks are not version-controlled.** They come from the `pre-commit`
  framework, a per-machine install driven by `.pre-commit-config.yaml`.
- **Some checks exist only in CI.** Typecheck exists nowhere. JS has no
  coverage floor. CI runs eslint without `--max-warnings=0`, so warnings
  pass.
- **The CI backstop is broken.** The `pre-commit` CI job runs the swift,
  gradle and prettier hooks on ubuntu, where those toolchains are not
  installed.

This epic moves every language-path check into one locally runnable gate.
It closes the gaps on the way.

## 2. Scope

### 2.1 In scope

- A composed `scripts/gate.zsh` for each bootstrapped language repo.
- `make lint` runs that script, `make fmt` applies fixes, and `make hooks`
  points git at the hooks directory.
- A version-controlled `hooks/pre-push`.
- `gate: make lint` in `.maintenance.yml`.
- One CI job, `gate`, with branch protection reduced to `gate` plus the
  hosted scanners.
- Pre-commit is retired on the language paths.
- New checks: typecheck, a JS coverage floor, and zero-warning eslint.
- A three-step migration for existing repos.

### 2.2 Out of scope

- `acceptance (<iface>)`. It stays a CI-only exception until #704 (§8).
- Hosted scanners: CodeQL, Scorecard, Sonar and Snyk. These need a hosted
  service or a token, so they cannot be local by nature. They stay
  CI-only, are listed by name, and remain required.
- Non-check workflows: push-and-sign, docs and spec publishing,
  template-drift-watch, release. They stay unchanged.
- The IaC path. #1602 delivered it; this epic only generalises its
  documentation.

## 3. Decisions

### 3.1 Ownership is the IaC split

The plugin owns the mechanism, `scripts/gate.zsh`. The repo owns the command,
`make lint`, which `.maintenance.yml` records as `gate: make lint`.
`hooks/pre-push` runs the gate command, `make hooks` sets
`core.hooksPath hooks`, and CI's single `gate` job runs `{{GATE_COMMAND}}`.

### 3.2 Hosted scanners are named exceptions

CodeQL, Scorecard, Sonar and Snyk (the App, and `snyk container test`,
which needs `SNYK_TOKEN`) stay CI-only. So does `acceptance (<iface>)`,
until #704. Each one is listed by name in a "CI-only checks" section of the
generated README, and each stays a required context in branch protection.
Any other check is in the gate.

### 3.3 One composed script per repo (approach A)

`render.zsh` builds `gate.zsh` from tagged blocks, using the per-tool
composition #1670 introduced:

- the shared stages are written once;
- each language contributes its own block file, for the primary language
  and every auxiliary;
- the conditional stages (contracts, policy, image, ops, web UI) are
  included when their marker is present at bootstrap time.

The rendered script names exactly the stages this repo has. A stage whose
subject later disappears still reports a skip at runtime. A deleted
Dockerfile is the example.

### 3.4 Stages, in order, stopping at the first red

| # | Stage | Check |
|---|---|---|
| 1 | hygiene | Over `git ls-files`: trailing whitespace, end-of-file newline, conflict markers, private keys, large files, JSON validity |
| 2 | yaml | `yamllint --strict` |
| 3 | secrets | `gitleaks detect` |
| 4 | format (check mode) | See the per-language commands below |
| 5 | lint | `ruff check`, `golangci-lint run`, `swiftlint lint --strict`, `eslint --max-warnings=0`. Java's lint is its compile step. |
| 6 | typecheck | `mypy` (Python); `tsc --noEmit` when `tsconfig.json` exists. Go, Java and Swift report `skipped — compiler-checked`. |
| 7 | test | The language test runner. Finding no tests is FAILED (§3.6). |
| 8 | coverage | diff-cover `--fail-under=90` (§3.5) |
| 9 | sast | `semgrep --config=auto --error` |
| 10 | vuln-scan | `trivy fs`: vuln, secret and misconfig findings at HIGH or CRITICAL, plus the license scan |
| 11 | contracts | spectral lint, contracts drift, griffe API stability |
| 12 | policy | `check-no-cluster-deploy.zsh` |
| 13 | image | `docker build` or `ko build --local`, then `trivy image` |
| 14 | ops | ops conformance |
| 15 | webui | playwright and `lhci autorun` |

The format stage's commands are:

- `ruff format --check`
- `golangci-lint fmt --diff`
- `./gradlew spotlessCheck`
- `swift-format lint --strict`
- `prettier --check .`

Trivy becomes a required gate tool for every language repo.

### 3.5 Coverage: diff-cover against a base the gate computes

The coverage stage runs diff-cover `--fail-under=90` on the lines changed
since the merge-base with `origin/<default>`:

- **The base.** The gate computes the merge-base itself, so the hook and CI
  measure the same diff. CI checks out with `fetch-depth: 0` so the merge-base
  can be found.
- **No changed lines.** A diff with no changed lines reports
  `skipped — no changed lines`.
- **JavaScript.** JS joins the floor through vitest's lcov output.

### 3.6 Verdicts, skips and failures

**Verdict lines.** The format is the IaC gate's, unchanged:
`gate: <stage> ok`, `gate: <stage> skipped — <reason>`, and
`gate: <stage> FAILED`.

**Exit codes.** Exit 0 is green and exit 1 means a stage failed. Exit 2
means a missing tool or a usage error, and it comes before any stage runs.

**Missing tools.** Before stage 1, the gate checks with `command -v` that
every tool its rendered stages need is installed. When one is missing, it
names the tool and its pinned version and exits 2.

**Two kinds of skip.**

- **Not applicable: a skip everywhere.** The thing the stage would check is
  absent. Examples: `no Dockerfile`, `no changed lines`, `no tsconfig.json`,
  `compiler-checked`, `no openapi/`, `no web UI`.
- **Unavailable: a skip locally, FAILED when `CI=true`.** The stage applies,
  but the environment cannot run it. Examples:
  - the Docker daemon is down;
  - the machine is offline, so the semgrep rules or the trivy DB cannot be
    fetched;
  - no browser is available;
  - no merge-base, because `origin/<default>` was not fetched.

  In CI the line reads, for example,
  `gate: image FAILED — docker unavailable in CI`. Without this split, a
  misconfigured runner would skip the image scan and still report a green
  `gate`.

**No tests is FAILED.** Each runner's exit for "no tests found" maps to red,
for example pytest's exit 5 and `go test`'s "no test files".

**No escape hatches.** There is no `--continue`, no per-stage disable and no
`SKIP=` variable. A repo that cannot run a stage changes `gate:` in
`.maintenance.yml` to its own command, where the change is visible.

### 3.7 Pre-commit is replaced

On the language paths, bootstrap no longer emits `.pre-commit-config.yaml`
and no longer runs `install-precommit-hooks.zsh` or
`reconcile-precommit-hooks.zsh`.

- **Checks move to the gate.** Hygiene, yamllint, gitleaks and the
  linters and formatters become the gate's check-mode stages.
- **Fixes move to `make fmt`.** Auto-fix is now an explicit target that
  runs `ruff format`, `ruff check --fix`, `golangci-lint fmt`,
  `spotlessApply`, `swift-format format -i`, `prettier --write` and
  `eslint --fix`.
- **The format stage names the fix.** Its FAILED line names `make fmt`.

### 3.8 CI: one `gate` job

`gate.yml` replaces `quality-<vis>.yml` and its noop twin.

- **Runner.** The single `gate` job runs on `macos-latest` when Swift is
  among the resolved languages, and on `ubuntu-latest` otherwise.
- **Steps.** The job checks out with `fetch-depth: 0`, installs the pinned
  toolchain, and runs `{{GATE_COMMAND}}`.
- **Pins.** Each install step is named `install <tool>` and carries a
  `<TOOL>_VERSION` value. Preflight and the tests read the same pins.
- **Docs-only PRs.** These still report `gate`, as one fast run, so the
  required context never hangs waiting.
- **Sonar.** Sonar is a second job in `gate.yml`, with `needs: gate`. It
  consumes the coverage artifact that the gate uploads.
- **CodeQL and Scorecard.** Both keep their own workflow files.
- **Retired workflows.** The pre-commit CI job, `gitleaks.yml`,
  contracts-lint, contracts-drift, api-stability, no-cluster-deploy and the
  webui-quality jobs are retired.

Branch protection on a language path requires `gate` and the §3.2 hosted
contexts, and nothing else.

## 4. Structure

What lands in a target repo:

```text
<repo>/
├── Makefile               # lint, fmt, hooks (emitted only if absent)
├── hooks/pre-push         # runs the gate command (plugin-owned, overwritten)
├── scripts/gate.zsh       # composed stages (plugin-owned, overwritten)
├── .maintenance.yml       # gate: make lint (added only if absent)
├── README.md              # gains a "CI-only checks" section
└── .github/workflows/
    ├── gate.yml           # jobs: gate, sonar (needs: gate)
    ├── codeql.yml, scorecard.yml        # hosted, unchanged
    └── push-and-sign / release / docs … # unchanged
```

Preflight (Step 4.5) installs the same pinned toolchain locally, so the
local verdict and the CI verdict agree. Bootstrap finishes by running
`make hooks`.

### 4.1 Migrating existing repos

Today's branch protection requires `test-and-coverage`, `pre-commit` and
other old contexts. A single PR that adds `gate.yml` and deletes the old
workflows would never receive those contexts, so it could not merge without
an admin override. Migration therefore takes three steps, and each step can
merge on its own:

1. **Add the gate.** A PR adds `gate.yml`, `scripts/gate.zsh`, the Makefile
   targets, `hooks/pre-push` and `gate:`. The old workflows stay, so the old
   required contexts gate this PR.
2. **Switch protection.** Once step 1 has merged, `branch-protection.sh`
   sets the required contexts to `gate` plus the hosted scanners.
3. **Retire the old checks.** A PR deletes the retired workflows and
   `.pre-commit-config.yaml`.

**Who migrates.** Re-running bootstrap on an existing repo performs the
migration. It is idempotent, and it waits for step 1 to merge before it
switches protection. The maintenance pipeline only detects a repo that is
still on `quality-*.yml`. It files one issue per repo and never migrates on
its own.

**Deletion rules.**

- A retired file is deleted only when it still matches its template render.
  A hand-edited one is listed in the PR body and left in place.
- A `.pre-commit-config.yaml` hook that the repo added itself is listed in
  step 3's PR body under "not carried over — add a stage to `gate.zsh` or
  drop it".
- Local `.git/hooks/pre-commit` scripts need no uninstall, because git
  ignores `.git/hooks` once `core.hooksPath` is set.

**Custom gate commands.** When a repo already has its own `gate:` value,
migration keeps it and reports it. `scripts/gate.zsh` is still emitted, so
the repo can switch to it when it chooses.

## 5. Testing

Deterministic behaviour is tested in bats. Real toolchains run only in E4,
as #1602 did.

- **Render** (`bootstrap-gate-render.bats`).
  - Language sets covered: each single language, Python with a JS
    auxiliary, and Swift with JS.
  - For each set, the rendered `gate.zsh` has exactly the expected stages,
    in order.
  - The workflow has one `gate` job, on macOS exactly when Swift is in the
    set.
  - Every `install <tool>` step carries a parseable `<TOOL>_VERSION` pin.
  - `Makefile` and `gate:` are emitted only when absent.
- **Behaviour** (`gate-script.bats`). Every tool is stubbed, with host
  `/usr/bin` hidden (#1605).
  - For each stage: ok, a not-applicable skip, an unavailable skip with
    `CI` unset, and an unavailable FAILED with `CI=true`.
  - A missing tool exits 2 before stage 1.
  - The first red stops the run.
  - Finding no tests is FAILED.
  - The diff-cover base comes from the merge-base.
- **Protection.**
  - A language path requires exactly `gate` plus the hosted contexts.
- **Migration.**
  - The three steps run in order, and bootstrap stops before the protection
    switch until step 1 has merged.
  - A file that matches its template is deleted. An edited one is reported.
  - Repo-added pre-commit hooks are listed as not carried over.
- **Repo-wide invariant.** A `git ls-files` sweep asserts that no
  language-path template references `pre-commit` or
  `.pre-commit-config`.
- **Mutation.** Every new guard is mutation-checked once (#1587).
- **E4 end to end.** One scratch fixture repo per language, built outside
  the repository, using real toolchains on macOS.
  - `make lint` is green on the clean fixture.
  - A seeded defect reds its stage.
  - `hooks/pre-push` refuses that push.
  - Migration runs against a fixture that is still on `quality-*.yml`.
  - The gate's wall-clock time is recorded for each fixture.

## 6. Documentation

- `explanation/iac-gate.md` generalises to `explanation/gate-command.md`,
  one page for both families. The old path redirects to it.
- New `how-to/migrate-to-the-gate.md`.
- New `reference/gate-stages.md`. Its stage table lists, for each stage, the
  tools, the not-applicable condition and the unavailable condition.
- ARCHITECTURE.md extends the gate position from IaC to every path and
  retires the pre-commit statement.
- The bootstrap README template gains the "CI-only checks" section.

## 7. Risks

| Risk | Mitigation |
|---|---|
| **Slow pushes.** Fifteen stages, image and web UI among them, make pre-push slow. | Stages with nothing to check skip at once. E4 records the wall-clock time per fixture, and an over-budget figure becomes a follow-up issue rather than an escape hatch. |
| **Commit-time auto-fix is lost.** | `make fmt` takes over, and the format stage's FAILED line names it. |
| **One script on two platforms.** The gate runs on macOS locally and on ubuntu in CI, and the BSD and GNU tools differ. | The ubuntu bats CI job runs the behaviour suite. The IaC gate has already proved the pattern. |
| **Swift CI cost.** A Swift repo's whole gate runs on macOS minutes. | Accepted. Splitting the job would bring back a second required context. |
| **Breaking change to the bootstrap contract.** No pre-commit config, and new required contexts. | A major version bump of `development`, plus the migration how-to. |

Retiring the pre-commit CI job also fixes the toolchain-less ubuntu
backstop bug from §1.

## 8. Follow-ups

- Move `acceptance (<iface>)` into the gate once #704 lands.
- Delete `install-precommit-hooks.zsh` and `reconcile-precommit-hooks.zsh`
  outright once no tracked repo is still on pre-commit.
- Set a pre-push wall-clock budget, if the E4 numbers call for one.

## 9. Decomposition

| # | Child | Depends on |
|---|---|---|
| 1 | `gate.zsh` framework: verdict lines, both skip classes, the missing-tool refusal, exit codes, shared stages 1–3 and 9–10, behaviour tests | — |
| 2a–2e | One language block each (Python, Go, Java, Swift, JS): format, lint, typecheck, test, coverage. Each is a separate tagged-block file, so the five can run in parallel. | 1 |
| 3 | Conditional stages: contracts, policy, image, ops, web UI | 1 |
| 4 | Emission: `gate.yml`, Makefile `fmt`, hooks and `gate:` on the language paths, the README "CI-only checks" section, no more pre-commit emission | 2a–2e, 3 |
| 5 | Branch protection: `gate` plus the hosted contexts on the language paths | 4 |
| 6 | Preflight: install the pinned toolchain (one pin, several readers) | 4 |
| 7 | Migration: the three-step re-bootstrap, the deletion rules, maintenance detection | 5, 6 |
| 8 | Docs: explanation, how-to, reference, ARCHITECTURE | 7 |
