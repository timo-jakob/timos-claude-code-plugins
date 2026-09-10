# kubernetes-repo-untested-policy fixture

A whole-repo shape carrying a Kyverno policy set with **no tests**: it holds
`policies/kyverno/require-registry.yaml` and deliberately **no**
`kyverno-test.yaml`.

That absence is the entire point. A policy nobody tested usually matches nothing
and passes everything silently, so the machinery must notice it:

- **maintenance** reports it as a `policy_tests` finding
  (→ `kubernetes-policy-triage`);
- the **gate** is expected to emit `warning: policies declared but no kyverno
  test fixtures` (`::warning::…` under GitHub Actions) from its `policy` stage
  and stay **green** — an untested policy set is a finding to file, not a
  build failure.

That expectation **is** verified end-to-end, by
[`../../kubernetes-ci-fixtures.bats`](../../kubernetes-ci-fixtures.bats)
(#1199, #1603), which runs the bootstrapped gate script (`scripts/k8s-gate.zsh`)
over a temp copy of this variant with the pinned toolchain and asserts all six
stages green — `config-scan` included, since the gate runs the pinned `trivy`
binary itself (under #1199's workflow-step harness that stage was unasserted).
What is verified *here* is tool-level (see below).

## Why there is a chart

The variant also ships a minimal `charts/app`, carrying the same
clean-by-construction Deployment as [`../kubernetes-repo/`](../kubernetes-repo/).
It carries the same `.kube-linter.yaml` as both siblings — so all three variants
are linted under one check set — and the same genuinely templated
`configmap.yaml` as [`../kubernetes-repo/`](../kubernetes-repo/), so an absent or
empty helm render is observable here too. (The broken variant ships no chart at
all, which is why its rendered set carries no `helm_*` file.) The chart is
not decoration — a bare `policies/kyverno/` directory would make this fixture
unreachable by the very machinery it exists to exercise:

- **The topic marker** fires on `Chart.yaml`, `kustomization.yaml`,
  `kustomization.yml`, `Kustomization`, or an `argoproj.io` reference. A policy
  directory carries none of them, so without the chart neither
  `/development:maintenance` nor bootstrap would ever detect this tree as a
  Kubernetes repo.
- **The policy job evaluates something real.** `kyverno apply` runs over the
  rendered output *before* the no-test-fixtures warning is reached. With no
  workload anywhere, that apply would match nothing and still exit 0, so
  `schema`, `policy` and `argocd` would all pass **vacuously** — and the warning
  would sit behind a policy set nothing had exercised. `lint` would not even do
  that: `kube-linter` errors with "no valid objects found" on an object-free
  tree, so it would red outright — and the gate's nothing-to-render skip would
  not save it either (the policy document carries a top-level `kind:`, so the
  rendered tree is never object-free).

The chart is clean, so this variant's expectation is **green plus the
untested-policy warning**.

## Run against a copy, never the working tree

The gate script leaves the tree it gates untouched, but the six-job workflow's
`policy` job, still shipped until #1604, dereferences `policies/kyverno` **in
place** (`rm -rf` followed by a `mv` of a mirror) — so pointing that pipeline at
this directory would rewrite the fixture, and `policies/kyverno` is the one
thing this variant is about. **Copy the variant to a temp directory and point the tool or the pipeline
at the copy**, as a repository in its own right — exactly as it would meet an
untested policy directory in reality.

## Verifying it directly

Run from this directory, with the **pinned toolchain** in front of your PATH:

```bash
REPO_ROOT=/path/to/timos-claude-code-plugins          # <- replace with your checkout
IAC_BIN="$(zsh "$REPO_ROOT/tests/iac-tools.zsh")"
[ -n "$IAC_BIN" ] \
  && export PATH="$IAC_BIN:$PATH" \
  || echo 'FAIL: toolchain not resolved — no verdict below is trustworthy'
zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins      # the authoritative seven versions
```

(No `exit` in that block on purpose: it is the one snippet here you must run in
your **current** shell, since the `export` is the whole point.)

**The block below is a subshell recipe**, and this one is not: it opens with
`set -euo pipefail`, reports failures with `exit 1`, and `cd`s into a `mktemp -d`
it never leaves. Pasting it into the shell you just exported `PATH` into would
leave errexit set there, close it on the first FAIL, and otherwise strand you in
a temp directory. Run it as a unit — `bash <<'EOF' … EOF`, or wrap in `( … )`.
The exported `PATH` is inherited by the subshell.

The script **prints** its bin directory; it cannot modify your shell's PATH, so
the `export` is what actually pins the run — and the emptiness check is what
stops a failed resolve from silently leaving an empty leading PATH entry (the
cwd) with no pinned tool on it. The versions are deliberately **not restated
here** — `--print-pins` is the one authoritative list.

**At those versions a red is a regression.** On any other version, re-run pinned
before concluding anything. This recipe
exercises kube-linter and kyverno (read from the workflow template) plus helm
(pinned in `iac-tools.zsh`, since the template installs neither helm nor
kustomize) — the `helm template` below produces everything the other two judge:

```bash
set -euo pipefail
WORK="$(mktemp -d)"; cp -R . "$WORK"; cd "$WORK"       # never rewrite the checked-in tree
rm -rf /tmp/untested-rendered && mkdir -p /tmp/untested-rendered

helm template app charts/app > /tmp/untested-rendered/helm_charts_app.yaml
grep -q 'rendered-by-helm' /tmp/untested-rendered/helm_charts_app.yaml \
  || { echo 'FAIL: helm did not render the templated ConfigMap'; exit 1; }
cp policies/kyverno/require-registry.yaml \
   /tmp/untested-rendered/plain_policies_kyverno_require-registry.yaml   # the standalone sweep

kube-linter lint /tmp/untested-rendered/               # zero findings, at the pin
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

## The argocd stage and REPO_SLUG on this variant

This variant ships no Argo CD `Application`, so it pins **no particular slug**
— and under the gate script it needs none: the slug is resolved lazily
(`REPO_SLUG`, then `GITHUB_REPOSITORY`, then the `origin` remote) and consulted
only when an Application was found, so with none declared the argocd stage is
green whether the variable is set, empty or absent. The typed refusal — `gate:
argocd FAILED` naming `REPO_SLUG=owner/name` — fires only when Applications are
present and nothing resolves; it is what stops an unresolved slug from
filtering every Application out and passing vacuously.

The six-job **workflow**, still shipped until #1604, is stricter: its `argocd`
job opens with a `[ -z "${REPO_SLUG:-}" ]` guard that refuses an unset *or*
empty value with `::error::REPO_SLUG is empty …` before any Application is read
(the empty case used to pass silently — the filter's `endswith("/")` degenerated
to true — which is the blind spot #1199 closed). A harness driving that job
must set a non-empty value even here.

## Sibling variants

| variant | expectation |
| --- | --- |
| [`../kubernetes-repo/`](../kubernetes-repo/) | fully green |
| [`../kubernetes-repo-broken/`](../kubernetes-repo-broken/) | red, every finding attributable to one file |
| `.` (this one) | green, with the untested-policy warning |
| [`../kubernetes-repo-helmcharts/`](../kubernetes-repo-helmcharts/) | green (policy skipped); proves `helmCharts:` inflation |

No network access, no private content, and no reference to any real deployment.

