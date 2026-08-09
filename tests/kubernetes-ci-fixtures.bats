#!/usr/bin/env bats
#
# The REAL-TOOL half of the bootstrap IaC check pipeline's coverage (epic #1150,
# child #1199) — the bootstrapped `kubernetes-ci` workflow
# (development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl)
# executed with helm, kustomize, kubeconform, kube-linter, kyverno and yq over
# the three fixture repositories #1155 shipped.
#
# WHY IT EXISTS. #1154 covers the same template with RECORDING STUBS: it proves
# each step reaches the right tool with the right arguments, which is what you
# need to see a vacuous pass coming. It cannot prove the tools then AGREE — that
# the clean fixture really lints clean, that the broken one really reds with the
# four check ids its README table names. #1155 proved that half by hand, at the
# tool level, and explicitly left "does the WORKFLOW go green/red over these
# trees" to this file. Without it the fixtures exist and are never executed
# against the thing they were built for.
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
# six (kubeconform, kube-linter, kyverno, yq) are read FROM the template, so a
# bump there moves the harness with it; helm and kustomize are pinned in that
# script, because the template installs neither. The
# host's own brew-installed kube-linter is therefore never what these assertions
# measure — which is the only way "green" here can mean anything.
#
# WHY EVERY RUN COPIES THE FIXTURE FIRST. The policy job dereferences
# `policies/kyverno` IN PLACE (`rm -rf` then `mv` of a mirror). Pointed at the
# checked-in tree it would rewrite the fixtures — and for the untested-policy
# variant that directory IS the fixture. Every test below runs against a copy in
# $BATS_TEST_TMPDIR, and one test pins that discipline by checksumming the
# committed trees around the destructive step.
#
# WHAT IS DELIBERATELY UNASSERTED. `config-scan` runs a third-party
# `aquasecurity/trivy-action`, not a `run:` block, so step extraction cannot
# execute it and this harness makes NO claim about it — neither green nor red.
# That is recorded as an executable fact rather than a comment: the
# `config-scan is unasserted by this harness…` test fails the moment config-scan
# grows a `run:` step, which is exactly when the exemption stops being honest.
#
# Two render-job branches are also unasserted HERE and are tracked in #1224: the
# `kind: Component` exclusion and the alternate marker spellings
# (`kustomization.yml`, `Kustomization`). No committed fixture ships either
# shape, so only their shell logic is covered — by tests/bootstrap-iac-pipeline.bats,
# against recording stubs. The epic plan assigned them to this story; they were
# reassigned rather than dropped.

bats_require_minimum_version 1.5.0

load assertions

