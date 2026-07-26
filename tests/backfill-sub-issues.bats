#!/usr/bin/env bats
#
# Behavioral tests for backfill-sub-issues.zsh (#802): the one-time migration
# of an epic's markdown task-list children into GitHub-native sub-issues. What
# these tests pin down is the migration contract: convert exactly the task-list
# children (fence-aware, first ref per line, cross-repo refs reported but never
# migrated), idempotency (already-attached children are skipped — an immediate
# second run is a no-op), and --dry-run writing NOTHING.
#
# gh is stubbed via the GH_BIN seam. The stub serves the epic body, the
# existing sub-issue list, and per-child issue ids from fixture files, and
# appends every POST to $POST_LOG — the write-detector the no-op and dry-run
# assertions rely on.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/backfill-sub-issues.zsh"

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURE_DIR"
  POST_LOG="$BATS_TEST_TMPDIR/posts.log"
  : > "$POST_LOG"

  # Default epic #746 shape: three markdown children, none attached natively.
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
The epic. See #999 in prose (not a child).

## Children
- [ ] #790 — first
- [x] #791 — second (closed, still a child)
- [ ] o/r#792 — third, this-repo-qualified ref
EOF
  echo '[]' > "$FIXTURE_DIR/sub-issues.json"

  # Fake gh, keyed on the api path:
  #   repos/o/r/issues/<epic>            -> {"body": <epic-body.txt>} (via --jq .body)
  #   repos/o/r/issues/<epic>/sub_issues -> sub-issues.json (numbers via --jq)
  #   repos/o/r/issues/<child>           -> {"id": 1000+child} (via --jq .id)
  #   -X POST ...(/sub_issues)           -> logged to $POST_LOG, exit 0
  #     (a child number listed in fail-posts.txt makes its POST fail instead)
  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
post=false; path=""; sub_id=""
prev=""
for a in "$@"; do
  case "$a" in
    POST) [ "$prev" = "-X" ] && post=true ;;
    repos/*) path="$a" ;;
    sub_issue_id=*) sub_id="${a#sub_issue_id=}" ;;
  esac
  prev="$a"
done
if $post; then
  child=$((sub_id - 1000))
  if [ -f "$FIXTURE_DIR/fail-posts.txt" ] && grep -qx "$child" "$FIXTURE_DIR/fail-posts.txt"; then
    echo "gh: Validation Failed (child #$child already has a parent)" >&2
    exit 1
  fi
  echo "POST $path sub_issue_id=$sub_id" >> "$POST_LOG"
  echo '{}'
  exit 0
fi
case "$path" in
  */sub_issues)
    # fail-sub-issues marker: the list GET itself fails (auth/network)
    if [ -f "$FIXTURE_DIR/fail-sub-issues" ]; then echo "gh: 502" >&2; exit 1; fi
    # emulate `--jq '[.[].number]'` over the canned list
    jq -c '[.[].number]' "$FIXTURE_DIR/sub-issues.json" ;;
  repos/o/r/issues/746)
    # emulate `--jq .body`
    cat "$FIXTURE_DIR/epic-body.txt" ;;
  repos/o/r/issues/*)
    # fail-id-lookup marker: this child's id GET fails
    n="${path##*/}"
    if [ -f "$FIXTURE_DIR/fail-id-lookup.txt" ] && grep -qx "$n" "$FIXTURE_DIR/fail-id-lookup.txt"; then
      echo "gh: 404" >&2; exit 1
    fi
    # emulate `--jq .id`: id = 1000 + number
    echo $((1000 + n)) ;;
  *) echo "unexpected path: $path" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB"
}

backfill() {
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" POST_LOG="$POST_LOG" \
    zsh "$S" --repo o/r --epic 746 "$@"
}

# ---- usage errors ----------------------------------------------------------

@test "usage: missing --repo exits 2" {
  run zsh "$S" --epic 5
  [ "$status" -eq 2 ]
}

@test "usage: missing --epic exits 2" {
  run zsh "$S" --repo o/r
  [ "$status" -eq 2 ]
}

@test "usage: non-numeric --epic exits 2" {
  run zsh "$S" --repo o/r --epic abc
  [ "$status" -eq 2 ]
}

@test "usage: unknown argument exits 2" {
  run zsh "$S" --repo o/r --epic 5 --bogus
  [ "$status" -eq 2 ]
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  run zsh "$S" --repo o/r --epic
  [ "$status" -eq 2 ]
  contains "$output" "--epic needs a value"
}

# ---- the conversion ---------------------------------------------------------

@test "converts the markdown task-list children into native sub-issues" {
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '[.already_present, .failed]')" = '[[],[]]' ]
  # one POST per child, carrying the resolved issue id
  [ "$(wc -l < "$POST_LOG")" -eq 3 ]
  grep -q 'sub_issue_id=1790' "$POST_LOG"
  grep -q 'sub_issue_id=1791' "$POST_LOG"
  grep -q 'sub_issue_id=1792' "$POST_LOG"
}

