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
# twice — here and in gather-kubernetes-findings.zsh — and SKILL.md asserts in
# prose that the two prune the same trees. That claim is DERIVED below rather
# than trusted: a marker that fires where the gather does not produces an empty
# topic plan on a real GitOps repo, and a gather that finds what the marker does
# not never runs at all. Either way nothing would be red.

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
  [ "$(printf '%s\n' "$RECIPE" | wc -l)" -le 14 ]
  starts_with "$RECIPE" 'k8s_hits='
  ends_with "$RECIPE" '. 2>/dev/null'
  contains "$RECIPE" 'argoproj.io'

  # the SECOND executable kubernetes recipe: the path lister that fills
  # language_meta.manifests. It is a THIRD copy of the prune and --exclude-dir
  # sets, so it gets the same sentinel treatment and the same derived oracles.
  [ "$(grep -c '^  # kubernetes-manifests:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^  # kubernetes-manifests:end$' "$SKILL")" -eq 1 ]
  MANIFESTS="$(sed -n '/^  # kubernetes-manifests:begin$/,/^  # kubernetes-manifests:end$/p' "$SKILL" \
    | grep -v '^  #' | sed 's/^  //')"
  [ -n "$MANIFESTS" ]
  [ "$(printf '%s\n' "$MANIFESTS" | wc -l)" -le 16 ]
  starts_with "$MANIFESTS" 'k8s_paths='
  ends_with "$MANIFESTS" '|| printf '"'"'%s\n'"'"' "$k8s_paths"'

  # and the gather's own detection block, the parity oracles' other operand. Its
  # sed range needs the SAME shape guards as RECIPE above and for the same
  # reason: an end address that stops matching prints to EOF, after which the
  # oracles would compare a runaway blob — and still pass, because the rest of
  # the script's `-name` tokens are quoted and invisible to names_of.
  [ "$(grep -c '^manifest_hits=' "$GATHER")" -eq 1 ]
  GATHER_BLOCK="$(sed -n '/^manifest_hits=/,/|| true)"$/p' "$GATHER")"
  [ -n "$GATHER_BLOCK" ]
  [ "$(printf '%s\n' "$GATHER_BLOCK" | wc -l)" -le 10 ]
  starts_with "$GATHER_BLOCK" 'manifest_hits='
  ends_with "$GATHER_BLOCK" '|| true)"'
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

@test "both recipes survive an unreadable subtree under errexit (#1152)" {
  # the orchestrator runs its detection block under `set -e` / `pipefail`, which
  # is why both recipes carry `2>/dev/null` and `|| true` on the capture. Drop
  # the `|| true` and one unreadable directory aborts the WHOLE topic detection.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  chart
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$RECIPE")"
  local marker_status="$status"
  run bash -c "set -e; set -o pipefail; cd '$W'; $(printf '%s' "$MANIFESTS")"
  local lister_status="$status" lister_output="$output"
  chmod 755 "$W/locked"
  [ "$marker_status" -eq 0 ]
  [ "$lister_status" -eq 0 ]
  contains "$lister_output" 'charts/app/Chart.yaml'
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
  [ "$recipe_prunes" = "/\\.git/ /node_modules/ /templates/ /vendor/ " ]
}

@test "the marker and the gather exclude the SAME dirs from the argoproj grep (#1152)" {
  local recipe_ex gather_ex manifests_ex
  recipe_ex="$(printf '%s\n' "$RECIPE" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  gather_ex="$(grep -oE '\-\-exclude-dir=[a-z_.]+' "$GATHER" | sort -u | tr '\n' ' ')"
  manifests_ex="$(printf '%s\n' "$MANIFESTS" | grep -oE '\-\-exclude-dir=[a-z_.]+' | sort -u | tr '\n' ' ')"
  [ -n "$recipe_ex" ]
  [ "$recipe_ex" = "$gather_ex" ]
  [ "$recipe_ex" = "$manifests_ex" ]
  # the --include NARROWING, held across the same three copies: without it the
  # argoproj half becomes "any file mentioning Argo"
  local recipe_in gather_in manifests_in
  recipe_in="$(includes_of "$RECIPE")"
  gather_in="$(includes_of "$(cat "$GATHER")")"
  manifests_in="$(includes_of "$MANIFESTS")"
  [ "$recipe_in" = "--include='*.yaml' --include='*.yml' " ]
  [ "$recipe_in" = "$gather_in" ]
  [ "$recipe_in" = "$manifests_in" ]
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

@test "the gather script is executable — the partition runs test -x (#1152)" {
  [ -x "$GATHER" ]
}

# ---------------------------------------------------------------------------
# The CONSUMER half of the halt contract
#
# tests/kubernetes-dispatcher.bats pins the producer — the dispatcher returning
# plan:[] + missing_tooling:[] + human_action_required. These pin the orchestrator
# rules that make that reach a human. Until #1153, EVERY kubernetes finding comes
# back as a halt of exactly that shape, so deleting or reordering any of the rules
# below renders every kubernetes run as "Clean — the topic's tools ran and found
# nothing" with the whole suite green.
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
  contains "$tp" '`development-kubernetes` does'
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
