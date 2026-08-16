#!/usr/bin/env bats
#
# Behavioral tests for gather-kubernetes-findings.zsh (epic #1150, child #1152).
#
# These tests were written and run FAILING before the gather script existed —
# they pin the payload contract that the `development-kubernetes` maintenance
# dispatcher consumes, so the two cannot drift.
#
# The load-bearing distinction throughout: an UNCONFIGURED tool is ABSENT from
# `findings_by_tool` (the v2 contract in ARCHITECTURE.md), which is why the
# absence assertions use `has()` rather than a length check — `[] | length` is
# also 0, so a length assertion would make "not configured" and "configured and
# clean" indistinguishable, which is precisely the confusion this gather's
# policy skip must never create.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-kubernetes-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"
}

chart() {
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
}

kustomize() {
  # parameterised: the script matches all three spellings kustomize accepts, and
  # a helper hardcoding one would let either other -o -name clause be deleted
  mkdir -p "$W/overlays/prod"
  printf 'resources:\n  - ../../base\n' > "$W/overlays/prod/${1:-kustomization.yaml}"
}

argocd() {
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: app\n' \
    > "$W/apps/app.yaml"
}

policy() {
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yaml"
}

policy_test() {
  mkdir -p "$W/policies/kyverno"
  printf 'name: p-test\npolicies:\n  - p.yaml\n' > "$W/policies/kyverno/kyverno-test.yaml"
}

gather() { zsh "$GATHER" "$W"; }

# the orchestrator partitions on `test -x` and then EXECUTES the file, so the
# shebang is part of the contract; `zsh "$GATHER"` bypasses it
gather_directly() { "$GATHER" "$W"; }

@test "a Helm chart alone: manifest_validation configured, policy NOT configured (#1152)" {
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "false" ]
  # policy_tests tracks policy — it is the key the dispatcher's missing_tooling
  # exemption is defined over, so leaving it unasserted lets that exemption
  # silently change scope
  [ "$(echo "$output" | jq -r '.tooling_configured.policy_tests')" = "false" ]
  # the POSITIVE half of the findings_by_tool contract: a configured tool's key
  # is present with an empty array. Without this, deleting `{manifest_validation: []}`
  # from the emit would make "configured and clean" indistinguishable from "not
  # configured" — the same confusion, in the direction the has() tests don't cover
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("manifest_validation")')" = "true" ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.manifest_validation')" = "[]" ]
}

@test "the skip note is ABSENT when policies ARE declared (#1152)" {
  # the other half of the note contract, and the one nothing covered: hoisting
  # `notes+=(...)` out of its guard keeps every other test green while Phase 9
  # reports "no policies declared" verbatim for a repo that declared several
  chart; policy
  run gather
  [ "$status" -eq 0 ]
  lacks "$(echo "$output" | jq -r '.notes[]')" "no policies declared"
  [ "$(echo "$output" | jq -r '.notes | length')" = "1" ]
}

@test "tooling_configured carries exactly the three documented keys (#1152)" {
  # dropping one silently changes what the dispatcher's exemption applies to;
  # adding one re-emits an adopt-a-tool recommendation the charter forbids
  chart; policy
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured | keys_unsorted | sort | join(",")')" \
    = "manifest_validation,policy,policy_tests" ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy_tests')" = "true" ]
  # and the configured policy tool's own key is present-and-empty
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "true" ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.policy')" = "[]" ]
}

@test "each of the three Kustomize spellings marks manifest_validation configured (#1152)" {
  # kustomization.yaml, kustomization.yml and Kustomization are three separate
  # -o -name clauses; a repo using the bare `Kustomization` spelling must not be
  # reported manifest-free
  local spelling
  for spelling in kustomization.yaml kustomization.yml Kustomization; do
    rm -rf "$W"; mkdir -p "$W"
    kustomize "$spelling"
    run gather
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  done
}

