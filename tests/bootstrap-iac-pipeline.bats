#!/usr/bin/env bats
#
# Behavioral tests for the bootstrap IaC check pipeline (epic #1150, child #1154)
# — `development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl`,
# the §3l bootstrap rules that emit it, and `branch-protection.sh --iac-only`,
# which turns its six jobs into required status checks.
#
# The template is the one artifact of this epic that becomes a *requirable status
# check* in a consumer repo, so the assertions are split deliberately:
#
#   * STRUCTURE (jobs, needs, artifact wiring, pins, tool invocations) is read
#     from the YAML with `yq`, not grepped. A substring sweep cannot tell
#     `needs: render` on the schema job from the same literal inside a comment.
#   * BEHAVIOUR is executed. Every `run:` step is extracted by name and run
#     against real directory shapes with recording stubs, because the failure
#     mode that matters here is not a crash but a VACUOUS PASS — a check that
#     goes green having validated nothing. Structure alone cannot see that.
#
# `yq` and `yamllint` are called unguarded (the tests/ops-api-fragment.bats
# precedent) and are declared dependencies in .github/workflows/script-tests.yml
# and tests/Dockerfile: an absent one should fail these red rather than silently
# skip the only coverage the template has.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  # the six checks, in pipeline order — the same list ARCHITECTURE.md, §3l and
  # branch-protection.sh's IaC mode state, asserted against the file that
  # actually produces them
  EXPECTED_JOBS="render schema lint policy config-scan argocd"
  W="$BATS_TEST_TMPDIR/repo"
  RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$W" "$RUNNER_TEMP" "$STUB_BIN"
  export RUNNER_TEMP
  # recorders created HERE, not inside a `run`-invoked helper: `run` is a
  # subshell, so a path assigned there is unset in the test body — and
  # `lacks "$(cat "$unset")"` is an EMPTY haystack that passes trivially, the
  # inert assertion tests/no-inert-*.bats exist to forbid
  CALLS="$BATS_TEST_TMPDIR/calls.txt"
  : > "$CALLS"
  export CALLS
  # DERIVED, not hardcoded: a renamed workflow-level env.RENDER_DIR would
  # otherwise leave every behavioural test passing against a value the workflow
  # no longer uses. `!= null` because `yq -r` prints the string "null" for an
  # absent key, which is non-empty and would sail past a bare [ -n ].
  RDIR="$(yq -r '.env.RENDER_DIR' "$TMPL")"
  # ONE assertion per line: `[ a ] && [ b ]` is an AND-list, so errexit never
  # sees the left test — an EMPTY $RDIR, the very case this guard exists for,
  # would short-circuit and setup would continue with RENDER_DIR unset
  [ -n "$RDIR" ]
  [ "$RDIR" != "null" ]
  make_stubs
}

# Recording stubs for the three CLIs the workflow drives. They record their full
# argv — "did the step reach the tool" is only half the question; "with which
# arguments" is what separates enforcement from a vacuous pass.
make_stubs() {
  cat > "$STUB_BIN/helm" <<'EOF'
#!/bin/sh
printf 'helm %s\n' "$*" >> "$CALLS"
case "$1" in
  template) printf 'apiVersion: apps/v1\nkind: Deployment\n'; exit "${HELM_EXIT_TEMPLATE:-0}" ;;
  dependency) exit "${HELM_EXIT_DEP:-0}" ;;
esac
exit 0
EOF
  cat > "$STUB_BIN/kustomize" <<'EOF'
#!/bin/sh
printf 'kustomize %s\n' "$*" >> "$CALLS"
case "$1" in
  build) printf 'apiVersion: v1\nkind: Service\n'; exit "${KUSTOMIZE_EXIT_BUILD:-0}" ;;
esac
exit 0
EOF
  # exit codes are parameterised: a stub that always succeeds cannot tell a step
  # that propagates kyverno's verdict from one that swallows it
  cat > "$STUB_BIN/kyverno" <<'EOF'
#!/bin/sh
printf 'kyverno %s\n' "$*" >> "$CALLS"
case "$1" in
  apply) exit "${KYVERNO_EXIT_APPLY:-0}" ;;
  test) exit "${KYVERNO_EXIT_TEST:-0}" ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN"/helm "$STUB_BIN"/kustomize "$STUB_BIN"/kyverno
}

# One `run:` script, extracted by job and step NAME.
#
# By name, not by index: an inserted step would silently shift an index and the
# behavioural tests would then exercise the install step, passing while
# asserting nothing about the guarantee they exist for.
step_script() {
  yq -r ".jobs.\"$1\".steps[] | select(.name == \"$2\") | .run" "$TMPL"
}

# Run one extracted step in $W with the runner variables the workflow supplies
# and the stubs on PATH. The workflow's default shell is bash, so `sh -c` would
# not do: several steps use process substitution.
run_step() {
  local script
  script="$(step_script "$1" "$2")"
  # `|| return 1`, not a bare `[ … ]`: a non-final test inside a helper invoked
  # through `run` has its status discarded, so a renamed step would run
  # `bash -c ""` and report success having executed nothing
  [ -n "$script" ] && [ "$script" != "null" ] || return 1
  # the render job's first step creates $RENDER_DIR; a step run in isolation
  # needs it to already exist, exactly as it would on the runner
  mkdir -p "$W/$RDIR"
  # the JOB-level env the workflow supplies, read from the template itself
  # rather than hardcoded — a test that invented its own KYVERNO_VERSION would
  # stop exercising the value consumers actually get
  local env_args
  env_args="$(yq -r ".jobs.\"$1\".env // {} | to_entries | map(.key + \"=\" + (.value|tostring)) | join(\" \")" "$TMPL")"
  (
    cd "$W" || exit 1
    # shellcheck disable=SC2086
    PATH="$STUB_BIN:$PATH" RENDER_DIR="$RDIR" env $env_args bash -c "$script"
  )
}

render_step() { run_step render "$1"; }
policy_step() { run_step policy 'kyverno apply + test'; }

# The §3l section of SKILL.md, whitespace-normalised and END-ANCHORED.
#
# A sed range whose end address stops matching prints to EOF, and `[ -n ]` still
# passes — so the haystack silently widens to include Step 5's IaC block, which
# itself names all six checks. Every §3l needle below would then pass with §3l
# deleted outright. The terminator is asserted by its caller for that reason.
iac_section() {
  sed -n '/^### 3l\. Infrastructure-as-code repos/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "the template lives at the nested .github/workflows path (#1154)" {
  # mirrors every other workflow template's layout (templates/public/.github/…),
  # which keeps the rendered destination obvious and the file inside the `.tmpl`
  # tree renovate.json's customManager (`/\.tmpl$/`) watches for action pins
  [ -f "$TMPL" ]
  case "$TMPL" in
  */templates/iac/.github/workflows/kubernetes-ci.yml.tmpl) : ;;
  *) return 1 ;;
  esac
}

@test "the template is valid YAML and passes the repo's own strict yamllint (#1154)" {
  # yamllint, not a bare parse: the template becomes a consumer repo's workflow,
  # and bootstrap installs a yamllint pre-commit hook there — a template that
  # only parses would fail that repo's very first commit.
  # -c explicitly: yamllint discovers .yamllint relative to the CWD, so without
  # it a run from anywhere but the repo root silently falls back to the DEFAULT
  # ruleset (line-length 80, document-start required, `on:` truthy) and reds —
  # and the assertion could not tell which config had applied
  [ -f "$REPO_ROOT/.yamllint" ]
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$TMPL"
  [ "$status" -eq 0 ]
}

@test "the workflow declares exactly the six named checks (#1154)" {
  # DERIVED from the file and count-guarded: asserting only that the six names
  # appear would accept a seventh job, silently widening the required-context set
  # branch-protection.sh --iac-only applies
  local jobs expected
  jobs="$(yq -r '.jobs | keys | .[]' "$TMPL" | LC_ALL=C sort | tr '\n' ' ')"
  expected="$(printf '%s\n' $EXPECTED_JOBS | LC_ALL=C sort | tr '\n' ' ')"
  [ "$jobs" = "$expected" ]
  # GitHub reports a status check under the job's `name:` when one is present,
  # falling back to the job id only when it is absent — and a matrix suffixes it.
  # Either would leave `.jobs | keys` (and branch-protection's context list)
  # unchanged while the reported check name differs: every PR on every consumer
  # repo pinned at `expected` forever.
  local job
  for job in $EXPECTED_JOBS; do
    [ "$(yq -r ".jobs.\"$job\".name // \"none\"" "$TMPL")" = "none" ]
    [ "$(yq -r ".jobs.\"$job\".strategy // \"none\"" "$TMPL")" = "none" ]
  done
}

@test "the workflow triggers on pull_request with no path filter (#1154)" {
  # the six checks are only requirable if they REPORT on a PR: a switch to
  # workflow_dispatch, or an added paths filter, would leave every structural
  # assertion green while branch protection blocked each PR on six checks that
  # never arrive
  local keys
  keys="$(yq -r '.on | keys | .[]' "$TMPL" | tr '\n' ' ')"
  [ "$keys" = "pull_request " ]
  [ "$(yq -r '.on.pull_request.paths // "none"' "$TMPL")" = "none" ]
  [ "$(yq -r '.on.pull_request["paths-ignore"] // "none"' "$TMPL")" = "none" ]
  # least privilege, one edit away from being widened unnoticed
  [ "$(yq -r '.permissions | keys | join(",")' "$TMPL")" = "contents" ]
  [ "$(yq -r '.permissions.contents' "$TMPL")" = "read" ]
}

@test "every check but render consumes the RENDERED artifact, by name and path (#1154)" {
  # the property the whole design rests on. `needs: render` alone only ORDERS
  # the jobs — a download whose name or path drifted from the upload leaves
  # kubeconform, kube-linter and trivy pointed at an empty directory: five
  # required checks green having validated nothing.
  local job needs up_name up_path dl_name dl_path
  [ "$(yq -r '.jobs.render.needs // "none"' "$TMPL")" = "none" ]
  up_name="$(yq -r '.jobs.render.steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with.name' "$TMPL")"
  up_path="$(yq -r '.jobs.render.steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with.path' "$TMPL")"
  # `yq -r` prints "null" for an absent key, so a bare [ -n ] passes on a
  # DELETED with.name — and the coupling check below would then compare
  # "null" to "null" and pass on a template with no artifact names at all
  [ "$up_name" = "rendered" ]
  [ "$up_path" = '${{ env.RENDER_DIR }}' ]
  for job in $EXPECTED_JOBS; do
    [ "$job" = "render" ] && continue
    needs="$(yq -r ".jobs.\"$job\".needs" "$TMPL")"
    [ "$needs" = "render" ]
    dl_name="$(yq -r ".jobs.\"$job\".steps[] | select(.uses // \"\" | test(\"^actions/download-artifact@\")) | .with.name" "$TMPL")"
    dl_path="$(yq -r ".jobs.\"$job\".steps[] | select(.uses // \"\" | test(\"^actions/download-artifact@\")) | .with.path" "$TMPL")"
    [ "$dl_name" != "null" ]
    [ "$dl_name" = "$up_name" ]
    [ "$dl_path" = '${{ env.RENDER_DIR }}' ]
  done
}

