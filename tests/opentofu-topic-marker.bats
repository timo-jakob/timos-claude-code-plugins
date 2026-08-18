#!/usr/bin/env bats
#
# The `opentofu` topic marker (epic #1158, child #1160). The orchestrator's
# topic-detection recipe fires on any `*.tf` outside `.terraform/` (the provider
# cache) and vendored trees. `.tf.json` is deliberately NOT matched — the
# charter owns the syntax, the marker does not detect it, and ARCHITECTURE.md
# records why.
#
# CRITICAL DESIGN POINT, copied from tests/kubernetes-topic-marker.bats: these
# tests do NOT re-implement the recipe. They extract the authoritative one from
# the fenced block in development/skills/maintenance/SKILL.md (between the
# `# opentofu-marker:begin` / `:end` sentinels) and `eval` it. A hand-copied
# helper would prove things about this test file rather than about the artifact
# the orchestrator actually follows, letting the SKILL.md recipe drift with a
# green suite. The extraction is asserted non-empty and bounded so a broken
# extraction can never silently make every test vacuous, and every negative test
# asserts the precise no-match status (1) rather than "any failure", so a recipe
# that blows up (127, a set -e abort) cannot masquerade as a clean rejection.
#
# The SECOND thing this file exists for is 3-WAY PARITY. The detection rule is
# stated three times — SKILL.md's recipe (extracted here),
# gather-opentofu-findings.zsh's `gather-opentofu-marker` block, and
# detect-stack.sh's `is-opentofu-marker` block — and SKILL.md asserts in prose
# that all three use the same glob and prune the same trees. That claim is
# DERIVED below rather than trusted: a marker that fires where the gather does
# not produces an empty topic plan on a real provisioning repo, and a gather that
# finds what the marker does not never runs at all. Either way nothing would be
# red.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh"
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"

  # SHAPE guards first. `sed -n '/begin/,/end/p'` prints to END OF FILE when the
  # closing sentinel is missing or renamed, and a duplicated opening sentinel
  # concatenates blocks — either way RECIPE would become most of SKILL.md, whose
  # later fenced blocks contain git/gh commands and $(...) substitutions that
  # `eval` would then execute. Content-only guards cannot catch that, because the
  # real recipe is a PREFIX of the runaway blob. So: pin exactly one sentinel
  # pair, and bound the extraction's size and its first/last lines.
  [ "$(grep -c '^# opentofu-marker:begin$' "$SKILL")" -eq 1 ]
  [ "$(grep -c '^# opentofu-marker:end$' "$SKILL")" -eq 1 ]

  RECIPE="$(sed -n '/^# opentofu-marker:begin$/,/^# opentofu-marker:end$/p' "$SKILL" \
    | grep -v '^#')"
  [ -n "$RECIPE" ]
  # a RUNAWAY guard, not a budget: a sed range that stops matching prints
  # hundreds of lines, and every one of them would be eval'd
  [ "$(printf '%s\n' "$RECIPE" | wc -l)" -le 30 ]
  starts_with "$RECIPE" 'tofu_hits='
  # ends on the verdict ladder's `fi` — the recipe has THREE statuses
  # (0 opentofu / 1 not / 2 could-not-look), so its last line closes the
  # if/elif/else that chooses between them
  ends_with "$RECIPE" 'fi'

  # the gather's own detection block, one operand of the parity oracles
  [ "$(grep -c '^# gather-opentofu-marker:begin$' "$GATHER")" -eq 1 ]
  [ "$(grep -c '^# gather-opentofu-marker:end$' "$GATHER")" -eq 1 ]
  GATHER_BLOCK="$(sed -n '/^# gather-opentofu-marker:begin$/,/^# gather-opentofu-marker:end$/p' "$GATHER")"
  [ -n "$GATHER_BLOCK" ]
  # a RUNAWAY guard, not a budget — the same role as the recipe's bound above.
  # Raised from 40 to 60 when the block gained the `PRUNE_NAMES` derivation that
  # builds both prune forms from one declaration (the `.tf.json` probe must
  # prune during its walk, so it cannot reuse the `grep -v` operand list). The
  # bound still catches a runaway `sed` range by an order of magnitude.
  [ "$(printf '%s\n' "$GATHER_BLOCK" | wc -l)" -le 60 ]

  # ...and detect-stack.sh's, the third copy (#1160). It is NOT eval'd — it
  # carries `cd`/`exit 125` branches that only make sense inside that script —
  # so it is joined to the parity oracles textually, exactly as the kubernetes
  # sibling joins its own detect-stack block.
  [ "$(grep -c '^# is-opentofu-marker:begin$' "$DETECT")" -eq 1 ]
  [ "$(grep -c '^# is-opentofu-marker:end$' "$DETECT")" -eq 1 ]
  DETECT_BLOCK="$(sed -n '/^# is-opentofu-marker:begin$/,/^# is-opentofu-marker:end$/p' "$DETECT")"
  [ -n "$DETECT_BLOCK" ]
  [ "$(printf '%s\n' "$DETECT_BLOCK" | wc -l)" -le 40 ]

  # WHICH FORM each copy uses is asserted, not inferred. `prunes_of` picks its
  # extraction by emptiness, which works only because the grep-operand pattern
  # cannot match the gather's derived `-e "/${_pn}/"` (double-quoted). That is an
  # accident of quoting, and the gather's own source comment already warns that a
  # comment in that block can hijack these extractors — if one ever does,
  # prunes_of would read the wrong form and red pointing at prune drift that does
  # not exist. These guards make that failure name itself.
  contains "$RECIPE" "-e '/"
  contains "$DETECT_BLOCK" "-e '/"
  contains "$GATHER_BLOCK" 'PRUNE_NAMES=('
  lacks "$GATHER_BLOCK" "-e '/"
  # BOTH spellings, because prunes_of's first-branch regex makes the quote
  # OPTIONAL (`\-e '?/[^ ']+'?`) and the two non-gather copies use the unquoted
  # form. Guarding only the quoted one leaves a comment inside the gather's
  # sentinels that merely mentions `-e /vendor/` free to hijack the extractor —
  # very plausible, since that block's comments already discuss the `grep -v`
  # operand list — while this guard stays green.
  lacks "$GATHER_BLOCK" "-e /"
}