@test "an Argo CD resource alone marks manifest_validation configured (#1152)" {
  argocd
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "an Argo CD resource written as .yml also fires (#1152)" {
  # --include='*.yml' is a clause of its own; dropping it silently un-detects
  # every repo that spells its manifests .yml
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "argoproj.io under a pruned tree does NOT fire (#1152)" {
  # all four --exclude-dir entries, matching the find branch's loop
  local dir
  for dir in node_modules vendor templates .git; do
    rm -rf "$W"; mkdir -p "$W/$dir/argo"
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/$dir/argo/app.yaml"
    run gather
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
  done
}

@test "argoproj.io mentioned in prose does NOT fire (#1152)" {
  # the --include filter is a NARROWING: without it the marker becomes 'any file
  # mentioning Argo', which a README or a design doc satisfies
  printf 'We deploy with argoproj.io Argo CD.\n' > "$W/README.md"
  printf 'argoproj.io\n' > "$W/notes.txt"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
}

@test "an unrelated YAML-bearing repo is NOT a kubernetes repo (#1152)" {
  # the acceptance criterion that keeps the marker honest: the gather must not
  # fire on 'any YAML with apiVersion', which would match a workflow file or an
  # OpenAPI document in half the repos in existence
  mkdir -p "$W/.github/workflows"
  printf 'name: ci\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n' \
    > "$W/.github/workflows/ci.yml"
  printf 'openapi: 3.0.3\ninfo:\n  title: api\n  version: "1"\n' > "$W/openapi.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
}

@test "a chart under ANY of the four pruned trees does not count as a manifest (#1152)" {
  # all four entries, not the two that happened to be convenient: a vendored Helm
  # chart under node_modules/ is the realistic false positive this prune exists
  # for, and this very repo ships chart templates under bootstrap's templates/ tree
  local dir
  for dir in node_modules .git vendor templates; do
    rm -rf "$W"; mkdir -p "$W/$dir/sub/chart"
    printf 'apiVersion: v2\nname: x\nversion: 0.1.0\n' > "$W/$dir/sub/chart/Chart.yaml"
    run gather
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
  done
}

@test "the prune filter matches whole path SEGMENTS, not substrings (#1152)" {
  # a directory merely NAMED like a pruned one must still be searched; a filter
  # widened to a bare substring would silently stop detecting these repos
  mkdir -p "$W/templates-src/charts/app"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/templates-src/charts/app/Chart.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "a DIRECTORY named like a manifest is not a manifest (#1152)" {
  # `! -type d`, the same guard the react marker carries
  mkdir -p "$W/base/Kustomization"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
}

@test "a SYMLINKED manifest still counts (#1152)" {
  # the second half of the `! -type d` claim, and the one that has no test in
  # either file: `! -type d` → `-type f` satisfies the directory test identically
  # while silently dropping repos whose chart is symlinked into place
  mkdir -p "$BATS_TEST_TMPDIR/real" "$W/charts"
  printf 'apiVersion: v2\nname: r\nversion: 0.1.0\n' > "$BATS_TEST_TMPDIR/real/Chart.yaml"
  ln -s "$BATS_TEST_TMPDIR/real/Chart.yaml" "$W/charts/Chart.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "a DIRECTORY named like a policy is not a policy (#1152)" {
  # the policy finds' `-type f`, the counterpart of the manifest side's `! -type d`:
  # without it a directory named p.yaml would flip policy to true and raise a
  # policy_tests finding against a repo that declared nothing — a false accusation,
  # which is what trains users to ignore the finding
  chart
  mkdir -p "$W/policies/kyverno/p.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "false" ]
}

@test "a DIRECTORY named kyverno-test.yaml does not suppress the finding (#1152)" {
  # the mirror case: the fixture find's -type f keeps a directory from passing as
  # coverage and silently clearing a real untested-policy set
  chart; policy
  mkdir -p "$W/policies/kyverno/kyverno-test.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "1" ]
}

@test "a SYMLINKED policies/kyverno is followed, not reported as undeclared (#1152)" {
  # `[[ -d ]]` follows symlinks; find's default -P does not. Without `find -H` the
  # gate says "the directory is there" and the search says "nothing in it", so a
  # repo whose policy set is symlinked in reports policy: false — exactly the
  # silently-ignored policy set the glob contract exists to prevent
  chart
  mkdir -p "$BATS_TEST_TMPDIR/shared-policies" "$W/policies"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\n' \
    > "$BATS_TEST_TMPDIR/shared-policies/p.yaml"
  ln -s "$BATS_TEST_TMPDIR/shared-policies" "$W/policies/kyverno"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
}

@test "a SYMLINKED policy FILE inside a real directory still counts (#1152)" {
  # `find -H` follows only the COMMAND-LINE symlink, so a symlinked policy file
  # inside a real policies/kyverno/ would be type `l` and dropped — reporting a
  # symlink-shared policy set as undeclared, the silent skip the glob contract
  # exists to prevent. `-L` is what makes this pass.
  chart
  mkdir -p "$BATS_TEST_TMPDIR/shared" "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\n' > "$BATS_TEST_TMPDIR/shared/p.yaml"
  ln -s "$BATS_TEST_TMPDIR/shared/p.yaml" "$W/policies/kyverno/p.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
}

@test "a SYMLINKED kyverno-test fixture counts as coverage (#1152)" {
  # the inverted consequence of the same guard: a dropped symlinked fixture
  # raises the high-severity untested-policies finding against a repo whose
  # policies ARE tested — a false accusation, which is what trains users to
  # ignore the finding
  chart; policy
  mkdir -p "$BATS_TEST_TMPDIR/shared-tests"
  printf 'name: p-test\npolicies:\n  - p.yaml\n' \
    > "$BATS_TEST_TMPDIR/shared-tests/kyverno-test.yaml"
  ln -s "$BATS_TEST_TMPDIR/shared-tests/kyverno-test.yaml" \
    "$W/policies/kyverno/kyverno-test.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.policy_tests')" = "[]" ]
}

@test "a repo with MANY charts is still detected under the script's own pipefail (#1152)" {
  # the gather sets `set -euo pipefail` ITSELF, so it is the more exposed copy of
  # the capture-before-filter construction: a regression to `if find … | grep -q .`
  # passes every small-fixture test here and reports large GitOps monorepos as
  # manifest-free with exit 0, once find's output outruns the pipe buffer
  local i
  for i in $(seq 1 400); do
    mkdir -p "$W/charts/app$i"
    printf 'apiVersion: v2\nname: app%s\nversion: 0.1.0\n' "$i" > "$W/charts/app$i/Chart.yaml"
  done
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "a RELATIVE repo path beginning with a dash is handled (#1152)" {
  # the sole reason for the normalisation the script now carries (#1177 narrowed
  # it to relative paths that are not already `./`-anchored, so the documented
  # default `.` is left alone): such a path clears the `[[ -d ]]` gate but is
  # read as a start-point-ending ARGUMENT by `find -L "$policy_dir"`, which has
  # no `--` to protect it — `cd --` already covers the cd half. Every other test
  # passes an absolute path or none, so reverting it would keep the suite green.
  local dashed="$BATS_TEST_TMPDIR/-dash-repo"
  mkdir -p "$dashed/charts/app" "$dashed/policies/kyverno"
  printf 'apiVersion: v2\nname: d\nversion: 0.1.0\n' > "$dashed/charts/app/Chart.yaml"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\n' > "$dashed/policies/kyverno/p.yaml"
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$GATHER' -dash-repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
}

@test "an ordinary relative repo path is NOT rewritten into the diagnostics (#1177)" {
  # the other half of the normalisation contract: `.` and `./x` must pass through
  # untouched, because the messages this script's exit-2 contract exists to
  # produce are forwarded verbatim to a human as `gather failed: <stderr>`. The
  # pre-#1177 blanket form turned the documented no-argument default into `./.`
  # and printed `././policies/kyverno`; nothing pinned that, so re-widening it
  # would ship green.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/policies/kyverno/restricted"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\n' \
    > "$W/policies/kyverno/restricted/p.yaml"
  chmod 000 "$W/policies/kyverno/restricted"
  run --separate-stderr bash -c "cd '$W' && zsh '$GATHER' ."
  chmod 755 "$W/policies/kyverno/restricted"
  [ "$status" -eq 2 ]
  contains "$stderr" "could not list"
  lacks "$stderr" '././'
}

@test "an existing but UNREADABLE repo directory is an error, not an all-false payload (#1152)" {
  # "could not look" must never render as "looked and found nothing": every search
  # below the gate is wrapped in || true / 2>/dev/null, so without the -r/-x check
  # this would exit 0 with a confident empty verdict
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked/charts/app"
  printf 'apiVersion: v2\nname: l\nversion: 0.1.0\n' > "$locked/charts/app/Chart.yaml"
  chmod 000 "$locked"
  run --separate-stderr zsh "$GATHER" "$locked"
  chmod 755 "$locked"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "not a readable directory"
}

@test "a DANGLING policy symlink is still excluded (#1152)" {
  # the third claim of the -L rationale, and the only untested one: swapping the
  # policy finds' `-type f` for `! -type d` satisfies the other two while
  # flipping policy to true for a repo whose only policy file is a broken link —
  # and then raising the high-severity untested-policies finding against it
  chart
  mkdir -p "$W/policies/kyverno"
  ln -s "$BATS_TEST_TMPDIR/does-not-exist.yaml" "$W/policies/kyverno/p.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "false" ]
}

@test "a DANGLING fixture symlink does not count as coverage (#1152)" {
  chart; policy
  ln -s "$BATS_TEST_TMPDIR/gone-test.yaml" "$W/policies/kyverno/kyverno-test.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "1" ]
}

@test "an UNREADABLE policies/kyverno is an error, not a silent skip (#1152)" {
  # one level deeper than the repo gate: without its own guard this would emit
  # "no policies declared" for a repo that declared several
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart; policy
  chmod 000 "$W/policies/kyverno"
  run --separate-stderr gather
  chmod 755 "$W/policies/kyverno"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "policies/kyverno exists but is not readable"
}

@test "an unreadable SUBTREE with no markers is an error, not manifest_validation:false (#1177)" {
  # the repo gate above proves the TOP directory readable; it says nothing about
  # what is under it. A locked subtree may hold the very chart being looked for,
  # so `manifest_validation: false` here asserts a search that never finished —
  # and the orchestrator renders a configured-tool-free topic as clean.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr gather
  chmod 755 "$W/locked"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "did not complete"
}

@test "an unreadable node_modules trips the gather's FIND half specifically (#1177)" {
  # the mirror of the grep-half test below: the locked-DIRECTORY test above fails
  # BOTH halves, so `manifest_rc != 0` is never the sole cause and could be
  # deleted with the suite green. node_modules discriminates — the argoproj grep
  # skips it (--exclude-dir) while find has no -prune and descends it. The
  # regression pinned here is the common one: a vendored tree with restrictive
  # permissions emitting manifest_validation:false at exit 0, which the
  # orchestrator renders as a completed, clean search.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/node_modules/pkg"
  chmod 000 "$W/node_modules"
  run --separate-stderr gather
  chmod 755 "$W/node_modules"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  # BOTH halves named: find failed, grep completed cleanly
  contains "$stderr" "find exit 1"
  contains "$stderr" "grep exit 1"
}

@test "an unreadable FILE trips the gather's GREP half specifically (#1177)" {
  # the locked-DIRECTORY test above fails BOTH halves, so it is satisfied by
  # manifest_rc alone and would stay green with `|| argo_rc >= 2` deleted. A
  # locked FILE discriminates: find never reads file CONTENT, so it completes,
  # and only the argoproj grep errors — the one case where the grep half is the
  # sole signal. Without the disjunct this repo emits manifest_validation:false
  # at exit 0, which the orchestrator renders as a completed, clean search.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/secret.yaml"
  chmod 000 "$W/secret.yaml"
  run --separate-stderr gather
  chmod 644 "$W/secret.yaml"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  # names WHICH half failed, so the two disjuncts stay distinguishable. BOTH
  # needles: 'grep exit 2' alone would still match if find had also failed,
  # silently turning this back into the both-halves fixture it replaces.
  contains "$stderr" "grep exit 2"
  contains "$stderr" "find exit 0"
}

@test "an unreadable SUBTREE does not taint a found manifest (#1177)" {
  # the tolerant half: a hit is a hit. Only the NEGATIVE answer needs a complete
  # search, so a repo whose chart WAS found still emits its payload — otherwise
  # the hardening would fail every repo carrying one locked directory.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr gather
  chmod 755 "$W/locked"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  # and SILENT on the tolerant path: a leaked "Permission denied" would land in
  # the orchestrator's transcript and, on the halt path, in the note it prints
  # verbatim. Dropping a 2>/dev/null is otherwise invisible to this suite.
  [ -z "$stderr" ]
}

@test "an unreadable subtree under an ARGO-only repo still detects (#1177)" {
  # same rule through the grep half, whose exit 2 on an unreadable tree is the
  # status the old `2>/dev/null` conflated with a clean no-match. With -q, a
  # match wins over the error, so the verdict stands.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  argocd
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr gather
  chmod 755 "$W/locked"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  [ -z "$stderr" ]
}

@test "an unreadable POLICY subtree is an error, not 'no policies declared' (#1177)" {
  # the readable-directory gate covers policies/kyverno itself, not a directory
  # BENEATH it — and policies are commonly grouped per subject. Without the
  # find's own status check, a repo with several policies in a locked
  # subdirectory is reported as declaring none.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/policies/kyverno/restricted"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/restricted/p.yaml"
  chmod 000 "$W/policies/kyverno/restricted"
  run --separate-stderr gather
  chmod 755 "$W/policies/kyverno/restricted"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not list"
}

@test "unreachable FIXTURES never fabricate the untested-policies finding (#1177)" {
  # the costliest consequence of the unchecked finds: an empty fixture result
  # does not merely skip a step, it ACCUSES the repo of shipping policies that
  # pass everything silently — a high-severity finding resting on a search that
  # failed. This is the fixture layout that produced it: policies at the top of
  # policies/kyverno, their `kyverno test` fixtures grouped in a subdirectory
  # that cannot be read.
  #
  # NOTE on which guard fires: both policy finds walk the SAME tree, and the
  # policy one runs first, so it is that guard which reports here. The fixture
  # find's own check is defence-in-depth for a tree that changes between the two
  # walks (a directory locked or removed mid-run) and is deliberately left
  # without a dedicated test — no seam exists to fail the second walk while the
  # first succeeds, and a test that could not tell the guard's presence from its
  # absence would be inert, which is worse than none. What this test pins is the
  # OUTCOME the issue names: no accusation, and a named error instead.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart; policy
  mkdir -p "$W/policies/kyverno/fixtures"
  printf 'name: p-test\npolicies:\n  - ../p.yaml\n' \
    > "$W/policies/kyverno/fixtures/kyverno-test.yaml"
  chmod 000 "$W/policies/kyverno/fixtures"
  run --separate-stderr gather
  chmod 755 "$W/policies/kyverno/fixtures"
  [ "$status" -eq 2 ]
  # BOTH assertions: `lacks` alone passes by construction here (the script exits
  # before emitting, so stdout is empty), which would let a regression that
  # printed a well-formed all-false payload WHILE exiting 2 slip through — the
  # exact failure the sibling exit-2 tests in this file guard with `[ -z ]`
  [ -z "$output" ]
  lacks "$output" "untested_policies"
  contains "$stderr" "could not list"
}

@test "a successful run writes NOTHING to stderr (#1152)" {
  # every search is 2>/dev/null-suppressed; dropping a suppression would leak
  # find/grep permission warnings into the orchestrator's transcript, with the
  # whole suite still green
  chart; policy; policy_test
  run --separate-stderr gather
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "a FAILING jq never emits a partial payload (#1152, #1177)" {
  # jq-absent is exit 3; jq present-but-failing is the other half. Since #1177 the
  # emitter CHECKS jq, so this pins the named guard rather than errexit's
  # incidental abort: `-eq 2` (inside the documented {0,2,3}) plus the message
  # the orchestrator relays. Asserting only `-ne 0` would hold identically with
  # the guard deleted — errexit would abort with jq's own status — so the
  # plausible "this `||` block is redundant under set -e" cleanup would ship green
  # while the script exited 5 and lost the named cause.
  chart
  local stub="$BATS_TEST_TMPDIR/jq-stub" real_jq zsh_bin
  real_jq="$(command -v jq)"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$stub"
  {
    printf '#!/bin/sh
'
    printf 'case "$*" in *--argjson*) exit 2 ;; esac
'
    printf 'exec %s "$@"
' "$real_jq"
  } > "$stub/jq"
  chmod +x "$stub/jq"
  run --separate-stderr env PATH="$stub:$PATH" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not emit the payload"
}

@test "a FAILING notes encode is exit 2 with its own named cause (#1177)" {
  # the sibling guard, and the one no fixture reached at all. `jq -R` appears
  # exactly once in the script — the notes encoder — and the assignment runs
  # under pipefail, so failing on `-R` isolates it from the payload emitter.
  # Without its guard the pipeline's failure aborts under errexit with jq's
  # status, outside the documented set and with no cause named.
  chart
  local stub="$BATS_TEST_TMPDIR/jq-stub-R" real_jq zsh_bin
  real_jq="$(command -v jq)"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$stub"
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in *-R*) exit 2 ;; esac\n'
    printf 'exec %s "$@"\n' "$real_jq"
  } > "$stub/jq"
  chmod +x "$stub/jq"
  run --separate-stderr env PATH="$stub:$PATH" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not encode the notes list"
}

@test "a repo whose PARENT directory has a pruned name is still searched (#1152)" {
  # the load-bearing reason for `cd "$repo" && find .`: with an absolute $repo the
  # grep -v filter would also test the checkout's own prefix, so a repo living
  # under ~/templates/ (or a workspace named vendor/) would have every hit
  # filtered and be reported manifest-free. Reverting the cd passes every other
  # test in this file, because BATS_TEST_TMPDIR never contains such a segment.
  local parent
  for parent in templates vendor node_modules; do
    local nested="$BATS_TEST_TMPDIR/$parent/repo"
    mkdir -p "$nested/charts/app"
    printf 'apiVersion: v2\nname: n\nversion: 0.1.0\n' > "$nested/charts/app/Chart.yaml"
    run zsh "$GATHER" "$nested"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  done
}

@test "no policy directory: emits a skip note, and NO policy keys at all (#1152)" {
  chart
  run gather
  [ "$status" -eq 0 ]
  # per the v2 contract an unconfigured tool is ABSENT from findings_by_tool —
  # asserted with has(), since `jq '.missing | length'` is also 0 and would pass
  # for an empty array, making "not configured" and "clean" indistinguishable
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy_tests")')" = "false" ]
  # the WHOLE note, consequence clause included: "no policies declared" alone
  # would let "— step skipped, not failed" be deleted, and that half is what
  # stops the orchestrator rendering the skip as a failure
  contains "$(echo "$output" | jq -r '.notes[]')" \
    "no policies declared at policies/kyverno/**/*.{yaml,yml} — step skipped, not failed"
}

@test "an absent policy directory is never a FINDING (#1152)" {
  # the charter's central guarantee: a public plugin must work in a repo with no
  # opinions yet, so declining to declare policies is a skip, never a defect
  chart
  run gather
  [ "$status" -eq 0 ]
  local flat
  flat="$(echo "$output" | jq -c '[.findings_by_tool[]?[]?]')"
  [ "$(echo "$flat" | jq -r 'length')" = "0" ]
}

@test "an EMPTY policy directory skips exactly like an absent one (#1152)" {
  # ARCHITECTURE states the contract as the GLOB policies/kyverno/**/*.{yaml,yml},
  # not the directory's existence — so a directory holding no matching file must
  # report policy: false rather than 'configured with zero policies'
  chart
  mkdir -p "$W/policies/kyverno"
  printf '{}\n' > "$W/policies/kyverno/notes.json"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "false" ]
}

@test "a .yml-only policy set is enforced, not silently ignored (#1152)" {
  # the other half of the glob contract: a repo that writes its policies as .yml
  # must be detected, or its policies go unrun with nothing to say so
  chart
  mkdir -p "$W/policies/kyverno"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' \
    > "$W/policies/kyverno/p.yml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
}

@test "policies without test fixtures: exactly one policy_tests finding (#1152)" {
  chart; policy
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "1" ]
}

