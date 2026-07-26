#!/usr/bin/env bats
#
# Behavioral tests for the human-curated suggestion-promotion overlay (#994,
# epic #992): `consolidate-findings.zsh --promote FILE` raises a human-selected
# set of waived Low findings to blocking, and `resolve-story-loop.zsh --promote`
# forwards the path to the consolidator on every round of the promotion sub-loop.
#
# One test per linked test-case issue, named in the test title so a reader can
# trace a case to its coverage: #1019-#1020 and #1022-#1026 live here; #1021
# (the loop pass-through) is split across tests/resolve-story-loop.bats (hook
# mode, the up-front refusals) and tests/resolve-story-loop-step.bats (the
# cross-invocation persistence and adoption — the load-bearing half, since a
# --resume that lost the overlay would converge as a false success). The load-bearing properties are the
# two that a naive implementation gets wrong: a promoted item must survive its
# own fix shifting the line (identity matching, not exact-key equality), and a
# run WITHOUT --promote must stay byte-identical, which is what keeps
# autonomous/headless runs provably unchanged.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh"
  F="$BATS_TEST_TMPDIR/findings.json"
  P="$BATS_TEST_TMPDIR/promote.json"

  # The representative finding throughout: the real file/dimension/title a
  # reviewer would raise against this very script, per the story's use_case.
  TARGET_FILE="development/skills/resolve-issue/scripts/consolidate-findings.zsh"
  TARGET_TITLE="LINEWIN is a magic number"
}

con() { run zsh "$S" --findings "$F" "$@"; }
# stdout/stderr split: the error-path contract is "a diagnostic on stderr and
# NO changelist on stdout". bats merges the two by default, which would make
# the stdout-is-empty assertion pass on the diagnostic text alone.
con_sep() { run --separate-stderr zsh "$S" --findings "$F" "$@"; }

# one waived Low finding at $1 (default 113)
low_finding() {
  local line="${1:-113}"
  local title="${2:-$TARGET_TITLE}"
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":$line,
  "title":"$title","description":"extract a named constant","reviewer":"script-reviewer"}]
EOF
}

# a promote file selecting the finding as the human saw it (file:113)
promote_target() {
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
}

# --- #1019 happy: promote bumps a Low into blocking -------------------------

@test "#1019 promote: a selected Low finding lands in blocking[] at priority High" {
  low_finding
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq '.summary.high' <<<"$output")" -eq 1 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.blocking[0].title' <<<"$output")" = "$TARGET_TITLE" ]
  [ "$(jq -r '.blocking[0].priority' <<<"$output")" = "High" ]
  [ "$(jq '.blocking[0].blocking' <<<"$output")" = "true" ]
  [ "$(jq -r '.blocking[0].severity' <<<"$output")" = "WARNING" ]
  # and it is GONE from suggestions — promoted, not duplicated into both
  [ "$(jq '.suggestions | length' <<<"$output")" -eq 0 ]
}

@test "#1019 promote: an unselected Low finding is untouched alongside a promoted one" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"extract a named constant","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"tests","file":"tests/consolidate-findings.bats","line":40,
  "title":"Assertion could be stronger","description":"assert the whole object","reviewer":"test-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "Assertion could be stronger" ]
  [ "$(jq -r '.suggestions[0].priority' <<<"$output")" = "Low" ]
}

# --- #1020 happy: a promoted item survives its own fix shifting the line ----

@test "#1020 promote: still promoted when the line drifts within the window" {
  # The human selected it at :113; fixing something above it moved it to :119.
  # Exact [file,line,dimension,title] equality would silently un-promote here,
  # and the sub-loop would converge without doing the work that was asked for.
  low_finding 119
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq '.blocking[0].line' <<<"$output")" -eq 119 ]
}

@test "#1020 promote: NOT promoted once the drift exceeds the proximity window" {
  # 113 -> 140 is well outside LINEWIN (10): beyond the window it is no longer
  # evidence of the same finding, so the overlay must not reach across it.
  low_finding 140
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
}

@test "#1020 promote: a null line on the finding is a wildcard, still promoted" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":null,
  "title":"$TARGET_TITLE","description":"extract a named constant","reviewer":"script-reviewer"}]