# Run the extracted recipe in $1 and return its status. `eval` in a subshell so
# a recipe that ever gained a stray `exit` cannot kill the test run — and so the
# `( exit 2 )` predicate form is observed as a status rather than a side effect.
marker() {
  ( cd "$1" && eval "$RECIPE" ) >/dev/null 2>&1
}

# same, but keeping stderr, for the not-evaluated message
marker_stderr() {
  ( cd "$1" && eval "$RECIPE" ) 2>&1 >/dev/null
}

# --- the parity oracles ------------------------------------------------------
# LC_ALL=C on every sort below. The literal pins are in C-collation order, and
# under a glibc en_US.UTF-8 locale punctuation is ignored at the primary level —
# so `.git .terraform node_modules vendor` would sort as
# `.git node_modules .terraform vendor` and the pin would red for a reason
# unrelated to prune drift. tests/opentofu-plugin-skeleton.bats guards its own
# entry-set equality the same way and for the same reason.
# `-name '<glob>'` tokens, quotes stripped — the marker glob.
glob_of() {
  printf '%s\n' "$1" | grep -oE "\-name '[^']+'" | sed "s/-name //; s/'//g" | LC_ALL=C sort -u | tr '\n' ' '
}

# The prune set, normalised to BARE DIRECTORY NAMES so the three copies can be
# compared across the two spellings they legitimately use:
#
#   * the SKILL.md recipe and detect-stack.sh write literal `grep -v` operands
#     (`-e '/\.terraform/'`), because they filter a captured list;
#   * the gather declares `PRUNE_NAMES` and DERIVES both a `grep -v` operand list
#     and a `find` prune expression from it — it needs the latter because its
#     `.tf.json` probe must prune during the walk, and a name list is the only
#     form that can produce both.
#
# Comparing raw text would therefore red on a difference of syntax rather than of
# behaviour. What must agree is WHICH TREES are excluded, so that is what this
# extracts: strip the operand marker, quotes, escapes and slashes, from
# whichever form the copy uses. The LEADING DOT is deliberately KEPT — stripping
# it made `.terraform` and `terraform` compare equal, so a copy edited to prune
# `/terraform/` instead of `/\.terraform/` passed while detecting a repo the
# other two reject. It is not needed for the cross-form comparison either: both
# spellings already normalise to `.terraform`.
prunes_of() {
  local block="$1" raw
  raw="$(printf '%s\n' "$block" | grep -oE "\-e '?/[^ ']+'?" || true)"
  if [ -z "$raw" ]; then
    # the derived form: read the single declaration instead
    raw="$(printf '%s\n' "$block" \
      | sed -n '/PRUNE_NAMES=(/,/^)/p' | sed '1d;$d' | tr -s '[:space:]' '\n')"
  fi
  printf '%s\n' "$raw" \
    | sed "s/^-e //; s|'||g; s|\\\\||g; s|/||g" \
    | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' '
}

