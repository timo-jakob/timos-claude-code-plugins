#!/usr/bin/env bats
#
# Behavioral tests for rollup-telemetry.zsh (#1007, epic #740 child (e)): the
# thin, stream-generic jq rollup over telemetry/v1 streams — plus its built-in
# v0->v1 adapter for the two pre-contract legacy files (review-loop.jsonl /
# refine-issue.jsonl), which are read where they lie and never migrated.
#
# tests/fixtures/telemetry/v0-review-loop.jsonl and v0-refine-issue.jsonl are
# VERBATIM copies of real pre-contract records (the live sinks are
# git-ignored, so vendoring is forced): v0-review-loop.jsonl (issue 912
# CONVERGED rounds 1 wall_s 7; issue 969 BUDGET_EXHAUSTED rounds 9 wall_s 8257),
# v0-refine-issue.jsonl (issue 796 parked/deferred wall_s 300; issue 902
# refined-ready wall_s 480). v1-mixed.jsonl and v1-multi-repo.jsonl are
# HAND-BUILT telemetry/v1 streams (contract-shaped, not vendored) and may be
# edited/extended freely: v1-mixed.jsonl holds two review-loop runs, one
# refine-issue run, one enrichment record, and one deliberately malformed
# line; v1-multi-repo.jsonl holds records split across two distinct named
# repos (one a non-trivial prefix of the other, to catch a substring-match
# regression) plus one record with repo: null.
#
# Numeric measures are asserted via --json + jq EQUALITY, never via a text-mode
# `contains` substring: "runs: 2" also matches "runs: 25", so a substring
# needle at the end of a line can pass on an inflated value. Text-mode
# assertions are reserved for RENDERING (e.g. the "-" withheld marker).
#
# Exit codes are asserted EXACTLY: 0 success (incl. empty stream and skipped
# malformed lines), 2 usage, 3 internal — the shared taxonomy
# emit-telemetry.zsh / validate-telemetry.zsh already use.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/telemetry/rollup-telemetry.zsh"
  ZSH_BIN="$(command -v zsh)"
  FIX="$REPO_ROOT/tests/fixtures/telemetry"
}

# jq-extract one field from a --json array's first (or Nth, 0-based) entry.
_jqf() { echo "$1" | jq -r "$2"; }
# same, but COMPACT (-c) — for comparing a whole object/array as one string.
_jqfc() { echo "$1" | jq -c "$2"; }

# ------------------------------------------------------------- v0 adaptation

@test "v0-review-loop.jsonl: run count, outcome mix, mean rounds/wall_s, escalation rate" {
  run zsh "$S" --json "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":1,"parked":0,"escalated":1,"failed":0}' ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "5" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "4132" ]
  [ "$(_jqf "$output" '.[0].escalation_rate')" = "0.5" ]
}

@test "v0-refine-issue.jsonl: refined-ready -> success, parked -> parked, in both directions" {
  run zsh "$S" --json "$FIX/v0-refine-issue.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "refine-issue" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":1,"parked":1,"escalated":0,"failed":0}' ]
  [ "$(_jqf "$output" '.[0].escalation_rate')" = "0" ]
}

@test "v0 pipeline attribution is filename-first under canonical names" {
  local d="$BATS_TEST_TMPDIR/canon"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/review-loop.jsonl"
  cp "$FIX/v0-refine-issue.jsonl" "$d/refine-issue.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  local rl_count refine_count unknown_count
  rl_count=$(echo "$output" | jq '[.[] | select(.pipeline == "review-loop")] | length')
  refine_count=$(echo "$output" | jq '[.[] | select(.pipeline == "refine-issue")] | length')
  unknown_count=$(echo "$output" | jq '[.[] | select(.pipeline == "unknown")] | length')
  [ "$rl_count" -eq 1 ]
  [ "$refine_count" -eq 1 ]
  [ "$unknown_count" -eq 0 ]
}

