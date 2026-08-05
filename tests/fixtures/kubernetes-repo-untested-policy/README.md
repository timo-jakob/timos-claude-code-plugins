# kubernetes-repo-untested-policy fixture

A whole-repo shape carrying a Kyverno policy set with **no tests**: it holds
`policies/kyverno/require-registry.yaml` and deliberately **no**
`kyverno-test.yaml`.

That absence is the entire point. A policy nobody tested usually matches nothing
and passes everything silently, so the machinery must notice it:

- **maintenance** reports it as a `policy_tests` finding
  (→ `kubernetes-policy-triage`);
- the **check pipeline** is expected to emit `::warning::policies declared but
  no kyverno test fixtures` from its `policy` job and stay **green** — an
  untested policy set is a finding to file, not a build failure.

Verifying that pipeline-level expectation end-to-end is #1199's job, not this
fixture's; what is verified here is tool-level (see below).

## Why there is a chart

The variant also ships a minimal `charts/app`, carrying the same
clean-by-construction Deployment as [`../kubernetes-repo/`](../kubernetes-repo/).
It carries the same `.kube-linter.yaml` and the same genuinely templated
`configmap.yaml` as its siblings, so all three variants are linted under one
check set and an absent or empty helm render is observable here too. The chart is
not decoration — a bare `policies/kyverno/` directory would make this fixture
unreachable by the very machinery it exists to exercise:

- **The topic marker** fires on `Chart.yaml`, `kustomization.yaml`,
  `kustomization.yml`, `Kustomization`, or an `argoproj.io` reference. A policy
  directory carries none of them, so without the chart neither
  `/development:maintenance` nor bootstrap would ever detect this tree as a
  Kubernetes repo.
- **The policy job evaluates something real.** `kyverno apply` runs over the
  rendered output *before* the no-test-fixtures warning is reached. With no
  workload anywhere, that apply would see only the policy document itself and
  the `lint` job would have no valid object — three jobs would pass vacuously
  and the warning would sit behind a policy set nothing had exercised.

The chart is clean, so this variant's expectation is **green plus the
untested-policy warning**.

## Run against a copy, never the working tree

The `policy` job dereferences `policies/kyverno` **in place** — `rm -rf` followed
by a `mv` of a mirror — so pointing a pipeline run at this directory would
rewrite the fixture, and `policies/kyverno` is the one thing this variant is
about. **Copy the variant to a temp directory and point the tool or the pipeline
at the copy**, as a repository in its own right — exactly as it would meet an
untested policy directory in reality.

## Verifying it directly

Run from this directory, with the versions the pipeline pins — **kube-linter
0.7.2, kyverno 1.13.4**:

```bash
set -euo pipefail
WORK="$(mktemp -d)"; cp -R . "$WORK"; cd "$WORK"       # never rewrite the checked-in tree
rm -rf /tmp/untested-rendered && mkdir -p /tmp/untested-rendered

helm template app charts/app > /tmp/untested-rendered/helm_charts_app.yaml
grep -q 'rendered-by-helm' /tmp/untested-rendered/helm_charts_app.yaml \
  || { echo 'FAIL: helm did not render the templated ConfigMap'; exit 1; }
cp policies/kyverno/require-registry.yaml \
   /tmp/untested-rendered/plain_policies_kyverno_require-registry.yaml   # the standalone sweep

kube-linter lint /tmp/untested-rendered/               # kube-linter 0.7.2 — zero findings
kyverno apply policies/kyverno/require-registry.yaml \
  --resource /tmp/untested-rendered/ | tee /tmp/untested-apply.txt       # pass: 1, fail: 0
grep -qE 'pass: [1-9]' /tmp/untested-apply.txt \
  || { echo 'FAIL: the policy matched NOTHING — the chart is not being evaluated'; exit 1; }

test ! -e policies/kyverno/kyverno-test.yaml \
  || { echo 'FAIL: kyverno-test.yaml present — this variant is defined by its absence'; exit 1; }
```

The `pass: 1` assertion is the one that matters here. This variant ships no
`kyverno-test.yaml`, so it has no fixture asserting the rule fires, and
`kyverno apply` exits 0 **both** when the rule evaluated the Deployment and
passed **and** when it matched nothing at all. Only the counter tells those
apart — and a rule matching nothing is exactly the vacuity the chart was added
to prevent.

## The argocd job still needs REPO_SLUG set

This variant ships no Argo CD `Application`, so it pins **no particular slug**.
It is not free of the variable, though: the `argocd` job runs on every variant
and its compile probe dereferences `$REPO_SLUG` under `set -euo pipefail`
*before* any Application is read. Unset, the step dies on an unbound variable.

**Empty is worse than it looks.** The probe URL collapses to a bare
host with a trailing slash, the filter's `endswith("/" + $s)` guard degenerates to
`endswith("/")` — which is TRUE — so the probe passes, no typed error is raised,
and the job then greens having selected nothing: a vacuous pass the probe does
*not* catch. (Verified against the shipped template.) So a harness must set
`REPO_SLUG` to some non-empty value here; any value will do. Closing that blind
spot in the workflow itself belongs to #1199, not to this fixture.

## Sibling variants

| variant | expectation |
| --- | --- |
| [`../kubernetes-repo/`](../kubernetes-repo/) | fully green |
| [`../kubernetes-repo-broken/`](../kubernetes-repo-broken/) | red, every finding attributable to one file |
| `.` (this one) | green, with the untested-policy warning |

No network access, no private content, and no reference to any real deployment.

