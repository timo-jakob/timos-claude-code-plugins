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

**`config-scan` is the sixth job, and deliberately excluded** — same carve-out
as the two sibling variants. It runs a third-party `trivy-action` rather than a
`run:` block, so step extraction has nothing to execute, and trivy's severity
assignments move between releases. The job is **unasserted**: neither green nor
red is claimed, and a red there is *not* a fixture regression — do not chase it
by editing this variant's chart. Every "green" claim on this page means the five
executable jobs.

That pipeline-level expectation **is** verified end-to-end, by
[`../../kubernetes-ci-fixtures.bats`](../../kubernetes-ci-fixtures.bats)
(#1199), which executes the workflow's own `run:` blocks over a temp copy of
this variant with the pinned toolchain. What is verified *here* is tool-level
(see below).

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
  tree, so it would red outright, and the render job's sentinel would not save
  it (the policy document carries a top-level `kind:`, so the sentinel never
  fires).

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

Run from this directory, with the **pinned toolchain** in front of your PATH:

```bash
REPO_ROOT=/path/to/timos-claude-code-plugins          # <- replace with your checkout
IAC_BIN="$(zsh "$REPO_ROOT/tests/iac-tools.zsh")"
[ -n "$IAC_BIN" ] \
  && export PATH="$IAC_BIN:$PATH" \
  || echo 'FAIL: toolchain not resolved — no verdict below is trustworthy'
zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins      # the authoritative six versions
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

## The argocd job still needs REPO_SLUG set

This variant ships no Argo CD `Application`, so it pins **no particular slug**.
It is not free of the variable, though: the `argocd` job runs on every variant,
and since #1199 its very first statement is a `[ -z "${REPO_SLUG:-}" ]` guard.
The `:-` is what makes **unset and empty behave identically** — both stop there
with `::error::REPO_SLUG is empty …` and exit 1, before any Application is read.
(Before that guard, unset died on `set -u`'s unbound-variable error and empty
passed silently; only the guard collapses the two into one legible failure.)

**Why the empty case needed its own guard.** It was the worse of the two: the
probe URL collapses to a bare host with a trailing slash, the filter's
`endswith("/" + $s)` guard degenerates to `endswith("/")` — which is TRUE — so
the probe *passed*, no typed error was raised, and the job greened having
selected nothing. A vacuous pass the probe itself could not catch, and one
`set -u` never caught and never could, because the variable is *set*, just
empty. That is the blind spot #1199 closed.

A harness must therefore still set `REPO_SLUG` to some non-empty value here —
any value will do, since this variant ships no Argo CD `Application` — but the
consequence of forgetting is now a loud failure that names the variable, whether
you left it empty or never set it at all.

## Sibling variants

| variant | expectation |
| --- | --- |
| [`../kubernetes-repo/`](../kubernetes-repo/) | fully green |
| [`../kubernetes-repo-broken/`](../kubernetes-repo-broken/) | red, every finding attributable to one file |
| `.` (this one) | green, with the untested-policy warning |

No network access, no private content, and no reference to any real deployment.