@test "v0 shape-sniff fallback attributes review-loop correctly under stdin (no filename)" {
  run bash -c "cat '$FIX/v0-review-loop.jsonl' | zsh '$S' --json -"
  [ "$status" -eq 0 ]
  # both records land in ONE review-loop group, not split with a stray unknown
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "v0 shape-sniff fallback attributes refine-issue correctly under stdin (no filename)" {
  run bash -c "cat '$FIX/v0-refine-issue.jsonl' | zsh '$S' --json -"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "refine-issue" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "shape-sniff and filename-first attribution genuinely agree on the same records" {
  # The stdin side has no name at all, so it MUST go through shape-sniff. The
  # file side is copied to the canonical filename so it genuinely exercises
  # filename-first — comparing the fixture's own basename against itself would
  # exercise shape-sniff on BOTH sides and never touch the filename branch.
  run --separate-stderr bash -c "cat '$FIX/v0-review-loop.jsonl' | zsh '$S' --json -"
  [ "$status" -eq 0 ]
  local from_stdin="$output"
  [ "$(_jqf "$from_stdin" '.[0].run_count')" = "2" ]

  local d="$BATS_TEST_TMPDIR/agree"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/review-loop.jsonl"
  run --separate-stderr zsh "$S" --json "$d/review-loop.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_stdin" ]
}

@test "filename-first attribution wins over a CONFLICTING shape-sniff result" {
  # A record shaped like refine-issue (objections_raised) but filed under the
  # canonical review-loop filename must still attribute to review-loop —
  # filename is checked FIRST, never overridden by a shape match.
  local d="$BATS_TEST_TMPDIR/conflict"
  mkdir -p "$d"
  echo '{"objections_raised":1,"outcome":"parked","rounds":1,"wall_s":5}' > "$d/review-loop.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  # The OUTCOME is the half that proves narrowing follows the ATTRIBUTED
  # pipeline rather than re-sniffing: as review-loop it narrows on the absent
  # `status` -> failed. A re-sniffing regression would read outcome:"parked"
  # -> parked while leaving `pipeline` review-loop either way.
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":0,"parked":0,"escalated":0,"failed":1}' ]
}

@test "a v0 record matching neither shape lands in the unknown pipeline bucket" {
  local f="$BATS_TEST_TMPDIR/mystery.jsonl"
  echo '{"ts":1700000000,"wall_s":42,"rounds":1,"outcome":"whatever"}' > "$f"
  run bash -c "cat '$f' | zsh '$S' --json -"
  [ "$status" -eq 0 ]
  contains "$output" '"pipeline":"unknown"'
  # unknown-pipeline outcome is never guessed from a field it doesn't own
  contains "$output" '"outcome_mix":{"success":0,"parked":0,"escalated":0,"failed":1}'
}

@test "outcome narrowing mirrors the (b)/(c) retrofits for every legacy status" {
  local f="$BATS_TEST_TMPDIR/statuses.jsonl"
  {
    echo '{"status":"CONVERGED","findings_by_round":[],"rounds":1,"wall_s":1}'
    echo '{"status":"SKIPPED","findings_by_round":[],"rounds":1,"wall_s":1}'
    echo '{"status":"ERROR","findings_by_round":[],"rounds":1,"wall_s":1}'
    echo '{"status":"BUDGET_EXHAUSTED","findings_by_round":[],"rounds":1,"wall_s":1}'
    echo '{"status":"ESCALATE_NO_CONVERGENCE","findings_by_round":[],"rounds":1,"wall_s":1}'
    # …plus the two catch-all arms the named statuses never reach: an
    # UNRECOGNIZED status string, and a non-string status. Both must land on
    # the never-a-guess `failed`, not on some "unknown escalation states are
    # escalations" guess.
    echo '{"status":"WEIRD_NEW_STATUS","findings_by_round":[],"rounds":1,"wall_s":1}'
    echo '{"status":null,"findings_by_round":[],"rounds":1,"wall_s":1}'
  } > "$f"
  run zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  # CONVERGED, SKIPPED -> success (2); ERROR + the two catch-alls -> failed (3);
  # BUDGET_EXHAUSTED, ESCALATE_NO_CONVERGENCE -> escalated (2)
  contains "$output" '"outcome_mix":{"success":2,"parked":0,"escalated":2,"failed":3}'
}

@test "v0 refine-issue narrowing has the same never-a-guess catch-all for unknown and non-string outcomes" {
  # narrow_refine's third arm and its non-string guard: the only refine
  # narrowing otherwise exercised is the fixture's parked/refined-ready pair.
  # Filename-attributed so it genuinely reaches narrow_refine rather than the
  # pipeline-level unknown catch-all.
  local d="$BATS_TEST_TMPDIR/refine-catchall"
  mkdir -p "$d"
  { echo '{"objections_raised":1,"outcome":"abandoned","rounds":1,"wall_s":5}'
    echo '{"objections_raised":1,"outcome":null,"rounds":1,"wall_s":5}'; } > "$d/refine-issue.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "refine-issue" ]
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":0,"parked":0,"escalated":0,"failed":2}' ]
}

@test "v0 outcome narrowing follows the ATTRIBUTED pipeline, not a second shape re-sniff" {
  # A record living in review-loop.jsonl (filename-attributed) but missing the
  # shape-sniff field findings_by_round must still narrow via the
  # review-loop status vocabulary, not fall through to the "failed" catch-all.
  local d="$BATS_TEST_TMPDIR/attr"
  mkdir -p "$d"
  echo '{"status":"CONVERGED","rounds":1,"wall_s":5}' > "$d/review-loop.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].outcome_mix.success')" = "1" ]
  [ "$(_jqf "$output" '.[0].outcome_mix.failed')" = "0" ]
}

# ------------------------------------------------------------ stdin / files

@test "stdin and file input yield byte-identical, non-empty numbers" {
  run zsh "$S" "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  local from_file="$output"
  # non-numeric anchor only — the real numbers are pinned by jq equality
  # elsewhere; this test's own job is the stdin/file equality below.
  contains "$from_file" "Pipeline: review-loop"
  run bash -c "cat '$FIX/v0-review-loop.jsonl' | zsh '$S' -"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_file" ]
}

