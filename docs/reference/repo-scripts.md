# Repo scripts

Four helper scripts live in [`scripts/`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts):

| Script | What it does |
| --- | --- |
| [`capture-session-log.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/capture-session-log.zsh) | Bundles a Claude Code run's main transcript **and** its subagent transcripts (plus any worktree / headless `plugin-test` sessions it spawned) into one `.tgz` for handing a real run back to the plugins. Interactive by default (no arguments — defaults to the newest project + session); supports `--list`, `--project`, `--session`, `--out`, `--dry-run`, `--main-only`, and `--related`. See "Feeding real runs back" in [How-to: maintain this repo](../how-to/maintain-this-repo.md). |
| [`check-marketplace-sync.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/check-marketplace-sync.zsh) | Verifies that every per-plugin version in `.claude-plugin/marketplace.json` matches the corresponding `plugin.json`. Exits `0` when in sync, `1` on any mismatch, `2` on usage errors (missing `jq` or marketplace file). Takes no arguments; run it locally before pushing. Also runs in CI via `marketplace-sync.yml` on every PR that touches a `plugin.json` or `marketplace.json` (issue #188). |
| [`check-styleguide-pin.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/check-styleguide-pin.zsh) | Proves the **shipped** Spectral shim still resolves the published org API styleguide **through the pin** (#689). Lints the non-conforming fixture with `templates/common/.spectral.yaml` itself as `--ruleset`, so the remote `extends` resolves over the network, and asserts **positively** that every id in its `EXPECTED_RULES` roster fires at `error` — because a pin that 404s (or resolves but loads no rules) makes Spectral report "0 problems", so an expect-failure check would go green on a completely broken pin. …and, symmetrically, that the committed conforming fixture produces zero error findings through the same pin, so a ruleset that flagged everything cannot satisfy the roster assertion; a missing fixture is exit `2`, never a verdict. Takes no arguments; needs `node`/`npx`, `jq`, `curl` **and network**. Exits `0` when the pin resolves and enforces every id in that roster, `1` on a pin or conformance failure, `2` on tooling/usage errors. Runs in CI via `styleguide-pin.yml` on every PR touching the shim, the ruleset, the fixtures or the checker — plus a weekly cron, because a pin can rot from outside this repo (a deleted tag, a CDN regression) with nothing here changing. |
| [`refresh-local-install.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/refresh-local-install.zsh) | Fully refreshes your local install: updates the Claude Code CLI (Homebrew cask or `claude update`), hard-purges every on-disk cache for the `timos-claude-code-plugins` marketplace (per-plugin cache, marketplace clone, plugin data dir, shared catalog cache), then re-adds the marketplace and reinstalls every plugin it publishes — so local state matches the latest published marketplace. Only the timos marketplace is touched. Destructive: prints the plan and prompts once; `-y`/`--yes` skips the prompt, `--dry-run` prints the plan and changes nothing. Restart Claude Code afterwards to apply. The closing summary reports each version transition (`old -> new`, or the bare version when this run changed nothing) plus the date **and local time** that plugin's directory was last changed in the marketplace repo, formatted per your locale. Requires `jq` + the `claude` CLI; `git` is optional (without it, or when the marketplace clone can't be deepened past its shallow single commit, the dates read `unknown`). |

## Scripts bootstrap emits into a target repository

The scripts above are this repository's own. `/development:bootstrap` also writes scripts
**into the repositories it bootstraps**. This section documents the gate script.

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