# Resolve the pinned toolchain ONCE per file rather than per test: it is a
# no-op when the cache is warm, but a cold first run downloads ~100 MB and the
# suite may run its tests in parallel (run-gate.zsh passes --jobs), so six
# concurrent downloads into one cache directory is a race nobody needs.
setup_file() {
  local repo_root bin_dir shim
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Called UNGUARDED and allowed to fail the file, the tests/Dockerfile +
  # script-tests.yml precedent for yq and yamllint: silently skipping would drop
  # the only end-to-end coverage this pipeline has, and a skipped check that
  # reads as green is the failure mode this whole epic is about.
  #
  # `zsh <script>`, not the exec bit: the CI step and every other call site
  # invoke it that way, and a lost mode bit would otherwise abort this whole
  # file with a bare permission error naming nothing about the toolchain.
  bin_dir="$(zsh "$repo_root/tests/iac-tools.zsh")"

  # A kubeconform SHIM, ahead of the real binary on PATH.
  #
  # The pipeline's schema step is `kubeconform -strict -summary
  # -ignore-missing-schemas` with no `-cache`, so kubeconform downloads the
  # Kubernetes JSON schemas from raw.githubusercontent.com on EVERY invocation —
  # four times per suite run. script-tests.yml's path filter is a `**`
  # catch-all, so a transient failure from that host reds this suite on a PR
  # touching nothing IaC-related. The toolchain cache does not help: it removes
  # the binary downloads only.
  #
  # `-cache` is PREPENDED, not appended: Go's flag package stops parsing at the
  # first positional argument, and the step's own arguments end with the render
  # directory. The shim is a test-harness concern only — the step still runs
  # verbatim from the template, and adding `-cache` to the shipped template
  # (which would benefit consumer repos too) is deliberately left out of scope.
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
  # the four tests that execute the schema step run concurrently; on a cold
  # cache they would all fetch and write the same schema files into the same
  # directory, and kubeconform's cache writes are not atomic — a concurrent
  # reader can see a partial file and report it as an invalid schema, a red
  # naming nothing about the fixtures.
  printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: warm' \
    'spec:' '  selector:' '    matchLabels: {app: warm}' '  template:' \
    '    metadata:' '      labels: {app: warm}' '    spec:' '      containers:' \
    '      - name: c' '        image: registry.example.com/app:1.0.0' \
    '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: warm' \
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
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  # read from the file setup_file wrote rather than an exported variable: bats
  # runs setup_file in its own shell, and a value only *usually* propagating is
  # not a foundation for a suite whose whole point is that PATH is pinned
  IAC_BIN="$(cat "$BATS_FILE_TMPDIR/bin-dir")"
  [ -n "$IAC_BIN" ]
  [ -d "$IAC_BIN" ]
  # the schema-cache shim (see setup_file); ahead of $IAC_BIN only for the
  # EXECUTED steps, so the toolchain test below still resolves the real binaries
  IAC_SHIM="$(cat "$BATS_FILE_TMPDIR/shim-dir")"
  [ -d "$IAC_SHIM" ]
  # the shim reads both paths from the environment rather than having them baked
  # into its text (see setup_file), so run_step must export them
  IAC_KUBECONFORM_BIN="$(cat "$BATS_FILE_TMPDIR/kubeconform-bin")"
  IAC_KUBECONFORM_CACHE="$(cat "$BATS_FILE_TMPDIR/kubeconform-cache-dir")"
  [ -x "$IAC_KUBECONFORM_BIN" ]
  [ -n "$IAC_KUBECONFORM_CACHE" ]
  # DERIVED from the workflow, not hardcoded: a renamed env.RENDER_DIR would
  # otherwise leave every test below asserting against a directory the pipeline
  # no longer writes. `!= null` because `yq -r` prints the string "null" for an
  # absent key, which is non-empty and would sail past a bare [ -n ].
  RDIR="$(yq -r '.env.RENDER_DIR' "$TMPL")"
  [ -n "$RDIR" ]
  [ "$RDIR" != "null" ]
  RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export RUNNER_TEMP
}

# ---------------------------------------------------------------------------
# Driving the workflow
# ---------------------------------------------------------------------------

# One `run:` script, extracted by job and step NAME — never by index, so an
# inserted step cannot silently shift a test onto a different block. The two
# validation steps (schema, lint) carry no `name:` at all, so `@unnamed` selects
# the job's single nameless `run:` step; a second one would make the selection
# ambiguous, which the step-env test at the bottom of this file catches.
step_script() {
  if [ "$2" = "@unnamed" ]; then
    yq -r ".jobs.\"$1\".steps[] | select(has(\"run\")) | select(has(\"name\") | not) | .run" "$TMPL"
    return
  fi
  yq -r ".jobs.\"$1\".steps[] | select(.name == \"$2\") | .run" "$TMPL"
}