@test "the documented argument order (operand first, flags after) is honoured" {
  run --separate-stderr zsh "$S" "$FIX/v1-mixed.jsonl" --json --pipeline review-loop
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "a directory aggregates every *.jsonl and ignores everything else" {
  local d="$BATS_TEST_TMPDIR/dir"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/"
  cp "$FIX/v0-refine-issue.jsonl" "$d/"
  echo "not telemetry at all" > "$d/notes.txt"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  [ "$total" -eq 4 ]
}

@test "a directory read is non-recursive: a nested subdirectory's *.jsonl is ignored" {
  local d="$BATS_TEST_TMPDIR/nested"
  mkdir -p "$d/sub"
  cp "$FIX/v0-review-loop.jsonl" "$d/"
  cp "$FIX/v0-refine-issue.jsonl" "$d/sub/deep.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  [ "$total" -eq 2 ]
}

@test "a directory named *.jsonl inside the DIR operand is ignored, not fed to jq" {
  local d="$BATS_TEST_TMPDIR/weirdentry"
  mkdir -p "$d/weird.jsonl"
  cp "$FIX/v0-review-loop.jsonl" "$d/good.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  [ "$total" -eq 2 ]
}

@test "a symlink to a real *.jsonl inside a DIR IS followed and read" {
  local d="$BATS_TEST_TMPDIR/symlinked"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/real.jsonl"
  ln -s real.jsonl "$d/link.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  # real.jsonl (2) + link.jsonl, the SAME file followed through the symlink (2)
  [ "$total" -eq 4 ]
}

@test "a DANGLING *.jsonl symlink inside a DIR is ignored, not fed to jq as a source" {
  local d="$BATS_TEST_TMPDIR/dangling"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/good.jsonl"
  ln -s /nonexistent/target.jsonl "$d/dangling.jsonl"
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "a FILE or DIR path containing a space is handled" {
  local d="$BATS_TEST_TMPDIR/dir with space"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/has space.jsonl"
  run zsh "$S" --json "$d/has space.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
  run zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "-- ends option parsing so a leading-dash-named file can be given" {
  local d="$BATS_TEST_TMPDIR/dashname"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/-shared.jsonl"
  run zsh "$S" --json -- "$d/-shared.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "-- with TWO following operands is still the one-input usage error" {
  # The -- arm has its own inner loop calling the same one-operand guard;
  # a `break` after the first argument would silently accept the second.
  run zsh "$S" -- "$FIX/v0-review-loop.jsonl" "$FIX/v0-refine-issue.jsonl"
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "a bare trailing -- with no operand falls through to the default sink, not a usage error" {
  local d="$BATS_TEST_TMPDIR/bare-dashdash"
  mkdir -p "$d"
  run bash -c "cd '$d' && zsh '$S' --"
  [ "$status" -eq 0 ]
  [ "$output" = "no records" ]
}

# ---------------------------------------------------------------- v1-mixed

@test "v1-mixed.jsonl: review-loop values are asserted exactly (mean_rounds/mean_wall_s/outcome_mix/escalation_rate)" {
  run --separate-stderr zsh "$S" --json "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  local rl
  rl=$(echo "$output" | jq -c '.[] | select(.pipeline == "review-loop")')
  [ "$(echo "$rl" | jq '.run_count')" = "2" ]
  [ "$(echo "$rl" | jq -c '.outcome_mix')" = '{"success":1,"parked":0,"escalated":1,"failed":0}' ]
  [ "$(echo "$rl" | jq '.mean_rounds')" = "3" ]
  [ "$(echo "$rl" | jq '.mean_wall_s')" = "606" ]
  [ "$(echo "$rl" | jq '.escalation_rate')" = "0.5" ]
}

@test "v1-mixed.jsonl: refine-issue values are asserted exactly" {
  run --separate-stderr zsh "$S" --json "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  local ri
  ri=$(echo "$output" | jq -c '.[] | select(.pipeline == "refine-issue")')
  [ "$(echo "$ri" | jq '.run_count')" = "1" ]
  [ "$(echo "$ri" | jq -c '.outcome_mix')" = '{"success":1,"parked":0,"escalated":0,"failed":0}' ]
  [ "$(echo "$ri" | jq '.mean_rounds')" = "1" ]
  [ "$(echo "$ri" | jq '.mean_wall_s')" = "480" ]
  [ "$(echo "$ri" | jq '.escalation_rate')" = "0" ]
}

@test "kind:enrichment is excluded from run counts and outcome mix" {
  run --separate-stderr zsh "$S" --json "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  # 2 review-loop + 1 refine-issue run records; the enrichment and the
  # malformed line are both excluded.
  [ "$total" -eq 3 ]
}

@test "a malformed line warns on stderr naming its source and line number, does not blind the rest, and exit stays 0" {
  run --separate-stderr zsh "$S" "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  contains "$stderr" "v1-mixed.jsonl: line 3:"
  contains "$stderr" "malformed"
  contains "$output" "Pipeline: review-loop"
  contains "$output" "Pipeline: refine-issue"
}

@test "a valid-JSON but non-object line is skipped with a warning, like a malformed one" {
  local f="$BATS_TEST_TMPDIR/nonobject.jsonl"
  {
    echo '{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}'
    echo '42'
    echo '"a string"'
    echo '[1,2]'
    echo '{"schema":"telemetry/v1","kind":"run","run_id":"b","parent_run_id":null,"ts":2,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}'
  } > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  contains "$stderr" "line 2"
  contains "$stderr" "line 3"
  contains "$stderr" "line 4"
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "blank and whitespace-only lines are skipped SILENTLY (no warning, no shifted line numbers)" {
  local f="$BATS_TEST_TMPDIR/blanks.jsonl"
  {
    echo '{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}'
    printf '\n   \n\t\n'
    echo 'not json at all'
  } > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  # the malformed line is line 5 (1 record + 3 blank lines), never line 2
  contains "$stderr" "line 5"
  lacks "$stderr" "line 2"
  lacks "$stderr" "line 3"
  lacks "$stderr" "line 4"
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
}

@test "the unknown pipeline is an ORDINARY --json entry, with the identical key set" {
  # Not a special-cased object, not a trailing note — the documented shape is
  # "unknown included as just another entry". Needs a stream that actually
  # produces an unknown bucket alongside a named one, which v1-mixed cannot.
  local f="$BATS_TEST_TMPDIR/unknown-entry.jsonl"
  { echo '{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"review-loop","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"payload":{"rounds":1}}'
    echo '{"ts":1700000000,"wall_s":42,"rounds":1,"outcome":"whatever"}'; } > "$f"
  run --separate-stderr bash -c "cat '$f' | zsh '$S' --json -"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "2" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "unknown")] | length')" = "1" ]
  # every entry — unknown included — carries exactly the same key set
  [ "$(_jqfc "$output" '[.[] | keys] | unique')" = '[["escalation_rate","mean_rounds","mean_wall_s","outcome_mix","pipeline","run_count"]]' ]
}

@test "the how-to page is registered in the mkdocs nav, the docs MOC, and the how-to index" {
  # A page missing from any of the three is orphaned; the strict docs build
  # catches only the nav omission, so pin all three here.
  local page="docs/how-to/read-pipeline-telemetry.md"
  [ -f "$REPO_ROOT/$page" ]
  run grep -F "how-to/read-pipeline-telemetry.md" "$REPO_ROOT/mkdocs.yml"
  [ "$status" -eq 0 ]
  run grep -F "how-to/read-pipeline-telemetry.md" "$REPO_ROOT/docs/index.md"
  [ "$status" -eq 0 ]
  run grep -F "(read-pipeline-telemetry.md)" "$REPO_ROOT/docs/how-to/index.md"
  [ "$status" -eq 0 ]
}

@test "--json array shape: exactly the documented keys, no totals entry" {
  run --separate-stderr zsh "$S" --json "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  local kind
  kind=$(echo "$output" | jq -r 'type')
  [ "$kind" = "array" ]
  local keys
  keys=$(echo "$output" | jq -c '[.[] | keys] | unique')
  [ "$keys" = '[["escalation_rate","mean_rounds","mean_wall_s","outcome_mix","pipeline","run_count"]]' ]
  local mix_keys
  mix_keys=$(echo "$output" | jq -c '[.[].outcome_mix | keys] | unique')
  [ "$mix_keys" = '[["escalated","failed","parked","success"]]' ]
  local has_totals
  has_totals=$(echo "$output" | jq '[.[] | select(.pipeline == "total" or .pipeline == "totals")] | length')
  [ "$has_totals" -eq 0 ]
}

# --------------------------------------------------------------- --repo

@test "--repo filters to one repo, genuinely removing the other repo's records" {
  # v1-multi-repo.jsonl spans TWO named repos, so the filtered count is
  # provably different from the unfiltered one — a fixture where --repo
  # excludes nothing would pass even if the flag were parsed and ignored.
  run --separate-stderr zsh "$S" --json --repo owner-a/proj "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].run_count')" = "2" ]
  run --separate-stderr zsh "$S" --json "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].run_count')" = "4" ]
}

@test "--repo matches CASE-INSENSITIVELY, in both directions" {
  # GitHub identities are case-insensitive but case-preserving, so the same
  # repo can reach a sink as Foo/Bar and be filtered for as foo/bar. Without
  # a differently-cased needle here, deleting BOTH ascii_downcase calls from
  # the filter would keep the whole suite green.
  run --separate-stderr zsh "$S" --json --repo owner-a/proj "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  local exact="$output"

  # (a) mixed-case NEEDLE against lowercase records
  run --separate-stderr zsh "$S" --json --repo OWNER-A/Proj "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "$exact" ]

  # (b) lowercase needle against a mixed-case RECORD — the other side of the fold
  local f="$BATS_TEST_TMPDIR/mixedcase.jsonl"
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"Owner-A/Proj","repo_type":null,"pipeline":"review-loop","issue":null,"pr":null,"outcome":"success","wall_s":10,"tokens":null,"payload":{"rounds":1}}' > "$f"
  run --separate-stderr zsh "$S" --json --repo owner-a/proj "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  [ -z "$stderr" ]
}

