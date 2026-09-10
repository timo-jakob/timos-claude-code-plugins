#!/usr/bin/env bats
#
# The REAL-TOOL half of the bootstrap IaC gate's coverage (epic #1602, child
# #1603; before that epic #1150, child #1199) — the bootstrapped gate script
# (development/skills/bootstrap/templates/iac/scripts/k8s-gate.zsh.tmpl)
# executed with helm, kustomize, kubeconform, kube-linter, kyverno, trivy and
# yq over the fixture repositories under tests/fixtures/kubernetes-repo*.
#
# WHY IT EXISTS. tests/bootstrap-iac-pipeline.bats covers the kubernetes-ci
# workflow template with RECORDING STUBS: it proves each step reaches the right
# tool with the right arguments, which is what you need to see a vacuous pass
# coming. It cannot prove the tools then AGREE — that the clean fixture really
# lints clean, that the broken one really reds with the four check ids its
# README table names. This file proves that half, and since #1603 it proves it
# against the ONE artifact a consumer will actually run: the gate script that
# `make lint`, the pre-push hook and the one-job CI workflow all invoke verbatim
# once #1604 wires them — today it is run directly. (#1199 first proved it by
# extracting the six-job workflow's `run:` blocks; the gate script lifted those
# blocks, and the verdict counts below are the same ones — that they still hold
# is #1603's central acceptance criterion.)
#
# WHY THE TOOLCHAIN IS PINNED, AND NOT TAKEN FROM $PATH. Every assertion here is
# a tool VERDICT — "zero findings", "exactly four findings", "fail: 1" — and
# those move between tool releases: kube-linter's default check set changes
# between them (checks are added, renamed and retired), so a newer binary does
# not reproduce the fixtures' counts — measured, not assumed: one minor ahead of
# the pin reports three findings on the broken fixture where the pin reports
# four. Each fixture README carries the same rule: at the pinned versions a red
# is a regression, on any other version re-run pinned before concluding anything.
# tests/iac-tools.zsh resolves the pinned versions into a cache directory OUTSIDE
# the repository, and this file puts that directory first on PATH. Four of the
# seven (kubeconform, kube-linter, kyverno, yq) are read FROM the workflow
# template, so a bump there moves the harness with it; helm, kustomize and trivy
# are pinned in that script, because the template installs none of them
# directly. The host's own brew-installed kube-linter is therefore never what
# these assertions measure — which is the only way "green" here can mean
# anything.
#
# WHY EVERY RUN COPIES THE FIXTURE FIRST. The gate is a script a developer runs
# on a WORKING TREE, and one test below pins the promise that it leaves that
# tree exactly as it found it. Running it against the checked-in fixtures would
# make a regression of that promise rewrite the fixtures themselves — so every
# test runs against a copy in $BATS_TEST_TMPDIR, and the copy discipline is
# enforced by run_gate rather than trusted.
#
# WHAT CHANGED FROM #1199'S HARNESS. `config-scan` is now ASSERTED: it was
# exempt while it ran as a third-party `trivy-action` step this harness could
# not execute; the gate runs the `trivy` binary itself, pinned like every other
# tool, with the check set embedded in that binary, so its verdict is as
# reproducible as kube-linter's. The gate also stops at the first failing stage,
# so the broken variant's per-stage reds are reached by removing the files that
# red the EARLIER stages — each such removal is stated in the test that makes it.

bats_require_minimum_version 1.5.0

load assertions

# Resolve the pinned toolchain ONCE per file rather than per test: it is a
# no-op when the cache is warm, but a cold first run downloads ~200 MB and the
# suite may run its tests in parallel (run-gate.zsh passes --jobs), so seven
# concurrent downloads into one cache directory is a race nobody needs.
setup_file() {
  local repo_root bin_dir shim
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Called UNGUARDED and allowed to fail the file, the tests/Dockerfile +
  # script-tests.yml precedent for yq and yamllint: silently skipping would drop
  # the only end-to-end coverage this gate has, and a skipped check that reads
  # as green is the failure mode this whole epic is about.
  #
  # `zsh <script>`, not the exec bit: the CI step and every other call site
  # invoke it that way, and a lost mode bit would otherwise abort this whole
  # file with a bare permission error naming nothing about the toolchain.
  bin_dir="$(zsh "$repo_root/tests/iac-tools.zsh")"

  # A kubeconform SHIM, ahead of the real binary on PATH.
  #
  # The gate's schema stage is `kubeconform -strict -summary
  # -ignore-missing-schemas` with no `-cache`, so kubeconform downloads the
  # Kubernetes JSON schemas from raw.githubusercontent.com on EVERY invocation.
  # script-tests.yml's path filter is a `**` catch-all, so a transient failure
  # from that host reds this suite on a PR touching nothing IaC-related. The
  # toolchain cache does not help: it removes the binary downloads only.
  #
  # `-cache` is PREPENDED, not appended: Go's flag package stops parsing at the
  # first positional argument, and the stage's own arguments end with the render
  # directory. The shim is a test-harness concern only — the stage still runs
  # verbatim from the script, and adding `-cache` to the shipped script (which
  # would benefit consumer repos too) is deliberately left out of scope.
  shim="$BATS_FILE_TMPDIR/shim"
  mkdir -p "$shim" "${bin_dir}/../kubeconform-cache"
  # A QUOTED heredoc, with the paths passed through the environment instead of
  # interpolated into the script text. IAC_TOOLS_CACHE is taken verbatim from the
  # caller, so a cache root containing `$`, a backtick or a quote would otherwise
  # produce a shim that execs a different path or does not parse — and the
  # failure mode is the silent one: falling through to the real kubeconform with
  # no -cache, hitting the network on every invocation, which is exactly what
  # this shim exists to stop.
  cat > "$shim/kubeconform" <<'EOF'
#!/bin/sh
exec "$IAC_KUBECONFORM_BIN" -cache "$IAC_KUBECONFORM_CACHE" "$@"
EOF
  chmod +x "$shim/kubeconform"
  printf '%s\n' "$bin_dir/kubeconform" > "$BATS_FILE_TMPDIR/kubeconform-bin"
  printf '%s\n' "$bin_dir/../kubeconform-cache" > "$BATS_FILE_TMPDIR/kubeconform-cache-dir"

  # WARM the schema cache serially, here, before any test runs. run-gate.zsh
  # drives the suite with `bats --jobs` and no --no-parallelize-within-file, so
  # the tests that reach the schema stage run concurrently; on a cold cache they
  # would all fetch and write the same schema files into the same directory, and
  # kubeconform's cache writes are not atomic — a concurrent reader can see a
  # partial file and report it as an invalid schema, a red naming nothing about
  # the fixtures.
  printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: warm' \
    'spec:' '  selector:' '    matchLabels: {app: warm}' '  template:' \
    '    metadata:' '      labels: {app: warm}' '    spec:' '      containers:' \
    '      - name: c' '        image: registry.example.com/app:1.0.0' \
    '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: warm' \
    '---' 'apiVersion: argoproj.io/v1alpha1' 'kind: Application' 'metadata:' '  name: warm' \
    > "$BATS_FILE_TMPDIR/warm.yaml"
  # best-effort: a cold cache with no network simply leaves the tests to fail on
  # their own terms, which is the documented cold-cache behaviour
  PATH="$shim:$bin_dir:$PATH" \
    IAC_KUBECONFORM_BIN="$bin_dir/kubeconform" \
    IAC_KUBECONFORM_CACHE="$bin_dir/../kubeconform-cache" \
    kubeconform -strict -summary -ignore-missing-schemas \
    "$BATS_FILE_TMPDIR/warm.yaml" >/dev/null 2>&1 || true

  printf '%s\n' "$bin_dir" > "$BATS_FILE_TMPDIR/bin-dir"
  printf '%s\n' "$shim" > "$BATS_FILE_TMPDIR/shim-dir"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/development/skills/bootstrap/templates/iac/scripts/k8s-gate.zsh.tmpl"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  [ -f "$GATE" ]
  # read from the file setup_file wrote rather than an exported variable: bats
  # runs setup_file in its own shell, and a value only *usually* propagating is
  # not a foundation for a suite whose whole point is that PATH is pinned
  IAC_BIN="$(cat "$BATS_FILE_TMPDIR/bin-dir")"
  [ -n "$IAC_BIN" ]
  [ -d "$IAC_BIN" ]
  # the schema-cache shim (see setup_file); ahead of $IAC_BIN only for the
  # EXECUTED gate, so the toolchain test below still resolves the real binaries
  IAC_SHIM="$(cat "$BATS_FILE_TMPDIR/shim-dir")"
  [ -d "$IAC_SHIM" ]
  # the shim reads both paths from the environment rather than having them baked
  # into its text (see setup_file), so run_gate must export them
  IAC_KUBECONFORM_BIN="$(cat "$BATS_FILE_TMPDIR/kubeconform-bin")"
  IAC_KUBECONFORM_CACHE="$(cat "$BATS_FILE_TMPDIR/kubeconform-cache-dir")"
  [ -x "$IAC_KUBECONFORM_BIN" ]
  [ -n "$IAC_KUBECONFORM_CACHE" ]
  # a recorder for the stubs some tests put on PATH (the kubectl fallback, the
  # trivy argv check)
  CALLS="$BATS_TEST_TMPDIR/calls.txt"
  : > "$CALLS"
}

# ---------------------------------------------------------------------------
# Driving the gate
# ---------------------------------------------------------------------------