# find's type guard. Neither the glob nor the prune oracle covers it, and it is
# load-bearing in all three copies: without it a DIRECTORY someone named
# `env.tf` fires the topic on a repo with no HCL at all, and a copy that dropped
# it would detect a repo the other two reject — the divergence this file exists
# to prevent, with nothing else red.
type_guards_of() {
  printf '%s\n' "$1" | grep -oE '! -type d|-type f' | LC_ALL=C sort -u | tr '\n' ' '
}

# --- the verdict -------------------------------------------------------------

@test "a repo with a .tf at the root is opentofu (#1381)" {
  printf 'provider "aws" {}\n' > "$W/main.tf"
  run -0 marker "$W"
}

@test "a .tf nested in a module tree is opentofu" {
  mkdir -p "$W/modules/network"
  printf 'variable "cidr" {\n  type = string\n}\n' > "$W/modules/network/vpc.tf"
  run -0 marker "$W"
}

@test "a repo with no .tf at all is NOT opentofu — status exactly 1" {
  printf '# readme\n' > "$W/README.md"
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: a\n' > "$W/charts/app/Chart.yaml"
  run -1 marker "$W"
}

@test "an empty repo is NOT opentofu — status exactly 1" {
  run -1 marker "$W"
}

@test "a repo whose only .tf sit under the pruned trees yields status exactly 1 (#1382)" {
  # the criterion the story pins by number: pruned-only must be a clean
  # rejection, never a could-not-look and never a match
  mkdir -p "$W/.terraform/providers" "$W/vendor/modules" "$W/node_modules/x" "$W/.git"
  printf 'provider "aws" {}\n' > "$W/.terraform/providers/cached.tf"
  printf 'provider "aws" {}\n' > "$W/vendor/modules/v.tf"
  printf 'provider "aws" {}\n' > "$W/node_modules/x/n.tf"
  printf 'provider "aws" {}\n' > "$W/.git/hook.tf"
  run -1 marker "$W"
}

@test "each pruned tree is pruned on its own, so no single -e token can be deleted" {
  # a fixture carrying all four at once stays green if three of the four tokens
  # are removed; one directory per case is what makes each token load-bearing
  local d
  for d in .terraform vendor node_modules .git; do
    rm -rf "$W"
    mkdir -p "$W/$d/inner"
    printf 'provider "aws" {}\n' > "$W/$d/inner/x.tf"
    run -1 marker "$W"
  done
}

@test "a real .tf still fires when pruned copies also exist" {
  mkdir -p "$W/.terraform"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  printf 'provider "aws" {}\n' > "$W/main.tf"
  run -0 marker "$W"
}

@test "a DIRECTORY named main.tf is not a module — the ! -type d guard" {
  # neither the glob nor the prune oracle pins this guard — `type_guards_of`
  # does, and pins its TEXT across all three copies; this test pins its
  # BEHAVIOUR in the extracted recipe. Without the guard a directory someone
  # named `env.tf` fires the topic on a repo with no HCL at all
  mkdir -p "$W/main.tf"
  run -1 marker "$W"
}