@test "the policy_tests finding carries the family's finding fields (#1152)" {
  # the dispatcher routes on `tool` and the orchestrator renders `message`/`files`;
  # a finding missing them would plan a group nobody can act on.
  #
  # The key set is asserted over EVERY finding with one jq -e, not by probing
  # element [0] — so the contract generalises to any future finding this tool
  # grows. And note the shape: a `[ "$(… jq -er '.severity')" != "" ]` would be
  # VACUOUS, because jq prints the string "null" for a missing key and "null" is
  # not empty — the exact hazard tests/kubernetes-plugin-skeleton.bats documents.
  # These assertions keep jq's exit status live instead.
  chart; policy
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_tool.policy_tests
    | length == 1
    and all(.[]; has("id") and has("tool") and has("type") and has("severity")
                 and has("message") and has("fix") and has("files"))
    and all(.[]; (.severity | type == "string" and length > 0)
                 and (.fix | type == "string" and length > 0)
                 and (.files | type == "array" and length > 0))' >/dev/null
  local f
  f="$(echo "$output" | jq -c '.findings_by_tool.policy_tests[0]')"
  [ "$(echo "$f" | jq -r '.tool')" = "policy_tests" ]
  [ "$(echo "$f" | jq -r '.id')" = "policy_tests:untested-policies" ]
  [ "$(echo "$f" | jq -r '.type')" = "untested_policies" ]
  [ "$(echo "$f" | jq -r '.severity')" = "high" ]
  [ "$(echo "$f" | jq -r '.files[0]')" = "policies/kyverno/" ]
  contains "$(echo "$f" | jq -r '.message')" "no kyverno test fixtures"
}