EOF
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

# --- #1024 corner: disjoint titles are not promoted -------------------------

@test "#1024 promote: a proximity-gathered finding with disjoint title tokens is NOT promoted" {
  # Same file, same dimension, two lines away — but a genuinely different
  # finding. Gathering alone must not promote it; the title verdict decides.
  low_finding 115 "Prefer printf over the echo builtin"
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "Prefer printf over the echo builtin" ]
  [ "$(jq -r '.suggestions[0].priority' <<<"$output")" = "Low" ]
}

@test "#1024 promote: a reworded title sharing a significant token IS promoted" {
  # The ambiguous branch of the #983 verdict: a reword must not defeat the
  # match, so a shared significant token still promotes (fail toward doing what
  # the human asked, exactly as the non-convergence verdict fails toward them).
  low_finding 113 "LINEWIN should be a documented constant"
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "#1024 promote: a different dimension at the same line is NOT promoted" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"tests","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d","reviewer":"test-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  # ...and it stayed WAIVED — blocking==0 alone would also hold if the overlay
  # had dropped the finding from the changelist entirely
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "$TARGET_TITLE" ]
}

# --- #1022 corner: no --promote is byte-identical (the headless path) -------

@test "#1022 promote: omitting --promote leaks no promotion state into the document" {
  # A headless/autonomous run passes no --promote at all, so its changelist must
  # be indistinguishable from one produced before this feature existed. Asserting
  # a few scalars would pass on a build that added a `promoted` key to every
  # item, reordered `summary`, or added a top-level field — so pin the SHAPE.
  low_finding
  run --separate-stderr zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -Sc 'keys' <<<"$output")" = '["blocking","conflicts","escalation_reasons","false_trips","non_converging","round","suggestions","summary"]' ]
  [ "$(jq -Sc '.summary | keys' <<<"$output")" = '["blocking","conflicts","critical","false_trips","high","low"]' ]
  [ "$(jq -Sc '.suggestions[0] | keys' <<<"$output")" = '["agreement","blocking","description","dimension","false_trip","file","line","non_converging","priority","reviewers","severity","suggested_fix","title"]' ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.suggestions[0].priority' <<<"$output")" = "Low" ]
}

@test "#1022 promote: a promoted key matching nothing this round is a silent no-op" {
  # The item was already fixed, so nothing matches — the sub-loop must be able
  # to converge, not error out on a key it can no longer find.
  low_finding
  cat > "$P" <<'EOF'
[{"file":"some/other/file.zsh","line":1,"dimension":"tests","title":"already fixed"}]
EOF
  con --round 3 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
}

# --- #1023 corner: an empty promoted array is a no-op ------------------------

@test "#1023 promote: an empty array yields byte-identical output to no flag at all" {
  # Compare FILES, not bats' $output: $output strips trailing newlines and (without
  # --separate-stderr) merges stderr in, so a trailing-newline or diagnostic
  # difference would be invisible behind a claim of byte-identity.
  low_finding
  printf '[]' > "$P"
  zsh "$S" --findings "$F" --round 1 > "$BATS_TEST_TMPDIR/without.json" 2> "$BATS_TEST_TMPDIR/without.err"
  zsh "$S" --findings "$F" --round 1 --promote "$P" > "$BATS_TEST_TMPDIR/with.json" 2> "$BATS_TEST_TMPDIR/with.err"
  cmp -s "$BATS_TEST_TMPDIR/without.json" "$BATS_TEST_TMPDIR/with.json"
  [ ! -s "$BATS_TEST_TMPDIR/without.err" ]
  [ ! -s "$BATS_TEST_TMPDIR/with.err" ]
}

# --- #1019/#1020 regression: promoted items behave like real blockers -------

@test "promote: a promoted blocker carried into the next round escalates as non-converging" {
  # The point of promotion is that the loop treats these as blockers in every
  # downstream sense — including refusing to spin on one that never gets fixed.
  low_finding
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  local prev="$BATS_TEST_TMPDIR/prev.json"
  printf '%s' "$output" > "$prev"

  low_finding
  con --round 2 --promote "$P" --prev "$prev"
  [ "$status" -eq 0 ]
  [ "$(jq '.non_converging' <<<"$output")" = "true" ]
  [ "$(jq -r '.escalation_reasons | index("non_converging_blocker") != null' <<<"$output")" = "true" ]
}