@test ".tf.json is NOT matched — the recorded decision, not an accident" {
  printf '{"provider": {"aws": {}}}\n' > "$W/main.tf.json"
  run -1 marker "$W"
}

@test "a file merely ENDING in tf is not matched" {
  printf 'x\n' > "$W/notes.rtf"
  printf 'x\n' > "$W/tf"
  run -1 marker "$W"
}

@test "the recipe is a predicate — it registers nothing and has no side-effecting tail" {
  # a recipe ending in `if … fi` that REGISTERED the topic would exit 0 whether
  # or not the marker fired, so the caller's $? would stop meaning anything.
  # Proven by the negative cases above returning exactly 1, and pinned here
  # against the text so a future `topics+=(opentofu)` tail is caught directly.
  lacks "$RECIPE" 'topics+='
  lacks "$RECIPE" 'supported_topics'
}

@test "the recipe never uses a bare exit, which would kill the orchestrator's shell" {
  # `( exit 2 )` yields the status without terminating a caller that eval'd it
  contains "$RECIPE" '( exit 2 )'
  run -0 bash -c "printf '%s\n' \"\$1\" | grep -cE '^[[:space:]]*exit ' || true" _ "$RECIPE"
  [ "$output" = "0" ]
}

@test "a search that did not complete is status 2, never a clean rejection" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  # an unreadable directory makes find exit 1 with no hits — "could not look",
  # which must never render as "this repo has no infrastructure code"
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run -2 marker "$W"
  chmod 755 "$W/locked"
}

@test "the not-evaluated status carries a named reason on stderr" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run marker_stderr "$W"
  chmod 755 "$W/locked"
  contains "$output" "opentofu marker: search did not complete"
  contains "$output" 'refusing to report "not opentofu"'
}

@test "a HIT stands even when the search did not complete" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  # the same rule the gather inherits: an unfinished search taints only the
  # NEGATIVE verdict, so a repo with modules AND an unreadable sibling is still
  # detected rather than refused
  printf 'provider "aws" {}\n' > "$W/main.tf"
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run -0 marker "$W"
  chmod 755 "$W/locked"
}

@test "the recipe captures before it filters — a piped grep -q would invert under pipefail" {
  # `find … | grep -q` exits at the first match, find dies of SIGPIPE, and the
  # pipeline reports non-zero even though a module WAS found — a failure that
  # only appears once find's output outruns the pipe buffer. The capture is what
  # makes it pipefail-safe, so it is pinned textually AND exercised below.
  contains "$RECIPE" 'tofu_hits="$(find'
  lacks "$RECIPE" 'grep -q'
}

@test "the recipe survives pipefail with a large tree (the SIGPIPE case)" {
  # THE FIXTURE MUST OUTRUN THE PIPE BUFFER or it proves nothing: the inversion
  # needs the writer still blocked when grep exits, and the buffer is 16 KiB on
  # macOS / 64 KiB on Linux. 400 short paths are ~6 KB — comfortably inside it —
  # so the earlier form of this test passed against the broken recipe too. Long
  # directory names push `find`'s OUTPUT (which is what is piped here, not the
  # file contents) past the threshold, and the byte count is asserted so a later
  # trim cannot silently take it back below.
  local i deep
  deep="d$(printf 'e%.0s' {1..120})p"
  mkdir -p "$W/many/$deep"
  for i in $(seq 1 600); do printf 'provider "aws" {}\n' > "$W/many/$deep/m$i.tf"; done
  local bytes
  bytes="$(cd "$W" && find . -name '*.tf' | wc -c | tr -d ' ')"
  [ "$bytes" -gt 65536 ]
  run -0 bash -c "set -o pipefail; cd '$W' && eval \"\$1\"" _ "$RECIPE"
}

# --- 3-way parity ------------------------------------------------------------

