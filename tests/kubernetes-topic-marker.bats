#!/usr/bin/env bats
#
# The `kubernetes` topic marker (epic #1150, child #1152). The orchestrator's
# topic-detection recipe fires on a Helm `Chart.yaml`, a Kustomize manifest (any
# of the three spellings kustomize accepts), or a file containing `argoproj.io`
# — deliberately NOT "any YAML with apiVersion", which would match half the
# repos in existence.
#
# CRITICAL DESIGN POINT, copied from tests/react-topic-marker.bats: these tests
# do NOT re-implement the recipe. They extract the authoritative one from the
# fenced block in development/skills/maintenance/SKILL.md (between the
# `# kubernetes-marker:begin` / `:end` sentinels) and `eval` it. A hand-copied
# helper would prove things about this test file rather than about the artifact
# the orchestrator actually follows, letting the SKILL.md recipe drift with a
# green suite. The extraction is asserted non-empty and bounded so a broken
# extraction can never silently make every test vacuous, and every negative test
# asserts the precise no-match status (1) rather than "any failure", so a recipe
# that blows up (127, a set -e abort) cannot masquerade as a clean rejection.
#
# The SECOND thing this file exists for is PARITY. The detection rule is stated
# FOUR times — SKILL.md's verdict recipe and its manifests lister (both extracted
# here), gather-kubernetes-findings.zsh, and detect-stack.sh's
# `is-kubernetes-marker` block (#1153) — and SKILL.md asserts in prose that they
# prune the same trees. That claim is DERIVED below rather than trusted: a marker
# that fires where the gather does not produces an empty topic plan on a real
# GitOps repo, and a gather that finds what the marker does not never runs at
# all. Either way nothing would be red.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-kubernetes-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"

  # SHAPE guards first. `sed -n '/begin/,/end/p'` prints to END OF FILE when the
  # closing sentinel is missing or renamed, and a duplicated opening sentinel
  # concatenates blocks — either way RECIPE would become most of SKILL.md, whose
  # later fenced blocks contain git/gh commands and $(...) substitutions that
  # `eval` would then execute. Content-only guards cannot catch that, because the
  # real recipe is a PREFIX of the runaway blob. So: pin exactly one sentinel
  # pair, and bound the extraction's size and its first/last lines.
  [ "$(grep -c '^# kubernetes-marker:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^# kubernetes-marker:end$' "$SKILL")" -eq 1 ]

  RECIPE="$(sed -n '/^# kubernetes-marker:begin$/,/^# kubernetes-marker:end$/p' "$SKILL" \
    | grep -v '^#')"
  [ -n "$RECIPE" ]
  # the bound is a RUNAWAY guard, not a budget: a sed range that stops matching
  # prints hundreds of lines, and every one of them would be eval'd. #1177's
  # per-search status capture roughly doubled the recipe (8 lines -> ~21), so
  # the bound moved with it and still catches a runaway by two orders of
  # magnitude.
  [ "$(printf '%s\n' "$RECIPE" | wc -l)" -le 30 ]
  starts_with "$RECIPE" 'k8s_hits='
  # ends on the verdict ladder's `fi` since #1177 — the recipe now has THREE
  # statuses (0 kubernetes / 1 not / 2 could-not-look), so its last line is the
  # close of the if/elif/else that chooses between them
  ends_with "$RECIPE" 'fi'
  contains "$RECIPE" 'argoproj.io'

  # the SECOND executable kubernetes recipe: the path lister that fills
  # language_meta.manifests. It is a THIRD copy of the prune and --exclude-dir
  # sets, so it gets the same sentinel treatment and the same derived oracles.
  [ "$(grep -c '^  # kubernetes-manifests:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^  # kubernetes-manifests:end$' "$SKILL")" -eq 1 ]
  MANIFESTS="$(sed -n '/^  # kubernetes-manifests:begin$/,/^  # kubernetes-manifests:end$/p' "$SKILL" \
    | grep -v '^  #' | sed 's/^  //')"
  [ -n "$MANIFESTS" ]
  [ "$(printf '%s\n' "$MANIFESTS" | wc -l)" -le 30 ]
  starts_with "$MANIFESTS" 'k8s_paths='
  # the guarded printf moved INSIDE the same three-way ladder (#1177): print the
  # list, or name the failed search on stderr, or print nothing at all
  ends_with "$MANIFESTS" 'fi'
  contains "$MANIFESTS" 'printf '"'"'%s\n'"'"' "$k8s_paths"'

  # and the gather's own detection block, the parity oracles' other operand. Its
  # sed range needs the SAME shape guards as RECIPE above and for the same
  # reason: an end address that stops matching prints to EOF, after which the
  # oracles would compare a runaway blob — and still pass, because the rest of
  # the script's `-name` tokens are quoted and invisible to names_of.
  # SENTINEL-bounded and covering BOTH halves — the find AND the argoproj grep.
  # The old `/^manifest_hits=/,/|| true)"$/` range stopped at the find half, so
  # the --exclude-dir/--include oracles had to fall back to the whole file, and
  # an unbounded union cannot tell "present in this recipe" from "present
  # somewhere in the script". Same treatment, same reason, as DETECT_BLOCK.
  [ "$(grep -c '^# gather-kubernetes-marker:begin$' "$GATHER")" -eq 1 ]
  [ "$(grep -c '^# gather-kubernetes-marker:end$' "$GATHER")" -eq 1 ]
  GATHER_BLOCK="$(sed -n '/^# gather-kubernetes-marker:begin$/,/^# gather-kubernetes-marker:end$/p' "$GATHER" \
    | grep -v '^[[:space:]]*#')"
  [ -n "$GATHER_BLOCK" ]
  [ "$(printf '%s\n' "$GATHER_BLOCK" | wc -l)" -le 30 ]
  starts_with "$GATHER_BLOCK" 'manifest_hits='
  ends_with "$GATHER_BLOCK" 'fi'
  contains "$GATHER_BLOCK" 'find .'
  contains "$GATHER_BLOCK" 'argoproj.io'

  # the FOURTH copy (#1153): detect-stack.sh's `is_kubernetes` key, which
  # review-dispatch.zsh reads as a fallback repo_type. It gets the same shape
  # guards and joins the same parity oracles — a detect-stack that fired where
  # the orchestrator's marker does not would route a repo's review loop to a
  # panel its maintenance dispatch never selects.
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  [ -f "$DETECT" ]
  # SENTINEL-bounded, exactly like RECIPE and MANIFESTS above — and for a
  # sharper reason. The oracles below compare sorted UNIONS of extracted
  # tokens, so deriving detect-stack's operand from the WHOLE 1600-line file
  # would let any other block in this actively-extended script supply a
  # `--exclude-dir=templates` or `--include='*.yaml'` and mask its deletion
  # from the kubernetes recipe: union unchanged, parity green, and the argoproj
  # grep quietly widened to "any file mentioning Argo".
  [ "$(grep -c '^# is-kubernetes-marker:begin$' "$DETECT")" -eq 1 ]
  [ "$(grep -c '^# is-kubernetes-marker:end$' "$DETECT")" -eq 1 ]
  # `[[:space:]]`, not `\s`: the latter is a GNU extension, and BSD grep (which
  # is /usr/bin/grep on the macos-latest CI leg, where script-tests.yml puts
  # /bin first on PATH) reads it as a literal `s` — the pattern would degrade to
  # `^s*#` there, leaving the recipe's tab-indented comments in the block on one
  # leg but not the other
  DETECT_BLOCK="$(sed -n '/^# is-kubernetes-marker:begin$/,/^# is-kubernetes-marker:end$/p' "$DETECT" \
    | grep -v '^[[:space:]]*#')"
  [ -n "$DETECT_BLOCK" ]
  # a looser bound than its three siblings (~21-22 lines) because this copy
  # carries two NAMED cannot-enter branches the others fold into one, and it is
  # tab-indented bash rather than a fenced snippet. Still a runaway guard: the
  # file is ~1900 lines, so a sed range running to EOF misses this by 40x.
  [ "$(printf '%s\n' "$DETECT_BLOCK" | wc -l)" -le 45 ]
  starts_with "$DETECT_BLOCK" 'is_kubernetes="false"'
  ends_with "$DETECT_BLOCK" 'fi'
  # the block must carry BOTH halves — the find and the argoproj grep — or the
  # oracles silently stop covering the half that fell outside it
  contains "$DETECT_BLOCK" 'find .'
  contains "$DETECT_BLOCK" 'argoproj.io'
}