# Run the gate in $W with the pinned toolchain first on PATH, $SLUG as
# REPO_SLUG, and the render directory kept at $RENDERED so its contents can be
# asserted after the run.
#
# `env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY`: this suite runs ON GitHub
# Actions, where both are exported. The first switches the gate's warnings to
# `::warning::` workflow commands and the second is a slug fallback — either
# would make a test pass or fail for a reason that depends on where the suite
# happens to be running. The tests that exercise them set each deliberately.
#
# Extra environment for the gate goes in $GATE_ENV, one `NAME=value` per line;
# names to UNSET (applied after the sets, so K8S_GATE_RENDER_DIR and REPO_SLUG
# can be withheld) in $GATE_ENV_UNSET, one per line; an extra PATH prefix in
# $GATE_PATH_PREFIX (stubs go ahead of the toolchain).
run_gate() {
  local kv
  local -a env_pairs=() env_unset=()
  # The copy discipline, ENFORCED rather than trusted. `cd ""` SUCCEEDS in bash
  # (it is a no-op), so `cd "$W" || exit 1` alone does not catch a run_gate
  # reached without prepare — the subshell would simply stay in bats' cwd, the
  # repository root, and gate THAT. $W is set only by prepare, and bats test
  # bodies run under `set -e` but NOT `set -u`, so an unset $W is silent.
  # One assertion per line.
  [ -n "${W:-}" ] || return 1
  [ -d "$W" ] || return 1
  [ -n "${SLUG:-}" ] || return 1
  [ -n "${RENDERED:-}" ] || return 1
  # and it must be a COPY, never the committed tree — the whole premise of the file
  case "$W" in "$BATS_TEST_TMPDIR"/*) : ;; *) return 1 ;; esac
  # An ARRAY, one pair per line, not a space-joined string that `env` word-splits
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    env_pairs+=("$kv")
  done <<< "${GATE_ENV:-}"
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    env_unset+=(-u "$kv")
  done <<< "${GATE_ENV_UNSET:-}"
  (
    cd "$W" || exit 1
    # `${a[@]+"${a[@]}"}` — an empty array expanded plainly is an unbound-variable
    # error on bash 3.2 under `set -u`; bats does not set it, but the harness is
    # not the only context this could ever run in
    env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY \
      PATH="${GATE_PATH_PREFIX:+$GATE_PATH_PREFIX:}$IAC_SHIM:$IAC_BIN:$PATH" \
      REPO_SLUG="$SLUG" K8S_GATE_RENDER_DIR="$RENDERED" \
      IAC_KUBECONFORM_BIN="$IAC_KUBECONFORM_BIN" \
      IAC_KUBECONFORM_CACHE="$IAC_KUBECONFORM_CACHE" \
      ${env_pairs[@]+"${env_pairs[@]}"} env ${env_unset[@]+"${env_unset[@]}"} zsh "$GATE"
  )
}

# Copy one fixture variant to a temp directory, leaving $W pointing at the copy,
# $SLUG at the variant's declared slug and $RENDERED at a fresh render path.
#
# The slug is `fixture-org/<variant-dir>` — the contract each fixture README
# states and each variant's Application documents encode.
prepare() {
  W="$BATS_TEST_TMPDIR/$1"
  # clear first: a second `prepare X` in one test would otherwise `cp -R` INTO
  # the existing copy, landing the variant at $W/X and rendering nothing
  rm -rf "$W"
  cp -R "$FIXTURES/$1" "$W"
  SLUG="fixture-org/$1"
  # OUTSIDE the copy (the gate refuses a render dir inside the tree it gates)
  # and absent, since the gate refuses a non-empty one
  RENDERED="$BATS_TEST_TMPDIR/rendered-$1"
  rm -rf "$RENDERED"
}

# The rendered tree's file names, sorted — the render stage's observable output.
rendered_files() {
  # the directory check is what makes this helper able to FAIL. A bare pipeline
  # returns `tr`'s status, and bats does not run test bodies under pipefail, so
  # every `[ "$status" -eq 0 ]` after it would be unfalsifiable — dead weight
  # that reads as coverage.
  [ -d "$RENDERED" ] || return 1
  # shellcheck disable=SC2012  # names are what is asserted, not metadata
  ls -1 "$RENDERED" | LC_ALL=C sort | tr '\n' ' '
}

# The `gate:` verdict lines of a run, in order, one per line — and nothing else.
# Line-anchored: the script's own precondition messages carry a `k8s-gate: `
# prefix, which a substring needle would mistake for a verdict.
verdict_lines() {
  printf '%s\n' "$1" | grep '^gate: ' || true
}

# The gate's diagnostic lines — `error:` / `warning:` in either spelling.
# Line-anchored for the same reason: kyverno's counter line reads `error: 0`.
diagnostic_lines() {
  printf '%s\n' "$1" | grep -E '^(::)?(error|warning)(::|: )' || true
}

# The six ok lines the fully green variants must print, in stage order.
expected_all_ok() {
  printf '%s\n' 'gate: render ok' 'gate: schema ok' 'gate: lint ok' \
    'gate: policy ok' 'gate: config-scan ok' 'gate: argocd ok'
}

# Every regular file under a directory, with a checksum, paths relative to the
# directory. `cksum` reading STDIN prints only the checksum and size, so the
# manifest carries the relative path exactly once — and cksum is POSIX, unlike
# `shasum`, which the debian-slim test image does not ship. `-type f` only: a
# symlink is listed by what it points at, which one test below relies on.
tree_manifest() {
  local f
  find "$1" -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "${f#"$1"/}" "$(cksum < "$f")"
  done
}

# The four committed fixture variants this file drives, one per line.
variants() {
  printf '%s\n' kubernetes-repo kubernetes-repo-broken \
    kubernetes-repo-untested-policy kubernetes-repo-helmcharts
}

# ---------------------------------------------------------------------------
# The toolchain itself, and the template's shape
# ---------------------------------------------------------------------------

@test "the harness runs the versions the pipeline installs, not the host's (#1199, #1603)" {
  # The install steps are the one part of the consumer's CI this harness does
  # NOT execute — they curl into /usr/local/bin, which is not a thing to do to a
  # developer's machine. Asserting the resolved binaries report the versions
  # those steps pin is the honest equivalent: it is what makes every verdict
  # below reproducible, and it fails loudly if iac-tools.zsh and the template
  # ever drift apart.
  local tool
  for tool in helm kustomize kubeconform kube-linter kyverno trivy yq; do
    # `bash -c 'command -v'`, not `env command -v`: `command` is a shell builtin
    # and only some systems (macOS) also ship it as /usr/bin/command — on the
    # debian-slim test image `env command` is a 127, which would red this test
    # for a reason that has nothing to do with the toolchain
    run env PATH="$IAC_BIN:$PATH" bash -c "command -v $tool"
    [ "$status" -eq 0 ]
    # from the CACHE, not the host: a brew-installed kube-linter one minor
    # ahead reports findings on a genuinely clean fixture
    starts_with "$output" "$IAC_BIN/"
  done

  # ALL SEVEN, against iac-tools.zsh's own `--print-pins`. Not four: helm,
  # kustomize and trivy are the pins that exist NOWHERE but that script (the
  # template installs none of them directly, so there is no upstream pin to
  # read), which makes them the ones most prone to silent drift — and a helm
  # bump that changes default rendering moves `Valid: 3` and the rendered sets
  # below with nothing naming the cause. Read from the script rather than
  # restated here, the same read-it-from-the-thing-that-installs-it discipline
  # as the template pins.
  local pins tool want probe seen=0
  pins="$(zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins)"
  [ -n "$pins" ]

  while read -r tool want; do
    [ -n "$tool" ] || continue
    [ -n "$want" ] || return 1
    seen=$(( seen + 1 ))
    case "$tool" in
      helm)        probe="helm version --short" ;;
      kustomize)   probe="kustomize version" ;;
      kubeconform) probe="kubeconform -v" ;;
      kube-linter) probe="kube-linter version" ;;
      kyverno)     probe="kyverno version" ;;
      trivy)       probe="trivy --version" ;;
      yq)          probe="yq --version" ;;
      *) return 1 ;;
    esac
    run env PATH="$IAC_BIN:$PATH" bash -c "$probe"
    [ "$status" -eq 0 ]
    # ANCHORED on a non-version character both sides, exactly as iac-tools.zsh's
    # own probe is: a plain substring `0.7.2` also matches 10.7.2 and 0.7.20, so
    # the check meant to independently verify the pinning would be looser than
    # the code it verifies.
    matches "$output" "(^|[^0-9.])${want//./\\.}([^0-9.]|$)"
  done <<< "$pins"
  # a count guard: a --print-pins that silently stopped emitting a tool would
  # otherwise shrink this test's reach to whatever it still lists, and the loop
  # would pass having checked fewer binaries than the harness actually runs
  [ "$seen" -eq 7 ]
}

@test "the template carries no placeholder and renders to itself, syntax-checked (#1603)" {
  # `{{UPPERCASE}}` is render.zsh's placeholder shape. The gate script declares
  # none, so bootstrap must emit it byte-for-byte — asserted by RENDERING it
  # through the real renderer and comparing, not by grep alone: a stray
  # conditional-block marker would also change the rendered form.
  run grep -nE '\{\{[A-Z_]+\}\}' "$GATE"
  [ "$status" -eq 1 ]
  local out="$BATS_TEST_TMPDIR/rendered-template"
  run zsh "$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh" \
    --templates "$REPO_ROOT/development/skills/bootstrap/templates" --out "$out" \
    iac/scripts/k8s-gate.zsh.tmpl
  [ "$status" -eq 0 ]
  [ -f "$out/iac/scripts/k8s-gate.zsh" ]
  run cmp "$out/iac/scripts/k8s-gate.zsh" "$GATE"
  [ "$status" -eq 0 ]
  # and the rendered form parses — the acceptance criterion as written
  run zsh -n "$out/iac/scripts/k8s-gate.zsh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--help prints the header and an unknown argument is a usage error (#1603)" {
  # from an EMPTY directory, never bats' cwd (the repository root): if the
  # argument loop regressed and `--only` fell through, the gate would gate this
  # whole checkout — minutes of real tools — instead of failing fast on
  # "nothing to render"
  local empty="$BATS_TEST_TMPDIR/empty-cwd"
  mkdir -p "$empty"
  run bash -c "cd '$empty' && zsh '$GATE' --help"
  [ "$status" -eq 0 ]
  contains "$output" 'THE SIX STAGES, IN ORDER, STOPPING AT THE FIRST FAILURE'
  contains "$output" 'EXIT CODES'
  # the documented status set includes the two the signal traps produce
  contains "$output" '130 / 143'
  run bash -c "cd '$empty' && zsh '$GATE' --only render"
  [ "$status" -eq 2 ]
  contains "$output" 'unknown argument: --only'
  [ -z "$(verdict_lines "$output")" ]
}

# ---------------------------------------------------------------------------
# The clean variant — expected green through every stage
# ---------------------------------------------------------------------------

@test "clean: the gate is green through all six stages, in order (#1199, #1603)" {
  prepare kubernetes-repo
  run run_gate
  [ "$status" -eq 0 ]
  # EXACTLY the six verdict lines, in stage order — the output contract. An
  # enumerated whole-list comparison, not six `contains`: a stage printing twice,
  # a stage missing, or a stage out of order would all pass a needle sweep.
  [ "$(verdict_lines "$output")" = "$(expected_all_ok)" ]
  # the counters, not just the exit code: kubeconform exits 0 over an EMPTY
  # directory too, so a render regression would read as a passing schema stage
  contains "$output" 'Valid: 3'
  contains "$output" 'Invalid: 0'
  contains "$output" 'No lint errors found!'
  # `pass: 2`, not merely exit 0: `kyverno apply` also exits 0 when the rule
  # matched NOTHING, which is the vacuity this fixture's chart exists to prevent
  contains "$output" 'pass: 2, fail: 0'
  # and the fixtures ran — this variant ships kyverno-test.yaml, so the stage
  # must reach `kyverno test` rather than taking the no-fixtures warning branch
  contains "$output" 'Test Summary: 1 tests passed and 0 tests failed'
  lacks "$output" 'no kyverno test fixtures'
  # foreign-app.yaml points at charts/does-not-exist under a repoURL whose slug
  # has this variant's slug as a strict PREFIX. A filter that regressed to a
  # contains-style match would select it and name that path here.
  lacks "$output" 'charts/does-not-exist'
  # and no diagnostic at all — a warning on the clean variant is a regression
  [ -z "$(diagnostic_lines "$output")" ]
}

@test "clean: the render stage renders both engines, and only rendered output (#1199, #1603)" {
  prepare kubernetes-repo
  run run_gate
  [ "$status" -eq 0 ]
  # the exact tree the downstream stages consumed. An enumerated list, not a
  # spot check: a MISSING render and an EXTRA unrendered input are both failures
  # this fixture exists to catch, and only a whole-set assertion sees the second.
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml kustomize_kustomize_overlays_prod.yaml plain_argocd_app-of-apps.yaml plain_argocd_foreign-app.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
  # the kustomize BASE is deliberately partial and must never reach a validator.
  # It sits HERE, while $output still holds the listing: below the `cat` it would
  # be matching a filename against rendered Helm YAML, where the needle can never
  # appear — an assertion that passes whatever the render stage did.
  lacks "$output" 'kustomize_kustomize_base'
  # helm actually RAN: the ConfigMap's value is substituted from values.yaml, so
  # the literal template expression here would mean the render stage shipped its
  # input and every downstream check validated a Go template
  run cat "$RENDERED/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'rendered-by-helm'
}

@test "render: the input-exclusion rules each leave their input unrendered (#1603)" {
  # Every `continue` in the render stage is a documented rule no committed
  # fixture reaches; planted here, each is observable only through the exact
  # rendered set. A rule deleted from the script adds a file to that set.
  prepare kubernetes-repo
  # a LIBRARY chart (quoted value, the house style the probe tolerates) — helm
  # refuses to template it, so rendering it would red a correct repository
  mkdir -p "$W/charts/common/templates"
  printf '%s\n' 'apiVersion: v2' 'name: common' 'version: 0.1.0' 'type: "library"' \
    > "$W/charts/common/Chart.yaml"
  printf '%s\n' '{{- define "common.name" -}}common{{- end -}}' \
    > "$W/charts/common/templates/_helpers.tpl"
  # a VENDORED subchart under the app chart's own charts/ — rendered as part of
  # its parent, never on its own
  mkdir -p "$W/charts/app/charts/sub/templates"
  printf '%s\n' 'apiVersion: v2' 'name: sub' 'version: 0.1.0' > "$W/charts/app/charts/sub/Chart.yaml"
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: sub-config' \
    > "$W/charts/app/charts/sub/templates/configmap.yaml"
  # a Kustomize COMPONENT — never built standalone, and its partial patch must
  # not be swept up as a standalone manifest either
  mkdir -p "$W/components/labels"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1alpha1' 'kind: Component' \
    'patches:' '  - path: patch.yaml' > "$W/components/labels/kustomization.yaml"
  printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: worker' \
    '  labels:' '    tier: backend' > "$W/components/labels/patch.yaml"
  # the `.yml` marker spelling — a root found only by the `.yaml` spelling
  # would be swept as a standalone manifest and validated as INPUT
  mkdir -p "$W/kustomize/overlays/staging"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' \
    'namespace: staging' 'resources:' '  - ../prod' > "$W/kustomize/overlays/staging/kustomization.yml"
  # …and the third marker spelling, `Kustomization` with no extension, on a
  # root that consumes staging in turn
  mkdir -p "$W/kustomize/overlays/canary"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' \
    'namespace: canary' 'resources:' '  - ../staging' > "$W/kustomize/overlays/canary/Kustomization"
  run run_gate
  [ "$status" -eq 0 ]
  run rendered_files
  [ "$status" -eq 0 ]
  # prod is CONSUMED by staging and staging by canary, so only canary is
  # built; the library chart, the subchart and the component produce no file
  # of their own, and neither the component's patch nor either marker is
  # copied as plain
  [ "$output" = "helm_charts_app.yaml kustomize_kustomize_overlays_canary.yaml plain_argocd_app-of-apps.yaml plain_argocd_foreign-app.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
  # …and the subchart really was rendered, inside its parent
  run cat "$RENDERED/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'sub-config'
}

@test "render: a chart at the repository ROOT renders as helm_root.yaml (#1603)" {
  # `${d#./}` leaves a root chart's dirname as ".", which is neither empty nor a
  # usable slug or release name; the normalisation to "root" is asserted here
  # because no fixture keeps a Chart.yaml at its root
  W="$BATS_TEST_TMPDIR/root-chart"
  SLUG="fixture-org/root-chart"
  RENDERED="$BATS_TEST_TMPDIR/rendered-root-chart"
  mkdir -p "$W"
  cp -R "$FIXTURES/kubernetes-repo/charts/app/." "$W/"
  cp "$FIXTURES/kubernetes-repo/.kube-linter.yaml" "$W/"
  run run_gate
  [ "$status" -eq 0 ]
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_root.yaml " ]

  # the kustomize half of the same normalisation: a kustomization.yaml at the
  # repository root renders as kustomize_root.yaml, never `kustomize_..yaml`
  W="$BATS_TEST_TMPDIR/root-overlay"
  SLUG="fixture-org/root-overlay"
  RENDERED="$BATS_TEST_TMPDIR/rendered-root-overlay"
  mkdir -p "$W"
  cp "$FIXTURES/kubernetes-repo/kustomize/base/deployment.yaml" "$W/"
  cp "$FIXTURES/kubernetes-repo/.kube-linter.yaml" "$W/"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' \
    'resources:' '  - deployment.yaml' > "$W/kustomization.yaml"
  # the base deployment is deliberately partial and would red lint — the
  # subject here is the render stage's file name, so stop at the first red and
  # read the rendered tree the stage left behind
  run run_gate
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "kustomize_root.yaml " ]
}

@test "render: file names cannot collide — an underscore in a path is escaped (#1603)" {
  # slug_of's guarantee, on the one variant with no kyverno fixture bound to
  # the chart's path: charts/my_app and charts/my/app would otherwise both
  # become helm_charts_my_app.yaml, the second silently overwriting the first
  prepare kubernetes-repo-untested-policy
  mv "$W/charts/app" "$W/charts/my_app"
  mkdir -p "$W/charts/my"
  cp -R "$W/charts/my_app" "$W/charts/my/app"
  run run_gate
  [ "$status" -eq 0 ]
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_my__app.yaml helm_charts_my_app.yaml plain_policies_kyverno_require-registry.yaml " ]
}

@test "clean: the argocd green is not vacuous — an owned dangling app reds it (#1199, #1603)" {
  # The other half of the negative control. The foreign-app check above proves
  # the filter is not too WIDE; on its own it is equally consistent with a filter
  # that selects nothing at all — which is exactly what an unset or mis-set
  # REPO_SLUG produces, and the failure every fixture README warns about.
  # Planting an Application this repo DOES own, pointing at a path that does not
  # exist, proves the filter is not too NARROW either.
  prepare kubernetes-repo
  cat > "$W/argocd/injected.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: injected
spec:
  source:
    repoURL: https://example.com/$SLUG.git
    path: charts/injected-missing
YAML
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'error: app-of-apps references missing path: charts/injected-missing'
  # the FAILED verdict is the last line of the run, and every stage before it
  # still reported ok — a red argocd must not hide a green schema
  [ "$(verdict_lines "$output")" = "$(expected_all_ok | sed '$d'; printf 'gate: argocd FAILED\n')" ]
}

@test "clean: the COMMITTED app-of-apps.yaml is what the filter selects (#1199, #1603)" {
  # The injected-Application control above proves the filter is not too narrow,
  # but it does so with a document the TEST writes — so it says nothing about
  # `argocd/app-of-apps.yaml`, and nothing about whether prepare's hardcoded
  # `fixture-org/<variant>` slug still matches the repoURL the fixture declares.
  # Removing the path that document points at makes the committed file itself
  # load-bearing: the red can only happen if it was read, selected by the slug,
  # and its `.spec.source.path` extracted.
  prepare kubernetes-repo
  [ -d "$W/charts/app" ]
  rm -rf "$W/charts/app"
  # …and the policy set, whose kyverno fixture consumes that chart's deployment
  # as a resource and would red the policy stage first — the gate stops at the
  # first red, and argocd is the stage under test here
  rm -rf "$W/policies"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'error: app-of-apps references missing path: charts/app'
}

@test "clean: under GitHub Actions the diagnostics are workflow commands (#1603)" {
  # the same injected red as above, with GITHUB_ACTIONS set the way a runner
  # sets it: the message must arrive as a `::error::` annotation there, so a red
  # gate surfaces on the PR rather than only in the log
  prepare kubernetes-repo
  cat > "$W/argocd/injected.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: injected
spec:
  source:
    repoURL: https://example.com/$SLUG.git
    path: charts/injected-missing
YAML
  # …and a generator-templated ApplicationSet, whose path is reported as a
  # notice rather than checked — the third annotation level
  cat > "$W/argocd/injected-set.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: injected-set
spec:
  template:
    spec:
      source:
        repoURL: https://example.com/$SLUG.git
        path: 'apps/{{path}}'
YAML
  GATE_ENV='GITHUB_ACTIONS=true'
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" '::error::app-of-apps references missing path: charts/injected-missing'
  lacks "$output" 'error: app-of-apps'
  contains "$output" '::notice::templated path not statically checkable: apps/{{path}}'
  # the verdict lines are NOT annotations — they are the contract in both places
  contains "$output" 'gate: argocd FAILED'
}

# ---------------------------------------------------------------------------
# The broken variant — every red attributable to one file and one check id
# ---------------------------------------------------------------------------

@test "broken: render and schema stay green — they own nothing here (#1199, #1603)" {
  prepare kubernetes-repo-broken
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: render ok'
  contains "$output" 'gate: schema ok'
  # the defects here are semantic, not structural — a schema red would be a
  # regression in the render stage, never the fixture doing its job
  contains "$output" 'Invalid: 0'
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "plain_broken_argocd_dangling-app.yaml plain_broken_argocd_dangling-multisource.yaml plain_broken_bad-registry.yaml plain_broken_latest-tag.yaml plain_broken_no-limits.yaml plain_broken_no-probe.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
}

@test "broken: the lint stage reds with exactly the four documented check ids, and the gate stops there (#1199, #1603)" {
  prepare kubernetes-repo-broken
  run run_gate
  [ "$status" -eq 1 ]
  # EXACTLY four, so a manifest firing a second file's check — or a finding from
  # the Argo CD / policy documents that also land in the rendered tree — reds
  # this too. This is the "no extra findings" half; the PAIRING is the test below.
  contains "$output" 'found 4 lint errors'
  # bad-registry.yaml is the one row kube-linter must stay silent on: its defect
  # belongs to the policy stage, and a lint finding there would collapse two rows
  # of the table into one file
  lacks "$output" 'plain_broken_bad-registry.yaml'
  # the gate STOPS at the first failing stage: the verdict lines end at lint,
  # and no later stage ran — asserted on the whole list, so a stage that kept
  # going after the red is visible
  [ "$(verdict_lines "$output")" = "$(printf '%s\n' 'gate: render ok' 'gate: schema ok' 'gate: lint FAILED')" ]
  lacks "$output" 'Applying'
  lacks "$output" 'Report Summary'
}

@test "broken: each lint finding is attributable to its own file and check id (#1199, #1603)" {
  # #1199's central acceptance criterion — "each red attributable to the ONE file
  # and check id its README table names" — and the one an unpaired needle set
  # cannot express. Asserting that every file name appears somewhere in the log
  # and every check id appears somewhere in the log is equally satisfied by a
  # regression in which no-probe.yaml fired `latest-tag` and latest-tag.yaml
  # fired `no-readiness-probe`: exactly the attributability drift the fixture's
  # table exists to prevent, and the total count does not see it either.
  #
  # kube-linter prints one finding per line carrying both the path and its
  # `(check: <id>…)`, so grepping the line for a file and asserting on THAT
  # binds the two.
  prepare kubernetes-repo-broken
  local file
  run run_gate
  [ "$status" -eq 1 ]
  local lint_output="$output" line
  for file in no-probe no-limits latest-tag; do
    line="$(printf '%s\n' "$lint_output" | grep -- "plain_broken_${file}.yaml")"
    [ -n "$line" ]
    output="$line"
    case "$file" in
    no-probe)
      contains "$output" 'check: no-readiness-probe'
      lacks "$output" 'check: latest-tag'
      lacks "$output" 'check: unset-cpu-requirements'
      lacks "$output" 'check: unset-memory-requirements'
      ;;
    no-limits)
      # deliberately ONE file carrying TWO ids: one removed guarantee, two ways
      # kube-linter names it
      contains "$output" 'check: unset-cpu-requirements'
      contains "$output" 'check: unset-memory-requirements'
      lacks "$output" 'check: no-readiness-probe'
      lacks "$output" 'check: latest-tag'
      ;;
    latest-tag)
      contains "$output" 'check: latest-tag'
      lacks "$output" 'check: no-readiness-probe'
      lacks "$output" 'check: unset-cpu-requirements'
      lacks "$output" 'check: unset-memory-requirements'
      ;;
    esac
  done
}

# The three lint-owned files of the broken variant. The gate stops at the first
# red, so a test that wants to SEE the policy or argocd red must first take the
# lint red out of its way — by removing exactly these, which the README table
# assigns to `lint` and to nothing else.
remove_lint_rows() {
  rm "$W/broken/no-probe.yaml" "$W/broken/no-limits.yaml" "$W/broken/latest-tag.yaml"
}

@test "broken: the policy stage reds on the registry rule, before kyverno test (#1199, #1603)" {
  prepare kubernetes-repo-broken
  remove_lint_rows
  run run_gate
  [ "$status" -eq 1 ]
  # lint is now clean — bad-registry.yaml is the one row it stays silent on —
  # so the red is the policy stage's, and the gate stopped there
  [ "$(verdict_lines "$output")" = "$(printf '%s\n' 'gate: render ok' 'gate: schema ok' 'gate: lint ok' 'gate: policy FAILED')" ]
  # the COUNTER and the rule, not just the non-zero exit: `kyverno apply` also
  # exits non-zero on a bad path, an unloadable policy or a missing binary, and
  # the stage can equally red on the dereference or the empty-selection gate
  contains "$output" 'fail: 1'
  contains "$output" 'bad-registry'
  # the AUTOGEN rule name — the policy matches kinds: [Pod] and these resources
  # are Deployments, so the generated name is what the output actually carries;
  # a harness grepping the authored `images-from-allowed-registry` alone would
  # match this substring by accident and prove nothing about autogen
  contains "$output" 'autogen-images-from-allowed-registry'
  # and the stage ends there, under err_exit — this variant's expected-FAIL
  # kyverno fixture is therefore never reached by the gate, which is why the
  # test below runs it directly
  lacks "$output" 'Test Summary'
}

@test "broken: kyverno test passes directly — the fixture the gate never reaches (#1199)" {
  prepare kubernetes-repo-broken
  # `kyverno test` is unreachable through the policy stage here (the apply above
  # ends it), so the expected-fail fixture would otherwise be shipped and never
  # executed by anything.
  run env PATH="$IAC_BIN:$PATH" kyverno test "$W/policies/kyverno/"
  [ "$status" -eq 0 ]
  contains "$output" '1 tests passed and 0 tests failed'
}

@test "broken: the argocd stage reds naming BOTH dangling paths (#1199, #1603)" {
  prepare kubernetes-repo-broken
  remove_lint_rows
  # …and the policy row — together with the policy set, whose expected-FAIL
  # kyverno fixture consumes bad-registry.yaml as its resource and would red
  # the policy stage without it. What remains is the two Argo CD documents,
  # which the earlier stages all accept; policy skips.
  rm "$W/broken/bad-registry.yaml"
  rm -rf "$W/policies"
  run run_gate
  [ "$status" -eq 1 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_ok | sed '$d' | sed 's|^gate: policy ok$|gate: policy skipped — no policies declared at policies/kyverno/**/*.{yaml,yml}|'; printf 'gate: argocd FAILED\n')" ]
  # dangling-app.yaml, via the singular .spec.source
  contains "$output" 'error: app-of-apps references missing path: charts/does-not-exist'
  # dangling-multisource.yaml, via the multi-source .spec.sources[] — the leg
  # that would silently stop being read without a fixture that only uses it
  contains "$output" 'error: app-of-apps references missing path: charts/also-missing'
}

