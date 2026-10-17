# Repo scripts

Among others, these helper scripts live in
[`scripts/`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts):

| Script | What it does |
| --- | --- |
| `build-workflows-booklet.zsh` | Builds the standalone workflows booklet, `workflows.pdf` and `workflows.epub`: the [How the plugins work](../explanation/how-the-plugins-work.md) pages with their diagrams. The chapters are not listed in the script; they are the mkdocs nav entries for `docs/explanation/how-the-plugins-work.md`, `how-the-family-learns.md` and `docs/explanation/workflow-*.md`, in nav order. It uses the same pandoc image, filter, headers and font size as the manual. Takes an optional output directory inside the repository (default: the repo root); needs `docker`. Exits `0` when both files were produced, `1` when a build failed or left an empty file, `2` on usage/tooling errors. Runs in `docs.yml` on every docs PR, and in `docs-publish.yml`, which attaches both files to the `docs-latest` release. |
| [`capture-session-log.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/capture-session-log.zsh) | Bundles a Claude Code run's main transcript **and** its subagent transcripts (plus any worktree / headless `plugin-test` sessions it spawned) into one `.tgz` for handing a real run back to the plugins. Interactive by default (no arguments — defaults to the newest project + session); supports `--list`, `--project`, `--session`, `--out`, `--dry-run`, `--main-only`, and `--related`. See "Feeding real runs back" in [How-to: maintain this repo](../how-to/maintain-this-repo.md). |
| [`check-marketplace-sync.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/check-marketplace-sync.zsh) | Verifies that every per-plugin version in `.claude-plugin/marketplace.json` matches the corresponding `plugin.json`. Exits `0` when in sync, `1` on any mismatch, `2` on usage errors (missing `jq` or marketplace file). Takes no arguments; run it locally before pushing. Also runs in CI via `marketplace-sync.yml` on every PR that touches a `plugin.json` or `marketplace.json` (issue #188). |
| [`check-styleguide-pin.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/check-styleguide-pin.zsh) | Proves the **shipped** Spectral shim still resolves the published org API styleguide **through the pin** (#689). Lints the non-conforming fixture with `templates/common/.spectral.yaml` itself as `--ruleset`, so the remote `extends` resolves over the network, and asserts **positively** that every id in its `EXPECTED_RULES` roster fires at `error` — because a pin that 404s (or resolves but loads no rules) makes Spectral report "0 problems", so an expect-failure check would go green on a completely broken pin. …and, symmetrically, that the committed conforming fixture produces zero error findings through the same pin, so a ruleset that flagged everything cannot satisfy the roster assertion; a missing fixture is exit `2`, never a verdict. Takes no arguments; needs `node`/`npx`, `jq`, `curl` **and network**. Exits `0` when the pin resolves and enforces every id in that roster, `1` on a pin or conformance failure, `2` on tooling/usage errors. Runs in CI via `styleguide-pin.yml` on every PR touching the shim, the ruleset, the fixtures or the checker — plus a weekly cron, because a pin can rot from outside this repo (a deleted tag, a CDN regression) with nothing here changing. |
| `flake-hunt.zsh` | Reproduces load-dependent bats failures on demand (#1796). It runs the suite, or the `.bats` files you name, `--iterations` times under forced contention: an oversubscribed `bats --jobs`, one busy loop per CPU, and `LC_ALL=C`. It then reports each test that failed at least once, with its failure count and its first failure's TAP diagnostics. When to run it, and how to read the result, is in `MAINTAINING.md`, *Hunting load-dependent flakes*. The flags and exit codes are in the script's own header. |
| [`refresh-local-install.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/refresh-local-install.zsh) | Fully refreshes your local install: updates the Claude Code CLI (Homebrew cask or `claude update`), hard-purges every on-disk cache for the `timos-claude-code-plugins` marketplace (per-plugin cache, marketplace clone, plugin data dir, shared catalog cache), then re-adds the marketplace and reinstalls every plugin it publishes — so local state matches the latest published marketplace. Only the timos marketplace is touched. Destructive: prints the plan and prompts once; `-y`/`--yes` skips the prompt, `--dry-run` prints the plan and changes nothing. Restart Claude Code afterwards to apply. The closing summary reports each version transition (`old -> new`, or the bare version when this run changed nothing) plus the date **and local time** that plugin's directory was last changed in the marketplace repo, formatted per your locale. Requires `jq` + the `claude` CLI; `git` is optional (without it, or when the marketplace clone can't be deepened past its shallow single commit, the dates read `unknown`). |
| `render-diagrams.zsh` | Renders every Mermaid source `docs/**/diagrams/<name>.mmd` to the `<name>.svg` beside it, with the pinned `minlag/mermaid-cli` image and `scripts/mermaid/config.json`. Commit both files: the site and both PDF builds embed the SVG and need no Mermaid at build time. The config keeps labels as SVG `<text>`, because `rsvg-convert` (pandoc's SVG-to-PDF step) drops the `<foreignObject>` HTML labels Mermaid emits by default; the script refuses an SVG that still carries one, and marks every `<text>` `xml:space="preserve"` so word spacing survives. Takes `.mmd` paths, or none for all of them; needs `docker`. Exits `0` when every SVG rendered clean, `1` on a failed render, `2` on usage/tooling errors. `tests/workflow-diagrams.bats` checks the committed SVGs. |

## Scripts bootstrap emits into a target repository

The scripts above are this repository's own. `/development:bootstrap` also writes scripts
**into the repositories it bootstraps**. This section documents the three gate scripts.

### `scripts/k8s-gate.zsh`

Emitted on the infrastructure-as-code path only, as a plugin-owned artifact: a bootstrap
re-run shows you the diff and asks whether to overwrite it. Its source is the bootstrap
template `templates/iac/scripts/k8s-gate.zsh.tmpl`.
It is the gate **mechanism**: the six stages, their order and their tool invocations. The
repository's gate **command**, recorded as `gate:` in
[`.maintenance.yml`](maintenance-yml.md), is `make lint` by default, and the Makefile's
`lint` target runs this script. `.github/workflows/kubernetes-ci.yml`'s `gate` job and
`hooks/pre-push` both run that command. [The IaC gate](../explanation/iac-gate.md)
explains the design.

**Invocation.** Run `make lint`, or `zsh scripts/k8s-gate.zsh` from the repository root.
The script gates the current directory and takes no arguments except `-h` / `--help`.
Any other argument exits `2`.

**Required tools.** `helm`, `kubeconform`, `kube-linter`, `kyverno`, `trivy`, `yq`
(mikefarah's v4, not python-yq) and `kustomize`, or `kubectl` in its place. The script
checks every tool before it runs any stage. When a tool is missing it names the tool,
prints the `brew install` line for it, and exits `2` without running any stage.

**Stages**, in order. The script stops at the first stage that fails.

| # | Stage | What runs | Input |
| --- | --- | --- | --- |
| 1 | `render` | `helm template` per top-level chart; `kustomize build --enable-helm` per overlay root that no other root consumes (`kubectl kustomize --enable-helm` when `kustomize` is absent); standalone manifests, including policy fixture resources, copied as they are | the repository's sources, copied to a scratch directory |
| 2 | `schema` | `kubeconform -strict -summary -ignore-missing-schemas` | rendered |
| 3 | `lint` | `kube-linter lint`, which reads `.kube-linter.yaml` when present | rendered |
| 4 | `policy` | `kyverno apply` of the policies in `policies/kyverno/` against the rendered tree, then `kyverno test` on the fixtures there | rendered, plus `policies/kyverno/` |
| 5 | `config-scan` | `trivy config` with `--severity HIGH,CRITICAL`, which reads `.trivyignore` when present | rendered |
| 6 | `argocd` | checks that every path referenced by an `Application` / `ApplicationSet` this repository owns exists on disk | sources and rendered |

That is render → schema → lint → policy → config-scan → argocd. Rendering writes to a
temporary directory that the script removes on exit.

**Verdict lines.** Each stage that runs prints exactly one verdict line to stdout. After a
failure the run stops, so later stages print none:

| Line | Meaning |
| --- | --- |
| `gate: <stage> ok` | the stage passed |
| `gate: <stage> skipped — <reason>` | the stage did not run, for the stated reason |
| `gate: <stage> FAILED` | the stage failed; its tool's output is printed above the line |

The script prints errors, warnings and notices as `error: …`, `warning: …` and `notice: …`
lines. When
`GITHUB_ACTIONS` is set, it prints them as workflow commands (`::warning::…`) instead,
and they appear as annotations in CI.

**Skip rules.** A skip is always reported. There are exactly two:

- **Nothing to render.** This applies when the repository has no chart, no buildable
  overlay and no standalone manifest, or when rendering produced no object. `render` prints
  `gate: render skipped — nothing to render`, every later stage prints the same skip, and
  the script exits `0`. A freshly bootstrapped empty repository is therefore green.
- **No policies declared.** This applies when no file matches
  `policies/kyverno/**/*.{yaml,yml}`. `policy` skips and the other stages still run. An
  empty `policies/kyverno/`, or one holding only `.json` files, skips in the same way as an
  absent one. Once a matching file exists, the policies are enforced. A declared set that
  contains no `Policy` or `ClusterPolicy` document the pinned `kyverno` CLI can evaluate
  fails the stage rather than skipping it.

**Untested-policy warning.** When policies are declared but the directory contains no
`kyverno-test.yaml` or `kyverno-test.yml` fixture, `kyverno test` does not run, and the
script prints the warning
`policies declared but no kyverno test fixtures under policies/kyverno — maintenance reports this as policy_tests`.
This is a warning, not a failure. An untested policy usually matches nothing.

**Exit codes.**

| Code | Meaning |
| --- | --- |
| `0` | every stage passed or was skipped |
| `1` | a stage failed; its `FAILED` verdict line names it |
| `2` | the gate could not run: a required tool is missing, the invocation is bad, or `K8S_GATE_RENDER_DIR` names a directory the script refuses to use |
| `130` / `143` | interrupted (SIGINT) or terminated (SIGTERM). The stage that was running still prints its `FAILED` line, which shows where the run stopped rather than a tool's verdict, and the temporary directories are still removed |

**Environment variables.**

| Variable | Effect |
| --- | --- |
| `REPO_SLUG` | `owner/name` of the repository, used by the `argocd` stage to select the Applications this repository owns. Defaults to `GITHUB_REPOSITORY`, which every Actions runner sets, and then to the `origin` remote. You need it when the repository declares Argo CD Applications and neither default resolves, or when `origin` is a fork: the stage would then select no Application and pass without checking any path. With Applications present and no resolvable slug, the stage fails instead of passing without having checked anything |
| `K8S_GATE_RENDER_DIR` | render into this directory and keep it after the run, so you can inspect exactly what the gate validated. The directory must lie outside the repository and must be absent or empty. Otherwise the script exits `2` |

**Versions.** `.github/workflows/kubernetes-ci.yml` installs pinned tool versions.
Bootstrap's preflight installs the current Homebrew versions, which cannot be pinned.
Tool verdicts change between releases, so before you conclude that a local red is a
regression, run the pinned versions.

### `scripts/tofu-gate.zsh`

Emitted on the OpenTofu infrastructure-as-code path only, as a plugin-owned artifact. Its
source is the bootstrap template `templates/opentofu/scripts/tofu-gate.zsh.tmpl`. The
Makefile's `lint` target runs it, and `.github/workflows/opentofu-ci.yml`'s `gate` job and
`hooks/pre-push` both run that command. [Bootstrap an OpenTofu repository](../how-to/bootstrap-an-opentofu-repo.md)
walks through using it.

**Invocation.** Run `make lint`, or `zsh scripts/tofu-gate.zsh` from the repository root.
It takes no arguments except `-h` / `--help`; any other argument exits `2`.

**Required tools.** `tofu`, `tflint`, `trivy`, `conftest` and `jq`, each checked before any
stage runs. A missing tool is named with its `brew install` line, and the script exits `2`.

**Stages**, in order. The script stops at the first stage that fails, and runs every stage
on a scratch copy of the repository, so `tofu init` never writes into the working tree.

| # | Stage | What runs |
| --- | --- | --- |
| 1 | `fmt` | `tofu fmt -check -recursive` |
| 2 | `validate` | `tofu init -backend=false` and `tofu validate`, once per root module |
| 3 | `lint` | `tflint --recursive`, after `tflint --init` when `.tflint.hcl` exists |
| 4 | `config-scan` | `trivy config` with `--severity HIGH,CRITICAL`, which reads `.trivyignore` when present |
| 5 | `state-encryption` | report-only: warns when the repository owns state that nothing encrypts at rest |
| 6 | `policy` | `conftest test --all-namespaces` of the `.tf` files against `policies/conftest/hcl/`, then `conftest verify` |
| 7 | `plan-policy` | opt-in: `tofu plan` per root module, then `conftest test` of `tofu show -json` against `policies/conftest/plan/` |

**Verdict lines and exit codes** are the same as `scripts/k8s-gate.zsh`'s above, without
`K8S_GATE_RENDER_DIR`. A repository with no `.tf` or `.tf.json` outside `.terraform/`,
`node_modules/`, `vendor/` and `.git/` skips every stage and exits `0`.

**Skip rules.** `policy` prints a notice and skips when `policies/conftest/hcl/` holds no
`.rego`; with policies but no `conftest verify` tests it runs `conftest test` and warns.
`policy` fails, naming the file, on a `.rego` under `policies/conftest/` in neither `hcl/`
nor `plan/`: the maintenance gather's glob is `policies/conftest/**/*.rego`, so that file
is declared, yet no stage would evaluate it.
`plan-policy` skips unless `.maintenance.yml` records `opentofu_plan_policy: true`; with
the key on and `tofu init` or `tofu plan` failing, it fails and names the key.

**Versions.** `.github/workflows/opentofu-ci.yml` installs pinned tool versions; its
Conftest pin equals the one `gather-opentofu-findings.zsh` evaluates with.

### `scripts/go-gate.zsh`

Emitted for a repository whose `primary:` is `go` (#2122), as a plugin-owned artifact. Its
source is the bootstrap template `templates/languages/go/scripts/go-gate.zsh.tmpl`. The
repository's gate command is `make check` by default, and the Makefile's `check` target
runs this script. `.github/workflows/go-ci.yml`'s `gate` job and `hooks/pre-push` both run
that command.

**Invocation.** Run `make check`, or `zsh scripts/go-gate.zsh` from the repository root.
It takes no arguments except `-h` / `--help`; any other argument exits `2`.

**Required tools.** `golangci-lint`, `diff-cover`, `trivy`, `gitleaks` and `pre-commit`,
which `make setup` installs into `.tools/` at the versions the Makefile pins, whatever
`tools.vulnerabilities` declares. `buf`, `govulncheck`, `gocover-cobertura`, `oasdiff` and
`yq` are Go tool dependencies in `go.mod`, run with `go tool`; the gate puts `oasdiff` and
`yq` on `PATH` as shims for the checker scripts that call them by name. The Spectral CLI and
the `pandoc/extra` image are pinned in the two shared checkers stages 11 and 13 call,
[`scripts/check-contracts-lint.zsh`](#scriptscheck-contracts-lintzsh) and
[`scripts/check-docs.zsh`](#scriptscheck-docszsh). `node`,
`python3`, `docker` and `jq` are the machine's own. A missing tool fails the stage that
needs it: for a `make setup` tool the failure names `make setup`, for a machine tool it names
the tool, and for a `go tool` one go's own "no such tool" error shows, which `go get -tool`
fixes.

**Stages**, in order. The script stops at the first stage that fails. A stage it skips
prints one `go-gate: skip <stage> — <reason>` line.

| # | Stage | What runs | Skipped when |
| --- | --- | --- | --- |
| 1 | `format` | `golangci-lint fmt --diff`; any diff fails | no Go package yet |
| 2 | `lint` | `golangci-lint run` | no Go package yet |
| 3 | `proto` | `buf lint`, then `buf breaking` against `origin/<default branch>` | no `buf.yaml`; the breaking check alone when the base branch has no `buf.yaml` |
| 4 | `generation` | `buf generate`, then fails when a path named by an `out:` in `buf.gen.yaml` changed | no `buf.gen.yaml` |
| 5 | `tests` | `go test -race` with coverage, then `diff-cover --fail-under=90` against `origin/<default branch>` | the coverage floor alone, when no `*.go` file changed; no Go package yet |
| 6 | `vulnerabilities` | `govulncheck ./...`, plus `trivy fs --scanners vuln,secret,misconfig` when trivy is declared | `tools.vulnerabilities: none`; `govulncheck` alone, when there is no Go package yet |
| 7 | `secrets` | `gitleaks git` over `origin/<default branch>..HEAD` | never |
| 8 | `no cluster deploy` | `scripts/check-no-cluster-deploy.zsh` | never |
| 9 | `license` | `trivy fs --scanners license`, under every `tools.vulnerabilities` value | never |
| 10 | `pre-commit` | `SKIP=gitleaks,trivy-fs pre-commit run --all-files` | no `.pre-commit-config.yaml` |
| 11 | `contracts lint` | `scripts/check-contracts-lint.zsh`: Spectral over the newest major of `contracts/` and `contracts/ops/`; a newest `vN` without `openapi.yaml` fails | nothing under `contracts/`, no `.spectral.yaml` and not the checker changed against `origin/<default branch>` |
| 12 | `contracts semver` | `check-contracts-semver.sh` for `contracts/`, then `contracts/ops`, writing `contracts-semver-findings.json` and `contracts-ops-semver-findings.json`; either failing fails the stage | nothing under `contracts/` and not the checker changed |
| 13 | `docs` | `scripts/check-docs.zsh`: `mkdocs build --strict`, then `manual.pdf` and `manual.epub` with pandoc, failing on a missing glyph or an unresolved reference | no docs source (`docs.yml`'s paths) and not the checker changed; no `mkdocs.yml` |

Every comparison against the base branch needs its history, so CI checks out the full
history (`fetch-depth: 0`). Locally, a missing `origin/<default branch>` fails the gate
before its first stage and names `git fetch origin`.

### `scripts/check-contracts-lint.zsh`

Emitted with the Go gate (#2640), as a plugin-owned artifact copied verbatim from
`templates/common/scripts/check-contracts-lint.zsh`. It is the `contracts lint` stage every
language gate shares: a gate calls it rather than carrying its own copy of the selection.

**Invocation.** `zsh scripts/check-contracts-lint.zsh [--caller <name>]`, from the repository
root. `--caller` names the calling gate and prefixes every line the script prints:
`<caller>: FAIL contracts lint — <reason>` on stderr, `<caller>: linting <specs>` on stdout.
Without it the prefix is `check-contracts-lint`. `-h` / `--help` prints the header.

**What it does.** It selects the newest strict `vN` major of `contracts/` and of
`contracts/ops/` that holds an `openapi.yaml`, with the same selection `contracts-lint.yml`
makes, and refuses a newest `vN` directory without one rather than falling back to an older,
frozen major. It then runs the Spectral CLI it pins, through `npx`, with the repository's
`.spectral.yaml` and `--fail-severity error`. It needs `node`.

**Exit codes.** `0` linted; `1` failed, the reason on stderr; `2` an unknown or malformed
argument; `3` no `contracts/vN/openapi.yaml` to lint, which the gate reports as a skip.

### `scripts/check-docs.zsh`

Emitted with the Go gate (#2640), as a plugin-owned artifact copied verbatim from
`templates/common/scripts/check-docs.zsh`. It is the `docs` stage every language gate shares.

**Invocation.** `zsh scripts/check-docs.zsh --out <dir> [--caller <name>]`, from the
repository root. `--out` is an existing directory that receives `site/`, `manual.pdf`,
`manual.epub` and the pandoc log; the script neither creates nor removes it. `--caller`
prefixes every line the script prints, as for `check-contracts-lint.zsh`; without it the
prefix is `check-docs`. `-h` / `--help` prints the header.

**What it does.** It installs `requirements-docs.txt` into `.tools/docs-venv`, runs
`mkdocs build --strict`, derives the chapter order with `scripts/docs-nav-to-chapters.zsh`,
and builds `manual.pdf` and `manual.epub` with the `pandoc/extra` image it pins, the way
`docs.yml` does. It fails on a character xelatex has no glyph for and on an unresolved
reference, after a probe proves the image still reports one. It needs `python3` and
`docker`.

**Exit codes.** `0` built; `1` failed, the reason on stderr; `2` an unknown or malformed
argument, including a missing or empty `--out`, or one that is not an existing directory.
