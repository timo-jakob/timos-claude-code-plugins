# Keep application repos out of the cluster

The family's promotion contract says the infrastructure repository is the only
path to a cluster: an application repository publishes versioned, immutable
images and never writes to a cluster itself, and a version change reaches the
cluster as a pull request against the infrastructure repository. The position
and its rationale live in
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)
under *Deployment — GitOps promotion and immutable references*.

This page is about the gate that **enforces** the application-repo half of it:
the `no-cluster-deploy` check that `/development:bootstrap` installs into every
non-IaC repo.

## What you get

Bootstrap installs a pair, and they are never installed one without the other:

| File | Role |
| --- | --- |
| `scripts/check-no-cluster-deploy.zsh` | the checker — a static scan of `.github/workflows/**` |
| `.github/workflows/no-cluster-deploy.yml` | the `no-cluster-deploy` job that runs it on every pull request targeting the default branch (plus `workflow_dispatch`) |

`branch-protection.sh` adds `no-cluster-deploy` to the required contexts on both
application paths (public and private) — **when BOTH halves are on disk**
(`.github/workflows/no-cluster-deploy.yml` *and*
`scripts/check-no-cluster-deploy.zsh`; a present workflow with a missing checker
would report `no such file or directory` rather than a verdict). If either is
absent the script warns and omits the context, exactly as it does for
`image`/`ko-image.yml`,
so a repo bootstrapped before this gate existed can never be wedged at
`expected` by a required check no workflow reports. The corollary matters when
adopting: until the pair is rendered, the context is **not** required.

The workflow deliberately carries **no `paths:` filter**: a required status check resolves by name, and GitHub leaves a
required check in the `expected` state forever when a path filter skipped the
workflow that defines it — so a path-conditional required check wedges every
pull request that misses those paths. Running unconditionally is affordable
because the job is a static scan needing only `zsh`, `jq` and a pinned `yq`.

## What fails, and what does not

The v1 command set is closed. The checker inspects each step's `run:` body,
segment by segment, so a pipeline is judged by every command in it.