@test "policies with test fixtures: the key is PRESENT and empty (#1152)" {
  # `length == 0` alone cannot tell "configured and clean" from "key dropped
  # entirely" — null | length is also 0 — so pin both halves
  chart; policy; policy_test
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy_tests")')" = "true" ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.policy_tests')" = "[]" ]
}

@test "a nested kyverno-test.yml also counts as coverage (#1152)" {
  # fixtures are commonly grouped per policy in subdirectories, and .yml is as
  # valid as .yaml — missing either would report a tested policy set as untested
  chart; policy
  mkdir -p "$W/policies/kyverno/tests"
  printf 'name: p-test\npolicies:\n  - ../p.yaml\n' \
    > "$W/policies/kyverno/tests/kyverno-test.yml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy_tests")')" = "true" ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.policy_tests')" = "[]" ]
}

@test "a policy nested under the glob's ** is still a declared policy (#1152)" {
  # the contract is policies/kyverno/**/*.{yaml,yml}; a regression to -maxdepth 1
  # would keep every other test green while reporting a real policy set as
  # undeclared — the silent skip the charter forbids
  chart
  mkdir -p "$W/policies/kyverno/require-limits"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: rl\n' \
    > "$W/policies/kyverno/require-limits/policy.yaml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "1" ]
}