@test "every job that reads the SOURCE tree checks it out (#1154)" {
  # policy reads policies/kyverno/**; argocd resolves .spec.source.path against
  # the checkout; lint and config-scan read the consumer's own `.kube-linter.yaml`
  # / `.trivyignore` tuning files, which this template explicitly tells them they
  # may own. Drop the policy job's checkout and `find policies/kyverno` matches
  # nothing in every consumer repo — so the step takes the skip branch and
  # reports GREEN with the repo's declared policies never run.
  local job uses
  for job in render policy argocd lint config-scan; do
    uses="$(yq -r ".jobs.\"$job\".steps[].uses" "$TMPL")"
    printf '%s\n' "$uses" | grep -q '^actions/checkout@'
  done
  # schema needs only the artifact — kubeconform reads no repo-level config
  uses="$(yq -r '.jobs.schema.steps[].uses' "$TMPL")"
  run -1 sh -c "printf '%s\n' \"\$1\" | grep -q '^actions/checkout@'" _ "$uses"
}

@test "the render job uploads a non-hidden artifact and fails when it is empty (#1154)" {
  # two traps in one step: upload-artifact (>= v4.4) excludes hidden files by
  # default, so a `.rendered` work dir would upload NOTHING and every downstream
  # check would go green having validated nothing; and if-no-files-found must be
  # `error` so an empty render is a red build rather than a vacuous pass.
  local dir upload
  dir="$(yq -r '.env.RENDER_DIR' "$TMPL")"
  [ -n "$dir" ]
  [ "$dir" != "null" ]
  case "$dir" in .*) return 1 ;; esac
  upload="$(yq -r '.jobs.render.steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with["if-no-files-found"]' "$TMPL")"
  [ "$upload" = "error" ]
}

@test "the schema job runs kubeconform strictly, against the rendered tree (#1154)" {
  # the check IS the "renders an invalid manifest fails" criterion, and it is
  # only as strong as its flags: dropping -strict lets unknown fields through,
  # and retargeting from $RENDER_DIR to . validates the checkout's Go templates
  local runs
  runs="$(yq -r '.jobs.schema.steps[] | select(has("run")) | .run' "$TMPL")"
  contains "$runs" 'kubeconform'
  contains "$runs" '-strict'
  contains "$runs" '"$RENDER_DIR/"'
  # dropping this reds the schema check on every repo rendering a CRD instance —
  # a required check that could never go green, so it could never be required
  contains "$runs" '-ignore-missing-schemas'
  contains "$runs" '-summary'
  # ubuntu-latest ships none of these tools; without the install step the job
  # exits 127 and the check can never go green, so it can never be required
  contains "$runs" 'kubeconform-linux-amd64'
}

@test "the lint job runs kube-linter against the rendered tree (#1154)" {
  local runs
  runs="$(yq -r '.jobs.lint.steps[] | select(has("run")) | .run' "$TMPL")"
  contains "$runs" 'kube-linter lint "$RENDER_DIR/"'
  contains "$runs" 'kube-linter-linux.tar.gz'
}

@test "the policy job installs the kyverno CLI, versioned at JOB level (#1154)" {
  # ubuntu-latest ships none of these tools: without the install step the job
  # exits 127 and the check can never go green — so it can never be required,
  # which is the whole point of the slice. The behavioural policy tests run the
  # WORK step against a stub, so they are blind to the installer by construction.
  local runs
  runs="$(yq -r '.jobs.policy.steps[] | select(has("run")) | .run' "$TMPL")"
  contains "$runs" 'kyverno-cli_v'
  contains "$runs" '/usr/local/bin'
  # JOB-level, not step-level: the apply/test step interpolates the same version
  # into its error message, and a step-scoped env would leave it unset there —
  # fatal under `set -u`
  [ "$(yq -r '.jobs.policy.env.KYVERNO_VERSION' "$TMPL")" != "null" ]
}

@test "the argocd job installs mikefarah yq (#1154)" {
  # second instance of the same class; and it must be MIKEFARAH's, since the
  # step's expression uses `-o=json` and jq dialect
  local runs
  runs="$(yq -r '.jobs.argocd.steps[] | select(has("run")) | .run' "$TMPL")"
  contains "$runs" 'mikefarah/yq/releases/download'
  contains "$runs" 'chmod +x'
}

@test "the argocd step declares REPO_SLUG from github.repository (#1154)" {
  # the harness injects REPO_SLUG, so all eight argocd behavioural tests stay
  # green if the template's step env is deleted or renamed — while the real job
  # dies under `set -u` with "REPO_SLUG: unbound variable" on every consumer PR:
  # a required check that can never go green. The sibling case (the policy job's
  # job-level KYVERNO_VERSION) is asserted for exactly this reason.
  local slug
  slug="$(yq -r '.jobs.argocd.steps[] | select(.name == "every app path this repo owns exists") | .env.REPO_SLUG' "$TMPL")"
  # the repository EXPRESSION, not a hardcoded slug — the repoURL filter would
  # otherwise match nothing on every repo but the one it was baked for
  [ "$slug" = '${{ github.repository }}' ]
}

# The env-reference sweep, ONE implementation. Echoes three lines:
#   1) the violations string (empty when every reference is declared)
#   2) every reference it saw   3) how many run: steps it scanned
#
# Extracted so the positive test and its NEGATIVE CONTROL exercise the SAME
# code. A control that re-implements the sweep only vouches for its own copy:
# the moment the real sweep's regex or allowlist is edited and the copy is not,
# the control keeps passing while the sweep it certifies is broken.
env_sweep() {
  local tmpl="$1"
  local violations="" seen="" scanned=0
  local job n i script refs assigned undeclared declared
  while IFS= read -r job; do
    n="$(yq -r ".jobs.\"$job\".steps | length" "$tmpl")"
    for ((i = 0; i < n; i++)); do
      # comment lines stripped first: SETUP.md's `curl -u "$VAR"` example is
      # prose, not an interpolation the runner has to satisfy
      script="$(yq -r ".jobs.\"$job\".steps[$i].run // \"\"" "$tmpl" | grep -vE '^[[:space:]]*#')"
      [ -n "$script" ] || continue
      # LC_ALL=C throughout, on BOTH the sorts and the comms: `assigned` is
      # deliberately MIXED CASE (POLICY_SRC, kind_re, rel), the one shape where
      # locale collation and byte order disagree — and a comm that decides its
      # input is unsorted ABORTS, which would empty every violation set and pass
      # having checked nothing.
      refs="$(printf '%s\n' "$script" \
        | grep -oE '\$\{?[A-Z_][A-Z0-9_]*\}?|env\.[A-Z_][A-Z0-9_]*' \
        | tr -d '${}' | sed 's/^env\.//' | LC_ALL=C sort -u)"
      assigned="$(printf '%s\n' "$script" \
        | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=|read -r [A-Za-z_][A-Za-z0-9_]*' \
        | sed -E 's/^[[:space:]]*//; s/=$//; s/^read -r //' | LC_ALL=C sort -u)"
      declared="$( { yq -r '.env // {} | to_entries | .[].key' "$tmpl"
                     yq -r ".jobs.\"$job\".env // {} | to_entries | .[].key" "$tmpl"
                     yq -r ".jobs.\"$job\".steps[$i].env // {} | to_entries | .[].key" "$tmpl"
                   } | LC_ALL=C sort -u)"
      # NO `|| true`: comm is last in the pipeline, so its status is the
      # pipeline's, and swallowing it is exactly how this sweep would go inert
      undeclared="$(LC_ALL=C comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$assigned") \
        | grep -vE '^(RUNNER_TEMP|GITHUB_[A-Z_]*|HOME|PATH|PWD|IFS)?$' \
        | LC_ALL=C comm -23 - <(printf '%s\n' "$declared"))"
      [ -z "$undeclared" ] || violations="$violations $job[$i]:$(echo $undeclared)"
      seen="$seen $(echo $refs)"
      scanned=$((scanned + 1))
    done
  done < <(yq -r '.jobs | to_entries | .[].key' "$tmpl")
  printf '%s\n%s\n%s\n' "$violations" "$seen" "$scanned"
}

@test "every env var a run: step interpolates is DECLARED somewhere (#1154)" {
  # BY CONSTRUCTION, not one installer at a time. Each behavioural test runs its
  # step with the harness supplying the variables, so deleting a step's `env:`
  # leaves every one of them green while the real job dies under `set -u` with
  # "unbound variable" — a required check that can never go green. Four separate
  # instances of that class were found one per review round; this sweep closes
  # the class, so a fifth installer is covered the day it is added.
  local out violations seen scanned
  out="$(env_sweep "$TMPL")"
  violations="$(sed -n 1p <<< "$out")"
  seen="$(sed -n 2p <<< "$out")"
  scanned="$(sed -n 3p <<< "$out")"
  [ -z "$violations" ] || {
    printf 'undeclared env references: %s\n' "$violations" >&2
    return 1
  }
  # POSITIVE CONTROL: an extraction that silently matched nothing would satisfy
  # the emptiness check above while asserting nothing at all — the inert
  # assertion this suite forbids. Every known interpolation must be in `seen`.
  contains "$seen" 'RENDER_DIR'
  contains "$seen" 'KUBECONFORM_VERSION'
  contains "$seen" 'KUBE_LINTER_VERSION'
  contains "$seen" 'KYVERNO_VERSION'
  contains "$seen" 'YQ_VERSION'
  contains "$seen" 'REPO_SLUG'
  # COVERAGE CONTROL: the needles above prove the regex is live, not that the
  # ITERATION reached every step — RENDER_DIR alone appears in six of them, so
  # a whole job could extract nothing and they would all still pass. Derive the
  # expected count from the template so the sweep's reach cannot silently shrink.
  [ "$scanned" -eq "$(yq -r '[.jobs[].steps[] | select(has("run"))] | length' "$TMPL")" ]
}

@test "the env-var sweep actually FIRES when a step's env is deleted (#1154)" {
  # NEGATIVE CONTROL — the sweep above asserts an EMPTY violation set, which is
  # exactly what a broken extraction also produces. Run THE SAME helper over a
  # template copy with one `env:` block stripped and require it to report the
  # missing key by name, so "no violations" is evidence rather than an artifact.
  local doctored
  doctored="$BATS_TEST_TMPDIR/doctored.yml"
  yq 'del(.jobs.schema.steps[] | select(has("env")) | .env)' "$TMPL" > "$doctored"
  # the strip must be real, or the control proves nothing
  [ "$(yq -r '.jobs.schema.steps[] | select(has("env")) | .env.KUBECONFORM_VERSION' "$doctored")" = "" ]
  local violations
  violations="$(sed -n 1p <<< "$(env_sweep "$doctored")")"
  contains "$violations" 'KUBECONFORM_VERSION'
  contains "$violations" 'schema['
}

@test "config-scan's trivy inputs keep the check able to FAIL (#1154)" {
  # trivy-action defaults to exit-code 0 — report, never fail. Dropping the
  # override, widening the severity band, or retargeting scan-ref each turns a
  # required status check permanently green.
  local with
  with="$(yq -r '.jobs["config-scan"].steps[] | select(.uses // "" | test("^aquasecurity/trivy-action@")) | .with | to_entries | map(.key + "=" + (.value|tostring)) | join(" ")' "$TMPL")"
  contains "$with" 'scan-type=config'
  contains "$with" 'exit-code=1'
  contains "$with" 'severity=HIGH,CRITICAL'
  contains "$with" 'scan-ref=${{ env.RENDER_DIR }}/'
}

