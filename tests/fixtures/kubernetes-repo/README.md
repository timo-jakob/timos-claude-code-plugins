# kubernetes-repo fixture — the clean variant

A self-contained repository shape for exercising `development-kubernetes`: a
Helm chart, a Kustomize base + prod overlay, two Argo CD `Application`s, and a
Kyverno policy with a pass-only test fixture.

**This variant is expected fully green.** Every job of the bootstrapped
`kubernetes-ci` pipeline — `render`, `schema`, `lint`, `policy`, `config-scan`,
`argocd` — is expected to pass over it. Five of those six are backed by the
tool-level checks below; **`config-scan` is the exception** — it runs a
third-party `trivy-action`, which no command here executes, so its green is
expected rather than measured. Deciding how (or whether) to exercise it is
explicitly #1199's call. That whole-pipeline verdict is an
**expectation this fixture is built to be measured against, not an observation**:
executing the workflow is #1199's job. What has actually been run here is the
tool-level verification below.

Once #1199 does run it, a red is a **regression**, never the fixture doing its
job; the deliberate defects all live in
[`../kubernetes-repo-broken/`](../kubernetes-repo-broken/) — with one designed
exception, `argocd/foreign-app.yaml`, described under the fixture contract.

## Clean by construction, never clean by exclusion

`.kube-linter.yaml` **enables** one non-default check (`no-readiness-probe`) and
suppresses nothing. The manifests satisfy kube-linter's default set genuinely:
pinned on-registry image, readiness probe on a declared container port, CPU and
memory requests *and* limits, `runAsNonRoot`, `readOnlyRootFilesystem`, dropped
capabilities, and a pod anti-affinity (so the default `no-anti-affinity` check
genuinely applies at `replicas: 2`/`3` rather than being dodged by scaling to
one).

`charts/app/templates/configmap.yaml` is the one genuinely **templated**
manifest, substituting `note` from `values.yaml`. Without it nothing would
depend on `helm template` having actually run — `templates/deployment.yaml` is
plain YAML by necessity, because the Kyverno test fixture consumes it as a
*resource*. Its rendered output must read `rendered-by-helm`; if it ever reads
the literal template expression, the render job did not render.

## The Kustomize half is deliberately asymmetric

`kustomize/base/deployment.yaml` is genuinely **partial** — no image tag, no
probe, no resources, no security context — and `kustomize/overlays/prod`
completes it. The base is a kustomize *input*, and the pipeline excludes every
path under a recorded kustomize root from its plain-manifest sweep. If that
exclusion ever regressed, the base would reach the validators unrendered and
this **clean** variant would go red — which is exactly the regression the
exclusion exists to prevent, made observable.

## The fixture contract

The `argocd` job verifies `.spec.source.path` only for Applications whose
`repoURL` names the repository under test, comparing against the runner's own
`github.repository`. This variant declares:

```text
argocd/app-of-apps.yaml   repoURL .../fixture-org/kubernetes-repo.git   path charts/app        (resolves)
argocd/foreign-app.yaml   repoURL .../fixture-org/kubernetes-repo-extra.git   path charts/does-not-exist
```

so a harness must present the slug **`fixture-org/kubernetes-repo`** to that job.
Note *how*: the workflow pins `REPO_SLUG: ${{ github.repository }}` at step
level, and a step-level `env:` beats an exported shell variable — so exporting
`REPO_SLUG` around an unmodified workflow run does nothing. The contract is met
by a harness that **executes the job's `run:` block** with `REPO_SLUG` set (what
#1199 will do), or by overriding `github.repository`. Get it wrong and the
filter selects nothing, the job exits 0 having verified no path at all, and the
green is **vacuous**.

`foreign-app.yaml` is the negative control that makes the green non-vacuous in
the other direction: it is deliberately foreign, and its slug has this variant's
slug as a strict prefix, so a filter that regressed to a `contains`-style match
would select it, find its absent path, and red this variant.

## Run against a copy, never the working tree

The `policy` job dereferences `policies/kyverno` **in place** — `rm -rf` followed
by a `mv` of a mirror — so copy the variant to a temp directory before pointing a
**pipeline run** at it. The direct tool commands below are non-destructive and
are meant to run from this directory.

## Verifying it directly