@test "broken: an ApplicationSet's template source is read, and a templated path is a notice, not a red (#1603)" {
  # the two ApplicationSet legs of the extraction — `.spec.template.spec.source`
  # and `.spec.template.spec.sources[]` — and the `{{…}}` notice branch, none of
  # which a committed fixture reaches. Dropping either leg from the expression
  # would leave an app-of-apps authored as an ApplicationSet contributing zero
  # paths, the vacuous pass the stage exists to prevent.
  prepare kubernetes-repo-broken
  remove_lint_rows
  rm "$W/broken/bad-registry.yaml"
  rm -rf "$W/policies"
  cat > "$W/broken/argocd/dangling-set.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: dangling-set
spec:
  template:
    spec:
      source:
        repoURL: https://example.com/$SLUG.git
        path: charts/set-missing
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: dangling-multisource-set
spec:
  template:
    spec:
      sources:
        - repoURL: https://example.com/$SLUG.git
          path: charts/set-also-missing
        - repoURL: https://example.com/$SLUG.git
          path: 'apps/{{path}}'
YAML
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'error: app-of-apps references missing path: charts/set-missing'
  contains "$output" 'error: app-of-apps references missing path: charts/set-also-missing'
  # the generator-templated path cannot exist on disk and is reported, not red
  contains "$output" 'notice: templated path not statically checkable: apps/{{path}}'
  lacks "$output" 'missing path: apps/{{path}}'
}