@test "--repo composes with --pipeline: both filters genuinely remove records" {
  # owner-a/proj has only review-loop runs; owner-a/projected has one of
  # EACH pipeline — so every combination below is a real, distinct answer,
  # not one filter doing all the work while the other is silently ignored.
  run --separate-stderr zsh "$S" --json --repo owner-a/proj --pipeline review-loop "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]

  run --separate-stderr zsh "$S" --json --repo owner-a/projected --pipeline review-loop "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]

  run --separate-stderr zsh "$S" --json --repo owner-a/projected --pipeline refine-issue "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]

  # owner-a/proj has NO refine-issue record — a zero-filled section, not a
  # leak of owner-a/projected's refine-issue run into this repo's count.
  run --separate-stderr zsh "$S" --json --repo owner-a/proj --pipeline refine-issue "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "0" ]
}

@test "--repo excludes unknown-repo (legacy) records and prints an explicit note to stderr" {
  run --separate-stderr zsh "$S" --repo timo-jakob/timos-claude-code-plugins "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  contains "$stderr" "note: excluded 2 record(s) attributed to an unknown repo"
  [ "$output" = "no records" ]
}

@test "--json --repo also prints the exclusion note to stderr, keeping stdout a pure array" {
  run --separate-stderr zsh "$S" --json --repo timo-jakob/timos-claude-code-plugins "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  contains "$stderr" "note: excluded 2 record(s) attributed to an unknown repo"
}

@test "without --repo, unknown-repo (legacy) records are counted, not dropped" {
  run --separate-stderr zsh "$S" --json "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

@test "--repo unknown SELECTS the unknown bucket, and excludes named-repo records" {
  # Run against the MULTI-repo fixture, where exactly 1 of 5 records has
  # repo:null — on an all-unknown fixture "selects the unknown bucket" and
  # "applies no filter at all" produce identical output, so only this fixture
  # can tell the two implementations apart. wall_s 75 is that record alone.
  run --separate-stderr zsh "$S" --json --repo unknown "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "75" ]
}

@test "the --repo unknown reserved value is itself matched case-insensitively" {
  # The exclusion-note suppression compares the DOWNCASED filter to "unknown",
  # so --repo UNKNOWN must behave exactly like --repo unknown: select the
  # bucket AND report nothing excluded.
  run --separate-stderr zsh "$S" --json --repo UNKNOWN "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "75" ]
}

@test "--repo selects the exact named repo, not a prefix of it, in both directions" {
  # owner-a/proj is a non-trivial PREFIX of owner-a/projected: a substring or
  # prefix-match regression in the filter would leak the 3rd/5th records in.
  run --separate-stderr zsh "$S" --json --repo owner-a/proj "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "1" ]
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":1,"parked":0,"escalated":1,"failed":0}' ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "150" ]

  run --separate-stderr zsh "$S" --json --repo owner-a/projected "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" 'length')" = "2" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].run_count')" = "1" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].mean_wall_s')" = "50" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "refine-issue")][0].run_count')" = "1" ]
}

@test "--repo excludes a null-repo record with the unknown-repo note, same as a legacy record" {
  run --separate-stderr zsh "$S" --json --repo owner-a/proj "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  contains "$stderr" "note: excluded 1 record(s) attributed to an unknown repo"
}

@test "an unfiltered run over v1-multi-repo.jsonl counts the null-repo record as unknown, not dropped" {
  run --separate-stderr zsh "$S" --json "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  [ "$total" -eq 5 ]
}

@test "repo is a FILTER, never a grouping dimension — one review-loop group across two repos" {
  # ARCHITECTURE.md states this in bold. v1-multi-repo.jsonl's review-loop
  # records span 3 different repo attributions (owner-a/proj x2,
  # owner-a/projected, unknown) — if `repo` ever leaked into group_by, this
  # would report 3+ review-loop sections instead of one, and/or carry a
  # `repo` key on the per-pipeline object.
  run --separate-stderr zsh "$S" --json "$FIX/v1-multi-repo.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")] | length')" = "1" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].run_count')" = "4" ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0] | has("repo")')" = "false" ]
}

# ----------------------------------------------------------- --pipeline

@test "--pipeline filters to exactly one section" {
  run --separate-stderr zsh "$S" --json --pipeline review-loop "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 1 ]
  local name
  name=$(echo "$output" | jq -r '.[0].pipeline')
  [ "$name" = "review-loop" ]
}