@test "promote: the conflict item sees the PROMOTED priority (overlay runs before classification)" {
  # NB: conflict detection has no severity filter, so `.summary.conflicts == 1`
  # holds with or without --promote and proves nothing. What DOES differ is the
  # priority the conflict item carries for the promoted dimension, so assert
  # that — and pair it with the identical fixture run WITHOUT --promote, so the
  # test measures the delta rather than a constant.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d","reviewer":"script-reviewer"},
 {"severity":"WARNING","dimension":"performance","file":"$TARGET_FILE","line":113,
  "title":"avoid the extra jq pass","description":"d","reviewer":"perf"}]
EOF
  promote_target

  # control: no overlay -> the code_quality side is still Low, one blocker
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conflicts[0].items[] | select(.dimension=="code_quality") | .priority' <<<"$output")" = "Low" ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]

  # promoted -> the conflict item reports High, and both sides now block
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conflicts[0].items[] | select(.dimension=="code_quality") | .priority' <<<"$output")" = "High" ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 2 ]
  [ "$(jq '.summary.conflicts' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.escalation_reasons | index("unresolved_conflict") != null' <<<"$output")" = "true" ]
}

@test "promote: an already-blocking finding is left alone by a matching key" {
  # A promoted key must never re-stamp a reviewer-raised finding — it only ever
  # raises Low. A CRITICAL matching the key must stay Critical, not become High.
  cat > "$F" <<EOF
[{"severity":"CRITICAL","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d","reviewer":"script-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocking[0].priority' <<<"$output")" = "Critical" ]
  [ "$(jq '.summary.critical' <<<"$output")" -eq 1 ]
  [ "$(jq '.summary.high' <<<"$output")" -eq 0 ]
}

# --- #1025 error: invalid / unreadable promote JSON --------------------------

@test "#1025 promote: a nonexistent promote file exits 1 with no changelist on stdout" {
  low_finding
  con_sep --round 1 --promote "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # an absent file is "missing", not "malformed" — the diagnostic must send the
  # caller to the right problem, and it must never blame the findings file
  contains "$stderr" "--promote must be a non-empty regular file"
  lacks "$stderr" "invalid findings JSON"
}

@test "#1025 promote: malformed JSON exits 1 with no changelist on stdout" {
  low_finding
  printf 'not json at all' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "--promote file unreadable, or not a JSON array of objects with non-empty file and dimension and a string title"
}

@test "#1025 promote: valid JSON that is not an array exits 1" {
  # An object would abort jq mid-program on `$promote[]` and blank the
  # changelist while still exiting 0 — a silent empty round. Refuse it up front.
  low_finding
  printf '{"file":"a.zsh"}' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "not a JSON array"
}

@test "#1025 promote: an empty promote file exits 1" {
  low_finding
  : > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # named as the PROMOTE file, not misreported as invalid findings: jq exits 0
  # with empty output on an empty file, so an unguarded capture reaches
  # --argjson and fails in the final jq, blaming the wrong input entirely
  contains "$stderr" "--promote must be a non-empty regular file"
  lacks "$stderr" "invalid findings JSON"
}

# --- #1026 error: the _need_val contract on both scripts ---------------------

@test "#1026 promote: --promote with no value exits 2 (usage)" {
  low_finding
  con --round 1 --promote
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a value"
}

@test "#1026 promote: --promote followed by another flag exits 2 (usage)" {
  low_finding
  con --promote --round 1
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a value (got the flag --round)"
}

@test "#1026 promote: --promote with an explicitly empty value exits 2 (usage)" {
  # The realistic `--promote "$VAR"` with VAR unset. Left alone it reads as
  # "flag omitted" and converges having promoted nothing the human picked.
  low_finding
  con --round 1 --promote ""
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a non-empty value"
}

# A half-applied guard is the inconsistency the next caller trips on: these used
# to abort with zsh's raw nounset error and exit 1, which this script's taxonomy
# reserves for INTERNAL errors. One @test per flag, so a failure localizes.

@test "#1026 the consolidator's --round requires a value (exit 2)" {
  low_finding
  run zsh "$S" --findings "$F" --round
  [ "$status" -eq 2 ]
  contains "$output" "--round requires a value"
}

@test "#1026 the consolidator's --prev requires a value (exit 2)" {
  low_finding
  run zsh "$S" --findings "$F" --prev
  [ "$status" -eq 2 ]
  contains "$output" "--prev requires a value"
}

@test "#1026 the consolidator's --findings requires a value (exit 2)" {
  run zsh "$S" --findings
  [ "$status" -eq 2 ]
  contains "$output" "--findings requires a value"
}

# --- multi-item selection: the headline use case is a multiSelect of 0..N ------

@test "promote: selecting several items promotes exactly those, leaving the rest waived" {
  # Every other fixture promotes one item, so an implementation that read
  # $promote[0], or stopped at the first match, would pass the whole suite while
  # promoting one of the three things the human picked.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"tests","file":"tests/consolidate-findings.bats","line":40,
  "title":"Assertion could be stronger","description":"d2","reviewer":"test-reviewer"},
 {"severity":"SUGGESTION","dimension":"prose_logic","file":"development/skills/resolve-issue/SKILL.md","line":700,
  "title":"Unstated failure branch","description":"d3","reviewer":"prose-logic"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"$TARGET_TITLE"},
 {"file":"development/skills/resolve-issue/SKILL.md","line":700,"dimension":"prose_logic","title":"Unstated failure branch"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 2 ]
  [ "$(jq '.summary.high' <<<"$output")" -eq 2 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  # the ONE survivor is the unselected one, by title
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "Assertion could be stronger" ]
}