@test "broken: the config-scan stage reds on a wildcard ClusterRole that every earlier stage accepts (#1603)" {
  # the ONE stage no committed fixture reds. A wildcard RBAC rule is CRITICAL to
  # trivy (KSV-0044) and invisible to kube-linter's default set, which is what
  # keeps it attributable to config-scan alone. Without this, `trivy config …`
  # could be replaced by `true` and every test would stay green.
  prepare kubernetes-repo
  cat > "$W/argocd/wildcard-role.yaml" <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wildcard
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
YAML
  # a trivy that RECORDS its argv and delegates to the pinned binary: the two
  # flags the script calls load-bearing (embedded checks, no version nag) and
  # the threshold are only observable in the invocation
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/trivy" <<'EOF'
#!/bin/sh
printf 'trivy %s\n' "$*" >> "$CALLS"
exec "$REAL_TRIVY" "$@"
EOF
  chmod +x "$stub/trivy"
  GATE_PATH_PREFIX="$stub"
  GATE_ENV="$(printf '%s\n' "CALLS=$CALLS" "REAL_TRIVY=$IAC_BIN/trivy")"
  run run_gate
  [ "$status" -eq 1 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_ok | sed '$d' | sed '$d'; printf 'gate: config-scan FAILED\n')" ]
  # trivy's own check id and severity, so the threshold is proven in force —
  # a `--severity` narrowed to CRITICAL only would still pass this, which is
  # why the row is a CRITICAL: the assertion is that the stage RUNS trivy and
  # fails on its verdict, not which band the fixture happens to sit in
  contains "$output" 'KSV-0044 (CRITICAL)'
  contains "$output" 'plain_argocd_wildcard-role.yaml'
  run cat "$CALLS"
  [ "$status" -eq 0 ]
  starts_with "$output" 'trivy config --skip-check-update --skip-version-check --exit-code 1 --severity HIGH,CRITICAL '

  # …and a .trivyignore at the repository root is honoured — the escape hatch
  # the header documents, which only works because the stage runs from there
  printf '%s\n' 'AVD-KSV-0044' 'AVD-KSV-0046' > "$W/.trivyignore"
  rm -rf "$RENDERED"   # the gate refuses a non-empty render dir
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: config-scan ok'
}