@test "--pipeline naming a pipeline with zero matches still reports one zero-filled, withheld section" {
  run --separate-stderr zsh "$S" --json --pipeline does-not-exist "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "does-not-exist" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "0" ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "null" ]
  [ "$(_jqf "$output" '.[0].escalation_rate')" = "null" ]
}

@test "--pipeline naming a pipeline with zero matches renders withheld dashes in text mode" {
  run zsh "$S" --pipeline does-not-exist "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  contains "$output" "Pipeline: does-not-exist"
  contains "$output" "runs: 0"
  contains "$output" "mean rounds: -"
  contains "$output" "mean wall_s: -"
  contains "$output" "escalation rate: -"
}

@test "a non-withheld report renders the real numbers in text mode (outcome mix line included)" {
  run zsh "$S" "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  contains "$output" "outcome mix: success=1 parked=0 escalated=1 failed=0"
  contains "$output" "mean rounds: 5"
  contains "$output" "mean wall_s: 4132"
  contains "$output" "escalation rate: 0.5"
}

@test "--pipeline on a stream with NO records at all prints 'no records', not a synthesized zero section" {
  local f="$BATS_TEST_TMPDIR/empty.jsonl"
  : > "$f"
  run zsh "$S" --pipeline review-loop "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "no records" ]
}

@test "--repo emptying the stream + --pipeline still prints 'no records', not the synthesized section" {
  run zsh "$S" --repo some/other-repo --pipeline review-loop "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  contains "$output" "no records"
  lacks "$output" "Pipeline: review-loop"
}

# ------------------------------------------------------- reliability rule

@test "a mean divides by the count of records that CARRY the field, not by the group size" {
  # Every other fixture group is homogeneous (all records carry the field, or
  # none do), where non-null-count == group size — so a regression dividing by
  # ($arr | length) would pass. This MIXED group is the only shape that can
  # tell them apart: 2 records, one with rounds/wall_s, one without.
  local f="$BATS_TEST_TMPDIR/mixed-presence.jsonl"
  cat > "$f" <<'EOF'
{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":100,"tokens":null,"payload":{"rounds":4}}
{"schema":"telemetry/v1","kind":"run","run_id":"b","parent_run_id":null,"ts":2,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":null,"tokens":null,"payload":{}}
EOF
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
  # 4 / 1, never 4 / 2
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "4" ]
  # 100 / 1, never 100 / 2
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "100" ]
}

@test "a value coerced to null by the type guard is DROPPED from the divisor, not counted as 0" {
  local f="$BATS_TEST_TMPDIR/mixed-coerced.jsonl"
  cat > "$f" <<'EOF'
{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":100,"tokens":null,"payload":{}}
{"schema":"telemetry/v1","kind":"run","run_id":"b","parent_run_id":null,"ts":2,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":"ten","tokens":null,"payload":{}}
EOF
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "100" ]
}

@test "mean rounds is withheld (never 0) when no record in the group carries one" {
  local f="$BATS_TEST_TMPDIR/norounds.jsonl"
  cat > "$f" <<'EOF'
{"schema":"telemetry/v1","kind":"run","run_id":"x-1-a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":10,"tokens":null,"payload":{}}
{"schema":"telemetry/v1","kind":"run","run_id":"x-2-b","parent_run_id":null,"ts":2,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":20,"tokens":null,"payload":{}}
EOF
  run zsh "$S" "$f"
  [ "$status" -eq 0 ]
  contains "$output" "mean rounds: -"
  run zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
}

@test "mean wall_s is withheld (key present, null) when no record in the group carries one" {
  local f="$BATS_TEST_TMPDIR/nowall.jsonl"
  cat > "$f" <<'EOF'
{"schema":"telemetry/v1","kind":"run","run_id":"x-1-a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":null,"tokens":null,"payload":{"rounds":2}}
EOF
  run zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  local has_key
  has_key=$(echo "$output" | jq '.[0] | has("mean_wall_s")')
  [ "$has_key" = "true" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "null" ]
}

@test "escalation rate is withheld for an explicitly-filtered pipeline with zero runs" {
  run --separate-stderr zsh "$S" --json --pipeline nope "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].escalation_rate')" = "null" ]
}

@test "mean_wall_s is a per-record mean, not per-loop" {
  # The v0-review-loop fixture holds two DIFFERENT loops' terminal records
  # (issue 912 and issue 969) — the rollup must not attempt to group them.
  run zsh "$S" --json "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "4132" ]
}

# ------------------------------------------------- off-contract robustness

@test "a v1 record's rounds comes ONLY from payload.rounds, never from a top-level rounds" {
  # The envelope is closed and carries no top-level `rounds`, so a
  # mistakenly-tolerant read would start counting a field the contract places
  # in the payload. v0 records are the opposite (top-level) — pinned elsewhere.
  local f="$BATS_TEST_TMPDIR/rounds-source.jsonl"
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"rounds":99,"payload":{"rounds":2}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "2" ]

  # …and with an empty payload, the top-level 99 is NOT picked up: withheld.
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"y","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"rounds":99,"payload":{}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
}

@test "--pipeline matches EXACTLY (case-sensitively), unlike --repo" {
  # A deliberate asymmetry: `pipeline` is an OPEN identifier, but its values
  # are written verbatim by our own emitters, whereas a repo slug comes from a
  # case-insensitive-but-case-preserving external identity provider. If a
  # future edit folded case in the pipeline filter too, this would object.
  run --separate-stderr zsh "$S" --json --pipeline Review-Loop "$FIX/v1-mixed.jsonl"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "Review-Loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "0" ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
}