@test "every action is pinned to a full commit SHA with a version comment (#1154)" {
  # the semgrep gate bootstrap installs in downstream repos BLOCKS mutable tags,
  # so a template floating on @v4 would ship consumers a workflow their own
  # quality gate flags on arrival. POSIX class, not `\s`: BSD grep (the macOS
  # bats leg) reads `\s` as a literal `s` and the sweep would match nothing.
  local lines line
  lines="$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$TMPL")"
  [ -n "$lines" ]
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge 7 ]
  while read -r line; do
    matches "$line" 'uses: [^@]+@[0-9a-f]{40} # '
  done <<< "$lines"
}

@test "the template carries no bootstrap substitution placeholder (#1154)" {
  # §3l promises it renders byte-for-byte with no render.zsh flags. Adding a
  # {{DEFAULT_BRANCH}} later would falsify that silently — bootstrap would emit
  # it unsubstituted and trip the leftover check in the consumer's repo.
  run -1 grep -nE '\{\{[A-Z][A-Z0-9_]*\}\}' "$TMPL"
  # the GitHub expressions the file DOES rely on are still there, so the
  # assertion above cannot be satisfied by an empty/mangled file
  run grep -c '\${{ env.RENDER_DIR }}' "$TMPL"
  [ "$output" -ge 5 ]
}

# ---------------------------------------------------------------------------
# Behaviour — render job
# ---------------------------------------------------------------------------

@test "render/helm: a TOP-LEVEL charts/ collection is rendered, a vendored subchart is not (#1154)" {
  # the distinction the step's own comment calls out: a blanket
  # `-not -path '*/charts/*'` would skip the most common GitOps layout, helm
  # would render nothing, and every check would pass green on unvalidated charts
  mkdir -p "$W/charts/app" "$W/svc/charts/sub"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'apiVersion: v2\nname: svc\nversion: 0.1.0\n' > "$W/svc/Chart.yaml"
  printf 'apiVersion: v2\nname: sub\nversion: 0.1.0\n' > "$W/svc/charts/sub/Chart.yaml"
  run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'helm template charts-app ./charts/app'
  contains "$(cat "$CALLS")" 'helm template svc ./svc'
  lacks "$(cat "$CALLS")" 'svc/charts/sub'
  [ -f "$W/$RDIR/helm_charts_app.yaml" ]
  [ ! -f "$W/$RDIR/helm_svc_charts_sub.yaml" ]
}

@test "render/helm: a library chart is skipped, quoted or not (#1154)" {
  # `helm template` refuses a library chart outright, so failing to skip it reds
  # the render job — and every other job needs: render. `type: "library"` is
  # ordinary house style (yamllint's quoted-strings), so both spellings must skip.
  mkdir -p "$W/charts/common" "$W/charts/quoted" "$W/charts/ok"
  printf 'apiVersion: v2\nname: common\ntype: library\nversion: 0.1.0\n' > "$W/charts/common/Chart.yaml"
  printf 'apiVersion: v2\nname: quoted\ntype: "library"\nversion: 0.1.0\n' > "$W/charts/quoted/Chart.yaml"
  # POSITIVE CONTROL: without a chart that IS rendered, an empty $CALLS — from a
  # broken find, a mis-pathed fixture, or a step that skipped everything — would
  # satisfy the `lacks` needles just as well as the skip under test
  printf 'apiVersion: v2\nname: ok\nversion: 0.1.0\n' > "$W/charts/ok/Chart.yaml"
  run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'helm template charts-ok ./charts/ok'
  lacks "$(cat "$CALLS")" 'charts/common'
  lacks "$(cat "$CALLS")" 'charts/quoted'
}