@test "promote: an already-promoted item is no longer an eligible candidate" {
  # NB: with a single finding this is guaranteed by the still-Low filter alone,
  # so it does not exercise the claimed list — the fixture below does.
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"$TARGET_TITLE"},
 {"file":"$TARGET_FILE","line":115,"dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.blocking | length' <<<"$output")" -eq 1 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 0 ]
}

@test "promote: two keys whose NEAREST candidate is the same item still raise two items" {
  # Both keys sit at 114, so both rank the item at 113 first, and the second key
  # falls through to 118. NB the mechanism that makes it fall through is the
  # still-Low filter — key 1 rewrites 113 to High, so it is no longer a candidate
  # — not the `claimed` list, which is defensive belt-and-braces that only
  # becomes load-bearing if the overlay ever stops rewriting priority. What this
  # pins is the observable contract: two keys raise two DISTINCT items.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"LINEWIN naming is unclear","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":114,"dimension":"code_quality","title":"LINEWIN constant naming"},
 {"file":"$TARGET_FILE","line":114,"dimension":"code_quality","title":"LINEWIN constant comment"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 2 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 0 ]
}

# --- the overlay runs AFTER dedup, and merges rather than rewrites ------------

@test "promote: the key matches the CONSOLIDATED title and the item keeps its dedup fields" {
  # Two reviewers on the same file+line+dimension: dedup keeps the
  # longest-description representative, which is the title the human was shown.
  # This pins BOTH halves of the documented placement — after dedup (the key
  # matches the surviving title) and merge-not-rewrite (agreement/reviewers/
  # description survive promotion, so the fix pass and dossier keep their
  # evidence).
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"short one","description":"brief","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"a considerably longer and more detailed description of the same defect","reviewer":"test-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.blocking | length' <<<"$output")" -eq 1 ]
  [ "$(jq '.summary.high' <<<"$output")" -eq 1 ]
  [ "$(jq '.blocking[0].agreement' <<<"$output")" -eq 2 ]
  [ "$(jq '.blocking[0].reviewers | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.blocking[0].description' <<<"$output")" = "a considerably longer and more detailed description of the same defect" ]
  [ "$(jq -r '.blocking[0].title' <<<"$output")" = "$TARGET_TITLE" ]
}

# --- the promote key's own line field ----------------------------------------