@test "render and schema each have a red, and the gate stops at it (#1603)" {
  # the two stage-failure verdicts no fixture produces. A `|| true` on either
  # tool call would turn a broken chart into an empty render and an invalid
  # manifest into `gate: schema ok`.
  prepare kubernetes-repo
  # a Go template action helm cannot satisfy — the chart fails to render
  printf '%s\n' '{{ required "the render must fail here" .Values.absent }}' \
    > "$W/charts/app/templates/broken.yaml"
  run run_gate
  [ "$status" -eq 1 ]
  [ "$(verdict_lines "$output")" = "gate: render FAILED" ]
  contains "$output" 'the render must fail here'

  # an unknown field under -strict — kubeconform reds, lint is never reached
  prepare kubernetes-repo
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: bad' 'bogus: true' \
    > "$W/argocd/bad.yaml"
  run run_gate
  [ "$status" -eq 1 ]
  [ "$(verdict_lines "$output")" = "$(printf '%s\n' 'gate: render ok' 'gate: schema FAILED')" ]
  contains "$output" 'Invalid: 1'
  lacks "$output" 'KubeLinter'
}

@test "a stage failure exits 1 whatever status the failing tool returned (#1603)" {
  # every tool the fixtures red with happens to exit 1; a Go panic exits 2 and
  # an OOM kill 137, and without the trap's normalisation the gate would relay
  # those — 2 being the code the header reserves for "the gate could not run"
  prepare kubernetes-repo
  local stub="$BATS_TEST_TMPDIR/stub-bin" code
  mkdir -p "$stub"
  for code in 2 137; do
    printf '#!/bin/sh\necho "panic: simulated kube-linter crash"\nexit %s\n' "$code" > "$stub/kube-linter"
    chmod +x "$stub/kube-linter"
    GATE_PATH_PREFIX="$stub"
    rm -rf "$RENDERED"   # the gate refuses a non-empty render dir
    run run_gate
    [ "$status" -eq 1 ]
    [ "$(verdict_lines "$output")" = "$(printf '%s\n' 'gate: render ok' 'gate: schema ok' 'gate: lint FAILED')" ]
    # the tool's own output sits above the verdict line
    contains "$output" 'panic: simulated kube-linter crash'
  done

  # …and a SIGNAL keeps its own status — the two traps — while the EXIT trap
  # still runs, so nothing is left in $TMPDIR. A stub kube-linter signals its
  # parent, which is the gate's own zsh (the tools are invoked directly).
  local tmp="$BATS_TEST_TMPDIR/gate-tmp-signal" sig want
  for sig in TERM INT; do
    case "$sig" in TERM) want=143 ;; INT) want=130 ;; esac
    printf '#!/bin/sh\nkill -%s $PPID\nsleep 1\n' "$sig" > "$stub/kube-linter"
    chmod +x "$stub/kube-linter"
    rm -rf "$tmp"; mkdir -p "$tmp"
    GATE_PATH_PREFIX="$stub"
    GATE_ENV="TMPDIR=$tmp"
    GATE_ENV_UNSET='K8S_GATE_RENDER_DIR'
    run run_gate
    [ "$status" -eq "$want" ]
    contains "$output" 'gate: lint FAILED'
    run bash -c "ls -A '$tmp'"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
  done
}