@test "coverage is null — a topic has no application test suite (#1152)" {
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.coverage')" = "null" ]
}

@test "the presence-detection note is ALWAYS carried (#1152)" {
  # an empty topic plan with a non-empty tooling_configured reads as 'this topic
  # is clean — its tools ran and found nothing', which for this gather would be a
  # lie: nothing ran. The note is the only thing that reaches the Phase 9 summary
  # and can contradict that rendering.
  chart; policy; policy_test
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.notes[]' | grep -q "presence-detected only"
}

@test "a repo with no kubernetes markers still emits a well-formed payload (#1152)" {
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("manifest_validation")')" = "false" ]
  [ "$(echo "$output" | jq -r '.coverage')" = "null" ]
  [ "$(echo "$output" | jq -r '.notes | type')" = "array" ]
  # the configuration where an empty payload most reads as "clean" is exactly
  # where the presence note has to be there to contradict it — and both notes
  # apply here, so pin the count too
  echo "$output" | jq -r '.notes[]' | grep -q "presence-detected only"
  [ "$(echo "$output" | jq -r '.notes | length')" = "2" ]
}

@test "the payload carries exactly the four v2 top-level keys (#1152)" {
  # the dispatcher validates the envelope; a stray or missing key is a contract
  # break that would only surface at dispatch time
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[keys_unsorted[]] | sort | join(",")')" \
    = "coverage,findings_by_tool,notes,tooling_configured" ]
}