@test "promote: a key with no line at all is a wildcard across the file+dimension" {
  low_finding 140
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "promote: a key with an explicit null line is a wildcard too" {
  low_finding 140
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":null,"dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

# a promote key carrying a digit-only STRING line
promote_string_line() {
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":"113","dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
}

@test "promote: a digit-STRING line is NOT silently widened to a wildcard" {
  # Without the shared normline rule, "line":"113" would be a non-number ->
  # wildcard, quietly turning "near 113" into "anywhere in this file+dimension"
  # and promoting a Low 27 lines away.
  low_finding 140
  promote_string_line
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "$TARGET_TITLE" ]
}

@test "promote: a digit-STRING line still matches inside the window (recovery is lossless)" {
  low_finding 119
  promote_string_line
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "promote: a leading ./ on the PROMOTE key normalizes to the same file" {
  low_finding
  cat > "$P" <<EOF
[{"file":"./$TARGET_FILE","line":113,"dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "promote: a leading ./ on the FINDING normalizes to the same file" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"./$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d","reviewer":"script-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

# --- #1025 continued: arrays of NON-OBJECTS ----------------------------------

@test "#1025 promote: an array of strings is refused, naming the promote file" {
  low_finding
  printf '["%s"]' "$TARGET_TITLE" > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "identity-key objects"
  lacks "$stderr" "invalid findings JSON"
}

@test "#1025 promote: an array of numbers is refused, naming the promote file" {
  low_finding
  printf '[113]' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "identity-key objects"
  lacks "$stderr" "invalid findings JSON"
}

@test "#1025 promote: a non-object array is refused even on a round with NO Low findings" {
  # The overlay only evaluates $promote[] for Low items, so a guard that lived
  # inside the jq program would accept this file today and explode next round.
  cat > "$F" <<EOF
[{"severity":"CRITICAL","dimension":"bugs","file":"$TARGET_FILE","line":10,
  "title":"real blocker","description":"d","reviewer":"bug-hunter"}]
EOF
  printf '["a title"]' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "identity-key objects"
}

@test "#1025 promote: a file holding two concatenated arrays is refused" {
  # the realistic shape when a retry re-writes the scratch file with >> not >
  low_finding
  printf '[]\n[{"file":"a.zsh","line":1,"dimension":"tests","title":"t"}]\n' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "exactly ONE JSON array"
  lacks "$stderr" "invalid findings JSON"
}

@test "#1026 promote: a junk --round is a usage error, not a misattributed internal one" {
  # --round is interpolated as raw JSON, so an unvalidated value failed inside
  # the final jq and was reported as "invalid findings JSON" with exit 1
  low_finding
  con_sep --round abc
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--round must be a non-negative integer"
  lacks "$stderr" "invalid findings JSON"
}

@test "#1026 promote: a leading-zero --round is normalised, not rejected" {
  # legal shell, illegal JSON — it must not reach --argjson as `03`
  low_finding
  con --round 03
  [ "$status" -eq 0 ]
  [ "$(jq '.round' <<<"$output")" -eq 3 ]
}

# --- the two TOKENLESS verdict branches (highest blast radius) ---------------

@test "promote: a finding whose title yields no significant token is promoted regardless of the key" {
  # `($ct | length) == 0 then true` — a title of only short words cannot be
  # compared, so the overlay fails toward doing what the human asked. Free to
  # invert today: flipping this true to false leaves the rest of the suite green.
  low_finding 113 "fix it now"
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"completely unrelated wording"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "promote: a key with an empty title promotes, but stays bounded by the window" {
  # `select(((.title // "") | sigtokens | length) == 0)` — a tokenless KEY is a
  # wildcard over the file+dimension, so it must still be fenced by line
  # proximity or it would promote everything in the file.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":400,
  "title":"a distant unrelated finding","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":""}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  # the far one is untouched — the tokenless wildcard is bounded by the window
  # AND by the one-item-per-key rule
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "a distant unrelated finding" ]
}

@test "promote: an OMITTED title is refused; an EMPTY title is the (bounded) tokenless wildcard" {
  # The wildcard is expressed by an empty title, which is present-but-tokenless.
  # An omitted key is a mis-keyed file and is refused up front — it used to
  # degrade to "matches nothing", i.e. the human's selection silently dropped.
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality"}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "objects with non-empty file and dimension and a string title"

  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":""}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

# --- the proximity window's exact edge ---------------------------------------

@test "promote: a drift of exactly LINEWIN (10) is still promoted" {
  low_finding 123
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
}

@test "promote: a drift of LINEWIN + 1 is NOT promoted" {
  low_finding 124
  promote_target
  con --round 2 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
}

# --- the no-flag shape guard, over a document that is not the sparsest --------

@test "#1022 promote: no --promote leaks nothing into a document with blockers, conflicts and a carried match" {
  # The original shape guard ran on a single waived Low, so blocking[], conflicts[]
  # and the carried-blocker fields were all absent — the very item shape the
  # overlay mutates was never pinned. Run it over a realistic round-2 document.
  cat > "$F" <<EOF
[{"severity":"CRITICAL","dimension":"bugs","file":"a.zsh","line":10,
  "title":"nil deref","description":"d","reviewer":"bug-hunter"},
 {"severity":"WARNING","dimension":"performance","file":"b.zsh","line":20,
  "title":"n plus one","description":"d","reviewer":"perf"},
 {"severity":"WARNING","dimension":"code_quality","file":"b.zsh","line":20,
  "title":"extract helper","description":"d","reviewer":"quality"},
 {"severity":"SUGGESTION","dimension":"tests","file":"c.zsh","line":30,
  "title":"weak assertion","description":"d","reviewer":"test-reviewer"}]
EOF
  zsh "$S" --findings "$F" --round 1 > "$BATS_TEST_TMPDIR/prev.json"
  run --separate-stderr zsh "$S" --findings "$F" --round 2 --prev "$BATS_TEST_TMPDIR/prev.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -Sc 'keys' <<<"$output")" = '["blocking","conflicts","escalation_reasons","false_trips","non_converging","round","suggestions","summary"]' ]
  [ "$(jq -Sc '.blocking[0] | keys' <<<"$output")" = '["agreement","blocking","description","dimension","false_trip","file","line","matched_prior","non_converging","possible_false_trip","priority","reviewers","severity","suggested_fix","title"]' ]
  [ "$(jq -Sc '.conflicts[0] | keys' <<<"$output")" = '["between","detail","file","items","line"]' ]
  [ "$(jq -Sc '.conflicts[0].items[0] | keys' <<<"$output")" = '["dimension","priority","title"]' ]
  # and it really is a non-trivial document
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 3 ]
  [ "$(jq '.summary.conflicts' <<<"$output")" -eq 1 ]
}

# --- promote-key fields that match NOTHING (silent no-op, not a wildcard) -----
#
# Unlike an omitted line, which is a documented wildcard, an omitted or
# differently-cased `file`/`dimension` compares unequal and matches nothing — the
# human's selection is silently dropped and the sub-loop converges having done
# none of the work. Pin the contract in both directions so it is a decision.

@test "promote: a key with the file omitted is refused, not silently unmatched" {
  # A mis-keyed selection used to compare against "" and match nothing, so the
  # sub-loop converged having promoted none of what the human picked — with no
  # diagnostic anywhere. It is a typed refusal now.
  low_finding
  cat > "$P" <<EOF
[{"line":113,"dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "objects with non-empty file and dimension and a string title"
}

@test "promote: a WRONG-VALUED (but present) dimension still just matches nothing" {
  # The keys must be present; their values are still matched, not validated —
  # a real dimension that simply does not occur here is a legitimate no-op.
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"tests","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
}

@test "promote: the dimension comparison is case-SENSITIVE, so a mis-cased key matches nothing" {
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"Code_Quality","title":"$TARGET_TITLE"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 0 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
}

@test "promote: a key with TWO token-compatible candidates raises only the nearest" {
  # The eligible set genuinely holds 2 here: the key's title exact-matches
  # NEITHER item but shares a significant token with BOTH, so the exact-title arm
  # cannot collapse the set. This is the fixture that actually exercises the
  # one-to-one bound — an unbounded map would raise both.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"LINEWIN constant naming"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq '.blocking[0].line' <<<"$output")" -eq 113 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  [ "$(jq '.suggestions[0].line' <<<"$output")" -eq 118 ]
}

@test "promote: with two eligible candidates it picks the NEAREST, not the first" {
  # Same fixture, key moved to 120 — now the nearer candidate is the one at 118.
  # Without the distance sort this would still raise 113 and the mis-promotion
  # would be silent: one blocker at High either way.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":120,"dimension":"code_quality","title":"LINEWIN constant naming"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq '.blocking[0].line' <<<"$output")" -eq 118 ]
  [ "$(jq '.suggestions[0].line' <<<"$output")" -eq 113 ]
}

@test "promote: a line-less candidate ranks LAST among eligible ones" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":null,
  "title":"LINEWIN needs naming","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":120,"dimension":"code_quality","title":"LINEWIN constant naming"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq '.blocking[0].line' <<<"$output")" -eq 118 ]
}

@test "promote: an exact-title key takes its own item, leaving the token-neighbour waived" {
  # The overlay is ONE-TO-ONE: a key claims its nearest eligible candidate and
  # nothing else. Unbounded, a single selection would raise every
  # title-compatible Low in the window — blocking work the human never picked,
  # any of which can escalate the run at round 2.
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  promote_target
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.blocking[0].title' <<<"$output")" = "$TARGET_TITLE" ]
  # the neighbour the human did NOT pick stays waived
  [ "$(jq '.summary.low' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.suggestions[0].title' <<<"$output")" = "LINEWIN deserves a comment" ]
}

@test "promote: TWO keys raise TWO items — the bound is per key, not per run" {
  cat > "$F" <<EOF
[{"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":113,
  "title":"$TARGET_TITLE","description":"d1","reviewer":"script-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"$TARGET_FILE","line":118,
  "title":"LINEWIN deserves a comment","description":"d2","reviewer":"script-reviewer"}]
EOF
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":"$TARGET_TITLE"},
 {"file":"$TARGET_FILE","line":118,"dimension":"code_quality","title":"LINEWIN deserves a comment"}]
EOF
  con --round 1 --promote "$P"
  [ "$status" -eq 0 ]
  [ "$(jq '.summary.blocking' <<<"$output")" -eq 2 ]
  [ "$(jq '.summary.low' <<<"$output")" -eq 0 ]
}

@test "#1025 promote: a DIRECTORY exits 1, naming the path type not the contents" {
  # -s alone is true for a directory; without the -f half the caller is pointed
  # at the file's CONTENTS for a problem that is the path's type. Both sibling
  # suites pin this, so the consolidator's must too.
  low_finding
  con_sep --round 1 --promote "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "--promote must be a non-empty regular file"
  lacks "$stderr" "objects with non-empty file and dimension and a string title"
}

@test "#1025 promote: an array of key-less objects is refused, not silently no-oped" {
  # `[{}]` and mis-keyed objects passed a bare type=="object" predicate, then
  # compared against empty strings and matched nothing — the sub-loop converging
  # having promoted none of what the human picked, with no diagnostic anywhere.
  low_finding
  printf '%s' '[{}]' > "$P"
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "objects with non-empty file and dimension and a string title"
}

@test "#1025 promote: an EMPTY file or dimension value is refused (present but useless)" {
  # file and dimension are compared for equality, so an empty one matches only a
  # finding whose own field was missing — a mis-valued key that would otherwise
  # look like a legitimate no-op.
  low_finding
  cat > "$P" <<EOF
[{"file":"","dimension":"code_quality","title":"$TARGET_TITLE"}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "non-empty file and dimension"

  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","dimension":"","title":"$TARGET_TITLE"}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "non-empty file and dimension"
}

@test "#1025 promote: a NULL title is refused, but an empty string is accepted" {
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"dimension":"code_quality","title":null}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "a string title"
}

@test "#1025 promote: an object missing only 'dimension' is refused" {
  low_finding
  cat > "$P" <<EOF
[{"file":"$TARGET_FILE","line":113,"title":"$TARGET_TITLE"}]
EOF
  con_sep --round 1 --promote "$P"
  [ "$status" -eq 1 ]
  contains "$stderr" "objects with non-empty file and dimension and a string title"
  lacks "$stderr" "invalid findings JSON"
}