@test "the prose #999 cross-reference is never migrated" {
  backfill
  [ "$status" -eq 0 ]
  # assert the field EXISTS with the right arity first — an absent
  # .markdown_children makes `jq -c` print `null`, which trivially lacks "999"
  # and would let a dropped-field regression read as success
  [ "$(echo "$output" | jq -r '.markdown_children | length')" = "3" ]
  lacks "$(echo "$output" | jq -c '.markdown_children')" "999"
  # same guard for the WRITE side, which is what "never migrated" really rests
  # on: pin that three POSTs happened at all (the sibling test "converts the
  # markdown task-list children into native sub-issues" does the same) — an
  # empty $POST_LOG would satisfy the negative below on its own. That `wc -l`
  # pin is what makes the negative non-vacuous, NOT the choice of `lacks`: a
  # failed `cat` in an argument yields an empty haystack that `lacks` accepts.
  # `lacks` is still the right form over `run ! grep`, for a separate reason —
  # `run !` accepts ANY non-zero, so grep's exit 2 on an unreadable log would
  # read as "not migrated" (the hazard tests/assertions.bash documents).
  [ "$(wc -l < "$POST_LOG")" -eq 3 ]
  lacks "$(cat "$POST_LOG")" "sub_issue_id=1999"
}

@test "a checklist line inside a code fence is not migrated" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
```
- [ ] #601 example syntax
```
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "only the FIRST ref on a checklist line is taken (a trailing dep ref is ignored)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790 — the child, which depends on #999
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "a genuinely cross-repo ref is skipped and reported, not migrated" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] other/repo#55 — cross-repo, unmigratable
- [ ] #790 — same-repo child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '["other/repo#55"]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
}

@test "a this-repo ref differing only in case is a same-repo child, not cross-repo (slugs are case-insensitive)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] O/R#790 — same repo, different casing
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '[]' ]
}

@test "asterisk and plus bullet task-list items are migrated too" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
* [ ] #790 — asterisk bullet
+ [x] #791 — plus bullet
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791]' ]
}

@test "a self-reference (tracker line naming the epic itself) is never a child" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790 — real child
- [ ] #746 stays open as the tracker and closes only when all slices close.
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
}

@test "a duplicate task-list entry is attached once" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790 — the child
- [ ] #790 — listed twice by mistake
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
}

# ---- idempotency ------------------------------------------------------------

@test "an immediate second run is a no-op (all children already present)" {
  echo '[{"number":790},{"number":791},{"number":792}]' > "$FIXTURE_DIR/sub-issues.json"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.already_present')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "a partially-backfilled epic attaches only the missing children" {
  echo '[{"number":790}]' > "$FIXTURE_DIR/sub-issues.json"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.already_present')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[791,792]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
}

# ---- dry-run ----------------------------------------------------------------

@test "--dry-run reports the plan and writes NOTHING" {
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.dry_run, .would_add, .added]')" = '[true,[790,791,792],[]]' ]
  [ ! -s "$POST_LOG" ]
}

@test "--dry-run reports skipped_cross_repo too (the vetting mode must show the full plan)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] other/repo#55 — cross-repo, unmigratable
- [ ] #790 — same-repo child
EOF
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.skipped_cross_repo, .would_add]')" = '[["other/repo#55"],[790]]' ]
  [ ! -s "$POST_LOG" ]
}

@test "--dry-run on a fully-backfilled epic plans nothing" {
  echo '[{"number":790},{"number":791},{"number":792}]' > "$FIXTURE_DIR/sub-issues.json"
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.would_add, .already_present]')" = '[[],[790,791,792]]' ]
  [ ! -s "$POST_LOG" ]
}

# ---- failure handling -------------------------------------------------------

@test "a child whose POST fails is recorded in failed and the run exits 5 (partial)" {
  echo '791' > "$FIXTURE_DIR/fail-posts.txt"
  backfill
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,792]' ]
  [ "$(echo "$output" | jq -r '.failed[0].number')" = "791" ]
  # `!= ""` would pass on a dropped field, because `jq -r` prints the literal
  # string `null` for a missing key — the same vacuity class as an unguarded
  # negative. Pin the key's presence and the captured stderr instead.
  [ "$(echo "$output" | jq -r '.failed | length')" -eq 1 ]
  contains "$(echo "$output" | jq -r '.failed[0].error')" "already has a parent"
}

@test "a failed epic-body fetch is a runtime error (exit 1)" {
  run env GH_BIN=/bin/false zsh "$S" --repo o/r --epic 746
  [ "$status" -eq 1 ]
  contains "$output" "failed to fetch epic"
}

@test "a failed sub-issue-list fetch is a runtime error (exit 1) and nothing is POSTed" {
  # the second exit-1 branch: the body fetch succeeds, the sub_issues GET fails.
  # Guards the pipefail dependency — without it a gh failure would read as [],
  # and the script would re-POST every child against a repo it failed to read.
  touch "$FIXTURE_DIR/fail-sub-issues"
  backfill
  [ "$status" -eq 1 ]
  contains "$output" "failed to list sub-issues"
  [ ! -s "$POST_LOG" ]
}

@test "a child whose id lookup fails is recorded in failed (exit 5) and the rest still attach" {
  echo '791' > "$FIXTURE_DIR/fail-id-lookup.txt"
  backfill
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,792]' ]
  [ "$(echo "$output" | jq -r '.failed[0].number')" = "791" ]
  [ "$(echo "$output" | jq -r '.failed[0].error')" = "failed to resolve issue id" ]
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
}

@test "an epic with no task list at all is a clean no-op (exit 0)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
Prose only. See #601 for context.
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.markdown_children, .added, .would_add]')" = '[[],[],[]]' ]
  [ ! -s "$POST_LOG" ]
}