**Read a pass precisely.** It means *no cluster-writing command appears
literally in a workflow's own `run:` text* — not that the repository never
writes to a cluster. See [Known gaps](#known-gaps-v1) before treating a green
check as evidence in an audit.

| Fails | Passes |
| --- | --- |
| `kubectl apply`, `create`, `replace`, `patch`, `delete` | `kubectl get`, `describe`, `diff`, `logs`, `wait` |
| `kubectl rollout restart`, `kubectl set image`, `kubectl scale` | — |
| `helm install`, `helm upgrade` (with **or** without `--install`), `helm rollback`, `helm uninstall` (and its `delete` / `del` / `un` aliases) | `helm template`, `helm lint`, `helm diff` |
| `argocd app sync`, `create`, `set` | `argocd app diff` |
| `flux reconcile`, `flux bootstrap` | `kustomize build` on its own, `kubeconform`, `conftest` |

`kustomize build | kubectl apply -f -` fails — the `kubectl apply` half matches,
which is why the pipeline needs no rule of its own.

A hit exits **1** and names, on stderr, the workflow file, the job id, the step
name (or its index when the step is unnamed) and the matched command:

```text
::error:: .github/workflows/deploy.yml: job 'deploy', step 'Ship it' runs `helm upgrade` — an application repo never deploys straight to a cluster
```

## The exemptions

There are three: two scoped, and one repo-wide.

**An ephemeral cluster the job stands up itself** — job-scoped. A job that runs
`kind create cluster`, `k3d cluster create`, `minikube start` or `ctlptl apply`
exempts the cluster-writing steps *at or after* it in that same job — including
the rest of the creating step's own body, so the single-step
`run: |` with `kind create cluster` followed by `kubectl apply` is exempt too.
An integration test that spins up kind and applies manifests to it is not a
deploy.

The exemption is **job-scoped, not file-scoped**. The identical step in a
sibling job of the same workflow still fails, because a sibling job writes to
whatever cluster its own credentials point at — and it runs *forward* from the
creating step, because a job that deploys and only afterwards stands up a kind
cluster deployed to someone else's.

A cluster-creating step carrying an `if:` guard does **not** confer the
exemption: the branch-per-environment shape (`if: pull_request` stands up kind,
`if: ref == main` deploys) is exactly what the gate exists to catch, since the
two are mutually exclusive and the deploy then reaches the real cluster. That
direction fails closed.

**A command carrying a real dry-run flag** — **command-scoped**, and the scope
is the point. Bare `--dry-run`, `--dry-run=client`, `--dry-run=server`,
`--dry-run=true`, or the separate-argument `--dry-run client|server`. Note that
**`--dry-run=none` and `--dry-run=false` do NOT exempt**: `none` is kubectl's
default and both mean "really do it", so treating the flag *name* as the
exemption would be a bypass a reviewer skims straight past.

A step that dry-runs and then really applies:

```yaml
- name: ship
  run: |
    kubectl apply --dry-run=client -f k8s/
    kubectl apply -f k8s/
```

still fails, on the second command. A step-scoped test would clear both — which
would make `--dry-run` a one-line switch for silencing the check on any step,
i.e. the standing escape hatch the section below says does not exist.

**A repository recording `primary: kubernetes`** — repo-wide; see
[Infrastructure repositories](#infrastructure-repositories).

Note what is deliberately *not* an exemption: the presence or absence of
credentials. A cloud OIDC login writes a kubeconfig in a **separate** step, so
the deploy step itself carries no secret literal — a credential heuristic would
miss precisely the case the gate exists to catch.

## Infrastructure repositories

The checker exits 0 when `.maintenance.yml` records `primary: kubernetes`, and
says so rather than reporting a clean scan:

```text
no-cluster-deploy EXEMPT: .maintenance.yml records primary: kubernetes
```

An infrastructure repository is the one place a cluster write belongs; its own
gate is `kubernetes-ci.yml`'s six checks (`render`, `schema`, `lint`, `policy`,
`config-scan`, `argocd`), which `branch-protection.sh --iac-only true` requires
instead. Bootstrap does not
render the pair on that path, `detect-stack.sh` holds both halves out of
`missing_artifacts` there, and `--iac-only true` never adds the context.

A repository that carries Kubernetes manifests **and** records a language
primary is an application repository and is checked — a repo that builds an
application is an application repo, whatever else it also carries.

## There is no escape hatch

There is no `# no-cluster-deploy: allow` annotation and no allowlist file, by
decision rather than by omission. The whole value of the rule is auditability,
and an annotation that switches the rule off inside the file that breaks it
destroys exactly the audit trail the rule protects. A warn-only gate fails the
same way more quietly: the warning scrolls past in a green check and the deploy
step stays.

A repository with a genuine exception **changes the check**, in a reviewed pull
request that a human reads. Outgrowing a decision earns a deliberate
re-decision, which is not the same as a standing escape hatch.

## Adopting it on an already-bootstrapped repo

The pair is delivered by gap-fill, not by drift detection —
`detect-template-drift.zsh` only reports drift on files that already exist, so
it can never deliver a *new* artifact. Re-run `/development:bootstrap` on the
repo: `detect-stack.sh` reports both paths in `missing_artifacts`, and Step 3.6
stamps a provenance marker on **both halves** so they are drift-tracked from
then on.

That matters most for the checker: it holds the command set, so it is the half
that actually goes stale, and a consumer running one that has fallen behind the
template is reported by `/development:maintenance` rather than staying green
forever.

**Rendering the pair does not by itself make the check required.** The context
is added only when `branch-protection.sh` runs *and* finds the workflow on disk,
and bootstrap's branch-protection step is an opt-in prompt. So after the pair is
committed, re-run that step (or accept the prompt) and confirm
`no-cluster-deploy` is listed in the required contexts — until then the workflow
runs but gates nothing, which is precisely the green-check-that-gates-nothing
shape this page warns about.

One thing gap-fill will **not** bring you: the matching `SETUP.md` section.
`SETUP.md` is a scaffold file and is deliberately never overwritten once you
have customized it, so copy that section across by hand — or read the checker's
own header, which carries the same rules in full.

## Known gaps (v1)

A pass means "no cluster-writing command appears literally in a workflow's own
`run:` text". Do not read it as proof the repository never writes to a cluster:

- **Only `run:` script bodies are inspected.** A deploy expressed as a
  marketplace action (`uses: azure/k8s-deploy@v4` and friends) or as a reusable
  workflow is not detected. A follow-up issue covers it.
- **Indirection is not followed.** `run: ./scripts/deploy.sh`, `run: make
  deploy`, `run: task deploy`, or a composite action under `.github/actions/**`
  reaches a cluster with nothing here to see. This is the commonest way a real
  deploy is invisible to v1.
- The ephemeral exemption reads `run:` bodies for the same reason, so a cluster
  stood up by `helm/kind-action` does not exempt its job. That direction fails
  **closed** — a false alarm a human sees — which is the safe side of the same
  gap.
- Some cluster-mutating verbs are outside the closed v1 set by decision, not
  because they are harmless: `kubectl run`, `edit`, `annotate`, `label`,
  `expose`, `cordon`, `uncordon`, `drain`, `taint`, `exec`, and `helm plugin
  install`. Widening the set is a deliberate re-decision in a reviewed PR.
- **A command reached only through a shell variable or an alias** defined
  earlier in the same body (`KUBECTL=kubectl; $KUBECTL apply -f k8s/`) is not
  resolved — tool detection compares literal basenames.
- A **nested** command substitution (`$( … $( … ) … )`) is lifted at the first
  `)`, so the outer remainder is read as text rather than as a command.
- A **heredoc body**, and a quoted string spanning several physical lines, are
  scanned line by line as commands. A step that writes documentation or a
  deploy script naming a banned command inside one **is reported**. That fails
  *closed* — a false alarm you can see — and is stated here rather than left to
  be discovered.
- A tool invoked **inside a container** (`docker run … bitnami/kubectl apply`)
  is not resolved: `docker` is the command, and the image argument is not
  walked. Named separately from indirection because the banned command *is*
  written literally on the line.
- The command inside `sh -c "…"` is re-scanned but not re-split, so only its
  first command is resolved (`sh -c "cd x && kubectl apply -f ."`).
- A workflow file that cannot be parsed **fails** the check, naming the file.
  Parsing is per file, so one malformed workflow never leaves the rest of the
  repository unscanned.
