# The IaC gate

When `/development:bootstrap` sets up a repository that holds Kubernetes manifests, Helm
charts, Kustomize overlays or Argo CD resources, and no application language, it installs
**one gate command** instead of a pipeline of separate checks. This page explains that
model and the decisions behind it. For the steps, see
[Bootstrap a GitOps repository](../how-to/bootstrap-a-gitops-repo.md). For exact stages,
verdict lines and exit codes, see
[Scripts bootstrap emits into a target repository](../reference/repo-scripts.md#scripts-bootstrap-emits-into-a-target-repository).

## One command, everywhere

The repository gets a single gate command, `make lint` by default. It is recorded as
`gate:` in [`.maintenance.yml`](../reference/maintenance-yml.md) and run in three places:

- by a developer at the keyboard;
- by `hooks/pre-push`, before every push;
- by the `gate` job in `.github/workflows/kubernetes-ci.yml`, on every pull request.

Each of the three runs the same command, so all three run the same checks. With the same
tool versions and the same repository slug they reach the same verdict. CI pins its tool
versions and a local install may not, so a local red is worth checking against the pinned
versions first; and in a clone of a fork, set `REPO_SLUG` to the upstream `owner/name`,
or the `argocd` stage checks no Application. A check that
runs only in CI is one a developer cannot run before pushing, and that is the failure this
model rules out.

The work is split between two files, and the split is what keeps the command stable:

- **`scripts/k8s-gate.zsh` is the mechanism**: the stages, their order and their tool
  invocations. Bootstrap owns this file, so a re-run can refresh it when the plugin
  improves.
- **The `Makefile` is the repository's file.** Its `lint` target runs the script, and its
  `hooks` target wires up the pre-push hook. Bootstrap writes a `Makefile` only when
  there is none, and never rewrites yours wholesale.

Either file on its own would fall short. With only the script, CI and developers would
call different names. With only a Makefile, the mechanism would live in a file the
repository owns, and bootstrap could never refresh it. A reusable workflow hosted in the
plugin repository was also rejected, because a developer could not run it locally and a
skew between plugin and repository versions would go unnoticed.

## Six stages over rendered output

The gate runs six stages in a fixed order and stops at the first failure:

| Stage | Checks | Input |
| --- | --- | --- |
| `render` | that every chart and overlay renders | the sources |
| `schema` | that every object matches its Kubernetes schema (`kubeconform`) | rendered |
| `lint` | generic hygiene such as probes, limits and non-root (`kube-linter`) | rendered |
| `policy` | your own rules, when you declare any (`kyverno`) | rendered, plus `policies/kyverno/` |
| `config-scan` | high and critical misconfigurations (`trivy config`) | rendered |
| `argocd` | that every path an Argo CD `Application` points at exists | sources and rendered |

**Every stage after `render` consumes the rendered output**, never the templates or the
Kustomize inputs. A chart's `templates/` directory holds Go templates, not Kubernetes
objects, and a Kustomize base is incomplete on purpose because the overlay fills in the
rest. Validating either as if it were output fails a correct repository, and it can pass a
chart that looks clean but renders an invalid manifest. Rendering first means the gate
checks what would actually be applied to the cluster.

**Helm inflation is on.** The render stage passes `--enable-helm` to Kustomize
unconditionally. Without it, Kustomize ignores the `helmCharts:` field, and the rendered
tree is empty for exactly the components that most need checking: third-party charts
pulled in through an overlay. An empty rendered tree passes every check without testing
anything.

**Policy is yours; the mechanism is the plugin's.** The plugin ships no Kyverno policies.
Generic hygiene belongs to `kube-linter`, and two tools enforcing one rule means two places
to silence a single false positive. You declare your own rules under
`policies/kyverno/`. Until you do, the `policy` stage reports a skip. That is not a failure,
because a repository with no policies has not yet chosen any rules to enforce. Once you
declare policies, violations fail the gate.

## Why one CI job

`.github/workflows/kubernetes-ci.yml` has one job, `gate`. It installs the pinned tools and
runs the gate command, and nothing else. Branch protection requires that one `gate` context.

The alternative, one job per stage, would give six requirable contexts and a more detailed
red at a glance. It would also put CI's definition of the gate in the workflow file, as six
invocations kept in step with the script by hand. A red `gate` gives less detail at a
glance, but the log answers it. Each stage prints one verdict line, such as
`gate: schema FAILED`, with its tool's output directly above it. Those lines read the same
in a terminal and in a workflow log.

The workflow pins every tool version, including `helm` and `kustomize`, which the runner
image already ships. GitHub updates the runner image on its own schedule, and a verdict
must not change for that reason.

## Why hooks are files, not a framework

On this path the pre-push hook is `hooks/pre-push`, a two-line script that runs the gate
command. `make hooks` points git at the version-controlled `hooks/` directory. Bootstrap
does not emit a `pre-commit` configuration here.

A hook committed to the repository reaches every fresh clone with the code it guards.
`pre-commit` installs hooks per machine from a Python tool, and a manifests repository has
no other reason to depend on Python. The hygiene hooks the shared `pre-commit`
configuration provides elsewhere, such as trailing whitespace and end-of-file checks, are
therefore not part of the gate on this path. If you want them, add them to the gate
command rather than beside it, so CI runs them too.

The hook has to be wired once per clone, because git does not follow `core.hooksPath`
from a committed file. That is what `make hooks` does.

## What an empty repository gets

A repository that has no charts, overlays or Argo CD resources yet can still be
bootstrapped as a GitOps repository: bootstrap asks you to confirm that explicitly. It
gets the whole set: the `Makefile`, `scripts/k8s-gate.zsh`, `hooks/pre-push`, the one-job
workflow, and `.maintenance.yml` with `primary: kubernetes` and `gate: make lint`.

Its first `make lint` prints `gate: render skipped — nothing to render`, prints the same
skip for every later stage, and exits `0`. The pipeline is green and required from the
first commit, and it starts checking manifests as soon as the first one lands. Every skip
is reported, so a green gate on an empty repository reads as an empty repository, not as
checks that passed.

Nothing records your confirmation. Until the repository has its first chart, overlay or
Argo CD resource, every bootstrap re-run asks the question again.

## What this path leaves out

A manifests repository has no test suite, so the application gates do not apply to it and
bootstrap does not render them: no coverage floor, no Sonar analysis, no CodeQL. It also
does not install the check that keeps application repositories from writing to a cluster,
because deploying to a cluster is the job of an infrastructure repository. See
[Keep application repos out of the cluster](../how-to/keep-app-repos-out-of-the-cluster.md)
for that check.