@test "every enum value passes through on the v1 path, including parked" {
  # `parked` reaching outcome_mix.parked is otherwise proven ONLY through the
  # v0 adapter's narrow_refine — a different code path. Dropping "parked" from
  # the v1 whitelist would turn every refine-issue park into a `failed` run.
  local f="$BATS_TEST_TMPDIR/v1-enum.jsonl"
  local base='{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"refine-issue","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"payload":{}}'
  local o
  for o in success parked escalated failed; do
    echo "$base" | jq -c ".outcome = \"$o\"" > "$f"
    run --separate-stderr zsh "$S" --json "$f"
    [ "$status" -eq 0 ]
    [ "$(_jqf "$output" ".[0].outcome_mix.$o")" = "1" ]
    [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  done
}

@test "a non-string repo/pipeline/outcome is bucketed or coerced, never a whole-run crash" {
  # repo is the dangerous one: the filter downcases .repo, so a non-string
  # leaking past the bucket guard would raise a jq type error and abort the
  # ENTIRE run with exit 3 — the exact inverse of "off-contract field types
  # never crash the rollup".
  local f="$BATS_TEST_TMPDIR/nonstring.jsonl"
  local base='{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"payload":{}}'
  { echo "$base" | jq -c '.repo = 5'
    echo "$base" | jq -c '.pipeline = 5'
    echo "$base" | jq -c '.outcome = 5'; } > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  # every emitted pipeline label is a string, so the --json shape holds
  [ "$(_jqf "$output" '[.[].pipeline | type] | unique | join(",")')" = "string" ]
  local total
  total=$(echo "$output" | jq '[.[].run_count] | add')
  [ "$total" -eq 3 ]
  # the non-string outcome is coerced to failed, not kept as a 5th key
  [ "$(_jqf "$output" '[.[].outcome_mix.failed] | add')" = "1" ]

  # …and filtering over a non-string repo still exits 0 with the note, not 3
  run --separate-stderr zsh "$S" --json --repo o/n "$f"
  [ "$status" -eq 0 ]
  contains "$stderr" "attributed to an unknown repo"
}

@test "one directory holding BOTH legacy v0 and telemetry/v1 files aggregates into single pipeline groups" {
  # The headline documented use case, and the rollup's reason to exist.
  local d="$BATS_TEST_TMPDIR/mixed-eras"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/review-loop.jsonl"
  cp "$FIX/v1-mixed.jsonl" "$d/"
  run --separate-stderr zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  # ONE review-loop group spanning both eras: v0's 2 + v1's 2
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")] | length')" = "1" ]
  local rl
  rl=$(echo "$output" | jq -c '.[] | select(.pipeline == "review-loop")')
  [ "$(echo "$rl" | jq '.run_count')" = "4" ]
  # means pool the two adapters' DIFFERENT rounds sources (v0 top-level,
  # v1 payload.rounds) into one divisor: (1+9+2+4)/4 and (7+8257+312+900)/4
  [ "$(echo "$rl" | jq '.mean_rounds')" = "4" ]
  [ "$(echo "$rl" | jq '.mean_wall_s')" = "2369" ]
}

@test "--repo over a MIXED v0/v1 directory keeps the v1 named records and reports the v0 ones excluded" {
  local d="$BATS_TEST_TMPDIR/mixed-eras-filtered"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/review-loop.jsonl"
  cp "$FIX/v1-mixed.jsonl" "$d/"
  run --separate-stderr zsh "$S" --json --repo timo-jakob/timos-claude-code-plugins "$d"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '[.[] | select(.pipeline == "review-loop")][0].run_count')" = "2" ]
  contains "$stderr" "excluded 2 record(s) attributed to an unknown repo"
}

@test "an off-enum v1 outcome is narrowed to failed, not left as a 5th outcome_mix key" {
  local f="$BATS_TEST_TMPDIR/badoutcome.jsonl"
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"cancelled","wall_s":10,"tokens":null,"payload":{}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqfc "$output" '.[0].outcome_mix')" = '{"success":0,"parked":0,"escalated":0,"failed":1}' ]
  [ "$(_jqf "$output" '.[0].outcome_mix | keys | length')" = "4" ]
}

@test "a non-numeric wall_s/rounds is withheld, not a crash" {
  local f="$BATS_TEST_TMPDIR/badnums.jsonl"
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":"ten","tokens":null,"payload":{"rounds":"two"}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "null" ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
}

@test "a non-object payload is guarded, not a crash" {
  local f="$BATS_TEST_TMPDIR/badpayload.jsonl"
  echo '{"schema":"telemetry/v1","kind":"run","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"payload":"oops"}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "null" ]
}

@test "a record declaring schema telemetry/v2 is excluded entirely, not read as v1" {
  local f="$BATS_TEST_TMPDIR/v2rec.jsonl"
  echo '{"schema":"telemetry/v2","kind":"run","pipeline":"acceptance","outcome":"success","wall_s":5}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "an off-enum kind is EXCLUDED, not coerced — the opposite policy from outcome" {
  # A string kind outside run/enrichment, and the two falsy shapes an
  # alternative-operator default would silently coerce to "run" and COUNT.
  # Only a genuinely ABSENT key defaults to run (pinned by the next test).
  local base='{"schema":"telemetry/v1","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":5,"tokens":null,"payload":{}}'
  local f="$BATS_TEST_TMPDIR/kind.jsonl"

  # POSITIVE CONTROL first: the identical fixture with kind "run" must COUNT.
  # Without it, an `[]` below could equally mean the fixture never parsed —
  # the assertion could not tell "excluded by policy" from "never got read".
  echo "$base" | jq -c '.kind = "run"' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]

  local k
  for k in '"checkpoint"' 'false' 'null' '5'; do
    echo "$base" | jq -c ".kind = $k" > "$f"
    run --separate-stderr zsh "$S" --json "$f"
    [ "$status" -eq 0 ]
    # excluded outright — never coerced into the `failed` bucket the way an
    # off-enum OUTCOME is. Name the shape on failure so a red run localizes.
    [ "$output" = "[]" ] || { echo "kind=$k was not excluded: $output" >&2; return 1; }
  done
}

@test "a v1 record missing kind defaults to run; missing pipeline/outcome default to unknown/failed" {
  local f="$BATS_TEST_TMPDIR/minimal-v1.jsonl"
  echo '{"schema":"telemetry/v1","run_id":"x","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"issue":null,"pr":null,"wall_s":5,"tokens":null,"payload":{}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "unknown" ]
  [ "$(_jqf "$output" '.[0].outcome_mix.failed')" = "1" ]
}

# ---------------------------------------------------------------- empty

@test "an empty stream exits 0 and prints an explicit 'no records' line" {
  local f="$BATS_TEST_TMPDIR/empty.jsonl"
  : > "$f"
  run zsh "$S" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "no records" ]
}

