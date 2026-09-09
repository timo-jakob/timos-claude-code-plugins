# IaC bootstrap — the single gate command

> Design for reshaping the `development` bootstrap skill's
> infrastructure-as-code path (§3l, #1154) around one locally runnable gate
> command that CI and a version-controlled pre-push hook invoke verbatim.
> Supersedes the six-job `kubernetes-ci.yml` shape. Epic: filed from this
> spec; children listed in §9.

## 1. Motivation

The consuming platform's `PLATFORM-CONTRACT.md` §12 ("Delivery Gate") binds
every repository it governs:

- the full validation gate is **one command**, runnable on a developer
  machine;
- CI invokes **that same command** — it must not re-implement a check, add
  one the local gate lacks, or run under a different configuration;
- a **pre-push hook** runs it, version-controlled in the repository so a
  fresh clone acquires it;
- **no check may exist only in CI**.

The IaC path bootstrap ships today violates each point. Its
`kubernetes-ci.yml` template re-implements six checks as six jobs
(`render`, `schema`, `lint`, `policy`, `config-scan`, `argocd`), none of
which a developer can run without reading the workflow. Its hooks come from
the `pre-commit` framework, a per-machine install rather than a
version-controlled file. And its `render` job runs plain `kustomize build`,
so a component that inflates a Helm chart through `helmCharts:` renders
empty and every downstream check passes green on nothing.

A fourth gap is independent of §12: the path refuses a language-free repo
that carries no Kubernetes marker. A GitOps repository that has not yet
committed its first `kustomization.yaml` therefore cannot bootstrap — which
is the one moment a tool called bootstrap exists for.

This slice fixes all four on the IaC path. The language paths (Python, Go,
Java, Swift, JavaScript) re-implement checks in CI in the same way; bringing
them onto the gate model is a follow-up epic (§8), not this slice.

## 2. Scope

**In.** The `development` plugin's bootstrap skill, IaC path only: the
generated gate script, Makefile, pre-push hook, workflow, `.maintenance.yml`
key, the Q4 empty-repo confirmation, the toolchain preflight, the
branch-protection context set, tests, and the user-facing documentation.

**Out.** The language paths. The `development-kubernetes` maintenance gather
script, which still runs the tools itself (§8). The mixed repo (#1193) and
the dual-marker repo (#1394). In-cluster admission control. Any layout
opinion — bootstrap writes no manifests, no `policies/`, no `apps/`.

## 3. Decisions

### 3.1 The gate is a script bootstrap emits; the command is the repo's

Bootstrap emits `scripts/k8s-gate.zsh` into the target repo. It is the
**mechanism** — the six stages, their order, their tool invocations — and it
is refreshed on a re-run like every other bootstrap artifact. The repo's
gate **command** is `make lint`, recorded in `.maintenance.yml` as
`gate: make lint`, and `lint` is a Makefile target that runs the script.

Why a script plus a Makefile target rather than either alone:

- A script alone makes CI and developers invoke different names (`make
  lint` locally, `scripts/k8s-gate.zsh` in the workflow), which is the drift
  §12 exists to forbid, and leaves the repo without the `hooks` target the
  pre-push wiring needs.
- A Makefile alone puts the mechanism into a file the consumer owns and
  edits, so a bootstrap re-run could not refresh it.

Approach rejected: a reusable workflow hosted in this plugin repository. The
check would then live where a developer cannot run it, and plugin/repo
version skew would be invisible.

### 3.2 Six stages, one process, rendered output

The script runs, in order, stopping at the first failing stage:

| Stage | What runs | Input |
|---|---|---|
| render | `helm template` per top-level chart; `kustomize build --enable-helm` per overlay root | sources |
| schema | `kubeconform -strict -summary -ignore-missing-schemas` | rendered |
| lint | `kube-linter lint` | rendered |
| policy | `kyverno apply` against rendered, then `kyverno test` on the fixtures | rendered + `policies/kyverno/` |
| config-scan | `trivy config` | rendered |
| argocd | every `Application`/`ApplicationSet` path this repo owns exists | rendered |

Rendering goes to a temporary directory the script removes on exit. Every
stage after `render` consumes rendered manifests, never templates or
Kustomize inputs — the property #1154 established, kept.

**Helm inflation is on.** `--enable-helm` is passed unconditionally. Without
it the `helmCharts:` field is silently ignored and the rendered tree is
empty for exactly the components that most need checking. `kustomize`
absent from `PATH` falls back to `kubectl kustomize`, which supports the
same flag.

**Each stage prints one verdict line** to stdout on completion —
`gate: <stage> ok`, `gate: <stage> skipped — <reason>`, or `gate: <stage>
FAILED` — so the output is readable in a terminal and in a workflow log
without either side adapting it.

### 3.3 Skips are reported, never silent; failures are loud

- **Nothing to render** (no chart, no buildable overlay): `render` reports
  `skipped — nothing to render`, every later stage skips for the same
  reason, and the gate exits 0. This is what makes bootstrapping an empty
  repository meaningful: the pipeline is green and waiting for the first
  manifest.
- **No `policies/kyverno/`**: `policy` skips with a report. The rule from
  #1150 holds — the plugin ships mechanism, the consumer ships policy, and
  absent policy is a skip, not a failure. A policy directory with no
  `kyverno test` fixtures is reported as a warning line, since an untested
  policy usually matches nothing.
- **A required tool is missing**: the script exits non-zero before running
  any stage, naming the tool and the exact `brew install` line. It never
  degrades to running the stages it can.
- **Any stage fails**: exit non-zero with that stage's tool output above the
  verdict line. Warning-only results do not satisfy the gate.

### 3.4 Hooks are files in the repository, not a framework

On the IaC path bootstrap emits `hooks/pre-push`, a two-line script that
runs the gate command, and a `Makefile` `hooks` target that sets
`core.hooksPath hooks`. Bootstrap runs `make hooks` once at the end of the
run. `.pre-commit-config.yaml` is **not** emitted on this path and Step 4a's
`pre-commit` install does not run.

Why: §12 requires the hook to be version-controlled and acquired by a fresh
clone; `pre-commit` hooks are installed per machine from a Python tool a
manifests repository has no other reason to carry. The hygiene hooks the
common config provides (trailing whitespace, end-of-file) are not part of
the gate on this path. If a consumer wants them, they belong inside the gate
command, not beside it.

### 3.5 The workflow is one job that runs the command

`kubernetes-ci.yml` becomes a single job named `gate`: checkout, install the
pinned tools, run `{{GATE_COMMAND}}`. The command is a bootstrap-time
substitution from `.maintenance.yml`, not a runtime read. Nothing else runs
in CI. Tool versions are pinned in the workflow and are the same versions
the local preflight installs (§3.7), so a local verdict and a CI verdict are
the same verdict.

Consequence: one requirable status context, `gate`, instead of six. §12
asks for exactly this — a check that fails in CI must be the same check
that failed locally, and one command has one result.

### 3.6 An empty GitOps repository bootstraps on explicit confirmation

Q4's "none — this is a GitOps/IaC repo" answer is accepted **without** the
Kubernetes marker when the user confirms a second, explicit question:

> This repository carries no Kubernetes marker yet (no `kustomization.yaml`,
> `Chart.yaml`, or Argo CD resource). Bootstrap it as an empty GitOps
> repository? The gate will report "nothing to render" until the first
> manifest lands.

Detection is unchanged: `detect-stack.sh` still reports `is_kubernetes:
false` on such a repo. The IaC path is selected from the **resolved** answer,
and `primary: kubernetes` is written to `.maintenance.yml` as today, so a
later run, the State D gap-fill, and the maintenance orchestrator all key on
the record rather than on the marker. The existing rule that a recorded
primary can veto but never grant the path still holds — the grant comes
from the user's answer in this run, not from the file.

"None" with `is_kubernetes=false` and **no** confirmation still halts, as
today.

### 3.7 Branch protection and preflight

`branch-protection.sh --iac-only true` requires the single context `gate`.
The Step 4.5 preflight batch-installs, on the IaC path, the tools the gate
needs: `kustomize`, `kubeconform`, `kube-linter`, `kyverno`, `trivy`, `yq`.
Versions are the ones `tests/iac-tools.zsh` pins for the fixture harness,
which are also the ones the workflow installs — one pin, three readers.

### 3.8 Idempotency

- `scripts/k8s-gate.zsh` and `hooks/pre-push` are plugin-owned artifacts:
  overwritten on a re-run after the usual diff-and-confirm.
- `Makefile` is emitted only when absent. When one exists, the idempotency
  reviewer proposes adding the `lint` and `hooks` targets, as it does for
  every other conflicting file today; bootstrap never rewrites a consumer's
  Makefile wholesale.
- `.maintenance.yml`'s `gate:` key is added when absent and left alone when
  present, so a consumer who renames the command keeps the name.

## 4. Structure of what lands in a target repository

```text
<repo>/
├── Makefile                          # lint, hooks (emitted if absent)
├── hooks/pre-push                    # runs `make lint`
├── scripts/k8s-gate.zsh              # the six stages
├── .maintenance.yml                  # primary: kubernetes, gate: make lint
└── .github/workflows/kubernetes-ci.yml   # one job: gate
```

Templates in this repository:

```text
development/skills/bootstrap/templates/iac/
├── Makefile.tmpl
├── hooks/pre-push.tmpl
├── scripts/k8s-gate.zsh.tmpl
└── .github/workflows/kubernetes-ci.yml.tmpl   # rewritten
```

`.maintenance.yml.tmpl` (common) gains the `gate:` line under the IaC
condition.

## 5. Testing

- **Fixture harness.** `tests/kubernetes-ci-fixtures.bats` currently
  executes the six-job pipeline's commands against
  `tests/fixtures/kubernetes-repo*` with the pinned tools and asserts
  verdict counts (zero findings on the clean fixture, four attributable
  findings on the broken one). It is repointed at the gate script and
  asserts the same counts, plus the verdict lines of §3.2.
- **New cases** for the gate script: empty repository exits 0 with the
  skip line; absent `policies/kyverno/` skips with its line; a policy
  directory without fixtures warns; a missing tool exits non-zero naming it
  and running no stage; a `helmCharts:` overlay renders non-empty.
- **Template render.** `bootstrap-iac-pipeline.bats` asserts the rewritten
  workflow has one job, that `{{GATE_COMMAND}}` resolves, and that the
  Makefile and hook templates render.
- **Skill flow.** `iac-selection-rule.bats` gains the empty-repo
  confirmation branch: confirmed → IaC path; declined → halt.
- **Branch protection.** The `--iac-only true` test asserts the single
  `gate` context.

## 6. Documentation

The plugin's users must be able to read how the IaC path works and how to
use it without opening the skill source.

- `docs/explanation/iac-gate.md` — the single-command model and why; the
  six stages; why one job; why hooks are files; why Helm inflation is on;
  what an empty repository gets.
- `docs/how-to/bootstrap-a-gitops-repo.md` — preconditions, answering Q4,
  the confirmation, what lands, running `make lint`, adding
  `policies/kyverno/`, what to require in branch protection, re-running
  bootstrap.
- `docs/reference/repo-scripts.md` — `scripts/k8s-gate.zsh`: stages, exit
  codes, verdict lines, skip rules.
- The `.maintenance.yml` reference gains `gate:`.
- `ARCHITECTURE.md`'s `development-kubernetes` section: "six checks" becomes
  the gate model; the branch-protection paragraph names the one context.
- `development/skills/bootstrap/SKILL.md` §3l rewritten to match; Q4's row
  gains the confirmation; Step 4a and 4.5 gain their IaC branches.
- `mkdocs.yml` nav entries for the two new pages.

## 7. Risks

- **Verdict counts move with tool versions.** Already true today and
  already handled by pinning in `tests/iac-tools.zsh`; the gate script
  adds no new exposure, but the workflow's pins must now be read from the
  same place or the "one pin, three readers" property is prose only.
- **`--enable-helm` needs network at render time** to fetch charts. The
  fixture harness must either vendor a chart or keep its Helm fixture to
  `helm template` on a local chart directory.
- **Single context is coarser.** A red `gate` says less at a glance than a
  red `schema`. The verdict lines in the log are the answer; if that proves
  insufficient, a `--only <stage>` flag is a small addition that does not
  change the model.
- **`kubectl kustomize` fallback** lags standalone `kustomize` by a version
  or two. Acceptable for a fallback; the preflight installs the standalone
  binary anyway.

## 8. Follow-ups this slice creates

- **Epic:** bring the language paths onto the gate model — each
  `quality-*.yml` becomes a job that runs the repo's declared gate command.
- **Story:** `gather-kubernetes-findings.zsh` reuses `scripts/k8s-gate.zsh`
  when the target repo carries it, instead of re-running the tools with its
  own invocations.
- **Consumer:** platform-infra #7 rewritten — it assumed bootstrap generates
  a six-job pipeline and that required checks come from it; both now flow
  from the gate.

## 9. Decomposition

Five children, dependency-ordered; each is a story `resolve-issue` can take
on its own:

1. Gate script template plus fixture-harness tests (§3.2, §3.3, §5).
2. Emission templates: rewritten workflow, Makefile, pre-push hook,
   `.maintenance.yml` `gate:` key (§3.1, §3.4, §3.5, §4). Blocked by 1.
3. Skill flow: Q4 empty-repo confirmation, §3l rewrite, Step 4a and 4.5
   IaC branches (§3.6, §3.7 preflight, §3.8). Blocked by 2.
4. `branch-protection.sh` single `gate` context (§3.7). Blocked by 2.
5. Documentation (§6). Blocked by 3 and 4.