@test "the render stage works on a scratch copy — a chart's dependency build never touches the tree (#1603)" {
  # the reason for the copy: `helm dependency build` on an umbrella chart
  # writes charts/*.tgz and a Chart.lock beside it. No committed fixture
  # declares a dependency, so the copy is observable only through one that
  # does — a file:// dependency on the fixture's own chart, so nothing is
  # fetched from the network
  prepare kubernetes-repo
  mkdir -p "$W/charts/umbrella"
  printf '%s\n' 'apiVersion: v2' 'name: umbrella' 'version: 0.1.0' 'dependencies:' \
    '  - name: app' '    version: 0.1.0' '    repository: file://../app' > "$W/charts/umbrella/Chart.yaml"
  local before after
  before="$(tree_manifest "$W")"
  contains "$before" 'charts/umbrella/Chart.yaml'
  run run_gate
  [ "$status" -eq 0 ]
  # the dependency WAS built and rendered — inside the copy: the umbrella's
  # render carries the app subchart's templated value
  run cat "$RENDERED/helm_charts_umbrella.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'rendered-by-helm'
  # …and nothing landed in the tree: no pulled chart, no lock file
  [ ! -e "$W/charts/umbrella/charts" ]
  [ ! -e "$W/charts/umbrella/Chart.lock" ]
  after="$(tree_manifest "$W")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# The untested-policy variant — green, plus the warning
# ---------------------------------------------------------------------------

@test "untested-policy: the gate is green and warns about the missing fixtures (#1199, #1603)" {
  prepare kubernetes-repo-untested-policy
  run run_gate
  # GREEN: an untested policy set is a maintenance finding to file, not a gate
  # failure — the whole point of this variant
  [ "$status" -eq 0 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_ok)" ]
  contains "$output" 'warning: policies declared but no kyverno test fixtures'
  # and the policy was actually EVALUATED before the warning: `kyverno apply`
  # exits 0 both when the rule passed and when it matched nothing at all, so
  # only the counter tells a real green from the vacuity the chart exists to
  # prevent
  contains "$output" 'pass: 1, fail: 0'
  lacks "$output" 'Test Summary'
  # The same render assertions the clean variant carries, and for the same
  # reason: without them a render regression that rendered nothing would take
  # the nothing-to-render skip and leave every stage "green" here. The fixture's
  # own README is explicit that its chart exists precisely so this variant is
  # never evaluated vacuously.
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml plain_policies_kyverno_require-registry.yaml " ]
  run cat "$RENDERED/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'rendered-by-helm'

  # …and under GitHub Actions the same warning is a workflow command — the
  # spelling the fixture README promises will surface on the PR
  rm -rf "$RENDERED"
  GATE_ENV='GITHUB_ACTIONS=true'
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" '::warning::policies declared but no kyverno test fixtures'
  lacks "$output" 'warning: policies declared'
}

# ---------------------------------------------------------------------------
# The helmcharts variant — Helm inflation is on
# ---------------------------------------------------------------------------

@test "helmcharts: a helmCharts: overlay renders non-empty and is validated (#1603)" {
  prepare kubernetes-repo-helmcharts
  run run_gate
  [ "$status" -eq 0 ]
  # policy skips — the variant declares none — and every other stage is ok
  [ "$(verdict_lines "$output")" = "$(expected_all_ok | sed 's|^gate: policy ok$|gate: policy skipped — no policies declared at policies/kyverno/**/*.{yaml,yml}|')" ]
  # BOTH renders of the vendored chart, as the fixture README states: the
  # inflated overlay and the top-level helm pass over the same chart directory
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_apps_app_charts_app.yaml kustomize_apps_app.yaml " ]
  # the inflated overlay is NON-EMPTY — objects, not a lone newline — and it
  # carries the OVERLAY's value, which only `--enable-helm` inflation with the
  # overlay's valuesInline can produce; the chart's own default would mean the
  # kustomize output was the helm pass's output copied, not an inflation
  run cat "$RENDERED/kustomize_apps_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'kind: Deployment'
  contains "$output" 'rendered-by-kustomize-helm'
  lacks "$output" 'rendered-by-helm'
  contains "$output" 'kind: ConfigMap'
}

@test "helmcharts: the inflated overlay is what the schema stage counted (#1603)" {
  # The rendered-file assertion above proves the file exists with the right
  # content; this proves the downstream stages consumed it. 4 valid objects: the
  # chart's Deployment and ConfigMap, twice (helm pass + inflated overlay). A
  # regression inflating nothing would count 2 and still exit 0.
  prepare kubernetes-repo-helmcharts
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'Valid: 4'
  contains "$output" 'Invalid: 0'
  contains "$output" 'No lint errors found!'
}

# ---------------------------------------------------------------------------
# Skips — reported, never silent
# ---------------------------------------------------------------------------

# The six skip lines an empty render must print, in stage order.
expected_all_skipped() {
  local s
  for s in render schema lint policy config-scan argocd; do
    printf 'gate: %s skipped — nothing to render\n' "$s"
  done
}

@test "empty: a directory with nothing to render skips every stage and exits 0 (#1603)" {
  # the empty-GitOps-repository case the epic exists for: green and waiting for
  # the first manifest, with every skip stated
  W="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$W"
  SLUG="fixture-org/empty"
  RENDERED="$BATS_TEST_TMPDIR/rendered-empty"
  run run_gate
  [ "$status" -eq 0 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_skipped)" ]
  # NO placeholder was validated in place of real output: the workflow this
  # script replaced wrote a sentinel ConfigMap so its downstream jobs had an
  # input; the gate skips instead, so no validator ran at all
  lacks "$output" 'Valid:'
  lacks "$output" 'KubeLinter'
  lacks "$output" 'error:'
}

@test "empty: an object-FREE render is 'nothing to render', not a file to validate (#1199, #1603)" {
  # The one corner whose design rests on an empirical claim about a real tool:
  # `kube-linter lint` errors with "no valid objects found" on a tree containing
  # none. A chart whose only template is value-gated off renders an object-FREE
  # file — helm writes a lone newline — which is why the gate greps for `^kind:`
  # across the rendered tree rather than counting files. A file-count test would
  # see one file, run the validators, and red a repo with nothing to validate.
  W="$BATS_TEST_TMPDIR/object-free"
  SLUG="fixture-org/object-free"
  RENDERED="$BATS_TEST_TMPDIR/rendered-object-free"
  mkdir -p "$W/charts/app/templates"
  printf '%s\n' 'apiVersion: v2' 'name: app' 'version: "0.1.0"' > "$W/charts/app/Chart.yaml"
  printf '%s\n' 'enabled: false' > "$W/charts/app/values.yaml"
  printf '%s\n' '{{- if .Values.enabled }}' 'apiVersion: v1' 'kind: ConfigMap' \
    'metadata:' '  name: gated' '{{- end }}' > "$W/charts/app/templates/configmap.yaml"
  run run_gate
  [ "$status" -eq 0 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_skipped)" ]
  # helm DID run and DID write a file — the skip is about objects, not files
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml " ]
  run cat "$RENDERED/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  lacks "$output" 'kind:'
}

@test "no policies: an absent policies/kyverno skips the policy stage and stays green (#1603)" {
  prepare kubernetes-repo
  rm -rf "$W/policies"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy skipped — no policies declared at policies/kyverno/**/*.{yaml,yml}'
  # a SKIP, with every other stage still run and ok — not an early exit
  [ "$(verdict_lines "$output")" = "$(expected_all_ok | sed 's|^gate: policy ok$|gate: policy skipped — no policies declared at policies/kyverno/**/*.{yaml,yml}|')" ]
  lacks "$output" 'Applying'
}

# ---------------------------------------------------------------------------
# Preconditions — a missing tool, the renderer fallback, the slug
# ---------------------------------------------------------------------------

# A PATH holding the pinned toolchain MINUS the named tools, plus ONLY the
# interpreters and coreutils the gate itself calls — and nothing else from the
# host. "The tool is absent" must be a fact about the PATH under test, not
# about the host: `$partial:/usr/bin:/bin` read as absent on macOS and in the
# debian container, but GitHub's ubuntu-latest image ships /usr/bin/kubectl, so
# there the kustomize leg found the fallback renderer, ran every stage, and the
# assertion went red for a reason no message named (#1614).
partial_toolchain() {
  local dir="$BATS_TEST_TMPDIR/partial-bin" tool resolved
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in helm kustomize kubeconform kube-linter kyverno trivy yq; do
    case " $* " in *" $tool "*) continue ;; esac
    ln -s "$IAC_BIN/$tool" "$dir/$tool"
  done
  # the wrapper's bash + the gate's zsh, then every external the gate calls
  # (grep the template for the list; a new one shows up here as a 127)
  for tool in bash zsh tar find grep sed awk mktemp ls cut tr dirname basename \
              sort git cp mkdir rm head printf env; do
    resolved="$(command -v "$tool")"
    [ -n "$resolved" ]
    ln -s "$resolved" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

@test "a missing tool exits 2 BEFORE any stage, naming it and its brew line (#1603)" {
  prepare kubernetes-repo
  local partial tool
  # EVERY tool, not one exemplar: each require_tool line is its own guard, and
  # a deleted one would fail mid-stage with a raw 127 instead of this exit 2
  for tool in helm kustomize kubeconform kube-linter kyverno trivy yq; do
    partial="$(partial_toolchain "$tool")"
    # the PATH is ONLY that directory: nothing the host has installed can stand
    # in for the missing tool (ubuntu-latest's /usr/bin/kubectl would, #1614)
    run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY PATH="$partial" \
      REPO_SLUG="$SLUG" bash -c "cd '$W' && zsh '$GATE'"
    [ "$status" -eq 2 ]
    case "$tool" in
      # neither renderer on PATH: the fallback leg is refused by name too
      kustomize) contains "$output" 'required tool not on PATH: kustomize (or kubectl)' ;;
      *)         contains "$output" "required tool not on PATH: $tool" ;;
    esac
    contains "$output" "brew install $tool"
    # NO stage ran — not even render, which needs nothing kubeconform provides.
    # Degrading to the stages that can run is the vacuous green this guard
    # exists to forbid.
    [ -z "$(verdict_lines "$output")" ]
  done
  # and every missing tool is named in ONE run, not one per attempt
  partial="$(partial_toolchain kubeconform trivy)"
  run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY PATH="$partial" \
    REPO_SLUG="$SLUG" bash -c "cd '$W' && zsh '$GATE'"
  [ "$status" -eq 2 ]
  contains "$output" 'required tool not on PATH: kubeconform'
  contains "$output" 'required tool not on PATH: trivy'
  contains "$output" 'brew install trivy'
}

@test "a yq of the wrong flavour is refused at the preflight, not after five stages (#1603)" {
  # python-yq passes `command -v yq`; without the flavour probe it would surface
  # as `gate: argocd FAILED` (exit 1) blaming the expression, minutes in
  prepare kubernetes-repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$stub/yq"
  chmod +x "$stub/yq"
  GATE_PATH_PREFIX="$stub"
  run run_gate
  [ "$status" -eq 2 ]
  contains "$output" 'required tool not on PATH: yq (mikefarah v4'
  contains "$output" 'brew install yq'
  [ -z "$(verdict_lines "$output")" ]
}

@test "the argocd stage refuses a vacuous pass when the yq expression cannot run (#1603)" {
  # a yq that passes the flavour probe but evaluates nothing: without the probe
  # document the stage would warn per file, extract zero paths and report ok
  prepare kubernetes-repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/yq" <<'EOF'
#!/bin/sh
case "$1" in --version) echo "yq (https://github.com/mikefarah/yq/) version v4.44.3" ;; esac
exit 0
EOF
  chmod +x "$stub/yq"
  GATE_PATH_PREFIX="$stub"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'refusing to report a vacuous pass'
  # the five stages before it were green — the refusal is the argocd stage's own
  contains "$output" 'gate: config-scan ok'
}

@test "the argocd stage warns and continues on a YAML file it cannot parse (#1603)" {
  # per-file yq, so one stray non-YAML .yml cannot truncate the path list —
  # and cannot red the stage either: it is reported, and the rest is checked
  prepare kubernetes-repo
  printf 'a: [\n' > "$W/argocd/broken.yml"
  run run_gate
  [ "$status" -eq 0 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_ok)" ]
  contains "$output" 'warning: could not parse ./argocd/broken.yml as YAML — skipped by the argocd stage'
  rm -rf "$RENDERED"
  GATE_ENV='GITHUB_ACTIONS=true'
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" '::warning::could not parse ./argocd/broken.yml as YAML'
  lacks "$output" 'warning: could not parse'
}