@test "--json on an empty stream emits an empty array" {
  local f="$BATS_TEST_TMPDIR/empty.jsonl"
  : > "$f"
  run zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "--json --pipeline on an empty stream still emits an empty array, not a synthesized section" {
  local f="$BATS_TEST_TMPDIR/empty.jsonl"
  : > "$f"
  run zsh "$S" --json --pipeline nope "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "an empty directory (no *.jsonl) behaves like an empty stream" {
  local d="$BATS_TEST_TMPDIR/emptydir"
  mkdir -p "$d"
  run zsh "$S" "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "no records" ]
}

@test "with no operand, a missing local default sink is an empty stream, not a usage error" {
  local d="$BATS_TEST_TMPDIR/no-sink-here"
  mkdir -p "$d"
  run bash -c "cd '$d' && zsh '$S'"
  [ "$status" -eq 0 ]
  [ "$output" = "no records" ]
}

@test "with no operand, an existing local default sink IS read" {
  local d="$BATS_TEST_TMPDIR/has-sink"
  mkdir -p "$d/.claude/telemetry"
  cp "$FIX/v0-review-loop.jsonl" "$d/.claude/telemetry/telemetry.jsonl"
  run bash -c "cd '$d' && zsh '$S' --json"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].pipeline')" = "review-loop" ]
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}

# ---------------------------------------------------------------- usage

@test "an unknown flag exits 2" {
  run zsh "$S" --bogus
  [ "$status" -eq 2 ]
  contains "$output" "unknown flag: --bogus"
}

@test "--repo missing its value exits 2" {
  run zsh "$S" --repo
  [ "$status" -eq 2 ]
  contains "$output" "--repo requires a value"
}

@test "--pipeline followed by another flag (no value) exits 2" {
  run zsh "$S" --pipeline --json
  [ "$status" -eq 2 ]
  contains "$output" "requires a value"
}

@test "--repo an empty string exits 2 as a non-empty-value violation" {
  run zsh "$S" --repo ""
  [ "$status" -eq 2 ]
  contains "$output" "--repo requires a non-empty value"
}

@test "--pipeline an empty string exits 2 as a non-empty-value violation" {
  run zsh "$S" --pipeline ""
  [ "$status" -eq 2 ]
  contains "$output" "--pipeline requires a non-empty value"
}

@test "--repo followed by a flag-shaped value names the flag it got instead" {
  run zsh "$S" --repo --json
  [ "$status" -eq 2 ]
  contains "$output" "--repo requires a value (got the flag --json)"
}

@test "an unreadable/nonexistent explicit FILE operand exits 2" {
  run zsh "$S" "$BATS_TEST_TMPDIR/does-not-exist.jsonl"
  [ "$status" -eq 2 ]
  contains "$output" "no such file or directory"
}

@test "an explicit EMPTY-STRING operand is a usage error, never a silent fallback to the default sink" {
  # The realistic shape is a wrapper forwarding an unset variable. Run it from
  # a directory that DOES have a populated default sink, so a regression that
  # branched on the operand's VALUE (rather than on whether one was given)
  # would exit 0 with that sink's report instead of the documented exit 2.
  local d="$BATS_TEST_TMPDIR/empty-operand"
  mkdir -p "$d/.claude/telemetry"
  cp "$FIX/v0-review-loop.jsonl" "$d/.claude/telemetry/telemetry.jsonl"
  run bash -c "cd '$d' && zsh '$S' ''"
  [ "$status" -eq 2 ]
  contains "$output" "no such file or directory"
  lacks "$output" "Pipeline: review-loop"
}

@test "an unreadable existing FILE operand exits 2, distinct from nonexistent" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local f="$BATS_TEST_TMPDIR/noperm.jsonl"
  cp "$FIX/v0-review-loop.jsonl" "$f"
  chmod 000 "$f"
  run zsh "$S" "$f"
  [ "$status" -eq 2 ]
  contains "$output" "not readable:"
}

@test "an unreadable DIR operand exits 2, not a false 'no records'" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local d="$BATS_TEST_TMPDIR/noperm-dir"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/"
  chmod 000 "$d"
  run zsh "$S" "$d"
  chmod 755 "$d"
  [ "$status" -eq 2 ]
  contains "$output" "not readable:"
}

@test "an unreadable *.jsonl inside an otherwise-readable DIR is a read failure (exit 3), never a silent undercount" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local d="$BATS_TEST_TMPDIR/dir-bad-file"
  mkdir -p "$d"
  cp "$FIX/v0-review-loop.jsonl" "$d/good.jsonl"
  echo 'irrelevant' > "$d/bad.jsonl"
  chmod 000 "$d/bad.jsonl"
  run zsh "$S" "$d"
  chmod 644 "$d/bad.jsonl"
  [ "$status" -eq 3 ]
  contains "$output" "failed to read a stream"
}

@test "a second positional operand is rejected, not silently ignored" {
  run zsh "$S" "$FIX/v0-review-loop.jsonl" "$FIX/v0-refine-issue.jsonl"
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "a FILE operand followed by explicit stdin '-' is rejected, not silently taken as stdin" {
  run zsh "$S" "$FIX/v0-review-loop.jsonl" -
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "two explicit stdin operands ('- -') are rejected" {
  run bash -c "cat '$FIX/v0-review-loop.jsonl' | zsh '$S' - -"
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "--help prints usage and exits 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: rollup-telemetry.zsh"
}

@test "-h is accepted as well as --help" {
  run zsh "$S" -h
  [ "$status" -eq 0 ]
  starts_with "$output" "usage:"
}

# ------------------------------------------------------------- internal

@test "a missing jq is an internal error, distinct from usage" {
  run env PATH="$BATS_TEST_TMPDIR/empty-path" "$ZSH_BIN" "$S" "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 3 ]
  contains "$output" "jq not found on PATH"
}

@test "a jq that runs but fails at the aggregation pass is an internal error, not a violation" {
  # The extraction pass (-R -r -n, no operand) must keep succeeding so the
  # real jq's -s (slurp, WITH a file operand) is what's made to fail —
  # matching exactly how the aggregation step invokes jq.
  local stub="$BATS_TEST_TMPDIR/jqstub"
  mkdir -p "$stub"
  local real_jq
  real_jq="$(command -v jq)"
  cat > "$stub/jq" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "-s" ]; then exit 1; fi
done
exec "$real_jq" "\$@"
EOF
  chmod +x "$stub/jq"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --json "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 3 ]
  contains "$output" "failed to aggregate records"
}

@test "an unreadable default sink (no operand) is a read failure (exit 3), never a false 'no records'" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local d="$BATS_TEST_TMPDIR/unreadable-sink"
  mkdir -p "$d/.claude/telemetry"
  cp "$FIX/v0-review-loop.jsonl" "$d/.claude/telemetry/telemetry.jsonl"
  chmod 000 "$d/.claude/telemetry/telemetry.jsonl"
  run bash -c "cd '$d' && zsh '$S'"
  chmod 644 "$d/.claude/telemetry/telemetry.jsonl"
  [ "$status" -eq 3 ]
  contains "$output" "failed to read a stream"
}

