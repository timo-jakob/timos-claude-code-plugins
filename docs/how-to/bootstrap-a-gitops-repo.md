# Bootstrap a GitOps repository

This guide sets up a repository of Kubernetes manifests, Helm charts, Kustomize overlays
or Argo CD resources, with no application code, so that one gate command validates it
locally and in CI. For why the gate works this way, see [The IaC gate](../explanation/iac-gate.md).

## Before you start

- The `development` plugin is installed. See [Install and use the plugins](install-and-use-plugins.md).
- The repository holds **no application language**. A repository with charts **and**
  application code is bootstrapped as a language repository, and this path does not
  apply to it.
- The repository may be **empty**. You can bootstrap it before the first chart, overlay
  or Argo CD `Application` exists.
- You are on macOS with Homebrew. Bootstrap's preflight uses `brew install` to install
  the gate's tools: `helm`, `kustomize`, `kubeconform`, `kube-linter`, `kyverno`, `trivy`
  and `yq`.

## Run bootstrap and answer the language question

From the repository root, run:

```text
/development:bootstrap
```

Bootstrap finds no application language, so it asks which languages the project will use.
What happens next depends on whether the repository already holds manifests.

**The repository already has a chart, a kustomization or an Argo CD resource.** Bootstrap
recognises it as infrastructure-as-code and offers **"none — this is a GitOps/IaC repo"**.
Choose it.

**The repository is empty.** Answer **"none"**. Bootstrap then asks you to confirm:

> There is no chart, kustomization or Argo CD resource here yet. Bootstrap this as an
> empty GitOps/IaC repository anyway — one required `gate` check, the `make lint`
> pre-push hook, and `primary: kubernetes`?

- **Confirm** to continue on the GitOps path.
- **Decline**, and bootstrap stops. Add a manifest, or name a language, and run it again.

If `.maintenance.yml` already records a different `primary:`, bootstrap does not
overwrite it. It reports the conflict and asks whether to change the record. See
[`.maintenance.yml`](../reference/maintenance-yml.md#primary).

Bootstrap then shows its plan. Confirm it to write the files.

## What lands

| File | What it is |
| --- | --- |
| `Makefile` | `make lint` runs the gate; `make hooks` wires the pre-push hook |
| `scripts/k8s-gate.zsh` | the gate's six stages: render → schema → lint → policy → config-scan → argocd |
| `hooks/pre-push` | runs the gate command before every push, once wired |
| `.github/workflows/kubernetes-ci.yml` | one job, `gate`, which runs the gate command on every pull request |
| `.maintenance.yml` | `primary: kubernetes` and `gate: make lint` |

Bootstrap also writes the files every repository gets, such as the contributor guide and
the end-user docs set. It does not write any of the application gates: coverage, Sonar,
CodeQL or a `pre-commit` configuration. Its final report lists everything it left out, and
why.

## Run the gate

```sh
make lint
```

Each stage prints one verdict line. On an empty repository every stage skips, and the gate
exits `0`:

```text
gate: render skipped — nothing to render
gate: schema skipped — nothing to render
gate: lint skipped — nothing to render
gate: policy skipped — nothing to render
gate: config-scan skipped — nothing to render
gate: argocd skipped — nothing to render
```

Once manifests exist, a passing stage prints `gate: <stage> ok`. A failing stage prints
`gate: <stage> FAILED` with its tool's output directly above the line. Fix that output and
run the gate again.
[Scripts bootstrap emits into a target repository](../reference/repo-scripts.md#scripts-bootstrap-emits-into-a-target-repository)
lists every verdict line, skip rule, exit code and environment variable.

## Wire the pre-push hook

```sh
make hooks
```

This sets git's `core.hooksPath` to the repository's `hooks/` directory, so
`hooks/pre-push` runs the gate command before every push and rejects the push when the
gate fails. Bootstrap runs `make hooks` for you when the gate already passes. Otherwise
its final report tells you to run it.

git does not carry that setting in a clone, so **everyone who clones the repository runs
`make hooks` once**.

## Add your own policies

The gate ships no policies. The `policy` stage reports `skipped` until you declare some.

1. Create `policies/kyverno/` and add your Kyverno policies there as `.yaml` or `.yml`
   files, each a `ClusterPolicy` or `Policy` document. Subdirectories are fine. The pinned
   Kyverno CLI cannot evaluate the policy kinds newer Kyverno releases introduced, such as
   `ValidatingPolicy`, and a directory holding only those fails the stage.
2. Add a `kyverno-test.yaml` fixture in the same directory. It lists the policies, the
   resources to test them against, and the result you expect for each. The gate treats
   fixture resources as manifests, so every stage checks them: each must be a complete
   resource that passes schema, lint, policy and config-scan. A resource written to
   violate a policy, or a minimal one without probes or resource limits, fails the gate. The format is
   Kyverno's own; see the
   [Kyverno CLI `test` documentation](https://kyverno.io/docs/kyverno-cli/usage/test/).
3. Run `make lint`. The `policy` stage applies your policies to the rendered manifests,
   then runs `kyverno test` on the fixtures.

A policy directory with no `kyverno-test.yaml` still passes the gate, but the gate prints
a warning, because an untested policy usually matches nothing. Once policies exist, a
violation fails the gate.

## Require the gate in branch protection

Require the single `gate` context. Bootstrap applies this for you: it protects the
default branch and requires `gate` and nothing else, because the workflow reports only
that one check.

If the final report says **no rule was applied**, it quotes the reason. The usual causes
are that the workflow is missing or its job has been renamed, or that your token was not
allowed to change branch protection. In that case bootstrap wrote nothing: not the
protection rule, and not the repository's merge settings. Fix the cause, then apply
everything the final report lists as outstanding, not only the `gate` check.

## Re-run bootstrap

Running `/development:bootstrap` again on a repository that is still manifests only is
safe:

- `scripts/k8s-gate.zsh` and `hooks/pre-push` belong to the plugin. Bootstrap shows you a
  diff and asks whether to overwrite them. Accept to take the plugin's current version.
- An existing `Makefile` is never rewritten wholesale. If it lacks the `lint` or `hooks`
  target, bootstrap proposes adding them.
- A recorded `gate:` value is kept and rendered into the workflow and the hook. To change
  the gate command, edit `gate:` in `.maintenance.yml` and re-run bootstrap.
- Until the repository holds its first chart, overlay or Argo CD resource, every re-run
  asks the language question and the empty-repo confirmation again.
- Once the repository also holds application code, it is no longer manifests only:
  a re-run treats it as a language repository, and branch protection stops requiring
  `gate`. Mixed repositories are not supported yet
  ([#1193](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1193)).

## Related

- [The IaC gate](../explanation/iac-gate.md) explains why one command, why one job and
  why rendered output.
- [Keep application repos out of the cluster](keep-app-repos-out-of-the-cluster.md)
  covers the check that GitOps repositories deliberately do not get.