@test "the marker GLOB is identical across all three copies (#1387)" {
  local a b c
  a="$(glob_of "$RECIPE")"
  b="$(glob_of "$GATHER_BLOCK")"
  c="$(glob_of "$DETECT_BLOCK")"
  # non-empty first: two failed extractions comparing equal as "" would be a
  # vacuous pass, which is precisely how a parity test rots
  [ "$a" = "*.tf " ]
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
}

@test "the PRUNE SET is identical across all three copies (#1387)" {
  local a b c
  a="$(prunes_of "$RECIPE")"
  b="$(prunes_of "$GATHER_BLOCK")"
  c="$(prunes_of "$DETECT_BLOCK")"
  [ -n "$a" ]
  # pinned as a literal too, not only as a three-way equality: three copies
  # edited together stay equal to each other while silently ceasing to prune
  # the provider cache
  [ "$a" = ".git .terraform node_modules vendor " ]
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
}

@test "the TYPE GUARD is identical across all three copies (#1387)" {
  local a b c
  a="$(type_guards_of "$RECIPE")"
  b="$(type_guards_of "$GATHER_BLOCK")"
  c="$(type_guards_of "$DETECT_BLOCK")"
  [ "$a" = "! -type d " ]
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
}

@test "detect-stack applies the type guard too — a directory named env.tf is not HCL" {
  # the behavioural twin of the recipe's own directory test, on the copy the
  # oracle above can only compare textually
  mkdir -p "$W/env.tf"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu == false' >/dev/null"
}

@test "the gather agrees with the marker on a pruned-only repo (#1387)" {
  # the parity that actually matters, exercised rather than derived: a marker
  # that fires where the gather does not yields an empty topic plan on a real
  # repo, and neither would be red
  mkdir -p "$W/.terraform"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  run -1 marker "$W"
  run -0 bash -c "zsh '$GATHER' '$W' | jq -e '.tooling_configured.format == false' >/dev/null"
}

@test "the gather agrees with the marker on a detected repo (#1387)" {
  printf 'provider "aws" {}\n' > "$W/main.tf"
  run -0 marker "$W"
  run -0 bash -c "zsh '$GATHER' '$W' | jq -e '.tooling_configured.format == true' >/dev/null"
}

@test "detect-stack agrees with the marker on a detected repo (#1387)" {
  printf 'provider "aws" {}\n' > "$W/main.tf"
  run -0 marker "$W"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu == true' >/dev/null"
}

@test "detect-stack agrees with the marker on a pruned-only repo (#1387)" {
  mkdir -p "$W/vendor/modules"
  printf 'provider "aws" {}\n' > "$W/vendor/modules/v.tf"
  run -1 marker "$W"
  # `== false`, never `| not`: `null | not` is TRUE, so the weaker form would
  # pass if the key were dropped from the envelope entirely or degraded to null
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu == false' >/dev/null"
}

@test "detect-stack emits is_opentofu as a real boolean, not a string" {
  printf 'provider "aws" {}\n' > "$W/main.tf"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu | type == \"boolean\"' >/dev/null"
}

@test "detect-stack's copy carries the cd/125 branches the recipe must NOT have" {
  # parity is over the GLOB and the PRUNE SET, not byte-equality: this copy runs
  # inside a script with a $cwd and its own exit contract, and pasting these
  # branches into the orchestrator recipe would kill the shell that eval'd it
  contains "$DETECT_BLOCK" 'exit 125'
  lacks "$RECIPE" 'exit 125'
  lacks "$RECIPE" '$cwd'
}

# --- the SKILL.md contract around the recipe ---------------------------------

@test "the topic table lists opentofu with its gather script" {
  run -0 grep -F '| `opentofu` |' "$SKILL"
  contains "$output" 'gather-opentofu-findings.zsh'
}

@test "opentofu requires no language — a provisioning repo has none" {
  # the required-language table is the single place the gate is applied, so a
  # row saying anything else would make every .tf-only repo undispatchable
  run -0 grep -F '| `opentofu` | none |' "$SKILL"
}