Run from this directory, with the versions the pipeline pins — **kube-linter
0.7.2, kyverno 1.13.4, kubeconform 0.6.7, yq 4.44.3**. Note `kube-linter` is
invoked *without* `--config`, exactly as the pipeline invokes it: it
auto-discovers `./.kube-linter.yaml` from the working directory, and that
discovery is what makes the non-default `no-readiness-probe` check apply at all.

The recipe reproduces the pipeline's **whole** `RENDER_DIR`, not just the two
renders: the render job also sweeps every standalone manifest carrying a
top-level `kind:` that is not a chart template, a kustomize input or a
kustomization file — which here means both Argo CD Applications *and* both files
under `policies/kyverno/`. Validating only the renders would leave those four
files unchecked by the very jobs the fully-green claim is about.

```bash
set -euo pipefail
rm -rf /tmp/rendered && mkdir -p /tmp/rendered          # fresh: never lint leftovers

helm template app charts/app            > /tmp/rendered/helm_charts_app.yaml
kustomize build kustomize/overlays/prod > /tmp/rendered/kustomize_prod.yaml
grep -q 'rendered-by-helm' /tmp/rendered/helm_charts_app.yaml \
  || { echo 'FAIL: helm did not render the templated ConfigMap'; exit 1; }
for m in argocd/*.yaml policies/kyverno/*.yaml; do      # the standalone sweep
  cp "$m" "/tmp/rendered/plain_$(printf '%s' "$m" | tr / _)"
done

kube-linter lint /tmp/rendered/                                      # zero findings
kubeconform -strict -summary -ignore-missing-schemas /tmp/rendered/  # 7 resources: 3 valid, 0 invalid, 4 CRs skipped
kyverno test policies/kyverno/                                       # 1 test passed

kyverno apply policies/kyverno/require-registry.yaml \
  --resource /tmp/rendered/ | tee /tmp/apply.txt                     # pass: 2, fail: 0
grep -qE 'pass: [1-9]' /tmp/apply.txt \
  || { echo 'FAIL: the policy matched NOTHING — a bare exit 0 would hide this'; exit 1; }
grep -q 'fail: 0' /tmp/apply.txt
```

Never lint the tree itself: that would reach `kustomize/base/deployment.yaml`,
which is a deliberately partial kustomize *input* and fires several checks by
design. Validate rendered output, not inputs.

### Checking the argocd filter

The `argocd` job uses neither of the tools above — it extracts paths with
`yq` + `jq` — so the negative control needs its own command. This is the one
that shows `foreign-app.yaml` doing its job:

```bash
set -euo pipefail
JQ_EXPR='select(type == "object")
  | select(.apiVersion == "argoproj.io/v1alpha1")
  | select(.kind == "Application" or .kind == "ApplicationSet")
  | [ .spec.source, .spec.template.spec.source,
      (.spec.sources // [])[], (.spec.template.spec.sources // [])[] ]
  | .[] | select(. != null)
  | select(((.repoURL // "") | sub("/$"; "") | sub("\\.git$"; "") | ascii_downcase) as $u
      | (env.REPO_SLUG | ascii_downcase) as $s
      | ($u | endswith("/" + $s)) or ($u | endswith(":" + $s)))
  | (.path // empty)'
export REPO_SLUG=fixture-org/kubernetes-repo
paths="$(for f in argocd/*.yaml; do yq -o=json '.' "$f" | jq -r "$JQ_EXPR"; done | sort | tr '\n' ' ')"
[ "$paths" = 'charts/app ' ] \
  || { echo "FAIL: expected exactly charts/app, got: [$paths]"; exit 1; }
test -e charts/app   # and it resolves, so the argocd job is green
```

Expected: **exactly `charts/app`**, which exists — so the job is green. If
`charts/does-not-exist` also appears, the repoURL filter has regressed to a
`contains`-style match and would have selected `foreign-app.yaml`; the assertion
above turns that into a loud failure instead of an eyeball comparison.



At those pinned versions a red is a regression. On any other version, re-run
pinned before concluding anything — kube-linter promotes checks into its default
set between releases, so a newer binary can report findings on a genuinely clean
fixture.

## Sibling variants

| variant | expectation |
| --- | --- |
| `.` (this one) | fully green |
| [`../kubernetes-repo-broken/`](../kubernetes-repo-broken/) | red, every finding attributable to one file |
| [`../kubernetes-repo-untested-policy/`](../kubernetes-repo-untested-policy/) | green, with the untested-policy warning |

No network access, no private content, and no reference to any real deployment —
this fixture must stay usable by anyone who clones the repository.