# The recipe is a PREDICATE — its exit status is the verdict — and it searches
# the CURRENT directory, so run it from the fixture in a subshell.
marker() { ( cd "$1" && eval "$RECIPE" ); }

# The manifests path-lister, run from a fixture like the verdict recipe.
list_manifests() { ( cd "$1" && eval "$MANIFESTS" ); }

# `-name X` tokens, sorted and space-joined — the marker filename set.
names_of() {
  printf '%s\n' "$1" | grep -oE '\-name [A-Za-z.]+' | sed 's/-name //' | sort -u | tr '\n' ' '
}

# `-e <pattern>` tokens of the grep -v filter, quotes stripped — the prune set.
prunes_of() {
  printf '%s\n' "$1" | grep -oE "\-e '?[^ ']+'?" | sed "s/-e //; s/'//g" | sort -u | tr '\n' ' '
}

# `--include=<glob>` tokens — the narrowing that keeps the argoproj grep from
# matching a README. Derived like the others so a matched deletion across all
# three copies still reds.
includes_of() {
  printf '%s\n' "$1" | grep -oE "\-\-include='[^']+'" | sort -u | tr '\n' ' '
}

chart() {
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
}

# ---------------------------------------------------------------------------
# The recipe's positive verdicts
# ---------------------------------------------------------------------------

@test "a Helm Chart.yaml is a kubernetes repo (#1152)" {
  chart
  run marker "$W"
  [ "$status" -eq 0 ]
}

@test "each of the three Kustomize spellings fires the marker (#1152)" {
  # the script matches kustomization.yaml, kustomization.yml and Kustomization;
  # testing only the first would let either other -o -name clause be dropped
  local spelling
  for spelling in kustomization.yaml kustomization.yml Kustomization; do
    rm -rf "$W"; mkdir -p "$W/overlays/prod"
    printf 'resources:\n  - ../../base\n' > "$W/overlays/prod/$spelling"
    run marker "$W"
    [ "$status" -eq 0 ]
  done
}

@test "an argoproj.io resource fires the marker with no chart present (#1152)" {
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  run marker "$W"
  [ "$status" -eq 0 ]
}

@test "an argoproj.io resource written as .yml also fires (#1152)" {
  # --include='*.yml' is a separate clause from --include='*.yaml'; dropping it
  # would silently un-detect every repo that spells its manifests .yml
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yml"
  run marker "$W"
  [ "$status" -eq 0 ]
}