@test "the temporary render and work directories are removed, on a green run and on a red one (#1603)" {
  # the header's promise, which run_gate's K8S_GATE_RENDER_DIR normally masks:
  # without the trap's rm, every run of the gate would leak the whole rendered
  # tree into the developer's $TMPDIR
  local tmp="$BATS_TEST_TMPDIR/gate-tmp"
  prepare kubernetes-repo
  mkdir -p "$tmp"
  GATE_ENV="TMPDIR=$tmp"
  GATE_ENV_UNSET='K8S_GATE_RENDER_DIR'
  run run_gate
  [ "$status" -eq 0 ]
  run bash -c "ls -A '$tmp'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # …and on a red, where only the EXIT trap can do it
  prepare kubernetes-repo-broken
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: lint FAILED'
  run bash -c "ls -A '$tmp'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "without kustomize the render stage falls back to kubectl kustomize --enable-helm (#1603)" {
  prepare kubernetes-repo
  local partial stub
  partial="$(partial_toolchain kustomize)"
  # a kubectl that RECORDS its argv and delegates to the real kustomize, so the
  # rest of the gate still has real output to validate — the fallback is about
  # which command the stage reaches for, and with which flag
  stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/kubectl" <<'EOF'
#!/bin/sh
printf 'kubectl %s\n' "$*" >> "$CALLS"
[ "$1" = kustomize ] || exit 1
shift
exec "$REAL_KUSTOMIZE" build "$@"
EOF
  chmod +x "$stub/kubectl"
  run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY \
    PATH="$stub:$IAC_SHIM:$partial:/usr/bin:/bin" \
    CALLS="$CALLS" REAL_KUSTOMIZE="$IAC_BIN/kustomize" \
    IAC_KUBECONFORM_BIN="$IAC_KUBECONFORM_BIN" IAC_KUBECONFORM_CACHE="$IAC_KUBECONFORM_CACHE" \
    REPO_SLUG="$SLUG" K8S_GATE_RENDER_DIR="$RENDERED" bash -c "cd '$W' && zsh '$GATE'"
  [ "$status" -eq 0 ]
  [ "$(verdict_lines "$output")" = "$(expected_all_ok)" ]
  run cat "$CALLS"
  [ "$status" -eq 0 ]
  # ONE overlay root, built through kubectl with Helm inflation on
  [ "$output" = "kubectl kustomize --enable-helm ./kustomize/overlays/prod" ]
  run rendered_files
  [ "$status" -eq 0 ]
  contains "$output" 'kustomize_kustomize_overlays_prod.yaml'
}

@test "the slug falls back to the origin remote, and its absence is a typed red, not a vacuous pass (#1603)" {
  prepare kubernetes-repo
  # remove the path the committed app-of-apps points at, so a SELECTED
  # Application reds and an unselected one does not — the only observable
  # difference between "the slug resolved" and "everything was filtered out".
  # The policy set goes with it: its kyverno fixture consumes that chart's
  # deployment and would red the policy stage before argocd is reached.
  rm -rf "$W/charts/app" "$W/policies"
  (cd "$W" && git init -q && git remote add origin "https://github.com/$SLUG.git")
  # no REPO_SLUG, no GITHUB_REPOSITORY: the remote is the only source left
  run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u REPO_SLUG \
    PATH="$IAC_SHIM:$IAC_BIN:$PATH" \
    IAC_KUBECONFORM_BIN="$IAC_KUBECONFORM_BIN" IAC_KUBECONFORM_CACHE="$IAC_KUBECONFORM_CACHE" \
    bash -c "cd '$W' && zsh '$GATE'"
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'error: app-of-apps references missing path: charts/app'

  # GITHUB_REPOSITORY — what every Actions runner exports — is consulted
  # before the remote: no REPO_SLUG, no remote, and the slug still resolves
  (cd "$W" && git remote remove origin)
  GATE_ENV="GITHUB_REPOSITORY=$SLUG"
  GATE_ENV_UNSET='REPO_SLUG'
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'error: app-of-apps references missing path: charts/app'
  GATE_ENV=""
  GATE_ENV_UNSET=""

  # …and with NO source at all, Applications present, the stage refuses rather
  # than filtering everything out and passing: the failure mode every fixture
  # README warns about, made a typed red
  run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u REPO_SLUG \
    PATH="$IAC_SHIM:$IAC_BIN:$PATH" \
    IAC_KUBECONFORM_BIN="$IAC_KUBECONFORM_BIN" IAC_KUBECONFORM_CACHE="$IAC_KUBECONFORM_CACHE" \
    bash -c "cd '$W' && zsh '$GATE'"
  [ "$status" -eq 1 ]
  contains "$output" 'gate: argocd FAILED'
  contains "$output" 'slug could not be resolved'
  contains "$output" 'set REPO_SLUG=owner/name'
  lacks "$output" 'missing path'
}

@test "K8S_GATE_RENDER_DIR inside the tree, or non-empty, is refused (#1603)" {
  prepare kubernetes-repo
  RENDERED="$W/rendered"
  run run_gate
  [ "$status" -eq 2 ]
  contains "$output" 'must lie outside the repository'
  [ -z "$(verdict_lines "$output")" ]
  RENDERED="$BATS_TEST_TMPDIR/stale-render"
  mkdir -p "$RENDERED"
  printf 'kind: Stale\n' > "$RENDERED/stale.yaml"
  run run_gate
  [ "$status" -eq 2 ]
  contains "$output" 'exists and is not an empty directory'
  [ -z "$(verdict_lines "$output")" ]
  # never CLEARED: the refusal is what protects a directory the caller named
  [ -f "$RENDERED/stale.yaml" ]
  # a regular FILE at the path is the other half of the same refusal
  RENDERED="$BATS_TEST_TMPDIR/render-is-a-file"
  printf 'x' > "$RENDERED"
  run run_gate
  [ "$status" -eq 2 ]
  contains "$output" 'exists and is not an empty directory'
}

# ---------------------------------------------------------------------------
# The working tree — left exactly as found
# ---------------------------------------------------------------------------

@test "the gate never modifies the tree it gates, nor the committed fixtures (#1199, #1603)" {
  # The policy stage of the workflow this script replaced dereferenced
  # policies/kyverno IN PLACE — fine on a disposable CI checkout, not on a
  # developer's working tree. The gate mirrors instead. Asserted on the COPY it
  # ran against (the tree it could have damaged) and on the committed fixtures
  # (the copy discipline), across every variant, whatever the verdict.
  local before after variant committed_before committed_after
  committed_before="$(for variant in $(variants); do tree_manifest "$FIXTURES/$variant"; done)"
  [ -n "$committed_before" ]
  contains "$committed_before" 'policies/kyverno/require-registry.yaml'
  for variant in $(variants); do
    prepare "$variant"
    before="$(tree_manifest "$W")"
    [ -n "$before" ]
    # the broken variant's gate is EXPECTED to exit non-zero; the subject here
    # is the tree it ran against, not its verdict
    run run_gate
    # POSITIVE evidence the run reached the stages that could have written into
    # the tree: the render stage's verdict, at least. A gate that exited at a
    # precondition would leave the tree untouched trivially.
    contains "$output" 'gate: render ok'
    after="$(tree_manifest "$W")"
    [ "$before" = "$after" ]
    # nothing LEFT BEHIND either — a mirror, a scratch file — which a manifest of
    # files present before cannot see
    run bash -c "cd '$W' && find . -name '.kyverno-deref*' -o -name 'k8s-gate*'"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
  done
  committed_after="$(for variant in $(variants); do tree_manifest "$FIXTURES/$variant"; done)"
  [ "$committed_before" = "$committed_after" ]
}

@test "a symlink-shared policy set is evaluated through a mirror, and the symlink survives (#1603)" {
  # Kyverno's walker does not descend a symlinked directory, so a policy set
  # shared by symlink needs dereferencing — and the gate must do it WITHOUT
  # replacing the developer's symlink with a copy, which is what the workflow's
  # in-place swap would do to a working tree.
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  ln -s ../shared-policies "$W/policies/kyverno"
  # the set is ORGANISED IN SUBDIRECTORIES with a repeated basename, so the
  # mirror's shape is observable: a flattening copy would overwrite one of the
  # two policies (pass: 4 becomes 2) and leave the fixture's `policies:
  # base/require-registry.yaml` entry pointing at a path the mirror lacks
  mkdir -p "$W/shared-policies/base" "$W/shared-policies/prod"
  mv "$W/shared-policies/require-registry.yaml" "$W/shared-policies/base/require-registry.yaml"
  sed 's/name: require-registry$/name: require-registry-prod/' \
    "$W/shared-policies/base/require-registry.yaml" > "$W/shared-policies/prod/require-registry.yaml"
  sed -i.bak 's|^  - require-registry.yaml$|  - base/require-registry.yaml|' "$W/shared-policies/kyverno-test.yaml"
  rm "$W/shared-policies/kyverno-test.yaml.bak"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy ok'
  # evaluated for real — the counter and the fixture run, through the mirror.
  # BOTH policies applied to both Deployments (a flattened mirror gives 2),
  # and the fixture's `resources: ../../charts/app/…` resolves from the mirror
  # exactly as from the link, which is the same-depth-sibling property the gate
  # relies on.
  contains "$output" 'pass: 4, fail: 0'
  contains "$output" 'Test Summary: 1 tests passed and 0 tests failed'
  # the tree is as it was: still a symlink, and no mirror left behind
  [ -L "$W/policies/kyverno" ]
  [ ! -e "$W/policies/.kyverno-deref" ]
  [ -d "$W/shared-policies" ]
}

@test "a policy the mirror cannot copy is a typed red, never a silently reduced set (#1603)" {
  # the per-entry copy's own failure arm. A `cp` that fails only for the
  # mirror path (and delegates otherwise) stands in for an unreadable file —
  # file modes cannot, since the container leg runs as root. Without the
  # typed red, the surviving policies would be applied and the stage would
  # print ok over a set missing one the repo declares.
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  ln -s ../shared-policies "$W/policies/kyverno"
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/cp" <<'EOF'
#!/bin/sh
case " $* " in *".kyverno-deref/require-registry.yaml "*) echo "cp: simulated unreadable policy" >&2; exit 1 ;; esac
exec /bin/cp "$@"
EOF
  chmod +x "$stub/cp"
  GATE_PATH_PREFIX="$stub"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  contains "$output" 'error: could not dereference policies/kyverno/require-registry.yaml'
  contains "$output" 'simulated unreadable policy'
  lacks "$output" 'gate: policy ok'
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "a dangling link INSIDE a policy tree is dropped from the mirror with a warning, and the rest is evaluated (#1603)" {
  # the strip branch: a link into an unfetched submodule beside real policies
  # must not red the gate over an entirely readable set — and the drop is
  # from the MIRROR, never the source tree
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  ln -s ../shared-policies "$W/policies/kyverno"
  ln -s ../does-not-exist.yaml "$W/shared-policies/submodule-policy.yaml"
  # …and one BEHIND a symlinked subdirectory of the shared tree, which a
  # physical walk never descends: it must be found, named at its path under
  # policies/kyverno, and skipped exactly like the top-level one — while a
  # REAL policy beside it in that subdirectory is copied and applied (pass: 4,
  # not 2: a walk that followed only the command-line link would miss it)
  mkdir -p "$W/policy-lib"
  ln -s ../policy-lib "$W/shared-policies/shared"
  ln -s ../unfetched/vendor.yaml "$W/policy-lib/vendor.yaml"
  sed 's/name: require-registry$/name: require-registry-shared/' \
    "$W/shared-policies/require-registry.yaml" > "$W/policy-lib/require-registry-shared.yaml"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy ok'
  # the paths are IN the warning line, so a CI annotation names them
  contains "$output" 'warning: skipping unresolvable symlinks under policies/kyverno: policies/kyverno/shared/vendor.yaml, policies/kyverno/submodule-policy.yaml'
  contains "$output" 'pass: 4, fail: 0'
  contains "$output" 'Test Summary: 1 tests passed and 0 tests failed'
  [ -L "$W/shared-policies/submodule-policy.yaml" ]
  [ -L "$W/policy-lib/vendor.yaml" ]
  [ ! -e "$W/policies/.kyverno-deref" ]
  # the same warning as a workflow command under GitHub Actions
  rm -rf "$RENDERED"
  GATE_ENV='GITHUB_ACTIONS=true'
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" '::warning::skipping unresolvable symlinks under policies/kyverno: policies/kyverno/shared/vendor.yaml'
  lacks "$output" 'warning: skipping unresolvable symlinks'
}

@test "a symlink loop in the policy tree is a typed red on every find, never a silent prune (#1603)" {
  # GNU find never prints the cyclic entry (it warns and exits 1); Apple's
  # find prints it and exits 0. The gate walks the tree itself, in zsh, and
  # refuses a loop by physical path before either find runs — so the verdict
  # is the same everywhere and names the offending link. Six shapes, each
  # closing the cycle differently: a link to the policy root, a link to an
  # ANCESTOR of it, a link to the filesystem root (the one physical path that
  # already ends in a slash — the containment pattern must not become `//*`),
  # one behind a HIDDEN directory (the walk's dotdir qualifier), a cycle
  # closing on its own parent inside a subtree, and one closing TWO levels
  # up (the lineage search past its last element). The first four resolve to
  # the policy root or above it and are refused AT the link by containment,
  # before anything descends the repository or the filesystem behind it; the
  # last two close on the lineage.
  local shape link tail
  for shape in root ancestor fsroot hidden subtree deep; do
    prepare kubernetes-repo
    mv "$W/policies/kyverno" "$W/shared-policies"
    ln -s ../shared-policies "$W/policies/kyverno"
    mkdir -p "$W/policy-lib"
    ln -s ../policy-lib "$W/shared-policies/shared"
    # a dangling link OUTSIDE the policy tree: the refusal must come before
    # the unresolvable-link walk, or an ancestor-shaped loop would sweep the
    # whole repository and report this file as a policy-tree member
    ln -s ../does-not-exist "$W/charts/dangling.yaml"
    tail='which contains policies/kyverno itself'
    case "$shape" in
      root)     ln -s ../shared-policies "$W/policy-lib/loop"; link='policies/kyverno/shared/loop' ;;
      ancestor) ln -s .. "$W/policy-lib/up";                  link='policies/kyverno/shared/up' ;;
      fsroot)   ln -s / "$W/policy-lib/fsroot";               link='policies/kyverno/shared/fsroot' ;;
      subtree)  mkdir -p "$W/shared-policies/a"
                ln -s ../a "$W/shared-policies/a/link";        link='policies/kyverno/a/link'
                tail='a directory already on its own path' ;;
      hidden)   mkdir -p "$W/shared-policies/.shared"
                ln -s ../../shared-policies "$W/shared-policies/.shared/loop"
                link='policies/kyverno/.shared/loop' ;;
      deep)     mkdir -p "$W/policy-lib/sub"
                ln -s .. "$W/policy-lib/sub/back";          link='policies/kyverno/shared/sub/back'
                tail='a directory already on its own path' ;;
    esac
    run run_gate
    [ "$status" -eq 1 ]
    contains "$output" 'gate: policy FAILED'
    contains "$output" "error: policies/kyverno contains a symlink loop: $link resolves to"
    # the arm that fired is named — a root or ancestor target by containment,
    # a cycle below by lineage
    contains "$output" "$tail"
    lacks "$output" 'gate: policy ok'
    lacks "$output" 'gate: config-scan'
    lacks "$output" 'skipping unresolvable symlinks'
    # find's own diagnostic never gets a chance to be the verdict
    lacks "$output" 'loop detected'
    [ ! -e "$W/policies/.kyverno-deref" ]
  done
}