@test "render/helm: charts differing only by _ vs / do not overwrite each other (#1154)" {
  # the `_`→`__` escaping: without it services/a_b and services/a/b collapse onto
  # one filename and one chart is silently never validated
  mkdir -p "$W/services/a_b" "$W/services/a/b"
  printf 'apiVersion: v2\nname: ab\nversion: 0.1.0\n' > "$W/services/a_b/Chart.yaml"
  printf 'apiVersion: v2\nname: b\nversion: 0.1.0\n' > "$W/services/a/b/Chart.yaml"
  run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  [ "$(find "$W/$RDIR" -name 'helm_*' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "render/helm: a ROOT chart renders under a valid release name (#1154)" {
  # `helm template . .` is an invalid release name, so a root chart would red the
  # job; the derivation must yield `root`
  printf 'apiVersion: v2\nname: root\nversion: 0.1.0\n' > "$W/Chart.yaml"
  run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'helm template root .'
  [ -f "$W/$RDIR/helm_root.yaml" ]
}

@test "render/kustomize: all three marker filenames are discovered (#1154)" {
  # finding only kustomization.yaml leaves the others unrendered AND lets them be
  # scooped up as "standalone manifests" — kustomize INPUTS validated as output
  mkdir -p "$W/a" "$W/b" "$W/c"
  printf 'resources: []\n' > "$W/a/kustomization.yaml"
  printf 'resources: []\n' > "$W/b/kustomization.yml"
  printf 'resources: []\n' > "$W/c/Kustomization"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'kustomize build' <<< "$(cat "$CALLS")")" -eq 3 ]
  [ "$(wc -l < "$RUNNER_TEMP/kustomize-roots.txt" | tr -d ' ')" -eq 3 ]
}

@test "render/kustomize: a base consumed by two overlays is not built, and errexit does not fire (#1154)" {
  # THE canonical layout, and the regression that made it red: the inner
  # consumed-scan loop returns its last body command's status, so an AND-list
  # form killed the whole step under `set -e` on any repo with two sibling
  # overlays — every downstream check then never ran.
  mkdir -p "$W/base" "$W/overlays/dev" "$W/overlays/prod"
  printf 'resources: []\n' > "$W/base/kustomization.yaml"
  printf 'resources:\n  - ../../base\n' > "$W/overlays/dev/kustomization.yaml"
  printf 'resources:\n  - "../../base"\n' > "$W/overlays/prod/kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kustomize build ./overlays/dev'
  # the quoted ref must resolve too — an unstripped quote makes the cd fail, the
  # base reads as unconsumed, and its deliberately partial output reds kube-linter
  contains "$(cat "$CALLS")" 'kustomize build ./overlays/prod'
  lacks "$(cat "$CALLS")" 'kustomize build ./base'
  # …but the base IS recorded as a root, which is what excludes its files from
  # the standalone sweep
  contains "$(cat "$RUNNER_TEMP/kustomize-roots.txt")" './base'
}

@test "render/kustomize: a local ref that merely STARTS with http is still consumed (#1154)" {
  # the scheme guard is anchored on `*://*`, NOT on a bare `http*` prefix, and
  # the template's comment says so — but nothing executed it. `- httpbin` is an
  # ordinary local resource ref (httpbin is a canonical example service);
  # narrowing the case back to `http*` would skip it, leave the root it names
  # reading as unconsumed, and build it standalone — whose deliberately partial
  # output reds kube-linter on a legitimate repo.
  # the ref must itself begin with `http` for the guard to be exercised — a
  # `../../httpbin` entry starts with `..` and would pass under either pattern,
  # proving nothing. A bare sibling name is the shape that discriminates.
  mkdir -p "$W/overlays/dev/httpbin"
  printf 'resources: []\n' > "$W/overlays/dev/httpbin/kustomization.yaml"
  printf 'resources:\n  - httpbin\n' > "$W/overlays/dev/kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  # the positive control — without it, a step that built nothing at all passes
  contains "$(cat "$CALLS")" 'kustomize build ./overlays/dev'
  lacks "$(cat "$CALLS")" 'kustomize build ./overlays/dev/httpbin'
}

@test "render/kustomize: a REMOTE ref is skipped without breaking local consumption (#1154)" {
  # the other half of the same guard: a genuine `scheme://` entry must not be
  # cd'd into, and its presence must not stop the sibling local ref from marking
  # its base consumed. Dropping the `*://*` arm makes the remote ref a failed cd
  # — silent today, but it is what the arm is for.
  mkdir -p "$W/base" "$W/overlays/dev"
  printf 'resources: []\n' > "$W/base/kustomization.yaml"
  printf 'resources:\n  - https://github.com/acme/base?ref=v1\n  - ../../base\n' \
    > "$W/overlays/dev/kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kustomize build ./overlays/dev'
  lacks "$(cat "$CALLS")" 'kustomize build ./base'
}

@test "render/kustomize: a base consumed only via a COMPONENT is not built (#1154)" {
  # the consumed-scan reads kustomize-ROOTS.txt, not kustomize-buildable.txt,
  # precisely so a Component still counts as a consumer. Swap the loop's input
  # to the buildable list and this base reads as unconsumed and is built
  # standalone — its deliberately partial output then reds kube-linter on every
  # consumer PR. Nothing exercised that until now.
  mkdir -p "$W/base" "$W/comp" "$W/overlays/dev"
  printf 'resources: []\n' > "$W/base/kustomization.yaml"
  printf 'kind: Component\nresources:\n  - ../base\n' > "$W/comp/kustomization.yaml"
  printf 'resources: []\n' > "$W/overlays/dev/kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  # the positive control — without it the two `lacks` run against an empty $CALLS
  contains "$(cat "$CALLS")" 'kustomize build ./overlays/dev'
  lacks "$(cat "$CALLS")" 'kustomize build ./base'
  lacks "$(cat "$CALLS")" 'kustomize build ./comp'
  # and the Component really WAS recorded as a root, which is what makes the
  # base count as consumed
  [ "$(wc -l < "$RUNNER_TEMP/kustomize-roots.txt" | tr -d ' ')" -eq 3 ]
}

@test "render/kustomize: a Component is recorded but never built, quoted or not (#1154)" {
  # kustomize rejects a standalone Component, so building it reds the job — while
  # its directory still holds partial patches the plain sweep must exclude
  mkdir -p "$W/comp" "$W/comp-quoted"
  printf 'kind: Component\nresources: []\n' > "$W/comp/kustomization.yaml"
  printf 'kind: "Component"\nresources: []\n' > "$W/comp-quoted/kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  lacks "$(cat "$CALLS")" 'kustomize build'
  # './comp' is a PREFIX of './comp-quoted', so a substring needle for the first
  # is satisfied by the second alone — the count is what discriminates
  [ "$(wc -l < "$RUNNER_TEMP/kustomize-roots.txt" | tr -d ' ')" -eq 2 ]
  contains "$(cat "$RUNNER_TEMP/kustomize-roots.txt")" './comp-quoted'
}

@test "render/copy: chart-owned and kustomize-input files are excluded (#1154)" {
  # copying a chart's templates/*.yaml would feed Go templates to kubeconform and
  # red every real chart repo — the opposite of "validate rendered output"
  mkdir -p "$W/chart/templates" "$W/base" "$W/apps"
  # both carry a top-level `kind:`, or they never match the sweep's own
  # `grep -lE '^kind:'` pre-filter and the -not -name prunes under test are never
  # reached — the assertions below would then pass with both prunes deleted
  printf 'apiVersion: v2\nname: c\nversion: 0.1.0\nkind: Chart\n' > "$W/chart/Chart.yaml"
  printf 'kind: Deployment\nreplicas: 1\n' > "$W/chart/values.yaml"
  printf 'kind: Deployment\nname: {{ .Release.Name }}\n' > "$W/chart/templates/deploy.yaml"
  printf './base\n' > "$RUNNER_TEMP/kustomize-roots.txt"
  printf 'kind: Deployment\n' > "$W/base/partial.yaml"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  run render_step 'copy standalone manifests so there is always something to validate'
  [ "$status" -eq 0 ]
  [ -f "$W/$RDIR/plain_apps_app.yaml" ]
  [ ! -f "$W/$RDIR/plain_chart_templates_deploy.yaml" ]
  [ ! -f "$W/$RDIR/plain_chart_values.yaml" ]
  [ ! -f "$W/$RDIR/plain_chart_Chart.yaml" ]
  [ ! -f "$W/$RDIR/plain_base_partial.yaml" ]
  # a real manifest was copied, so no sentinel is owed
  [ ! -f "$W/$RDIR/EMPTY.yaml" ]
}

@test "render/copy: an object-free tree gets a VALID sentinel object (#1154)" {
  # if-no-files-found: error makes an empty render red, and this branch is what
  # makes that survivable for an Argo-CD-only repo. It must be an OBJECT: kube-
  # linter errors with "no valid objects found" on a tree containing none, so a
  # comment-only sentinel would red the lint check in the corner it exists for.
  : > "$RUNNER_TEMP/kustomize-roots.txt"
  run render_step 'copy standalone manifests so there is always something to validate'
  [ "$status" -eq 0 ]
  [ -f "$W/$RDIR/EMPTY.yaml" ]
  [ "$(yq -r '.kind' "$W/$RDIR/EMPTY.yaml")" = "ConfigMap" ]
}

@test "render/copy: a rendered file with no objects still gets the sentinel (#1154)" {
  # the side door a file-count test cannot see: a chart whose manifests are all
  # value-gated off renders an object-FREE file, which leaves $RENDER_DIR
  # non-empty while kube-linter still finds nothing to lint
  : > "$RUNNER_TEMP/kustomize-roots.txt"
  mkdir -p "$W/$RDIR"
  printf -- '---\n# everything was disabled by values\n' > "$W/$RDIR/helm_app.yaml"
  run render_step 'copy standalone manifests so there is always something to validate'
  [ "$status" -eq 0 ]
  [ -f "$W/$RDIR/EMPTY.yaml" ]
}

@test "render: a FAILING helm template reds the step (#1154)" {
  # appending `|| true` here — mirroring the deliberate `|| true` on the adjacent
  # dependency-build line — would leave every other helm test green while every
  # downstream check validated a file that was never written
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  HELM_EXIT_TEMPLATE=1 run render_step 'helm template every top-level chart'
  [ "$status" -ne 0 ]
  contains "$(cat "$CALLS")" 'helm template'
}

@test "render: a FAILING helm dependency build is TOLERATED (#1154)" {
  # the whole point of that line's `|| true`: a dependency-free chart makes the
  # command fail, and without the tolerance the render job would red on it
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  HELM_EXIT_DEP=1 run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'helm template charts-app ./charts/app'
}

@test "render: a FAILING kustomize build reds the step (#1154)" {
  mkdir -p "$W/overlays/dev"
  printf 'resources: []\n' > "$W/overlays/dev/kustomization.yaml"
  KUSTOMIZE_EXIT_BUILD=1 run render_step 'kustomize build every overlay'
  [ "$status" -ne 0 ]
  contains "$(cat "$CALLS")" 'kustomize build'
}

@test "the render job's steps run producer-before-consumer (#1154)" {
  # the three steps communicate through $RUNNER_TEMP/kustomize-roots.txt, which
  # the copy step reads with a redirect that hard-fails under errexit when
  # absent. Every behavioural test above runs ONE step in isolation and supplies
  # that file, so nothing else would notice the two being reordered — and the
  # render job would then red on every consumer repo.
  local names
  names="$(yq -r '.jobs.render.steps[] | .name // "uses"' "$TMPL" | tr '\n' '|')"
  matches "$names" 'helm template.*kustomize build.*copy standalone'
}

@test "render: the three steps in ORDER produce one artifact tree (#1154)" {
  # the end-to-end pairing the isolated tests cannot show: the roots-file
  # handoff, the exclusion of kustomize inputs, and the sentinel's absence when
  # real objects were rendered
  mkdir -p "$W/charts/app" "$W/base" "$W/overlays/dev" "$W/apps"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'resources: []\n' > "$W/base/kustomization.yaml"
  printf 'resources:\n  - ../../base\n' > "$W/overlays/dev/kustomization.yaml"
  printf 'kind: Deployment\n' > "$W/base/partial.yaml"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  run render_step 'helm template every top-level chart'
  [ "$status" -eq 0 ]
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  run render_step 'copy standalone manifests so there is always something to validate'
  [ "$status" -eq 0 ]
  [ -f "$W/$RDIR/helm_charts_app.yaml" ]
  [ -f "$W/$RDIR/kustomize_overlays_dev.yaml" ]
  [ -f "$W/$RDIR/plain_apps_app.yaml" ]
  # the base is a kustomize INPUT, recorded by step 2 and excluded by step 3
  [ ! -f "$W/$RDIR/plain_base_partial.yaml" ]
  [ ! -f "$W/$RDIR/EMPTY.yaml" ]
}

# ---------------------------------------------------------------------------
# Behaviour — policy job
# ---------------------------------------------------------------------------

@test "policy: an ABSENT policies/kyverno skips with a clear notice and stays green (#1154)" {
  # the story's headline criterion, and the DEFAULT state of every repo that has
  # not declared opinions yet: the never-fails guarantee has to survive its own
  # most common case
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" 'no policies declared'
  contains "$output" '::notice::'
  [ ! -s "$CALLS" ]
}

@test "policy: an EMPTY policies/kyverno skips exactly like an absent one (#1154)" {
  # the glob is the contract, not the directory's existence — a `-d` test would
  # red a repo that created the directory before writing its first policy
  mkdir -p "$W/policies/kyverno"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" 'no policies declared'
}

@test "policy: a .json-only policies/kyverno skips too (#1154)" {
  mkdir -p "$W/policies/kyverno"
  printf '{}\n' > "$W/policies/kyverno/not-a-policy.json"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" 'no policies declared'
}

@test "render/kustomize: an overlay DIRECTORY ending in a space is built intact (#1154)" {
  # This pins `IFS=` on the loops that read DIRECTORY paths back from
  # kustomize-roots.txt / kustomize-buildable.txt — the only lines in this
  # template that can END in whitespace, which is the sole shape a bare `read`
  # mangles when reading into one variable. A directory named `overlays/dev `
  # writes a line with a trailing blank; a bare `read` trims it and kustomize is
  # handed `./overlays/dev`, which does not exist, so render reds on a
  # legitimate repo. (A space INSIDE a path, e.g. `charts/app /Chart.yaml`, is
  # not trimmed — an earlier version of this test used that shape and passed
  # with `IFS=` stripped from every loop. The other seven loops read lines that
  # never end in whitespace, so their `IFS=` is hardening this cannot observe.)
  mkdir -p "$W/overlays/dev "
  printf 'resources: []\n' > "$W/overlays/dev /kustomization.yaml"
  run render_step 'kustomize build every overlay'
  [ "$status" -eq 0 ]
  # EXACT content, not contains + a lacks: the obvious negative needle
  # ('…/dev' + newline) can never match, because command substitution strips
  # trailing newlines and $CALLS holds one line here — it would pass
  # unconditionally. Exact equality reds on the trimmed path and needs no twin.
  [ "$(cat "$CALLS")" = 'kustomize build ./overlays/dev ' ]
}

@test "policy: a .json-only tree with a broken symlink still SKIPS, not reds (#1154)" {
  # the second conjunct of the unresolvable-set gate. `stripped` matches any
  # dangling link by NAME while `policies` matches only *.{yaml,yml}, so gating
  # on `stripped` alone would hard-red a .json-only tree carrying one unrelated
  # broken link — a tree this step's contract says must skip exactly like an
  # absent one. The false-red twin of the vacuous pass.
  mkdir -p "$W/policies/kyverno"
  printf '{}\n' > "$W/policies/kyverno/not-a-policy.json"
  ln -s ../../not-fetched/gone.yaml "$W/policies/kyverno/gone.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" 'no policies declared'
  # proves the strip DID fire — so the first conjunct was true and the second is
  # what kept the check green
  contains "$output" 'dropped unresolvable symlinks'
  lacks "$output" 'only unresolvable symlinks'
  [ ! -s "$CALLS" ]
}

@test "policy: a .yml-only policy set is ENFORCED against the RENDERED tree (#1154)" {
  # the asymmetric half of the glob, and the argument contract with it: dropping
  # --resource, or pointing it at the checkout, evaluates zero resources and
  # always passes — the rendered-output property this file exists to protect
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: require-registry\n' \
    > "$W/policies/kyverno/require-registry.yml"
  run policy_step
  [ "$status" -eq 0 ]
  lacks "$output" 'no policies declared'
  # the WHOLE invocation: the step deliberately applies a CURATED copy of the
  # policy documents, not the raw directory, because `kyverno apply` errors when
  # handed a non-policy document — and it evaluates the RENDERED tree. A needle
  # on the verb alone survives both regressions.
  contains "$(cat "$CALLS")" "kyverno apply $RUNNER_TEMP/policies/ --resource $RDIR/"
}

@test "policy: a QUOTED or comment-suffixed kind is still enforced (#1154)" {
  # an unquoted-only selector drops every policy file of a repo writing
  # kind: "ClusterPolicy" — and the step would then report on a policy set that
  # is in fact perfectly evaluable
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: "ClusterPolicy"  # signed images only\nmetadata:\n  name: q\n' \
    > "$W/policies/kyverno/quoted.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kyverno apply'
  lacks "$output" '::error::'
}

@test "policy: a VIOLATION reds the step (#1154)" {
  # the scoping half of the never-fails guarantee, pinned in prose by
  # kubernetes-plugin-skeleton.bats but behaviourally ungated until now:
  # appending `|| true` to kyverno apply would keep every other test green while
  # making the required check permanently vacuous
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  KYVERNO_EXIT_APPLY=1 run policy_step
  [ "$status" -ne 0 ]
  # evidence the red came from THIS branch: run_step itself returns 1 when the
  # step is renamed or missing, so a bare status check is satisfied by the
  # harness's own failure — the regression the by-name lookup exists to expose
  contains "$(cat "$CALLS")" 'kyverno apply'
}

@test "policy: a FAILING kyverno test reds the step (#1154)" {
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  printf 'name: p\npolicies:\n  - p.yaml\n' > "$W/policies/kyverno/kyverno-test.yaml"
  KYVERNO_EXIT_TEST=1 run policy_step
  [ "$status" -ne 0 ]
  contains "$(cat "$CALLS")" 'kyverno test policies/kyverno/'
}

@test "policy: declared policies with NO test fixtures warn, and do not fail (#1154)" {
  # an untested policy set is a maintenance finding (policy_tests ->
  # kubernetes-policy-triage), not a build failure: the six-check design names no
  # policy-tests check, so running `kyverno test` unconditionally would turn a
  # reportable gap into a hard red on every PR
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" '::warning::'
  contains "$output" 'no kyverno test fixtures'
  contains "$(cat "$CALLS")" 'kyverno apply'
  lacks "$(cat "$CALLS")" 'kyverno test'
}

@test "policy: fixtures present run kyverno test at the tree's ORIGINAL path (#1154)" {
  # policies/kyverno/, NOT $RUNNER_TEMP: `kyverno test` resolves each fixture's
  # policies:/resources: entries relative to the TEST FILE, so reading the tree
  # from where the mirror was built breaks every fixture that reaches outside it
  # — a hard red on a repo whose policies and fixtures are correct.
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  printf 'name: p\npolicies:\n  - p.yaml\n' > "$W/policies/kyverno/kyverno-test.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kyverno test policies/kyverno/'
  lacks "$(cat "$CALLS")" "kyverno test $RUNNER_TEMP"
  lacks "$output" 'no kyverno test fixtures'
}

@test "policy: a fixture reaching OUTSIDE the policy tree still resolves (#1154)" {
  # the regression the in-place dereference exists to prevent: relocating the
  # tree to $RUNNER_TEMP silently repoints `../../manifests/…` at a path that
  # does not exist. Pinned by the CLI's cwd + argument, which is what decides it.
  mkdir -p "$W/policies/kyverno" "$W/manifests"
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: d\n' \
    > "$W/manifests/deployment.yaml"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  printf 'name: p\npolicies:\n  - p.yaml\nresources:\n  - ../../manifests/deployment.yaml\n' \
    > "$W/policies/kyverno/kyverno-test.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kyverno test policies/kyverno/'
  # the escaping reference is still reachable from the tree the CLI was handed
  [ -f "$W/policies/kyverno/../../manifests/deployment.yaml" ]
}

@test "policy: a SYMLINKED policy set is enforced, not skipped (#1154)" {
  # the defect the cp -RL mirror exists to close. gather-kubernetes-findings.zsh
  # walks the policy side with -L and therefore REPORTS such a set, so a skip
  # here is a green required check over policies maintenance says are live.
  mkdir -p "$W/shared-policies" "$W/policies"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: shared\n' \
    > "$W/shared-policies/shared.yaml"
  ln -s ../shared-policies "$W/policies/kyverno"
  run policy_step
  [ "$status" -eq 0 ]
  lacks "$output" 'no policies declared'
  contains "$(cat "$CALLS")" "kyverno apply $RUNNER_TEMP/policies/ --resource $RDIR/"
}

@test "policy: fixtures behind a symlinked DIRECTORY reach kyverno test (#1154)" {
  # the half that `-L` alone could not deliver: the probe fired but the CLI's
  # own lstat-based walker would not descend the symlink, so the gate opened
  # onto a `kyverno test` that finds nothing and errors — a hard red on a
  # required check. Against the mirror both sides see the same real tree.
  mkdir -p "$W/shared-policies/nested" "$W/policies"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: n\n' \
    > "$W/shared-policies/nested/n.yaml"
  printf 'name: n\npolicies:\n  - n.yaml\n' > "$W/shared-policies/nested/kyverno-test.yaml"
  ln -s ../shared-policies "$W/policies/kyverno"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$(cat "$CALLS")" 'kyverno test policies/kyverno/'
  lacks "$output" 'no kyverno test fixtures'
  # dereferenced IN PLACE: real directories at the original path — the property
  # that lets the CLI's lstat-based walker descend it, without moving the tree
  # out from under any relative fixture reference
  [ ! -L "$W/policies/kyverno" ]
  [ -d "$W/policies/kyverno/nested" ]
  [ ! -L "$W/policies/kyverno/nested" ]
  # and the shared source is untouched — rm -rf removed the LINK, not the target
  [ -f "$W/shared-policies/nested/n.yaml" ]
}

@test "policy: an ENTIRELY unresolvable policy set REDS, it does not skip green (#1154)" {
  # the regression the strip introduced and this branch closes: deleting the
  # broken links leaves an empty tree, which looked identical to "no policies
  # declared" — a green required check over a set the maintenance gather (which
  # walks with -L) reports as present. Before the strip existed, cp -RL failed
  # here and the step reded correctly.
  mkdir -p "$W/policies/kyverno"
  ln -s ../../not-fetched/a.yaml "$W/policies/kyverno/a.yaml"
  ln -s ../../not-fetched/b.yaml "$W/policies/kyverno/b.yaml"
  run policy_step
  [ "$status" -ne 0 ]
  contains "$output" '::error::'
  contains "$output" 'only unresolvable symlinks'
  lacks "$output" 'no policies declared'
  [ ! -s "$CALLS" ]
}

@test "policy: stripped symlinks are REPORTED, never dropped silently (#1154)" {
  # the partial variant: some members resolvable, some not. The set is reduced
  # before kyverno sees it, so what was dropped has to be visible or the check
  # reports on a silently smaller policy set.
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  ln -s ../../not-fetched/gone.yaml "$W/policies/kyverno/gone.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  contains "$output" '::warning::'
  contains "$output" 'dropped unresolvable symlinks'
  contains "$output" 'gone.yaml'
  contains "$(cat "$CALLS")" 'kyverno apply'
}

@test "policy: the strip never reaches outside the policy tree (#1154)" {
  # -xtype l, not -L … -type l: -L DESCENDS a valid symlinked subdirectory, so
  # the deletion would remove files at their real location outside
  # policies/kyverno — `all -> ../..` would sweep the whole checkout.
  mkdir -p "$W/policies/kyverno" "$W/common-policies"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: s\n' \
    > "$W/common-policies/shared.yaml"
  ln -s ../../not-fetched/outside.yaml "$W/common-policies/outside.yaml"
  ln -s ../../common-policies "$W/policies/kyverno/shared"
  run policy_step
  # the nested broken link is NOT stripped (the strip does not descend a valid
  # symlinked directory), so it falls through to cp's typed error — the outcome
  # the charter prefers for a declared-but-unreadable set, and the reason the
  # strip must not use -L to "helpfully" reach it
  [ "$status" -ne 0 ]
  contains "$output" 'could not dereference'
  # THE POINT: nothing outside policies/kyverno was touched. Under `-L` the
  # sweep would have deleted this link at its real location in a tree the repo
  # shares with other consumers.
  [ -L "$W/common-policies/outside.yaml" ]
  [ -f "$W/common-policies/shared.yaml" ]
}

@test "policy: a DANGLING symlink under the tree does not red the check (#1154)" {
  # cp -RL cannot stat a dangling link and fails the whole copy, so without the
  # pre-strip a link into an unfetched submodule (or to a gitignored artifact)
  # would hard-red a required check over an entirely readable policy set.
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  ln -s ../../not-fetched/submodule.yaml "$W/policies/kyverno/dangling.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  lacks "$output" '::error::'
  lacks "$output" 'no policies declared'
  contains "$(cat "$CALLS")" 'kyverno apply'
}

@test "policy: a policies/kyverno that is a DANGLING symlink reds, not skips (#1154)" {
  # `[ -d ]` alone is FALSE for a dangling link, so the bare guard would take the
  # skip branch and report green over a policy set the repo declares. The
  # charter's single skip condition is "no matching file", which an unreadable
  # path does not satisfy.
  mkdir -p "$W/policies"
  ln -s ../nowhere-shared "$W/policies/kyverno"
  run policy_step
  [ "$status" -ne 0 ]
  contains "$output" '::error::'
  contains "$output" 'could not dereference'
  lacks "$output" 'no policies declared'
  # THE DISCRIMINATOR for `-mindepth 1`. Without it the dangling START POINT is
  # itself matched, stripped, and reported — cp then fails with the same typed
  # error and the same status, so every needle above passes either way. This is
  # the only observable difference between the guarded and unguarded forms.
  lacks "$output" 'dropped unresolvable symlinks'
  [ -L "$W/policies/kyverno" ]
}

@test "policy: a LEFTOVER dereference mirror does not nest the policy tree (#1154)" {
  # `rm -rf "$MIRROR"` before the copy: a stale mirror (a self-hosted runner
  # that does not clear its temp, a re-run) would make cp copy INTO it and the
  # swap install policies/kyverno/kyverno/** — every escaping fixture ref then
  # off by one level, the exact regression the in-place rework exists to prevent.
  mkdir -p "$W/policies/kyverno" "$W/policies/.kyverno-deref/stale"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  printf 'name: p\npolicies:\n  - p.yaml\n' > "$W/policies/kyverno/kyverno-test.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  [ -f "$W/policies/kyverno/p.yaml" ]
  [ ! -e "$W/policies/kyverno/kyverno" ]
  [ ! -e "$W/policies/kyverno/stale" ]
  contains "$(cat "$CALLS")" 'kyverno test policies/kyverno/'
}

@test "policy: nested policy paths keep their collision-safe flattened names (#1154)" {
  # the mirror rebased every path onto $RUNNER_TEMP; flattening the ABSOLUTE
  # path would carry the runner's temp prefix into every name. Relative
  # flattening keeps the `_`→`__` guarantee that services/a_b and services/a/b
  # do not collapse onto one file — silently applying only the last one.
  mkdir -p "$W/policies/kyverno/a/b" "$W/policies/kyverno/a_b"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: one\n' \
    > "$W/policies/kyverno/a/b/p.yaml"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: two\n' \
    > "$W/policies/kyverno/a_b/p.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  [ -f "$RUNNER_TEMP/policies/a_b_p.yaml" ]
  [ -f "$RUNNER_TEMP/policies/a__b_p.yaml" ]
}

@test "policy: a symlink CYCLE inside the tree is stripped, real policies still enforced (#1154)" {
  # a cycle is unresolvable exactly like a dangling link, so the pre-strip
  # removes it and the readable policies beside it are still evaluated. The
  # alternative — letting cp -RL die on it — would hard-red a required check
  # over a policy set that is perfectly enforceable.
  mkdir -p "$W/policies/kyverno"
  ln -s loop "$W/policies/kyverno/loop"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
  run policy_step
  [ "$status" -eq 0 ]
  lacks "$output" 'no policies declared'
  contains "$(cat "$CALLS")" 'kyverno apply'
  # the cycle is gone from the dereferenced tree, and the real policy survived
  # -L, not -e: `-e` FOLLOWS symlinks and is false for a self-referential link
  # whether or not the strip removed it — a tautology that reads as evidence
  [ ! -L "$W/policies/kyverno/loop" ]
  [ -f "$W/policies/kyverno/p.yaml" ]
}

@test "policy: YAML the pinned CLI cannot evaluate FAILS rather than passing green (#1154)" {
  # Kyverno 1.14 kinds (ValidatingPolicy, …) the pinned 1.13.4 cannot run. The
  # charter has exactly ONE skip condition — no matching file — so a declared set
  # this pipeline cannot evaluate is a failure to report, never a second silent
  # skip: a green required check over unenforced policies is the outcome the
  # whole mechanism-here-policy-in-the-consumer design forbids.
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: policies.kyverno.io/v1alpha1\nkind: ValidatingPolicy\nmetadata:\n  name: v\n' \
    > "$W/policies/kyverno/v.yaml"
  run policy_step
  [ "$status" -ne 0 ]
  contains "$output" '::error::'
  contains "$output" 'no Policy/ClusterPolicy'
  lacks "$output" 'no policies declared'
  [ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# Behaviour — argocd job
# ---------------------------------------------------------------------------

argocd_step() {
  local script
  script="$(step_script argocd 'every app path this repo owns exists')"
  [ -n "$script" ] && [ "$script" != "null" ] || return 1
  (
    cd "$W" || exit 1
    PATH="$STUB_BIN:$PATH" RENDER_DIR="$RDIR" REPO_SLUG="${REPO_SLUG:-acme/k8s}" \
      bash -c "$script"
  )
}

app() {
  mkdir -p "$W/apps"
  cat > "$W/apps/$1.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
spec:
  source:
    repoURL: https://github.com/${3:-acme/k8s}.git
    path: $2
EOF
}

@test "argocd: an app path that exists passes (#1154)" {
  mkdir -p "$W/charts/app"
  app ok charts/app
  run argocd_step
  [ "$status" -eq 0 ]
  lacks "$output" '::error::'
}

@test "argocd: an app path that does NOT exist fails the check (#1154)" {
  app dangling charts/gone
  run argocd_step
  [ "$status" -ne 0 ]
  contains "$output" 'app-of-apps references missing path'
}

@test "argocd: a multi-source Application's paths are checked too (#1154)" {
  # reading only .spec.source extracts zero paths from an Argo CD >= 2.6
  # multi-source app, so the check would pass vacuously on exactly the repos
  # with the most paths to verify
  mkdir -p "$W/apps"
  cat > "$W/apps/multi.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: multi
spec:
  sources:
    - repoURL: https://github.com/acme/k8s.git
      path: charts/missing
EOF
  run argocd_step
  [ "$status" -ne 0 ]
  contains "$output" 'charts/missing'
}

@test "argocd: a SIBLING repo's paths are not checked against this repo (#1154)" {
  # contains() would match acme/k8s-apps for slug acme/k8s and red the build on
  # paths that are correctly absent locally
  app sibling charts/elsewhere acme/k8s-apps
  # POSITIVE CONTROL: extraction must be demonstrably live, or "no error" is
  # equally satisfied by a run that extracted nothing at all
  mkdir -p "$W/charts/app"
  app mine charts/app
  run argocd_step
  [ "$status" -eq 0 ]
  lacks "$output" '::error::'
  lacks "$output" 'charts/elsewhere'
}

@test "argocd: an ApplicationSet's templated path is reported, not failed (#1154)" {
  mkdir -p "$W/apps"
  cat > "$W/apps/set.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: set
spec:
  template:
    spec:
      source:
        repoURL: https://github.com/acme/k8s.git
        path: '{{path}}'
EOF
  run argocd_step
  [ "$status" -eq 0 ]
  contains "$output" 'templated path not statically checkable'
}

@test "argocd: an unparseable file WARNS and does not fail the check (#1154)" {
  # per-file yq, precisely so one bad document cannot truncate the path list;
  # and the templates/ prune must keep chart Go-templates out of that path
  mkdir -p "$W/charts/app" "$W/chart/templates"
  app ok charts/app
  printf 'a: [unclosed\n' > "$W/broken.yaml"
  printf 'kind: Deployment\nname: {{ .Release.Name }}\n' > "$W/chart/templates/deploy.yaml"
  run argocd_step
  [ "$status" -eq 0 ]
  contains "$output" 'could not parse'
  contains "$output" 'broken.yaml'
  lacks "$output" 'templates/deploy.yaml'
}

@test "argocd: a non-compiling path expression REFUSES to report a vacuous pass (#1154)" {
  # the guard that exists because yq exits non-zero both for "this file will not
  # parse" and "this expression will not compile" — without it, an expression the
  # pinned yq rejected would warn on every file, extract nothing, and exit 0: a
  # required check permanently green while validating nothing
  app ok charts/app
  cat > "$STUB_BIN/yq" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/yq"
  run argocd_step
  [ "$status" -ne 0 ]
  contains "$output" 'refusing to report a vacuous pass'
}

@test "argocd: an Application in the RENDERED tree is checked, its chart template pruned (#1154)" {
  # the reason this job downloads the artifact at all: a very common app-of-apps
  # authors its Application documents AS a Helm chart, so the source copies are
  # Go templates (correctly pruned) and only the RENDERED ones carry real paths.
  # Add `-not -path "./$RENDER_DIR/*"` to the find — the same prune the copy step
  # three jobs above legitimately carries — and this check extracts zero paths
  # and exits 0 on exactly the repos it exists to scrutinise.
  mkdir -p "$W/$RDIR" "$W/argo-apps/templates"
  cat > "$W/$RDIR/helm_argo-apps.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rendered
spec:
  source:
    repoURL: https://github.com/acme/k8s.git
    path: charts/gone
EOF
  printf 'kind: Application\npath: {{ .Values.path }}\n' > "$W/argo-apps/templates/app.yaml"
  run argocd_step
  [ "$status" -ne 0 ]
  contains "$output" 'app-of-apps references missing path: charts/gone'
  lacks "$output" 'templates/app.yaml'
}

@test "argocd: each rendered file is parsed once, not twice (#1154)" {
  # the single `find .` start point: adding "$RENDER_DIR" back as a second one
  # lists every rendered file under two spellings that `sort -u` cannot collapse,
  # so each is parsed twice and every warning duplicated
  mkdir -p "$W/$RDIR"
  printf 'a: [unclosed\n' > "$W/$RDIR/broken.yaml"
  run argocd_step
  [ "$status" -eq 0 ]
  [ "$(grep -c 'could not parse' <<< "$output")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# branch-protection.sh --iac-only
# ---------------------------------------------------------------------------

protection_stubs() {
  CURL_DATA="$BATS_TEST_TMPDIR/curl-data.txt"
  : > "$CURL_DATA"
  export CURL_DATA
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view") echo "acme/gitops" ;;
  "auth token") echo "stub-token" ;;
esac
exit 0
EOF
  # records the PUT/PATCH payloads so the applied rule can be asserted rather
  # than inferred from the script's own log output
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ]; then
    # compacted to a single line: the PUT payload is multi-line JSON, so an
    # as-is append makes "the Nth payload" unreadable by line
    printf '%s' "$a" | jq -c . >> "$CURL_DATA" 2>/dev/null || printf '%s\n' "$a" >> "$CURL_DATA"
  fi
  prev="$a"
done
# parameterised like make_stubs' kyverno/helm exits: a stub that only ever
# returns 200 leaves the 403 fallback — the one arm that exits 0 WITHOUT
# applying the rule — completely unexercised
echo "${CURL_HTTP_STATUS:-200}"
exit 0
EOF
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
}

@test "branch-protection --iac-only requires the six kubernetes-ci checks and nothing else (#1154)" {
  # the point of the whole slice: a GitOps repo's branch protection can require
  # something that BUILDS. Requiring the language-app contexts instead would pin
  # every PR on checks no rendered workflow reports.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts expected
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  # EXACT equality, derived from the same list the template is checked against: a
  # substring sweep accepts a context renamed to `render-manifests`, which branch
  # protection would then require and no job would ever report
  expected="$(printf '%s\n' $EXPECTED_JOBS | LC_ALL=C sort | paste -sd, -)"
  [ "$contexts" = "$expected" ]
  lacks "$contexts" 'test-and-coverage'
  lacks "$contexts" 'sonarcloud'
  lacks "$contexts" 'license-fs'
}

@test "branch-protection --iac-only on a 403 prints the SIX contexts and exits 0 (#1154)" {
  # the only arm that exits 0 without applying the rule, and Step 5's IaC
  # checklist is keyed on it ("unless Step 4b hit its 403 fallback") — the suite
  # pinned that PROSE while nothing executed the branch. A regression that moved
  # the contexts rebuild after the PUT, or made this arm exit non-zero, would
  # keep every other test green while each no-admin IaC bootstrap either died
  # mid-run or told the user to hand-require the language-app set.
  protection_stubs
  CURL_HTTP_STATUS=403 run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  # a hand-applied rule is a legitimate outcome, so this must NOT be a failure
  [ "$status" -eq 0 ]
  contains "$output" '403'
  # ANCHOR on the fallback heredoc's own markers. The script prints
  # `Required checks:` plus the bulleted list UNCONDITIONALLY, before curl is
  # ever called, so a bare per-job needle over $output is green no matter what
  # the 403 arm does — delete the whole recipe and it would still pass. These
  # three strings exist only inside the heredoc.
  contains "$output" 'Required status checks:'
  contains "$output" 'Settings → Branches → Add rule'
  contains "$output" 'Allow auto-merge'
  # each job must appear TWICE — once in the pre-PUT list, once in the manual
  # recipe — so dropping the recipe's own enumeration reds this
  local job
  for job in $EXPECTED_JOBS; do
    [ "$(grep -c -- "• $job\$" <<< "$output")" -eq 2 ]
  done
  # the IaC set, not the language-app one — relaying the wrong bullets hands the
  # user a recipe for contexts their repo will never report
  lacks "$output" 'test-and-coverage'
  lacks "$output" 'sonarcloud'
}

@test "branch-protection --iac-only ignores every language-app context PRODUCER (#1154)" {
  # the flag guards three of them — the visibility case, the `image` context and
  # the CodeQL matrix — but a test passing --has-dockerfile false --has-codeql
  # false only discriminates the first. Hoisting either of the others outside the
  # guard would add contexts no kubernetes-ci job reports, and the six-name
  # equality above would never see it.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile true --has-ko true --has-codeql true \
    --codeql-languages "python javascript" --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  [ "$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | length')" -eq 6 ]
  lacks "$contexts" 'image'
  lacks "$contexts" 'analyze ('
}

@test "branch-protection --iac-only on the PRIVATE path drops Sonar and Trivy too (#1154)" {
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility private --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  [ "$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | length')" -eq 6 ]
  lacks "$contexts" 'sonarqube'
  lacks "$contexts" 'trivy-fs'
}

@test "branch-protection with an explicit --iac-only false is the language path (#1154)" {
  # the arm Step 4b's invocation block actually renders on a language repo — the
  # other test omits the flag entirely, so a guard keying on the flag's PRESENCE
  # rather than its value would pass both
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'test-and-coverage'
  contains "$contexts" 'sonarcloud'
  lacks "$contexts" 'render'
  lacks "$contexts" 'config-scan'
}

@test "branch-protection rejects an --iac-only value that is neither true nor false (#1154)" {
  # unvalidated, `--iac-only True` silently takes the language-app path — the
  # exact permanent-`expected` failure the flag exists to prevent, with no
  # diagnostic. --visibility is validated for the same reason.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only True --default-branch main
  [ "$status" -ne 0 ]
  contains "$output" '--iac-only must be true or false'
  [ ! -s "$CURL_DATA" ]
}

@test "branch-protection --iac-only still applies the rule AND the merge settings (#1154)" {
  # skipping the script wholesale on this path would leave the default branch
  # unprotected and — because allow_auto_merge lives here — put every IaC
  # bootstrap into Step 4e's "arming failed" branch
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local rule
  rule="$(head -1 "$CURL_DATA")"
  [ "$(jq -r '.required_linear_history' <<< "$rule")" = "true" ]
  [ "$(jq -r '.allow_force_pushes' <<< "$rule")" = "false" ]
  [ "$(jq -r '.allow_deletions' <<< "$rule")" = "false" ]
  [ "$(jq -r '.required_pull_request_reviews.required_approving_review_count' <<< "$rule")" -eq 1 ]
  contains "$(cat "$CURL_DATA")" '"allow_auto_merge":true'
  contains "$(cat "$CURL_DATA")" '"delete_branch_on_merge":true'
}

@test "branch-protection without --iac-only is unchanged (#1154)" {
  # the flag must be additive: every existing repo keeps the language-app set
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'test-and-coverage'
  contains "$contexts" 'sonarcloud'
  lacks "$contexts" 'render'
  lacks "$contexts" 'config-scan'
}

# ---------------------------------------------------------------------------
# bootstrap SKILL.md — the rules that emit all of the above
# ---------------------------------------------------------------------------

@test "bootstrap's §3l emits the template and declares primary: kubernetes (#1154)" {
  # the template is inert unless bootstrap knows when to write it; §3l is the
  # only site that says so, and nothing mechanical would notice its deletion
  local section
  section="$(iac_section)"
  [ -n "$section" ]
  # END-ANCHOR: without it a stopped end address prints to EOF and every needle
  # below could be satisfied by Step 5's IaC block instead
  ends_with "$section" '### Idempotency rules (apply for every file write) '
  contains "$section" 'templates/iac/.github/workflows/kubernetes-ci.yml.tmpl'
  contains "$section" '`.github/workflows/kubernetes-ci.yml`'
  contains "$section" 'primary: kubernetes'
  # the whole clause: a bare "language" needle is satisfied by prose that still
  # requires one, which is the acceptance criterion this section exists to meet
  contains "$section" 'Do **not** require an application language before bootstrapping'
  # RESOLVED, not detected: keyed on detection alone, a language the user names
  # in Q4 would not bind and a language repo would take the IaC path
  contains "$section" 'the resolved language set is empty'
  contains "$section" 'resolved meaning *after* Q4'
  # …and the NARROWING that detect-stack.sh implements: a detected language
  # takes the repo off this path whatever `.maintenance.yml` records, so the
  # record can veto but never grant. Unpinned, the mixed repo creeps back in and
  # every detection-keyed section fires for a pipeline this path never generates.
  contains "$section" 'does not override a detected'
  contains "$section" 'the **mixed repo**'
  contains "$section" '#1193'
  contains "$section" 'in the **negative** direction'
  contains "$section" 'any *other* value (a language, `claude-plugin`) means not this path'
  # the retired capability asserted GONE, so it cannot be silently reinstated
  lacks "$section" 'does not un-resolve it'
  # the conflict handling the {{PRIMARY}} row's parenthetical delegates here —
  # unpinned, that cross-reference could dangle while bootstrap silently
  # overwrote a recorded `primary: python` with `kubernetes`
  contains "$section" 'Surface that conflict rather than resolving it silently'
  contains "$section" 'never let Q4'
  contains "$section" 'the recorded value stands'
  # …and the rule's OPERATIVE CONSEQUENCE, not just its statement. The needles
  # above pin *that* a conflict is surfaced; this pins that the emission is
  # confined to this path. Drop the qualifier and the emission sentence reads
  # unconditionally — bootstrap would write `primary: kubernetes` over the
  # recorded `primary: python` it was just told to leave alone.
  contains "$section" 'and only here, never on the conflict path'
  # the charter boundary — bootstrap seeding policies would put the plugin in the
  # opinion business the whole design keeps it out of
  contains "$section" 'Do not create `policies/kyverno/`'
  # the exclusion, restated as ONE rule when case 1 was removed: a non-empty
  # resolved language set is decisive on its own, so the record cannot revive
  # the path. The retired two-case phrasing is asserted gone with it.
  contains "$section" 'the repo is not on this path, **whatever `.maintenance.yml` records**'
  contains "$section" 'the record vetoes, never grants'
  lacks "$section" 'When neither case above holds'
  # the exclusion's CONSEQUENCE, not only its condition. Pinning the condition
  # alone leaves the forbidden actions rewordable — a language repo could be
  # made to require six IaC contexts from a workflow this path never emitted,
  # which is the permanent-`expected` state --iac-only exists to prevent.
  contains "$section" 'do not emit this template, write `primary: kubernetes`, or'
  contains "$section" 'pass `--iac-only true`'
  # and the two-arm split itself: collapse it and the on-disk arm below (the
  # Known limitation) loses the branch it hangs off
  contains "$section" 'depends on whether'
  contains "$section" '`kubernetes-ci.yml` is already on disk'
  # the Known-limitation arm must carry the FULL guard inline — it is a
  # cross-reference target read standalone, and without the middle clause its
  # own condition describes the case-1 repo whose handling is the opposite
  # the Known-limitation arm, now stated without the retired middle clause
  contains "$section" 'since the record vetoes but never grants'
}

@test "bootstrap's §3l names the six checks and runs branch protection in IaC mode (#1154)" {
  # skipping branch-protection.sh entirely was the earlier design and it silently
  # dropped the merge settings auto-merge arming depends on; the retired
  # instruction is asserted gone so the flip cannot be reverted
  local section job
  section="$(iac_section)"
  [ -n "$section" ]
  for job in $EXPECTED_JOBS; do
    contains "$section" "\`$job\`"
  done
  contains "$section" '--iac-only true'
  contains "$section" 'Never skip the script on this path'
  # the pointer at Step 4.5 — the step that would otherwise UNDO the rule three
  # steps later, and the one clause tying the two sites together
  contains "$section" 'do not let Step 4.5 undo it'
  lacks "$section" 'do not run Step 4b'
  # the emitted set, stated rather than left to inference — 3b/3c select by
  # visibility with no language condition, so nothing else stops a model
  # rendering a quality workflow whose sonarcloud job needs a job that does not exist
  # POLARITY, not tokens: `contains 'quality-public.yml'` alone is satisfied by
  # the exact opposite instruction ("emit quality-public.yml"), which is the
  # regression this test exists to catch
  contains "$section" 'It does **not** emit any of'
  contains "$section" 'a workflow GitHub refuses to run'
  contains "$section" 'quality-public.yml'
  contains "$section" 'needs: test-and-coverage'
  # §3l's own statement of the outgrown-repo limitation: the fresh-bootstrap arm
  # reads this copy, and without a needle it could be deleted while State D's
  # pointer at it survived
  contains "$section" 'Known limitation — a repo that outgrows this slice'
  contains "$section" 'more contradiction surface than protection'
  # the two artifact classes review found missing from the first draft
  contains "$section" 'codeql-noop.yml'
  contains "$section" 'infra/sonarqube'
}

@test "Step 4b passes --iac-only through to branch-protection.sh (#1154)" {
  # §3l's instruction is only executable if the invocation block carries the flag
  local block
  block="$(sed -n '/^### 4b\. Branch protection/,/^### 4b\.5/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED like iac_section: a renumbered `### 4b.5` would run the range to
  # EOF and silently widen the haystack
  ends_with "$block" '### 4b.5. Workflow labels (`blocked`) '
  # the VALUE and the condition, not just the flag name — the block could
  # otherwise document `--iac-only false` on the IaC path and still pass
  contains "$block" '--iac-only "<true on the §3l IaC path'
  contains "$block" 'it requires the six `kubernetes-ci.yml` jobs **instead of**'
  # the no-other-primary qualifier the sibling sites carry. This is the site a
  # model reads when COMPOSING the invocation, so without it here the conflict
  # repo yields `--iac-only true` and requires six contexts from a workflow §3l
  # never rendered — every PR pinned on a permanent `expected`.
  contains "$block" 'no other `primary:` recorded'
  contains "$block" 'settles it `false` whatever the marker says'
  # RESOLVED, and the detected-language veto — the two halves of the narrowing
  contains "$block" 'empty RESOLVED language set (after Q4)'
  contains "$block" 'A detected language, or a recorded language'
}

@test "the --iac-only qualifier is stated identically at every restatement (#1154)" {
  # ONE rule, four sites: the value spec a model composes from, the script's own
  # header, the SETUP.md bullet the user reads, and Step 5's IaC preamble. Round
  # 8 reached State D but not these, which is how the sites drifted apart in the
  # first place — sweep the whole class rather than one instance per round.
  local protect setup step5
  # comment markers stripped BEFORE normalising: the header wraps mid-sentence,
  # so a `# ` lands inside every multi-line needle and no prose assertion could
  # ever match — the shape that makes a "pinned" rule silently unpinned
  protect="$(sed -E 's/^[[:space:]]*#[[:space:]]?//' "$PROTECT" | tr -s '[:space:]' ' ')"
  contains "$protect" 'no other `primary:` recorded'
  contains "$protect" 'settles it false whatever the marker says'
  setup="$(tr -s '[:space:]' ' ' \
    < "$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl")"
  contains "$setup" 'no application language and no other `primary:` recorded'
  # …and the six context NAMES. SETUP.md says of itself that branch-protection.sh
  # is the source of truth and this list mirrors it — but a rename reds the
  # template and branch-protection tests (forcing EXPECTED_JOBS to move) while
  # SETUP.md silently keeps the stale names, handing a no-admin user (the 403
  # path) a recipe for contexts no workflow reports.
  local job
  for job in $EXPECTED_JOBS; do
    contains "$setup" "\`$job\`"
  done
  step5="$(sed -n '/^For the \*\*IaC path\*\*/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$step5" 'no other `primary:` recorded'
}

@test "Step 3.6 stamps kubernetes-ci.yml with the template the drift detector expects (#1154)" {
  # the PRODUCER half of the provenance coupling. tests/template-drift-fixes.bats
  # pins the consumer (the `tracked` entry in detect-template-drift.zsh); this
  # pins the stamp that feeds it. Delete or mistype this row and every IaC
  # bootstrap ships an unstamped kubernetes-ci.yml, so the tracked entry is fed
  # a file with no marker forever. §3l names the template for the RENDER, never
  # for the STAMP, so this row is the only site that states the pairing.
  local row
  row="$(grep -F '| `.github/workflows/kubernetes-ci.yml` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" '`iac/.github/workflows/kubernetes-ci.yml.tmpl`'
}

@test "Step 5's IaC checklist exists and states what the path did NOT generate (#1154)" {
  # §3l delegates to it; without the block the user is pointed at a checklist
  # item that does not exist
  local block
  block="$(sed -n '/^For the \*\*IaC path\*\*/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED like every sibling section test: a renamed terminating heading
  # runs the range to EOF, and the bare-token needles this test used to carry
  # (`render` matches "rendered", `lint` matches "yamllint", `policy` matches
  # "approver-policy") would then be satisfied by unrelated prose with the block
  # deleted outright
  ends_with "$block" '## Important Rules '
  # the LIST as written, not the bare names
  contains "$block" 'The six required checks (render, schema, lint, policy, config-scan, argocd)'
  contains "$block" 'show as "expected" in Settings'
  contains "$block" 'no CodeQL'
  contains "$block" 'no CI backstop'
  # the 403 caveat: branch-protection.sh degrades to printed instructions and
  # exits 0, so an unconditional "not outstanding" claim leaves a no-admin repo
  # unprotected with no TODO
  contains "$block" 'unless Step 4b hit its 403 fallback'
  # the Dockerfile case the Step 2 IaC plan variant delegates here
  contains "$block" 'That image is NOT scanned in CI'
  # the re-run promise, which §3l case 1 makes FALSE: every §3l bootstrap records
  # `primary: kubernetes`, and case 1 honours that record over any language
  # detected later — so "add a language and re-run" picks up nothing. The retired
  # wording is asserted GONE, not merely replaced, since both could coexist.
  # true again under the narrowing: a detected language takes the repo off this
  # path, so a re-run DOES pick the language gates up — but say what it costs
  contains "$block" 'Add a language later and re-run bootstrap'
  contains "$block" 'takes the repo off this path'
  contains "$block" 'REPLACE the six IaC contexts'
}

@test "Step 4.5 skips the per-path automation that would UNDO --iac-only (#1154)" {
  # the highest-leverage prose gap in the change: automate-public.sh /
  # automate-private.sh re-invoke branch-protection.sh WITHOUT the flag, and
  # that PUT *replaces* the rule — so deleting this block leaves every IaC
  # bootstrap ending with the language-app contexts required again, three steps
  # after the code this suite otherwise covers.
  local block
  block="$(sed -n '/^### Per-path automation/,/^## Step 5/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  ends_with "$block" '## Step 5: Print the Manual-Setup Checklist '
  contains "$block" 'The §3l IaC path skips this section entirely'
  contains "$block" 'automate-public.sh'
  contains "$block" 'without `--iac-only`'
  contains "$block" 'run no `automate-*.sh`'
  # the scope of the skip, or a model cannot tell whether the preflight runs
  contains "$block" 'Scope: this section only'
  # the hardcoded --has-codeql "true" contradicted §3l, which emits no codeql.yml
  lacks "$block" '--has-codeql "true"'
}

@test "Q4 offers the IaC answer and refuses it without the marker (#1154)" {
  # the only door into §3l. Delete the positive half and no question ever
  # produces the empty resolved language set the path keys on; delete the
  # negative half and any language-less repo — marker or not — is bootstrapped
  # with six required checks whose workflow was never emitted.
  local row
  row="$(grep -F '| **Q4: Languages** |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'none — this is a GitOps/IaC repo'
  contains "$row" '**"None" is a valid answer for an IaC repo**'
  contains "$row" 'takes §3l, not a halt'
  contains "$row" '**"None" with `is_kubernetes=false`** is *not*'
  # …and a recorded `primary: kubernetes` must NOT skip the question: the record
  # vetoes this path but never grants it, so skipping would resolve a mixed repo
  # onto the IaC path without ever asking (#1193)
  contains "$row" 'does **not** skip it'
  lacks "$row" 'Skip it entirely when'
  # RESOLVED, the rule §3l and the {{PRIMARY}} table both depend on
  contains "$row" 'resolves the language set'
}

@test "Step 1's State-D gap-fill resolves the IaC condition before branch protection (#1154)" {
  # the re-bootstrap mirror of the Step 4.5 guard, and previously the one prose
  # site of this change with zero coverage. Deleting its branch-protection rule
  # reproduces the same unflagged PUT — six live contexts swapped for language-app
  # contexts nothing reports — just on the re-bootstrap path.
  local block
  # the end address must FOLLOW the start: `#### State D` sits ABOVE this
  # blockquote and occurs once, so using it printed to EOF — and two of the
  # needles below are satisfied by §3l and Step 4 inside that widened haystack,
  # which would have let the very instruction this test guards be deleted green
  # terminated on the first bullet AFTER the blockquote, not on a heading 250
  # lines further down: a wider haystack lets a needle be satisfied by unrelated
  # prose, which is how the earlier run-to-EOF version could not discriminate
  block="$(sed -n '/^   > \*\*The IaC set is NOT blind-renderable/,/^   - `branch_protection.state == "missing"`/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  ends_with "$block" '- `branch_protection.state == "missing"` → offer "Apply branch protection '
  # NOT the sed start address (that literal is in the haystack by construction and
  # could not fail) — the paragraph's substantive rules
  contains "$block" 'render it only on the confirmed "none" answer'
  contains "$block" 'Rendering it blind would commit the §3l shape'
  contains "$block" 'ask Q4 (IaC wording) **first**'
  # the condition, with the qualifier's binding made explicit
  contains "$block" '`kubernetes-ci.yml` is present **AND**'
  contains "$block" 'a recorded `primary: kubernetes` grants nothing on its own'
  # RESOLVED, not merely detected — and the ORDERING that makes it achievable.
  # This tree is ordered and step 3 runs before Q4 is asked in step 6, so keying
  # on detected languages PUTs the six IaC contexts and only then lets the user
  # name a language: a language repo whose rule requires none of its own checks.
  contains "$block" 'the **resolved** language set is empty'
  contains "$block" '**Resolved means after Q4**'
  contains "$block" 'ask Q4 (IaC wording) BEFORE invoking the script'
  contains "$block" 'A language answer settles `--iac-only false`'
  lacks "$block" 'no language is detected **AND**'
  # the third precedence arm, which the condition previously dropped
  contains "$block" 'no other `primary:` is recorded'
  # the block's OWN clause, not the bare flag — that occurs at five other lines
  contains "$block" 'invoke `branch-protection.sh` with **`--iac-only true`**'
  # and the genuinely-mixed case, which §3l excludes rather than claims
  # needles kept WITHIN a source line: the block is a markdown blockquote, so
  # whitespace-normalising leaves the `>` markers in place and any needle
  # spanning a line break would never match
  # a detected language takes the repo OFF this path whatever the record says —
  # the record vetoes but never grants. The repo that has genuinely outgrown the
  # slice is DELEGATED to §3l's Known limitation rather than given a special case
  # here, so the two cannot drift apart, and the mixed repo proper is #1193.
  # Needles kept WITHIN a source line — this is a markdown blockquote, so
  # whitespace-normalising leaves the `>` markers between wrapped lines.
  contains "$block" 'takes the repo OFF this path'
  contains "$block" 'can only veto, never grant'
  contains "$block" 'has outgrown this slice'
  contains "$block" 'adds no'
  # the retired grant-arm asserted GONE, so the mixed repo cannot creep back
  lacks "$block" 'PLUS a language now detected is still the'
}

@test "the {{PRIMARY}} table resolves the zero-language kubernetes case to kubernetes (#1154)" {
  # without the branch the placeholder cannot resolve to `kubernetes` however
  # clearly §3l states the rule — and the RESULT is the half a needle on
  # `is_kubernetes` alone would not pin
  local row
  row="$(grep -F '| `{{PRIMARY}}` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'is_kubernetes'
  # branch (2)'s target, now carrying its no-conflicting-primary qualifier
  contains "$row" 'records no other `primary:`'
  contains "$row" '→ `kubernetes`'
  contains "$row" 'Resolved, not detected'
  # branch (1) is UNQUALIFIED: a detected language wins over the marker whatever
  # the record says, which is the narrowing detect-stack.sh implements. The
  # retired grant-branch is asserted gone so it cannot be silently reinstated —
  # it is what made every detection-keyed section fire on a mixed repo (#1193).
  contains "$row" 'a detected language takes precedence over the kubernetes marker'
  contains "$row" '#1193'
  lacks "$row" 'whatever languages detection found'
  # ORDERING: branch (2) must follow the single-language branch, or a language
  # repo carrying manifests would be hijacked onto the IaC path
  matches "$row" '\(1\).*exactly one language.*\(2\).*is_kubernetes.*\(3\)'
}

@test "the decision-tree post-condition admits the IaC path's empty language list (#1154)" {
  # the gate that would otherwise halt the run before Step 3 ever reaches §3l
  local block
  block="$(sed -n '/^### After the decision tree/,/^## Step 2/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED: this is the one range in the file with no sibling test pinning
  # the same addresses, so a renumbered `## Step 2` would print to EOF and leave
  # every needle below judging the rest of SKILL.md
  ends_with "$block" '## Step 2: Show the Plan and Get Confirmation '
  lacks "$block" '- A non-empty languages list.'
  contains "$block" 'There an empty list is the answer, not a missing value'
  contains "$block" 'halting there would make §3l unreachable'
}

@test "this suite's own trees are listed in the PR path filter (#1154)" {
  # a tree a suite READS but the filter does not LIST runs no bats leg at PR
  # time — the defect tests/kubernetes-plugin-skeleton.bats already polices for
  # its own trees
  local wf
  wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  [ -f "$wf" ]
  contains "$(cat "$wf")" "'development/skills/bootstrap/templates/**'"
  contains "$(cat "$wf")" "'development/skills/**/SKILL.md'"
  # (the "declared on both legs" claim is made by the SCOPED assertions below.
  # A file-wide `contains 'yamllint'` was satisfied by this workflow's own
  # explanatory comment block — and by tests/Dockerfile's — so it could never
  # have caught a package being dropped: the bare-token-satisfied-by-prose
  # failure this suite names as its concern.)
  # yq must come from mikefarah, never Debian's python-yq: the two are different
  # query languages, and under python-yq `on:` parses as the boolean true and
  # `-o=json` is rejected — so the same assertions would mean different things on
  # the two CI legs. Pinned by URL rather than left to the image's PATH order.
  contains "$(cat "$wf")" 'mikefarah/yq/releases/download'
  contains "$(cat "$REPO_ROOT/tests/Dockerfile")" 'mikefarah/yq/releases/download'
  # whitespace-normalised, because both install lists are written across
  # CONTINUATION lines — a per-line grep anchored on `sudo apt-get install`
  # could never match a re-added `yq` and would pass forever. `[[:space:]]`,
  # never `\s`: BSD grep reads the latter as a literal `s`.
  local apt_pkgs docker_pkgs
  # scoped to the apt PACKAGE LIST — brew's `yq` IS mikefarah's, so a
  # file-wide needle would flag the correct macOS line. Cut at the first `#`
  # (the comment explaining the exclusion) and, for the Dockerfile, at `&&`.
  apt_pkgs="$(tr -s '[:space:]' ' ' < "$wf")"
  apt_pkgs="${apt_pkgs#*apt-get install}"
  apt_pkgs="${apt_pkgs%%#*}"
  [ -n "$apt_pkgs" ]
  contains "$apt_pkgs" ' yamllint'
  lacks "$apt_pkgs" ' yq '
  docker_pkgs="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/tests/Dockerfile")"
  docker_pkgs="${docker_pkgs#*apt-get install}"
  docker_pkgs="${docker_pkgs%%&&*}"
  [ -n "$docker_pkgs" ]
  contains "$docker_pkgs" ' yamllint'
  lacks "$docker_pkgs" ' yq '
  # the macOS leg, scoped the same way — and it is this repo's PRIMARY platform,
  # so leaving it to a file-wide needle meant dropping yamllint or yq from
  # `brew install` kept this test green while the macOS bats leg lost the only
  # tools bootstrap-iac-pipeline.bats calls unguarded
  local brew_pkgs
  brew_pkgs="$(tr -s '[:space:]' ' ' < "$wf")"
  brew_pkgs="${brew_pkgs#*brew install}"
  brew_pkgs="${brew_pkgs%%#*}"
  [ -n "$brew_pkgs" ]
  contains "$brew_pkgs" ' yamllint'
  contains "$brew_pkgs" ' yq'
}

@test "the yq on PATH is mikefarah's, the dialect every structural assertion assumes (#1154)" {
  # one legible failure instead of twenty confusing ones: python-yq would red the
  # trigger test (PyYAML resolves `on:` to true) and the argocd tests (`-o=json`
  # is not its flag), with nothing saying why
  run yq --version
  [ "$status" -eq 0 ]
  contains "$output" 'mikefarah'
}