@test "a repo with MANY marker files still reports a match (#1152)" {
  # the SIGPIPE case: `find | grep -q` inverts under pipefail once find's output
  # outruns the pipe buffer, so a single-match fixture cannot discriminate. This
  # one is large enough to fill it, and runs under pipefail to match the family
  # scripts' own shell options.
  local i
  for i in $(seq 1 400); do
    mkdir -p "$W/charts/app$i"
    printf 'apiVersion: v2\nname: app%s\nversion: 0.1.0\n' "$i" > "$W/charts/app$i/Chart.yaml"
  done
  run bash -c "set -o pipefail; cd '$W' && $(printf '%s' "$RECIPE")"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The recipe's negative verdicts — status 1 exactly, never "any failure"
# ---------------------------------------------------------------------------

@test "an unrelated YAML-bearing repo is NOT a kubernetes repo (#1152)" {
  # the acceptance criterion: the marker must not be 'any YAML with apiVersion',
  # which every workflow file and OpenAPI document would satisfy
  mkdir -p "$W/.github/workflows"
  printf 'name: ci\non: [push]\njobs:\n  b:\n    runs-on: ubuntu-latest\n' \
    > "$W/.github/workflows/ci.yml"
  printf 'openapi: 3.0.3\ninfo:\n  title: api\n  version: "1"\n' > "$W/openapi.yaml"
  run marker "$W"
  [ "$status" -eq 1 ]
}

@test "an empty repo is NOT a kubernetes repo (#1152)" {
  run marker "$W"
  [ "$status" -eq 1 ]
}

@test "charts under EVERY pruned tree are ignored (#1152)" {
  # all four prune entries, not just the two the gather suite happened to cover:
  # a vendored chart under node_modules/ is the realistic false positive, and
  # this repo itself ships chart templates under a templates/ tree
  local dir
  for dir in node_modules .git vendor templates; do
    rm -rf "$W"; mkdir -p "$W/$dir/sub/chart"
    printf 'apiVersion: v2\nname: x\nversion: 0.1.0\n' > "$W/$dir/sub/chart/Chart.yaml"
    run marker "$W"
    [ "$status" -eq 1 ]
  done
}

@test "argoproj.io under a pruned tree is ignored (#1152)" {
  # all four --exclude-dir entries, matching the find branch's loop — otherwise
  # --exclude-dir=.git is pinned only textually by the parity oracle below
  local dir
  for dir in node_modules vendor templates .git; do
    rm -rf "$W"; mkdir -p "$W/$dir/argo"
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/$dir/argo/app.yaml"
    run marker "$W"
    [ "$status" -eq 1 ]
  done
}

@test "argoproj.io mentioned in prose does NOT fire the marker (#1152)" {
  # the --include filter is a NARROWING: without it the marker becomes 'any file
  # mentioning Argo', which a README or a design doc satisfies
  printf 'We deploy with argoproj.io Argo CD.\n' > "$W/README.md"
  printf 'argoproj.io\n' > "$W/notes.txt"
  run marker "$W"
  [ "$status" -eq 1 ]
}

@test "a DIRECTORY named like a manifest is not a manifest (#1152)" {
  # `! -type d`, the same guard the react recipe carries
  mkdir -p "$W/base/Kustomization"
  run marker "$W"
  [ "$status" -eq 1 ]
}

@test "a SYMLINKED manifest still counts (#1152)" {
  # `! -type d` is documented as TWO claims — a directory named like a manifest is
  # not one, while a symlinked manifest still is. Only the first has a test above,
  # and the likeliest edit (`! -type d` → `-type f`) satisfies it identically while
  # silently dropping monorepos whose chart is symlinked into place.
  mkdir -p "$BATS_TEST_TMPDIR/real" "$W/charts"
  printf 'apiVersion: v2\nname: r\nversion: 0.1.0\n' > "$BATS_TEST_TMPDIR/real/Chart.yaml"
  ln -s "$BATS_TEST_TMPDIR/real/Chart.yaml" "$W/charts/Chart.yaml"
  run marker "$W"
  [ "$status" -eq 0 ]
}

@test "the prune filter matches whole path SEGMENTS, not substrings (#1152)" {
  # a directory merely NAMED like a pruned one must still be searched — a filter
  # widened to a bare substring would silently stop detecting these repos
  # BOTH trees carry a chart, so both genuinely test the segment boundary — an
  # earlier version created the second one empty, proving nothing
  mkdir -p "$W/templates-src/charts/app" "$W/vendor-lib/charts/app"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/templates-src/charts/app/Chart.yaml"
  run marker "$W"
  [ "$status" -eq 0 ]
  rm -rf "$W/templates-src"
  printf 'apiVersion: v2\nname: b\nversion: 0.1.0\n' > "$W/vendor-lib/charts/app/Chart.yaml"
  run marker "$W"
  [ "$status" -eq 0 ]
}

@test "this suite's own CI trigger covers the trees it reads (#1152)" {
  # the marker recipe, the manifests recipe, both registration tables and the
  # Phase 6/7/9 rules all live in development/skills/maintenance/SKILL.md, and
  # the gather under development/skills/maintenance/scripts/. If either filter
  # entry is pruned, a PR deleting the marker recipe matches no path filter and
  # runs no bats leg at PR time — green by never running.
  local paths p
  paths="$(sed -n '/^  pull_request:/,/^  push:/p' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  [ -n "$paths" ]
  for p in 'development/skills/**/SKILL.md' 'development/skills/**/scripts/**' 'tests/**'; do
    contains "$paths" "      - '$p'"
  done
}

@test "neither recipe ABORTS under errexit on an unreadable subtree (#1152, #1177)" {
  # the orchestrator runs its detection block under `set -e` / `pipefail`, which
  # is why both recipes suppress their searches' stderr and never let a bare
  # non-zero escape uncontrolled: one unreadable directory must not abort the
  # WHOLE topic detection with a shell diagnostic and no verdict.
  #
  # #1177 kept that property and made the two recipes' ANSWERS diverge, because
  # a boolean and a list are not the same kind of claim:
  #   - the MARKER still answers 0. A hit settles a yes/no, so the chart it did
  #     find stands whatever else failed.
  #   - the LISTER answers 2. Completeness is its payload, so the same partial
  #     walk that leaves the marker's verdict intact makes the list a wrong
  #     answer — it would name the files walked before the error and the agents
  #     would report clean on the rest.
  # Both are DEFINED verdicts on stdout/stderr, which is what "survives errexit"
  # was always about.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  local marker_status="$status"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  local lister_status="$status" lister_output="$output" lister_err="$stderr"
  chmod 755 "$W/locked"
  [ "$marker_status" -eq 0 ]
  [ "$lister_status" -eq 2 ]
  # and NOT the truncated list it could have printed
  [ -z "$lister_output" ]
  contains "$lister_err" 'possibly-truncated'
}

@test "an unreadable subtree with NO manifests is exit 2, not a clean no (#1177)" {
  # the defect this issue exists for: the old `|| true` spanned the whole
  # find|grep chain, so a search that could not read part of the tree produced
  # the same empty string as a repo with no charts — and the recipe answered a
  # confident "not kubernetes" (1). It must now be distinguishable: status 2,
  # with the failing search named on stderr. Status 1 here would be the silent
  # false negative regressing.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  chmod 755 "$W/locked"   # restore BEFORE asserting, so a failure still cleans up
  [ "$status" -eq 2 ]
  # the FAILURE-BRANCH wording, not the generic prefix: 'kubernetes marker' also
  # appears in the ladder's other arms if they ever gain a message, so it could
  # not tell this branch from another
  contains "$stderr" 'did not complete'
}

@test "an unreadable node_modules trips the marker's FIND half specifically (#1177)" {
  # the mirror of the grep-half test below. The locked-DIRECTORY fixture above
  # fails BOTH halves, so `[ "$k8s_find_rc" -ne 0 ] ||` can be deleted with every
  # other test green. `node_modules` discriminates: the argoproj grep SKIPS it
  # (--exclude-dir), while find has no -prune and descends it, then filters the
  # paths afterwards. So find fails alone — and the regression this pins is the
  # common one, a vendored tree with restrictive permissions answering a
  # confident "not kubernetes" for a tree it could not walk.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/node_modules/pkg"
  chmod 000 "$W/node_modules"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  chmod 755 "$W/node_modules"
  [ "$status" -eq 2 ]
  # BOTH halves named: find failed, grep completed cleanly. Asserting only
  # 'did not complete' would be satisfied by the grep disjunct too.
  contains "$stderr" 'find 1'
  contains "$stderr" 'grep 1'
}

@test "an unreadable FILE trips the marker's GREP half specifically (#1177)" {
  # the locked-DIRECTORY fixture above fails BOTH halves, so it is satisfied by
  # the find disjunct alone — delete `|| [ "$k8s_argo_rc" -ge 2 ]` and it stays
  # green. A locked FILE is the discriminating case: find never reads file
  # CONTENT, so it completes (exit 0) and only the argoproj grep errors (exit 2).
  # Without the grep disjunct this repo goes back to a confident status 1.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/secret.yaml"
  chmod 000 "$W/secret.yaml"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  chmod 644 "$W/secret.yaml"
  [ "$status" -eq 2 ]
  contains "$stderr" 'did not complete'
  # and the message names WHICH half failed, so the two disjuncts stay
  # distinguishable in the transcript. BOTH needles: 'grep 2' alone would still
  # match if find had also failed, which would silently turn this back into the
  # both-halves fixture it exists to replace.
  contains "$stderr" 'grep 2'
  contains "$stderr" 'find 0'
}

@test "an unreadable subtree does NOT taint a positive verdict (#1177)" {
  # the other half of the rule: a hit is a hit. Only a NEGATIVE answer needs a
  # completed search, so a repo whose chart was found — or whose argoproj match
  # was found — still reports 0 despite the failed traversal. Without this the
  # hardening would turn every locked-directory repo into an error, which is the
  # opposite over-correction.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/apps" "$W/locked"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  chmod 000 "$W/locked"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  chmod 755 "$W/locked"
  [ "$status" -eq 0 ]
  # and SILENT on the tolerant path: the orchestrator quotes a marker's own
  # stderr verbatim as its unsupported_topics note, so a leaked
  # "find: ./locked: Permission denied" would become that note — and pollute
  # every transcript. Dropping a 2>/dev/null is otherwise invisible here.
  [ -z "$stderr" ]
}

@test "the manifests recipe reports an incomplete search instead of an empty list (#1177)" {
  # one level down, the same defect with a different blast radius: an empty
  # `manifests` list dispatches the topic naming no files at all, so the agents
  # review nothing and the run looks clean. Empty-and-complete still prints
  # nothing at exit 0 (the test above this one); empty-because-we-could-not-look
  # must not.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  chmod 755 "$W/locked"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'did not complete'
}

@test "the manifests lister trips on the GREP half too, WITHOUT pipefail (#1177)" {
  # Two gaps in one fixture. (1) Like the marker, the locked-DIRECTORY test above
  # only fails the find half, so the argoproj disjunct was uncovered. (2) The
  # no-pipefail leg is the one that matters: the recipe must capture grep's OWN
  # status, because a pipeline's status is its LAST command's and `sed` always
  # succeeds — `grep … | sed` would read 0 for a grep that exited 2 in exactly
  # the shell the orchestrator pastes this into, print nothing, and exit 0. That
  # is the silent empty manifests list this block exists to abolish, so the
  # no-pipefail leg is asserted FIRST and is not optional.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/secret.yaml"
  chmod 000 "$W/secret.yaml"
  # the orchestrator's own shell: errexit and pipefail NOT set
  run --separate-stderr bash -c "cd '$W'; $(printf '%s' "$MANIFESTS")"
  local plain_status="$status" plain_out="$output" plain_err="$stderr"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  chmod 644 "$W/secret.yaml"
  [ "$plain_status" -eq 2 ]
  [ -z "$plain_out" ]
  contains "$plain_err" 'did not complete'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  # both needles, so the fixture provably isolates the GREP disjunct
  contains "$stderr" 'grep 2'
  contains "$stderr" 'find 0'
}

@test "an unreadable node_modules trips the lister's FIND half — and it refuses a TRUNCATED list (#1177)" {
  # Two things at once, because they are the same branch. (1) The find disjunct
  # was uncovered: node_modules is skipped by the argoproj grep (--exclude-dir)
  # but descended by find (no -prune), so find fails alone. (2) A chart is
  # present, so find ALSO produced output — the truncated-list case. A list's
  # completeness IS its payload, so printing what was walked before the error at
  # exit 0 would hand the dispatch a partial file set and the agents would report
  # clean on everything they never saw. The lister therefore tests
  # incompleteness BEFORE printing, unlike the three boolean copies where one hit
  # legitimately settles the verdict.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/node_modules/pkg"
  chmod 000 "$W/node_modules"
  run --separate-stderr bash -c "cd '$W'; $(printf '%s' "$MANIFESTS")"
  local plain_status="$status" plain_out="$output"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  chmod 755 "$W/node_modules"
  # the chart was FOUND, and the list is still refused — that is the point
  [ "$plain_status" -eq 2 ]
  [ -z "$plain_out" ]
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'possibly-truncated'
  contains "$stderr" 'find 1'
  # `grep 1` here is the INITIALISER, not a completed search: the presence half
  # is non-empty, so the `[ -z "$k8s_paths" ]` branch is skipped and the argoproj
  # grep never runs at all. It still proves the isolation (rc 1 cannot be the
  # trigger), but do not read it as "the grep completed cleanly".
  contains "$stderr" 'grep 1'
  # POSITIVE CONTROL: with permissions restored the same fixture must produce a
  # real, non-empty list. Without it, a broken `-name Chart.yaml` clause would
  # silently degrade this into a duplicate of the empty find-half test above and
  # stop guarding the incompleteness-before-print ordering it exists for.
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  [ "$status" -eq 0 ]
  [ "$output" = "charts/app/Chart.yaml" ]
}

@test "the lister refuses an argoproj list that MATCHED and errored (#1177)" {
  # the lister drops `-q` deliberately (it needs the paths), so grep can exit 2
  # having ALREADY printed matches — and that list must still be refused, because
  # completeness is the payload. Both other grep-half fixtures leave the match set
  # EMPTY, so this state is uncovered: the tempting "harmonise the lister with the
  # three boolean copies" edit (treat a non-empty match set as success, mirroring
  # the marker's -q tolerance) would print a TRUNCATED Argo path list at exit 0
  # with the whole suite green.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/locked.yaml"
  chmod 000 "$W/apps/locked.yaml"
  run --separate-stderr bash -c "cd '$W'; $(printf '%s' "$MANIFESTS")"
  local plain_status="$status" plain_out="$output"
  run --separate-stderr bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  chmod 644 "$W/apps/locked.yaml"
  [ "$plain_status" -eq 2 ]
  [ -z "$plain_out" ]
  [ "$status" -eq 2 ]
  # emphatically NOT the path it did match
  [ -z "$output" ]
  lacks "$output" 'apps/app.yaml'
  contains "$stderr" 'possibly-truncated'
  contains "$stderr" 'grep 2'
  contains "$stderr" 'find 0'
}

@test "the manifests recipe writes NOTHING to stderr (#1152)" {
  # dropping 2>/dev/null would leak find's Permission denied into the transcript
  chart
  run --separate-stderr list_manifests "$W"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# Parity with the gather — the claim SKILL.md makes in prose, derived
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The manifests path-lister — a SECOND executable recipe, executed not just read
# ---------------------------------------------------------------------------

@test "the manifests recipe lists every match, repo-relative (#1152)" {
  # the `sed 's|^\./||'` strip is the contract: language_meta.manifests is
  # repo-relative, and a dropped strip would emit ./charts/app/Chart.yaml for
  # every path in every kubernetes dispatch
  mkdir -p "$W/charts/app" "$W/overlays/prod"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'resources: []\n' > "$W/overlays/prod/kustomization.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  contains "$output" 'charts/app/Chart.yaml'
  contains "$output" 'overlays/prod/kustomization.yaml'
  lacks "$output" './charts'
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "the manifests recipe prunes the same trees as the marker (#1152)" {
  mkdir -p "$W/charts/app" "$W/node_modules/x/chart" "$W/templates/y/chart"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'apiVersion: v2\nname: n\nversion: 0.1.0\n' > "$W/node_modules/x/chart/Chart.yaml"
  printf 'apiVersion: v2\nname: t\nversion: 0.1.0\n' > "$W/templates/y/chart/Chart.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  contains "$output" 'charts/app/Chart.yaml'
  lacks "$output" 'node_modules'
  lacks "$output" 'templates'
}

@test "the manifests recipe falls back to argoproj PATHS, never an empty list (#1152)" {
  # the fallback drops -q deliberately: the verdict recipe's `grep -rqlF` prints
  # nothing, so reusing it here would give an Argo-only repo an EMPTY manifests
  # list — the exact failure the prose warns about
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "apps/app.yaml" ]
}

@test "the manifests fallback does NOT list prose files mentioning argoproj.io (#1152)" {
  # the --include narrowing on the THIRD copy: the fallback fixture elsewhere in
  # this file contains only a .yaml, so deleting both --include flags stays green
  # there. Dropping them fills language_meta.manifests with README.md and every
  # prose file that happens to mention Argo.
  mkdir -p "$W/apps"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  printf 'We deploy with argoproj.io Argo CD.\n' > "$W/README.md"
  printf 'argoproj.io\n' > "$W/notes.txt"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "apps/app.yaml" ]
}

@test "a prose-only repo yields an EMPTY manifests list (#1152)" {
  printf 'We deploy with argoproj.io Argo CD.\n' > "$W/README.md"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the manifests recipe prefers the presence half over the fallback (#1152)" {
  mkdir -p "$W/charts/app" "$W/apps"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\n' > "$W/apps/app.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "charts/app/Chart.yaml" ]
}

@test "the manifests recipe prints NOTHING when there is nothing to list (#1152)" {
  # its siblings (react's find, spring's grep -l) print nothing on no-match; an
  # unguarded printf would emit one blank line, which a consumer reading
  # one-path-per-line turns into [""] — a manifest entry naming no file
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a manifest path containing a space stays ONE line (#1152)" {
  mkdir -p "$W/my charts/app"
  printf 'apiVersion: v2\nname: a\nversion: 0.1.0\n' > "$W/my charts/app/Chart.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "my charts/app/Chart.yaml" ]
}

@test "the manifests recipe applies the SAME ! -type d guard (#1152)" {
  # the parity oracles derive -name, prune and --exclude-dir tokens but NOT the
  # type guard, and none of the behavioural tests above touches it — so deleting
  # it (a directory named Kustomization becomes a manifests entry naming no file)
  # or swapping it for -type f (symlinked charts silently dropped) would ship
  # green while the marker and gather copies keep the identical claim tested
  mkdir -p "$W/base/Kustomization"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the manifests recipe lists a SYMLINKED manifest (#1152)" {
  mkdir -p "$BATS_TEST_TMPDIR/real" "$W/charts"
  printf 'apiVersion: v2\nname: r\nversion: 0.1.0\n' > "$BATS_TEST_TMPDIR/real/Chart.yaml"
  ln -s "$BATS_TEST_TMPDIR/real/Chart.yaml" "$W/charts/Chart.yaml"
  run list_manifests "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "charts/Chart.yaml" ]
}

@test "the marker and the gather match the SAME filenames (#1152)" {
  local block recipe_names gather_names
  block="$GATHER_BLOCK"
  [ -n "$block" ]
  recipe_names="$(names_of "$RECIPE")"
  gather_names="$(names_of "$block")"
  [ -n "$recipe_names" ]
  [ "$recipe_names" = "$gather_names" ]
  # the THIRD copy — the manifests lister — must agree too, or a repo dispatches
  # as kubernetes with a manifests list that omits its charts
  [ "$recipe_names" = "$(names_of "$MANIFESTS")" ]
  # and the FOURTH — detect-stack's is_kubernetes (#1153): a repo the review
  # dispatcher calls kubernetes but the orchestrator does not gets a review panel
  # its maintenance dispatch never selects, and vice versa
  [ "$recipe_names" = "$(names_of "$DETECT_BLOCK")" ]
  # and the set is the documented one, so a matched pair of deletions still reds
  [ "$recipe_names" = "Chart.yaml Kustomization kustomization.yaml kustomization.yml " ]
}

@test "the marker and the gather prune the SAME trees (#1152)" {
  local block recipe_prunes gather_prunes
  block="$GATHER_BLOCK"
  [ -n "$block" ]
  recipe_prunes="$(prunes_of "$RECIPE")"
  gather_prunes="$(prunes_of "$block")"
  [ -n "$recipe_prunes" ]
  [ "$recipe_prunes" = "$gather_prunes" ]
  [ "$recipe_prunes" = "$(prunes_of "$MANIFESTS")" ]
  [ "$recipe_prunes" = "$(prunes_of "$DETECT_BLOCK")" ]
  [ "$recipe_prunes" = "/\\.git/ /node_modules/ /templates/ /vendor/ " ]
}

@test "the marker and the gather exclude the SAME dirs from the argoproj grep (#1152)" {
  local recipe_ex gather_ex manifests_ex detect_ex
  recipe_ex="$(printf '%s\n' "$RECIPE" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  gather_ex="$(printf '%s\n' "$GATHER_BLOCK" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  manifests_ex="$(printf '%s\n' "$MANIFESTS" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  # derived from the SENTINEL-BOUNDED block, not the whole file: an unbounded
  # union cannot distinguish "present in this recipe" from "present somewhere
  # in a 1600-line script", so a token deleted here but present elsewhere would
  # leave the union — and this test — unchanged
  detect_ex="$(printf '%s\n' "$DETECT_BLOCK" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  [ -n "$recipe_ex" ]
  [ "$recipe_ex" = "$gather_ex" ]
  [ "$recipe_ex" = "$manifests_ex" ]
  [ "$recipe_ex" = "$detect_ex" ]
  # the --include NARROWING, held across the same four copies: without it the
  # argoproj half becomes "any file mentioning Argo"
  local recipe_in gather_in manifests_in detect_in
  recipe_in="$(includes_of "$RECIPE")"
  gather_in="$(includes_of "$GATHER_BLOCK")"
  manifests_in="$(includes_of "$MANIFESTS")"
  detect_in="$(includes_of "$DETECT_BLOCK")"
  [ "$recipe_in" = "--include='*.yaml' --include='*.yml' " ]
  [ "$recipe_in" = "$gather_in" ]
  [ "$recipe_in" = "$manifests_in" ]
  [ "$recipe_in" = "$detect_in" ]
  [ "$recipe_ex" = "--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=templates --exclude-dir=vendor " ]
}

@test "the marker recipe is a PREDICATE, not a topic-list mutation (#1152)" {
  # every sibling recipe's verdict is its exit status; a side-effecting
  # `topics=...; if ... fi` form exits 0 on every repo, so a caller reading $?
  # uniformly across the recipes would detect this topic everywhere
  lacks "$RECIPE" 'topics='
  lacks "$RECIPE" 'topics+='
}

# ---------------------------------------------------------------------------
# The registration rows — without them nothing above is ever reached
# ---------------------------------------------------------------------------

@test "the topics table registers kubernetes against its gather script (#1152)" {
  # anchored on the gather-script column: a bare `^| \`kubernetes\` |` also
  # matches the Required-language row asserted by the next test
  local row
  row="$(grep -E '^\| `kubernetes` \|.*gather-kubernetes-findings\.zsh' "$SKILL")"
  [ -n "$row" ]
  [ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" -eq 1 ]
  contains "$row" 'gather-kubernetes-findings.zsh'
  contains "$row" 'language-agnostic'
  # the marker's three spellings, so the row cannot describe a narrower marker
  # than the recipe below it implements
  contains "$row" 'Chart.yaml'
  contains "$row" 'kustomization.yml'
  contains "$row" 'argoproj.io'
}

@test "the Required-language table gates kubernetes on NO language (#1152)" {
  # the partition step is where the gate is applied; a GitOps repo has no
  # application language, so any requirement here would make the topic
  # permanently undispatchable for exactly the repo it exists to serve
  local table
  table="$(sed -n '/^| Topic | Required language |/,/^$/p' "$SKILL")"
  [ -n "$table" ]
  contains "$table" '| `kubernetes` | none |'
}

@test "the language_meta rule covers the hybrid marker (#1152)" {
  # kubernetes is neither a pure path marker nor a pure content marker, and the
  # topic-payload section forbids inventing a conventional root path — so
  # without an explicit clause the orchestrator has to guess what manifests is
  local skill
  skill="$(cat "$SKILL")"
  contains "$skill" 'HYBRID marker and needs its own clause'
  contains "$skill" 'k8s_paths='
  # the fallback must drop -q, or it would emit an empty path list
  contains "$skill" "grep -rlF 'argoproj.io'"
}

@test "the SKILL states what the orchestrator DOES with marker status 2 (#1177)" {
  # The producer half is pinned thoroughly above, and is worth nothing on its
  # own: the whole value of exit 2 depends on the orchestrator treating it as
  # "not evaluated" -> an unsupported_topics entry, rather than as "marker
  # absent" -> topic silently dropped. That instruction is PROSE, and the recipe
  # extraction strips comments, so without this test the paragraph can be
  # deleted and every other test here stays green while the hardening becomes a
  # no-op. The react twin carries exactly this test for its jq preflight.
  local skill
  skill="$(tr -s '[:space:]' ' ' < "$SKILL")"
  # the three-way read of $?, stated where the partition happens
  contains "$skill" 'three-way read of `$?`'
  contains "$skill" 'the marker was not evaluated'
  # …and the destination bucket, which is the load-bearing half
  contains "$skill" 'kubernetes marker: search did not complete'
  # never the absent bucket — the sentence that makes it a rule, not a hint
  contains "$skill" '**never** the absent bucket'
  # and the manifests lister's own consumer rule (#1177), which is a different
  # step with a different consequence — an empty manifests list, not a dropped topic
  contains "$skill" 'manifest listing did not complete'
  contains "$skill" 'Read the lister'"'"'s EXIT STATUS'
}

@test "EVERY prose consumer of detect-stack's exit contract carries the branch (#1177)" {
  # detect-stack.sh gained its first non-zero exit, which writes NO JSON. Without
  # this branch the phase validates an empty document and halts telling a user
  # with a healthy repo to run `git init` — a confidently wrong message derived
  # from a file that was never written.
  #
  # ARCHITECTURE.md states the caller obligation as a RULE (detect-stack.sh's own
  # header points there rather than enumerating consumers, so this comment must
  # not re-introduce a count). THREE of the bound call sites are prose — a model
  # follows them, no script executes them — so all three are pinned here:
  # maintenance Phase 1, bootstrap Step 1, and resolve-issue's step-3 C4 check.
  # The remaining two are scripts and are pinned behaviourally by their own
  # suites (tests/review-dispatch.bats, tests/gather-docs.bats). Bootstrap is
  # where the producer hardening becomes user-visible, and it re-invokes the
  # script three more times, so its rule is stated as binding every invocation
  # rather than only Step 1's.
  # whitespace-normalised, so a re-wrap of the paragraph cannot red a test whose
  # subject is the RULE, not the line breaks
  local skill bootstrap
  skill="$(tr -s '[:space:]' ' ' < "$SKILL")"
  contains "$skill" 'Check the exit status before parsing'
  contains "$skill" 'Halt and forward that stderr verbatim'
  # and the un-guessable half: the cause is NOT derivable from the stderr
  contains "$skill" 'Do not diagnose the cause beyond what the stderr says'

  bootstrap="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/bootstrap/SKILL.md")"
  contains "$bootstrap" 'detection aborted and printed NO JSON'
  contains "$bootstrap" 'Halt and show that stderr'
  contains "$bootstrap" 'binds EVERY `detect-stack.sh` invocation in this skill'
  # the half both the script header and ARCHITECTURE.md call the failure this
  # contract exists to prevent: the needles above all survive an edit rewriting
  # the rule as "on exit 2, halt", which would read an errexit-aborted detection
  # (exit 1, empty stdout) as success and drive Step 4 off an empty document
  contains "$bootstrap" 'Branch on **non-zero**, never on a specific code'

  # the PARITY claim bootstrap makes in prose ("the same wording maintenance
  # SKILL.md's Phase 1 mandates"), derived rather than trusted — this file's own
  # standard for its four-copy oracles. Both must hedge: rewriting either to
  # assert a cause confidently would hand a user opposite certainties about
  # evidence that cannot distinguish the two causes.
  contains "$skill" 'most likely'
  contains "$bootstrap" 'most likely'
  contains "$skill" 'not "the tree is unreadable"'
  contains "$bootstrap" 'not "the tree is unreadable"'

  # and the canonical statement of the contract — the site detect-stack.sh's
  # header redirects readers to, and the only one that binds FUTURE callers
  local arch
  arch="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" 'has an exit-code contract'
  contains "$arch" 'branch on **non-zero**, never on a specific code'
  contains "$arch" 'must **not** parse the empty document'
  contains "$arch" 'The **stderr is the deliverable**'
  contains "$arch" 'obligation is on every caller'

  # the THIRD prose call site, named by ARCHITECTURE.md and edited by #1177 — no
  # other suite covers it (tests/check-c4-currency.bats tests the comparator
  # script, not the SKILL's invocation prose), so without these needles that
  # branch can be reverted to a bare unchecked run with the whole suite green
  local resolve
  resolve="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  contains "$resolve" 'Branch on NON-ZERO, never on a specific code (#1177)'
  contains "$resolve" "relay detect-stack's stderr above verbatim"
}

@test "the halt branch RENDERS the unsupported bucket before halting (#1177)" {
  # the bucket is worthless if nothing prints it. Phase 9 never runs on the halt
  # branch, so a GitOps-only repo with no language and an unreadable subtree —
  # exactly the repo this topic exists for — would otherwise be reported
  # identically to a repo that has no charts at all.
  local skill
  skill="$(tr -s '[:space:]' ' ' < "$SKILL")"
  contains "$skill" 'print every `unsupported` / `unsupported_topics` entry with its note verbatim first'
  contains "$skill" 'that is not a verdict that this repo has no charts'
}

@test "the gather script is executable — the partition runs test -x (#1152)" {
  [ -x "$GATHER" ]
}

# ---------------------------------------------------------------------------
# The CONSUMER half of the halt contract
#
# tests/kubernetes-dispatcher.bats pins the producer — the dispatcher returning
# plan:[] + missing_tooling:[] + human_action_required. These pin the orchestrator
# rules that make that reach a human. Since #1153 routes every recognised group to
# a shipped agent, the halt shape is now reserved for a payload the dispatcher
# CANNOT UNDERSTAND — an unrouted findings_by_tool key, a dispatch_mode outside
# the enum, manifest_validation:false — which is precisely why the rules below
# still matter: that escalation is the only way such a payload reaches a human,
# and deleting or reordering any of them renders it as "Clean — the topic's tools
# ran and found nothing" with the whole suite green.
# ---------------------------------------------------------------------------

@test "Phase 6 reads human_action_required BEFORE tooling_configured (#1152)" {
  local p6
  p6="$(sed -n '/^A topic'"'"'s `plan` groups join the \*\*same Phase 8 queue/,/^## Phase 7/p' "$SKILL" \
        | tr -s '[:space:]' ' ')"
  [ -n "$p6" ]
  contains "$p6" 'depends first on `human_action_required`'
  contains "$p6" 'the dispatcher *deliberately halted*'
  contains "$p6" 'never render a clean verdict for that topic'
  # the notes rule: the kubernetes gather ALWAYS says its tools did not run, so a
  # clean verdict that ignores the notes is a lie even on the non-halt branch
  contains "$p6" 'presence-detected only'
}

@test "the PRODUCER half of the .language coupling is stated (#1152)" {
  # the dispatcher errors and stops when .language != "kubernetes", and
  # tests/kubernetes-dispatcher.bats pins that consumer half thoroughly. This is
  # the other side: the orchestrator's obligation to carry the topic name there.
  # The edit the rule warns against is the natural one — `language` is a strange
  # key to hold a topic name, so adding a real `topic` key (or nulling it for
  # topics) is the obvious cleanup — and it would leave the whole suite green
  # while every kubernetes dispatch errored into unsupported_topics.
  local tp
  tp="$(sed -n '/^- `language`: the \*\*topic name\*\*/,/^- `dispatch_mode`/p' "$SKILL" \
        | tr -s '[:space:]' ' ')"
  [ -n "$tp" ]
  contains "$tp" 'the **topic name**'
  # the whole two-halved rule: the assignment alone would survive a rewrite that
  # keeps the key but drops the coupling warning, which is the edit that breaks
  # the dispatch
  contains "$tp" 'contractual, not informational'
  # #1160 added a SECOND validating dispatcher, so the rule now names both —
  # the blast radius of a `.language` rename is two topics, not one, and a
  # needle on the singular phrasing would understate it
  contains "$tp" '`development-kubernetes` and `development-opentofu` both do'
  contains "$tp" 'never null it, normalise it, or move the topic name to a new key'
  contains "$tp" '`unsupported_topics` as `dispatch failed`'
}

@test "Phase 7's early-out is not language-only (#1152)" {
  local p7
  p7="$(sed -n '/^## Phase 7 —/,/^## Phase 8/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$p7" ]
  contains "$p7" 'This is not language-only'
  contains "$p7" 'renders the topic as **halted**, never as clean'
  # the load-bearing VERB, not the bare noun: 'dispatch target' alone is
  # satisfied by a negated 'continue all remaining phases for that dispatch
  # target', which is the opposite rule
  contains "$p7" 'skip all remaining phases for that dispatch target'
  # and the scoping half — without it, one topic's halt aborts the whole run
  contains "$p7" 'Every other target still proceeds'
}

@test "Phase 9's topic ladder puts the halt case BEFORE the clean case (#1152)" {
  # the ladder is declared 'ordered and EXHAUSTIVE', so ORDER is the contract:
  # the halt shape is an empty plan with an empty missing_tooling, which falls
  # straight through to 'Clean' if this case is moved after it
  local ladder halt_at clean_at
  ladder="$(sed -n '/^<Verdict — worded from the topic payload/,/^  <Otherwise: state the observed state plainly/p' "$SKILL")"
  [ -n "$ladder" ]
  contains "$ladder" 'non-empty human_action_required'
  contains "$ladder" 'This case comes BEFORE the two below'
  contains "$ladder" 'Halted — <N> group(s) need a human decision.'
  halt_at="$(printf '%s\n' "$ladder" | grep -n 'Halted — <N> group' | head -n1 | cut -d: -f1)"
  clean_at="$(printf '%s\n' "$ladder" | grep -n "Clean — the topic's tools ran" | head -n1 | cut -d: -f1)"
  [ -n "$halt_at" ]
  [ -n "$clean_at" ]
  [ "$halt_at" -lt "$clean_at" ]
}