@test "a directory shared by two links is a diamond, not a loop — evaluated through both, never refused (#1603)" {
  # the positive control for the lineage pop: the same physical directory
  # reached from two SIBLING branches is an ordinary way to share a rule set,
  # and only the pop after each recursion keeps it from reading as a cycle
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  ln -s ../shared-policies "$W/policies/kyverno"
  mkdir -p "$W/policy-lib" "$W/shared-policies/base" "$W/shared-policies/prod"
  sed 's/name: require-registry$/name: require-registry-shared/' \
    "$W/shared-policies/require-registry.yaml" > "$W/policy-lib/require-registry-shared.yaml"
  ln -s ../../policy-lib "$W/shared-policies/base/lib"
  ln -s ../../policy-lib "$W/shared-policies/prod/lib"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy ok'
  lacks "$output" 'symlink loop'
  # the shared policy applied through BOTH branches beside the original:
  # three policies over the two Deployments
  contains "$output" 'pass: 6, fail: 0'
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "a mirror left behind by a killed run is replaced, never merged into (#1603)" {
  # the symlink branch's own leftover handling: a stale policy in a
  # pre-existing policies/.kyverno-deref must not join today's set — merged
  # in, a policy the repo has since deleted would still enforce under ok
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  ln -s ../shared-policies "$W/policies/kyverno"
  mkdir -p "$W/policies/.kyverno-deref"
  sed 's/name: require-registry$/name: require-registry-stale/' \
    "$W/shared-policies/require-registry.yaml" > "$W/policies/.kyverno-deref/stale.yaml"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy ok'
  contains "$output" 'pass: 2, fail: 0'
  lacks "$output" 'require-registry-stale'
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "a mirror left behind by a killed run is never swept into the render (#1603)" {
  # only a SIGKILL leaves policies/.kyverno-deref in the tree; on the next
  # run the scratch copy must exclude it, or its stale policy documents are
  # validated as standalone manifests
  prepare kubernetes-repo
  mkdir -p "$W/policies/.kyverno-deref"
  cp "$W/policies/kyverno/require-registry.yaml" "$W/policies/.kyverno-deref/"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'Valid: 3'
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml kustomize_kustomize_overlays_prod.yaml plain_argocd_app-of-apps.yaml plain_argocd_foreign-app.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
}

@test "a member link that escapes the shared policy tree is dereferenced from where it sits, not from the mirror (#1603)" {
  # the relocation trap: policies/kyverno -> ../shared-policies, and inside it
  # a RELATIVE link to a sibling directory. Valid beside the real tree, that
  # link would point somewhere else beside policies/.kyverno-deref — and a
  # mirror built by copying links and dereferencing afterwards would drop the
  # policy (or read a different file) under a `gate: policy ok`. The dangling
  # link beside it is what used to select that branch.
  prepare kubernetes-repo
  mv "$W/policies/kyverno" "$W/shared-policies"
  mkdir -p "$W/policy-lib"
  mv "$W/shared-policies/require-registry.yaml" "$W/policy-lib/require-registry.yaml"
  ln -s ../policy-lib/require-registry.yaml "$W/shared-policies/require-registry.yaml"
  ln -s ../does-not-exist.yaml "$W/shared-policies/submodule-policy.yaml"
  ln -s ../shared-policies "$W/policies/kyverno"
  run run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: policy ok'
  contains "$output" 'warning: skipping unresolvable symlinks under policies/kyverno'
  # the policy behind the escaping link WAS evaluated — the counter is the
  # proof, since a dropped policy leaves `kyverno apply` nothing to apply
  contains "$output" 'pass: 2, fail: 0'
  contains "$output" 'Test Summary: 1 tests passed and 0 tests failed'
  [ -L "$W/shared-policies/require-registry.yaml" ]
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "a policy tree whose every member is unresolvable is a typed red, never a skip (#1603)" {
  # a set we EMPTIED ourselves is not an absent one: reporting green here is
  # the green-over-unenforced-policies outcome the gate refuses
  prepare kubernetes-repo
  rm -rf "$W/policies/kyverno"
  mkdir -p "$W/policies/kyverno"
  ln -s ../../unfetched/require-registry.yaml "$W/policies/kyverno/require-registry.yaml"
  ln -s ../../unfetched/kyverno-test.yaml "$W/policies/kyverno/kyverno-test.yaml"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  contains "$output" 'declares only unresolvable symlinks'
  lacks "$output" 'gate: policy skipped'
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "a dangling policies/kyverno symlink is a typed red, never a skip (#1603)" {
  # a DECLARED policy set that cannot be read must never report green: the same
  # green-over-unenforced-policies outcome the gate refuses for unevaluable kinds
  prepare kubernetes-repo
  rm -rf "$W/policies/kyverno"
  ln -s ../does-not-exist "$W/policies/kyverno"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  contains "$output" 'could not dereference policies/kyverno'
  lacks "$output" 'gate: policy skipped'
  lacks "$output" 'gate: config-scan'
  [ ! -e "$W/policies/.kyverno-deref" ]
}

@test "declared YAML that the kyverno CLI cannot evaluate is a red, not a skip (#1603)" {
  # the ONE skip condition is "no matching file"; YAML present but no
  # Policy/ClusterPolicy document (a Kyverno 1.14 ValidatingPolicy, say) is a
  # declared-but-unenforced set, which the gate refuses to call green
  prepare kubernetes-repo-untested-policy
  printf '%s\n' 'apiVersion: policies.kyverno.io/v1alpha1' 'kind: ValidatingPolicy' \
    'metadata:' '  name: future' > "$W/policies/kyverno/require-registry.yaml"
  run run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  contains "$output" 'no Policy/ClusterPolicy document the kyverno CLI'
  lacks "$output" 'gate: policy skipped'
}
