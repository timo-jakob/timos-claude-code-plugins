# kubernetes-repo-helmcharts fixture — the Helm-inflating overlay

A minimal repository shape for one property of the bootstrapped IaC gate
(`scripts/k8s-gate.zsh`, #1603): a Kustomization that inflates a Helm chart
through `helmCharts:` **renders non-empty and is validated**.

That property needs its own fixture because the clean variant
([`../kubernetes-repo/`](../kubernetes-repo/)) has no `helmCharts:` entry, and
the failure mode is a **vacuous pass**, not a red: without `--enable-helm`,
older `kustomize` builds ignore the field and render an empty tree, so every
downstream check passes green on exactly the component that most needed
checking. (Current builds refuse the field outright instead — a red, which is at
least visible.) The gate passes the flag unconditionally; this fixture is what
proves that.

## Layout

```text
apps/app/kustomization.yaml     helmCharts: [app], valuesInline note: rendered-by-kustomize-helm
apps/app/charts/app/            the clean variant's chart, vendored (kustomize's default chartHome)
.kube-linter.yaml               the clean variant's (adds no-readiness-probe, silences nothing)
```

The chart is **vendored**, with no `repo:`/`version:` on the entry, so kustomize
finds it present and never runs `helm pull` — the harness stays offline after
the toolchain fetch, which is the same self-containedness rule every fixture
here follows.

## What the gate renders over it

Two files, deliberately:

- `kustomize_apps_app.yaml` — the inflated overlay. Its ConfigMap reads
  `rendered-by-kustomize-helm`, the overlay's `valuesInline` value, which is the
  evidence that inflation used the overlay rather than the chart's defaults.
- `helm_apps_app_charts_app.yaml` — the same vendored chart rendered by the
  render stage's separate top-level `helm template` pass, with the chart's own
  values (`rendered-by-helm`). A chart directory under an overlay's `charts/` is
  still a top-level chart to that pass (its parent is not itself a chart), so it
  is rendered on its own as well. That is the shipped pipeline's behaviour,
  carried over unchanged so verdicts do not move; a repository that vendors
  charts this way sees both renders validated.

**This variant is green (exit 0)**: five stages `ok`, and `policy` skipped —
the variant declares no `policies/kyverno/`, so its verdict lines are

```text
gate: render ok
gate: schema ok
gate: lint ok
gate: policy skipped — no policies declared at policies/kyverno/**/*.{yaml,yml}
gate: config-scan ok
gate: argocd ok
```

At the versions `--print-pins` reports, a red here is a regression in the
render stage's Kustomize handling (or in the chart copy drifting from clean),
never the fixture doing its job; on any other version, re-run pinned before
concluding anything.

## Reproducing

Put the **pinned toolchain** in front of your PATH first — the same block the
sibling READMEs use, run in your **current** shell (the `export` is the point):

```bash
REPO_ROOT=/path/to/timos-claude-code-plugins          # <- replace with your checkout
IAC_BIN="$(zsh "$REPO_ROOT/tests/iac-tools.zsh")"
[ -n "$IAC_BIN" ] \
  && export PATH="$IAC_BIN:$PATH" \
  || echo 'FAIL: toolchain not resolved — no verdict below is trustworthy'
zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins      # the authoritative seven versions
```

Then run the gate over a copy, keeping the rendered tree to inspect it:

```sh
rm -rf /tmp/h /tmp/h-rendered
cp -R "$REPO_ROOT/tests/fixtures/kubernetes-repo-helmcharts" /tmp/h && cd /tmp/h
K8S_GATE_RENDER_DIR=/tmp/h-rendered REPO_SLUG=fixture-org/kubernetes-repo-helmcharts \
  zsh "$REPO_ROOT/development/skills/bootstrap/templates/iac/scripts/k8s-gate.zsh.tmpl"
grep rendered-by /tmp/h-rendered/*.yaml
```