# Run one extracted step in $W with the runner variables the workflow supplies,
# the pinned toolchain first on PATH, and $SLUG as REPO_SLUG.
#
# REPO_SLUG is supplied HERE rather than exported around the run because the
# workflow pins it at STEP level (`REPO_SLUG: ${{ github.repository }}`) and a
# step-level env beats an exported shell variable — the trap all three fixture
# READMEs warn about. Executing the `run:` block ourselves is what makes the
# fixture's declared slug reach the filter; get it wrong and the argocd job
# selects nothing and passes having verified no path at all.
run_step() {
  local script kv
  local -a env_pairs=()
  # The copy discipline, ENFORCED rather than trusted. `cd ""` SUCCEEDS in bash
  # (it is a no-op), so `cd "$W" || exit 1` alone does not catch a run_step
  # reached without prepare — the subshell would simply stay in bats' cwd, the
  # repository root, and run what this file's header calls the destructive step
  # there. $W is set only by prepare, and bats test bodies run under `set -e`
  # but NOT `set -u`, so an unset $W is silent. One assertion per line.
  [ -n "${W:-}" ] || return 1
  [ -d "$W" ] || return 1
  [ -n "${SLUG:-}" ] || return 1
  # and it must be a COPY, never the committed tree — the whole premise of the file
  case "$W" in "$BATS_TEST_TMPDIR"/*) : ;; *) return 1 ;; esac
  script="$(step_script "$1" "$2")"
  # `|| return 1` on its own line, not an `&&` chain: a non-final test inside a
  # helper invoked through `run` has its status discarded, so a renamed step
  # would run `bash -c ""` and report success having executed nothing
  [ -n "$script" ] || return 1
  [ "$script" != "null" ] || return 1
  # the JOB-level env the workflow supplies (policy's KYVERNO_VERSION), read
  # from the template rather than restated — a test inventing its own value
  # would stop exercising what consumers actually get.
  #
  # An ARRAY, one pair per line, not a space-joined string that `env` word-splits:
  # a job env value containing a space would make `env` stop consuming
  # assignments at the first non-assignment word and execute THAT word as the
  # command — so the step under test would never run, while the test either 127s
  # confusingly or passes having executed something else entirely.
  # ASSIGNED first, then read. A process substitution's status is discarded, so
  # a yq failure — or a selector that stops matching after a job rename — would
  # silently leave env_pairs empty and run the policy step WITHOUT
  # KYVERNO_VERSION, which no assertion here can see (the step interpolates it
  # only inside its unevaluable-kinds error branch).
  local env_yaml
  env_yaml="$(yq -r ".jobs.\"$1\".env // {} | to_entries | map(.key + \"=\" + (.value|tostring)) | .[]" "$TMPL")" \
    || return 1
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    env_pairs+=("$kv")
  done <<< "$env_yaml"
  (
    cd "$W" || exit 1
    # `${a[@]+"${a[@]}"}` — an empty array expanded plainly is an unbound-variable
    # error on bash 3.2 under `set -u`; bats does not set it, but the harness is
    # not the only context this could ever run in
    PATH="$IAC_SHIM:$IAC_BIN:$PATH" RENDER_DIR="$RDIR" REPO_SLUG="$SLUG" \
      IAC_KUBECONFORM_BIN="$IAC_KUBECONFORM_BIN" \
      IAC_KUBECONFORM_CACHE="$IAC_KUBECONFORM_CACHE" \
      env ${env_pairs[@]+"${env_pairs[@]}"} bash -c "$script"
  )
}

# Copy one fixture variant to a temp directory and run the render job over it,
# leaving $W pointing at the copy and $SLUG at the variant's declared slug.
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
  # RUNNER_TEMP is a property of the COPY, not of the test: a real runner job
  # gets a fresh one per job. The multi-variant test below calls prepare three
  # times, and the policy step copies its flattened policy documents into
  # $RUNNER_TEMP/policies WITHOUT clearing it, then applies over everything
  # present — so a shared temp would silently evaluate one variant's policies
  # against the next variant's resources. It is invisible today only because all
  # three variants happen to name their policy file identically.
  RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp-$1"
  rm -rf "$RUNNER_TEMP"
  mkdir -p "$RUNNER_TEMP"
  export RUNNER_TEMP
  mkdir -p "$W/$RDIR"
  run_step render 'helm template every top-level chart'
  run_step render 'kustomize build every overlay'
  run_step render 'copy standalone manifests so there is always something to validate'
}

# The rendered artifact's file names, sorted — the render job's observable output.
rendered_files() {
  # the directory check is what makes this helper able to FAIL. A bare pipeline
  # returns `tr`'s status, and bats does not run test bodies under pipefail, so
  # every `[ "$status" -eq 0 ]` after it would be unfalsifiable — dead weight
  # that reads as coverage.
  [ -d "$W/$RDIR" ] || return 1
  # shellcheck disable=SC2012  # names are what is asserted, not metadata
  ls -1 "$W/$RDIR" | LC_ALL=C sort | tr '\n' ' '
}

# The steps this file EXECUTES, as "job|step-name" — the selectors run_step
# takes. ONE definition, consumed by both the step-env test and the coverage
# accounting below, so `executed` can never be a number someone bumps to green a
# red instead of actually executing the new step.
executed_steps() {
  printf '%s\n' \
    'render|helm template every top-level chart' \
    'render|kustomize build every overlay' \
    'render|copy standalone manifests so there is always something to validate' \
    'schema|@unnamed' \
    'lint|@unnamed' \
    'policy|kyverno apply + test' \
    'argocd|every app path this repo owns exists'
}

# ---------------------------------------------------------------------------
# The toolchain itself
# ---------------------------------------------------------------------------

@test "the harness runs the versions the pipeline installs, not the host's (#1199)" {
  # The install steps are the one part of the workflow this harness does NOT
  # execute — they curl into /usr/local/bin, which is not a thing to do to a
  # developer's machine. Asserting the resolved binaries report the versions
  # those steps pin is the honest equivalent: it is what makes every verdict
  # below reproducible, and it fails loudly if iac-tools.zsh and the template
  # ever drift apart.
  local tool
  for tool in helm kustomize kubeconform kube-linter kyverno yq; do
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

  # ALL SIX, against iac-tools.zsh's own `--print-pins`. Not four: helm and
  # kustomize are the two pins that exist NOWHERE but that script (the template
  # installs neither, so there is no upstream pin to read), which makes them the
  # ones most prone to silent drift — and a helm bump that changes default
  # rendering moves `Valid: 3` and the rendered sets below with nothing naming
  # the cause. Read from the script rather than restated here, the same
  # read-it-from-the-thing-that-installs-it discipline as the template pins.
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
  [ "$seen" -eq 6 ]
}

# ---------------------------------------------------------------------------
# The clean variant — expected green through every executable job
# ---------------------------------------------------------------------------

@test "clean: the render job renders both engines and needs no sentinel (#1199)" {
  prepare kubernetes-repo
  # the exact artifact the downstream jobs consume. An enumerated list, not a
  # spot check: a MISSING render and an EXTRA unrendered input are both failures
  # this fixture exists to catch, and only a whole-set assertion sees the second.
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml kustomize_kustomize_overlays_prod.yaml plain_argocd_app-of-apps.yaml plain_argocd_foreign-app.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
  # the kustomize BASE is deliberately partial and must never reach a validator.
  # It sits HERE, while $output still holds the listing: below the `cat` it would
  # be matching a filename against rendered Helm YAML, where the needle can never
  # appear — an assertion that passes whatever the render job did.
  lacks "$output" 'kustomize_kustomize_base'
  # helm actually RAN: the ConfigMap's value is substituted from values.yaml, so
  # the literal template expression here would mean the render job shipped its
  # input and every downstream check validated a Go template
  run cat "$W/$RDIR/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'rendered-by-helm'
  # the empty-tree sentinel is for a repo with nothing to render; its presence
  # here would mean the render job produced no objects and the green below is
  # about a placeholder ConfigMap
  [ ! -e "$W/$RDIR/EMPTY.yaml" ]
}

@test "clean: the schema job is green (#1199)" {
  prepare kubernetes-repo
  run run_step schema @unnamed
  [ "$status" -eq 0 ]
  # the counter, not just the exit code: kubeconform exits 0 over an EMPTY
  # directory too, so a render regression would read as a passing schema check
  contains "$output" 'Valid: 3'
  contains "$output" 'Invalid: 0'
}

@test "clean: the lint job is green (#1199)" {
  prepare kubernetes-repo
  run run_step lint @unnamed
  [ "$status" -eq 0 ]
  contains "$output" 'No lint errors found!'
}

@test "clean: the policy job passes AND runs the repo's kyverno fixtures (#1199)" {
  prepare kubernetes-repo
  run run_step policy 'kyverno apply + test'
  [ "$status" -eq 0 ]
  # `pass: 2`, not merely exit 0: `kyverno apply` also exits 0 when the rule
  # matched NOTHING, which is the vacuity this fixture's chart exists to prevent
  contains "$output" 'pass: 2, fail: 0'
  # and the fixtures ran — this variant ships kyverno-test.yaml, so the step
  # must reach `kyverno test` rather than taking the no-fixtures warning branch
  contains "$output" 'Test Summary: 1 tests passed and 0 tests failed'
  lacks "$output" 'no kyverno test fixtures'
}

@test "clean: the argocd job is green and does NOT select the foreign app (#1199)" {
  prepare kubernetes-repo
  run run_step argocd 'every app path this repo owns exists'
  [ "$status" -eq 0 ]
  lacks "$output" '::error::'
  # foreign-app.yaml points at charts/does-not-exist under a repoURL whose slug
  # has this variant's slug as a strict PREFIX. A filter that regressed to a
  # contains-style match would select it and name that path here.
  lacks "$output" 'charts/does-not-exist'
}

@test "clean: the argocd green is not vacuous — an owned dangling app reds it (#1199)" {
  # The other half of the negative control. The test above proves the filter is
  # not too WIDE; on its own it is equally consistent with a filter that selects
  # nothing at all — which is exactly what an unset or mis-set REPO_SLUG
  # produces, and the failure every fixture README warns about. Planting an
  # Application this repo DOES own, pointing at a path that does not exist,
  # proves the filter is not too NARROW either.
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
  run run_step argocd 'every app path this repo owns exists'
  [ "$status" -ne 0 ]
  contains "$output" '::error::app-of-apps references missing path: charts/injected-missing'
}

@test "clean: the COMMITTED app-of-apps.yaml is what the filter selects (#1199)" {
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
  run run_step argocd 'every app path this repo owns exists'
  [ "$status" -ne 0 ]
  contains "$output" '::error::app-of-apps references missing path: charts/app'
}

# ---------------------------------------------------------------------------
# The broken variant — every red attributable to one file and one check id
# ---------------------------------------------------------------------------

@test "broken: render and schema stay green — they own nothing here (#1199)" {
  prepare kubernetes-repo-broken
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "plain_broken_argocd_dangling-app.yaml plain_broken_argocd_dangling-multisource.yaml plain_broken_bad-registry.yaml plain_broken_latest-tag.yaml plain_broken_no-limits.yaml plain_broken_no-probe.yaml plain_policies_kyverno_kyverno-test.yaml plain_policies_kyverno_require-registry.yaml " ]
  run run_step schema @unnamed
  [ "$status" -eq 0 ]
  # the defects here are semantic, not structural — a schema red would be a
  # regression in the render job, never the fixture doing its job
  contains "$output" 'Invalid: 0'
}

@test "broken: the lint job reds with exactly the four documented check ids (#1199)" {
  prepare kubernetes-repo-broken
  run run_step lint @unnamed
  [ "$status" -ne 0 ]
  # EXACTLY four, so a manifest firing a second file's check — or a finding from
  # the Argo CD / policy documents that also land in RENDER_DIR — reds this too.
  # This is the "no extra findings" half; the PAIRING is the test below.
  contains "$output" 'found 4 lint errors'
  # bad-registry.yaml is the one row kube-linter must stay silent on: its defect
  # belongs to the policy job, and a lint finding there would collapse two rows
  # of the table into one file
  lacks "$output" 'plain_broken_bad-registry.yaml'
}

@test "broken: each lint finding is attributable to its own file and check id (#1199)" {
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
  # each row of the README's table: the file, the check id(s) it owns, and the
  # ids it must NOT carry
  # the EXTRACTED step, run once — not a hand-written kube-linter invocation.
  # This is #1199's central criterion, and every other behavioural test here
  # goes through run_step precisely so a template edit (a --config, a different
  # target) cannot leave the harness asserting against a command the pipeline no
  # longer runs.
  run run_step lint @unnamed
  [ "$status" -ne 0 ]
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

@test "broken: the policy job reds on the registry rule, before kyverno test (#1199)" {
  prepare kubernetes-repo-broken
  run run_step policy 'kyverno apply + test'
  [ "$status" -ne 0 ]
  # the COUNTER and the rule, not just the non-zero exit: `kyverno apply` also
  # exits non-zero on a bad path, an unloadable policy or a missing binary, and
  # the step can equally red on the dereference or the empty-selection gate
  contains "$output" 'fail: 1'
  contains "$output" 'bad-registry'
  # the AUTOGEN rule name — the policy matches kinds: [Pod] and these resources
  # are Deployments, so the generated name is what the output actually carries;
  # a harness grepping the authored `images-from-allowed-registry` alone would
  # match this substring by accident and prove nothing about autogen
  contains "$output" 'autogen-images-from-allowed-registry'
  # and the step ends there, under `set -euo pipefail` — this variant's
  # expected-FAIL kyverno fixture is therefore never reached by the pipeline,
  # which is why the test below runs it directly
  lacks "$output" 'Test Summary'
}

@test "broken: kyverno test passes directly — the fixture the pipeline never reaches (#1199)" {
  prepare kubernetes-repo-broken
  # `kyverno test` is unreachable through the policy step here (the apply above
  # ends it), so the expected-fail fixture would otherwise be shipped and never
  # executed by anything.
  run env PATH="$IAC_BIN:$PATH" kyverno test "$W/policies/kyverno/"
  [ "$status" -eq 0 ]
  contains "$output" '1 tests passed and 0 tests failed'
}

@test "broken: the argocd job reds naming BOTH dangling paths (#1199)" {
  prepare kubernetes-repo-broken
  run run_step argocd 'every app path this repo owns exists'
  [ "$status" -ne 0 ]
  # dangling-app.yaml, via the singular .spec.source
  contains "$output" '::error::app-of-apps references missing path: charts/does-not-exist'
  # dangling-multisource.yaml, via the multi-source .spec.sources[] — the leg
  # that would silently stop being read without a fixture that only uses it
  contains "$output" '::error::app-of-apps references missing path: charts/also-missing'
}

# ---------------------------------------------------------------------------
# The untested-policy variant — green, plus the finding
# ---------------------------------------------------------------------------

@test "untested-policy: render, schema, lint and argocd are green (#1199)" {
  prepare kubernetes-repo-untested-policy
  # The same render assertions the clean variant carries, and for the same
  # reason: without them a render regression that emitted only the sentinel
  # ConfigMap would leave schema, lint and argocd green here, and three of this
  # variant's four job assertions would be resting on nothing. The fixture's own
  # README is explicit that its chart exists precisely so this variant is never
  # evaluated vacuously.
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "helm_charts_app.yaml plain_policies_kyverno_require-registry.yaml " ]
  run cat "$W/$RDIR/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  contains "$output" 'rendered-by-helm'
  [ ! -e "$W/$RDIR/EMPTY.yaml" ]

  run run_step schema @unnamed
  [ "$status" -eq 0 ]
  # the counter, not the exit code alone — kubeconform exits 0 over an empty
  # directory too, the same trap the clean variant's schema test names
  contains "$output" 'Valid: 2'
  contains "$output" 'Invalid: 0'
  run run_step lint @unnamed
  [ "$status" -eq 0 ]
  contains "$output" 'No lint errors found!'
  run run_step argocd 'every app path this repo owns exists'
  [ "$status" -eq 0 ]
  lacks "$output" '::error::'
}

@test "untested-policy: the policy job warns about the missing fixtures and stays green (#1199)" {
  # split from the jobs above so a failure names WHICH job regressed — this one
  # carries the whole third acceptance criterion on its own
  prepare kubernetes-repo-untested-policy
  run run_step policy 'kyverno apply + test'
  # GREEN: an untested policy set is a maintenance finding to file, not a build
  # failure — the whole point of this variant
  [ "$status" -eq 0 ]
  contains "$output" '::warning::policies declared but no kyverno test fixtures'
  # and the policy was actually EVALUATED before the warning: `kyverno apply`
  # exits 0 both when the rule passed and when it matched nothing at all, so
  # only the counter tells a real green from the vacuity the chart exists to
  # prevent
  contains "$output" 'pass: 1, fail: 0'
}

# ---------------------------------------------------------------------------
# The copy discipline, and what is deliberately not asserted
# ---------------------------------------------------------------------------

# Every regular file under the three fixture variants, with a checksum. `cksum`
# reading STDIN prints only the checksum and size, so the manifest carries the
# repo-relative path exactly once and never the temp prefix — and cksum is POSIX,
# unlike `shasum`, which the debian-slim test image does not ship.
fixture_manifest() {
  local d f
  for d in "$FIXTURES"/kubernetes-repo "$FIXTURES"/kubernetes-repo-broken \
           "$FIXTURES"/kubernetes-repo-untested-policy; do
    find "$d" -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "${f#"$REPO_ROOT"/}" "$(cksum < "$f")"
    done
  done
}

@test "the destructive policy step never touches the committed fixtures (#1199)" {
  local before after variant
  before="$(fixture_manifest)"
  # a non-empty baseline, or the comparison below passes over nothing at all —
  # the vacuous-assertion shape this suite's own conventions forbid
  [ -n "$before" ]
  contains "$before" 'tests/fixtures/kubernetes-repo/policies/kyverno/require-registry.yaml'

  # the policy step is the destructive one: it `rm -rf`s policies/kyverno and
  # moves a dereferenced mirror over it. Run it for every variant, through the
  # same copy discipline every other test uses.
  for variant in kubernetes-repo kubernetes-repo-broken kubernetes-repo-untested-policy; do
    prepare "$variant"
    # the broken variant's policy step is EXPECTED to exit non-zero; the subject
    # here is the tree it ran against, not its verdict
    run run_step policy 'kyverno apply + test'
    # POSITIVE evidence that the destructive path actually executed. `[ -d
    # "$W/policies/kyverno" ]` alone proves nothing: that directory is in the
    # fixture BEFORE the step runs, so it is equally satisfied when run_step did
    # nothing at all — a renamed step, a kyverno missing from $IAC_BIN, an early
    # exit at the empty-selection gate — and the manifest comparison below would
    # then pass trivially, reporting a discipline nothing exercised.
    #
    # `pass:`/`fail:` is `kyverno apply`'s counter, printed only AFTER the
    # dereference, the policy-selection gate and the empty-selection gate have
    # all been passed. It is therefore the earliest output that can only exist
    # if the tree was dereferenced in place.
    matches "$output" 'pass: [0-9]+, fail: [0-9]+'
    [ -d "$W/policies/kyverno" ]
  done

  after="$(fixture_manifest)"
  [ "$before" = "$after" ]
}

@test "the render sentinel keeps an object-free repo GREEN through schema and lint (#1199)" {
  # The one corner of the pipeline whose design rests on an empirical claim about
  # a real tool: `kube-linter lint` errors with "no valid objects found" on a
  # tree containing none, which is why the render job writes a real ConfigMap
  # rather than a comment. #1154 can only check the sentinel's SHAPE with stubs;
  # whether kube-linter and kubeconform actually go green over a directory
  # holding nothing but that ConfigMap is checkable only here — and the three
  # fixtures all assert the sentinel is ABSENT, so this branch was asserted
  # against three times and executed zero times.
  #
  # No fourth committed fixture is needed: a chart whose only template is
  # value-gated off renders an object-FREE file, which is the side door the
  # template's own comment names (a file-count test would not see it).
  W="$BATS_TEST_TMPDIR/object-free"
  SLUG="fixture-org/object-free"
  RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp-object-free"
  mkdir -p "$W/charts/app/templates" "$RUNNER_TEMP" "$W/$RDIR"
  export RUNNER_TEMP
  printf '%s\n' 'apiVersion: v2' 'name: app' 'version: "0.1.0"' > "$W/charts/app/Chart.yaml"
  printf '%s\n' 'enabled: false' > "$W/charts/app/values.yaml"
  printf '%s\n' '{{- if .Values.enabled }}' 'apiVersion: v1' 'kind: ConfigMap' \
    'metadata:' '  name: gated' '{{- end }}' > "$W/charts/app/templates/configmap.yaml"

  run_step render 'helm template every top-level chart'
  run_step render 'kustomize build every overlay'
  run_step render 'copy standalone manifests so there is always something to validate'

  # The sentinel fired even though the directory is NOT empty: helm wrote a
  # zero-byte `helm_charts_app.yaml`. That is precisely why the template's guard
  # greps for `^kind:` across $RENDER_DIR rather than counting files — a
  # file-count test would see one file, skip the sentinel, and hand kube-linter
  # a tree with no valid objects.
  run rendered_files
  [ "$status" -eq 0 ]
  [ "$output" = "EMPTY.yaml helm_charts_app.yaml " ]
  # object-FREE, not byte-empty — helm writes a lone newline, which is exactly
  # why `[ ! -s ]` (or any file-count check) is the wrong probe here and the
  # template greps for a `kind:` instead
  run cat "$W/$RDIR/helm_charts_app.yaml"
  [ "$status" -eq 0 ]
  lacks "$output" 'kind:'

  # ...and both downstream validators accept it, which is the whole point: a
  # repo with nothing to render must not ship a permanently red required check
  run run_step schema @unnamed
  [ "$status" -eq 0 ]
  contains "$output" 'Valid: 1'
  contains "$output" 'Invalid: 0'
  run run_step lint @unnamed
  [ "$status" -eq 0 ]
  contains "$output" 'No lint errors found!'
}

@test "config-scan is unasserted by this harness, and only while it has no run: step (#1199)" {
  # The one job this file makes NO claim about — neither green nor red. It is a
  # third-party `aquasecurity/trivy-action`, so step extraction has nothing to
  # execute, and trivy's severity assignments move between releases anyway.
  # Recording that as an executable fact rather than a comment: the moment
  # config-scan grows a `run:` block it becomes executable, and this test fails
  # to say so rather than leaving a silently stale exemption behind.
  run yq -r '[.jobs."config-scan".steps[] | select(has("run"))] | length' "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run yq -r '[.jobs."config-scan".steps[] | select(has("uses")) | .uses] | join(" ")' "$TMPL"
  contains "$output" 'aquasecurity/trivy-action'
}

@test "REPO_SLUG is the only step-level env the executed steps need (#1199)" {
  # run_step supplies the job-level env plus REPO_SLUG. A step-level `env:` on
  # any OTHER executed step would be silently dropped, and the step would then
  # run here with a variable unset that it has on the runner — a divergence that
  # shows up as a confusing red, or worse as a green over a different code path.
  local job step keys job_step seen=0
  while IFS= read -r job_step; do
    seen=$(( seen + 1 ))
    job="${job_step%%|*}"
    step="${job_step#*|}"
    # the extraction itself must still resolve — a renamed step would otherwise
    # make every behavioural test above run `bash -c ""` and pass vacuously
    run step_script "$job" "$step"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "null" ]
    if [ "$step" = "@unnamed" ]; then
      keys="$(yq -r "[.jobs.\"$job\".steps[] | select(has(\"run\")) | select(has(\"name\") | not) | .env // {} | keys | .[]] | join(\" \")" "$TMPL")"
      # exactly ONE nameless run: step per job, or `@unnamed` is ambiguous and
      # step_script would concatenate two scripts into one bash -c
      run yq -r "[.jobs.\"$job\".steps[] | select(has(\"run\")) | select(has(\"name\") | not)] | length" "$TMPL"
      [ "$output" = "1" ]
    else
      keys="$(yq -r "[.jobs.\"$job\".steps[] | select(.name == \"$step\") | .env // {} | keys | .[]] | join(\" \")" "$TMPL")"
    fi
    case "$job_step" in
    'argocd|'*) [ "$keys" = "REPO_SLUG" ] ;;
    *) [ "$keys" = "" ] ;;
    esac
  done < <(executed_steps)
  # a roster that ever emitted nothing would run zero assertions and pass; the
  # sibling accounting test guards its own use of executed_steps the same way
  [ "$seen" -gt 0 ]

  # ...and the WORKFLOW-level env, which run_step supplies as a hardcoded
  # RENDER_DIR rather than deriving. A second top-level key would be silently
  # missing from every executed step here — an unbound-variable red under the
  # step's own `set -u`, naming nothing about the harness.
  run yq -r '.env | keys | join(" ")' "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = "RENDER_DIR" ]
}

@test "every run: step in the template is either executed here or a named exemption (#1199)" {
  # The converse of the config-scan guard, and the reason this file's header can
  # claim to execute the workflow at all. The executed roster is hand-written, so
  # without a derivation against the template a NEW `run:` step — a second render
  # pass, an `install jq`, a post-check summariser — would simply never be
  # executed while every test here stayed green, quietly turning the coverage
  # claim false. tests/bootstrap-iac-pipeline.bats derives its sweep's reach the
  # same way, for the same reason.
  #
  # NEITHER side is a hand-maintained number. The exemptions are named
  # individually, and `executed` is the LENGTH of the shared roster the
  # behavioural tests actually drive — so when a new `run:` step reds this, the
  # only ways to green it are to add the step to `executed_steps` (and execute
  # it) or to name it as an exemption. An earlier version made `executed` a
  # literal `7`, which could be bumped to 8 to restore green while reinstating
  # exactly the blind spot this test exists to close.
  local total exempt executed
  executed="$(executed_steps | grep -c .)"
  [ "$executed" -gt 0 ]
  total="$(yq -r '[.jobs[].steps[] | select(has("run"))] | length' "$TMPL")"
  [ -n "$total" ]

  # The install steps: deliberately not executed, because they curl into
  # /usr/local/bin. The harness supplies the same PINNED versions via
  # iac-tools.zsh instead, and the toolchain test above asserts that equivalence.
  local name
  exempt=0
  for name in 'install kubeconform' 'install kube-linter' 'install kyverno CLI' 'install yq'; do
    run yq -r "[.jobs[].steps[] | select(has(\"run\")) | select(.name == \"$name\")] | length" "$TMPL"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    exempt=$(( exempt + 1 ))
  done
  # (no `[ "$exempt" -eq 4 ]` here: exempt is incremented once per iteration of a
  # four-element literal list, and an iteration can only be skipped by an
  # assertion that already failed — so it could never hold any other value. The
  # accounting below is what actually constrains it.)

  # executed + exempt must account for EVERY run: step in the file
  [ "$total" -eq $(( executed + exempt )) ]
}