@test "a repo path that is not a directory is an error, not an empty payload (#1152)" {
  # the title's second half needs asserting too: a regression printing a
  # well-formed all-false payload on stdout WHILE exiting 2 would otherwise pass,
  # and so would one dropping the diagnostic the orchestrator surfaces verbatim
  # in unsupported_topics as `gather failed: <error>`
  run --separate-stderr zsh "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "not a directory"
}

@test "a path that exists but is a FILE is the same error (#1152)" {
  printf 'not a repo\n' > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr zsh "$GATHER" "$BATS_TEST_TMPDIR/a-file"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "not a directory"
}

@test "jq missing from PATH is exit 3, not a garbled payload (#1152)" {
  # the whole payload is built by jq, so a regression that moved or deleted the
  # preflight would turn a jq-less machine into a confident empty payload rather
  # than a failure the orchestrator can report
  chart
  local stub zsh_bin
  stub="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$stub"
  # zsh itself must be reached by ABSOLUTE path — resolving it through the
  # stubbed PATH would exit 127 (command not found) and masquerade as the
  # failure this test is trying to observe
  zsh_bin="$(command -v zsh)"
  [ -x "$zsh_bin" ]
  run --separate-stderr env PATH="$stub" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "jq not found on PATH"
}

@test "with NO argument the gather reads the current directory (#1152)" {
  # the documented default (${1:-.}); every other test passes $W explicitly, so a
  # regression to a bare ${1} — which aborts under set -u — would go unnoticed
  chart
  run bash -c "cd '$W' && zsh '$GATHER'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "an ARGO-ONLY repo whose own directory is named like a pruned tree is searched (#1152)" {
  # GNU grep's --exclude-dir skips any COMMAND-LINE directory whose name matches,
  # so passing "$repo" (rather than cd-ing and grepping '.') would skip such a
  # repo ENTIRELY and report it manifest-free with exit 0. The find branch's
  # equivalent test uses a Chart.yaml and never reaches this branch.
  local parent
  for parent in templates vendor node_modules; do
    local nested="$BATS_TEST_TMPDIR/argo-$parent/$parent"
    mkdir -p "$nested/apps"
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$nested/apps/app.yaml"
    run zsh "$GATHER" "$nested"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  done
}

@test "a repo path containing a space is handled (#1152)" {
  local spaced="$BATS_TEST_TMPDIR/my repo"
  mkdir -p "$spaced/charts/app" "$spaced/policies/kyverno"
  printf 'apiVersion: v2\nname: s\nversion: 0.1.0\n' > "$spaced/charts/app/Chart.yaml"
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\n' > "$spaced/policies/kyverno/p.yaml"
  run zsh "$GATHER" "$spaced"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
}

@test "the script runs via its own shebang, as the orchestrator executes it (#1152)" {
  # `test -x` then direct execution is the discovery contract; every other test
  # here invokes `zsh "$GATHER"`, which bypasses the shebang entirely
  chart
  run gather_directly
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
}

@test "the script is executable — the orchestrator partitions on test -x (#1152)" {
  # discovery-by-convention: a non-executable gather leaves the topic in
  # unsupported_topics with 'no gather script yet', silently
  [ -x "$GATHER" ]
}