@test "the gather script the topic table names exists and is executable" {
  # the orchestrator partitions on `test -x`; a table row naming a
  # non-executable file puts the topic in unsupported_topics forever
  [ -x "$GATHER" ]
}

@test "SKILL.md documents the opentofu exit-2 row alongside the kubernetes one" {
  run -0 grep -F 'opentofu marker: search did not complete' "$SKILL"
}

@test "a directory named _terraform is NOT pruned by the recipe or detect-stack" {
  # The ESCAPING is the one thing no parity oracle can see: `prunes_of` strips
  # backslashes so the two spellings can be compared at all, so unescaping
  # `'/\.terraform/'` to `/terraform/` in either non-gather copy leaves all
  # three oracles green while the marker silently starts pruning `_terraform/`,
  # `1terraform/`, `agit/`. The gather's twin of this test lives in
  # tests/gather-opentofu.bats; these two cover the other copies.
  mkdir -p "$W/_terraform"
  printf 'provider "aws" {}\n' > "$W/_terraform/main.tf"
  run -0 marker "$W"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu == true' >/dev/null"
}

@test "a directory named agit is NOT pruned by the recipe or detect-stack" {
  mkdir -p "$W/agit"
  printf 'provider "aws" {}\n' > "$W/agit/main.tf"
  run -0 marker "$W"
  run -0 bash -c "cd '$W' && bash '$DETECT' | jq -e '.is_opentofu == true' >/dev/null"
}

# --- a FAILING prune filter is an unfinished search in every copy ------------
# `|| true` absorbs a status without inspecting it, so grep's operational error
# (exit 2) and a missing grep (127) were absorbed exactly like the intended
# no-match 1. The hits went empty with the FIND's status still 0, so each copy's
# "did not complete" arm did not fire and every one of them answered "not
# opentofu" for a search that never finished. All three carry the fix; all three
# are pinned here, because the parity oracles compare the glob, the prune set
# and the type guard — never the error handling.

@test "the RECIPE refuses (2) when the prune filter itself fails" {
  printf 'provider "aws" {}\n' > "$W/main.tf"
  local stub="$BATS_TEST_TMPDIR/stub" real
  mkdir -p "$stub"
  real="$(command -v grep)"
  printf '#!/usr/bin/env bash\ncase "$*" in *".terraform"*) exit 2 ;; esac\nexec %s "$@"\n' \
    "$real" > "$stub/grep"
  chmod +x "$stub/grep"
  run env "PATH=$stub:$PATH" bash -c "cd '$W' && $(printf '%s' "$RECIPE")"
  [ "$status" -eq 2 ]
  contains "$output" "did not complete"
}

@test "the recipe still reports plain no-match (1) when grep merely finds nothing" {
  # the other side: exit 1 is the genuine "everything was pruned" answer and
  # must NOT be read as an unfinished search, or every non-OpenTofu repo starts
  # refusing to answer
  mkdir -p "$W/.terraform"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  run marker "$W"
  [ "$status" -eq 1 ]
}

@test "detect-stack refuses (2) when the opentofu prune filter fails" {
  # a BLANKET failing grep cannot isolate this arm — detect-stack greps
  # throughout, and the kubernetes marker (which refuses the same way) runs
  # first, so the test would pass on the wrong guard's message. Fail only the
  # invocation carrying the opentofu prune operands and delegate every other.
  printf 'provider "aws" {}\n' > "$W/main.tf"
  local stub="$BATS_TEST_TMPDIR/stub2" real
  mkdir -p "$stub"
  real="$(command -v grep)"
  printf '#!/usr/bin/env bash\ncase "$*" in *".terraform"*) exit 2 ;; esac\nexec %s "$@"\n' \
    "$real" > "$stub/grep"
  chmod +x "$stub/grep"
  run env "PATH=$stub:$PATH" bash -c "cd '$W' && bash '$DETECT'"
  [ "$status" -eq 2 ]
  contains "$output" "refusing to report is_opentofu false"
  lacks "$output" "is_kubernetes"
}