@test "the rollup is executable and runs by bare path" {
  [ -x "$S" ]
  run "$S" --help
  [ "$status" -eq 0 ]
}

@test "output composes in a pipe: the rollup's own status stays 0 and the consumer gets real data" {
  # Observe the SCRIPT's status via PIPESTATUS — head always exits 0, so a
  # plain `run … | head` would assert nothing about the rollup.
  # NOTE what this first case does and does not pin: the text report is written
  # by a jq CHILD of the script, and the script ends in an unconditional
  # `exit 0`, so this proves the pipeline composes and the consumer receives
  # the first line — NOT the SIGPIPE trap itself. The second case is the one
  # that pins `trap '' PIPE`, because there the shell's own `print` builtin is
  # the writer.
  run bash -c "zsh '$S' '$FIX/v1-mixed.jsonl' 2>/dev/null | head -1; exit \${PIPESTATUS[0]}"
  [ "$status" -eq 0 ]
  contains "$output" "Pipeline: "

  # The zsh-builtin `print` path (the "no records" line) against a consumer
  # that exits WITHOUT reading. `exec true` means the same thing on GNU and
  # BSD/macOS, unlike `head -0` (which macOS rejects outright). The write
  # genuinely races a closed pipe because the script does several jq/mktemp
  # invocations before it ever prints.
  local empty="$BATS_TEST_TMPDIR/empty-pipe.jsonl"
  : > "$empty"
  run bash -c "zsh '$S' '$empty' | exec true; exit \${PIPESTATUS[0]}"
  [ "$status" -eq 0 ]
}

@test "a scratch-file failure is an internal error (exit 3), distinct from a read failure" {
  # The documented exit-3 taxonomy names a scratch-file failure; only the
  # jq-missing, read and aggregation causes were otherwise covered.
  local stub="$BATS_TEST_TMPDIR/mktempstub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/mktemp"
  chmod +x "$stub/mktemp"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 3 ]
  contains "$output" "failed to create a scratch file"
  lacks "$output" "failed to read a stream"
}

@test "the scratch files are cleaned up on exit, including on a usage error" {
  local tmp="$BATS_TEST_TMPDIR/scratchdir"
  mkdir -p "$tmp"
  run env TMPDIR="$tmp" zsh "$S" --json "$FIX/v0-review-loop.jsonl"
  [ "$status" -eq 0 ]
  # the EXIT trap removes BOTH mktemp files
  run bash -c "find '$tmp' -type f | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "a final line with no trailing newline is still counted" {
  local f="$BATS_TEST_TMPDIR/no-trailing-nl.jsonl"
  printf '%s' '{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}' > "$f"
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].run_count')" = "1" ]
}

@test "a non-integer mean is reported at full precision, never truncated or rounded" {
  local f="$BATS_TEST_TMPDIR/fractional.jsonl"
  cat > "$f" <<'EOF'
{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":10,"tokens":null,"payload":{"rounds":1}}
{"schema":"telemetry/v1","kind":"run","run_id":"b","parent_run_id":null,"ts":2,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":25,"tokens":null,"payload":{"rounds":2}}
EOF
  run --separate-stderr zsh "$S" --json "$f"
  [ "$status" -eq 0 ]
  [ "$(_jqf "$output" '.[0].mean_rounds')" = "1.5" ]
  [ "$(_jqf "$output" '.[0].mean_wall_s')" = "17.5" ]
  run --separate-stderr zsh "$S" "$f"
  [ "$status" -eq 0 ]
  contains "$output" "mean rounds: 1.5"
  contains "$output" "mean wall_s: 17.5"
}

@test "--help goes to stdout with a clean stderr; a usage error goes to stderr with a clean stdout" {
  # The script splits these deliberately, so a --json consumer's stdout can
  # never be corrupted by a diagnostic.
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage:"
  [ -z "$stderr" ]

  run --separate-stderr zsh "$S" --repo
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "requires a value"
}

@test "flags may not follow -- : a flag-shaped argument after it is taken as an operand" {
  run zsh "$S" -- --json
  [ "$status" -eq 2 ]
  contains "$output" "no such file or directory"

  run zsh "$S" -- "$FIX/v0-review-loop.jsonl" --json
  [ "$status" -eq 2 ]
  contains "$output" "only one input may be given"
}

@test "per-source warning labelling is correct across MULTIPLE sources in one DIR run" {
  local d="$BATS_TEST_TMPDIR/multisrc"
  mkdir -p "$d"
  { echo '{"schema":"telemetry/v1","kind":"run","run_id":"a","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}'
    echo 'bad line in a'; } > "$d/a.jsonl"
  { echo 'bad line in b'
    echo '{"schema":"telemetry/v1","kind":"run","run_id":"b","parent_run_id":null,"ts":1,"repo":"o/n","repo_type":null,"pipeline":"acceptance","issue":null,"pr":null,"outcome":"success","wall_s":1,"tokens":null,"payload":{}}'; } > "$d/b.jsonl"
  run --separate-stderr zsh "$S" --json "$d"
  [ "$status" -eq 0 ]
  contains "$stderr" "a.jsonl: line 2:"
  contains "$stderr" "b.jsonl: line 1:"
  [ "$(_jqf "$output" '.[0].run_count')" = "2" ]
}
