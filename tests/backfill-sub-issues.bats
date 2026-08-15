#!/usr/bin/env bats
#
# Behavioral tests for backfill-sub-issues.zsh (#802): the one-time migration
# of an epic's markdown task-list children into GitHub-native sub-issues. What
# these tests pin down is the migration contract: convert exactly the task-list
# children (fence-aware, first ref per line, cross-repo refs and
# self-references reported but never
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
post=false; path=""; sub_id=""; jqf=""
prev=""
for a in "$@"; do
  case "$a" in
    POST) [ "$prev" = "-X" ] && post=true ;;
    repos/*) path="$a" ;;
    sub_issue_id=*) sub_id="${a#sub_issue_id=}" ;;
  esac
  # capture the REQUESTED --jq filter rather than hardcoding one: the server
  # applies whatever the caller asks for, so hardcoding would silently pass a
  # script that changed its projection (and hide one that broke it)
  [ "$prev" = "--jq" ] && jqf="$a"
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
    jq -c "${jqf:-.}" "$FIXTURE_DIR/sub-issues.json" ;;
  repos/o/r/issues/746)
    # serve a real issue object and apply the REQUESTED filter: hardcoding the
    # body would keep the suite green if the script stopped asking for .body,
    # and a wrong field yields an empty plan reported as the documented clean
    # no-op at exit 0 — a failed parse indistinguishable from a no-op epic
    jq -n --arg body "$(cat "$FIXTURE_DIR/epic-body.txt")" \
      '{body: $body, title: "the epic", number: 746}' | jq -r "${jqf:-.}" ;;
  repos/o/r/issues/*)
    # fail-id-lookup marker: this child's id GET fails
    n="${path##*/}"
    if [ -f "$FIXTURE_DIR/fail-id-lookup.txt" ] && grep -qx "$n" "$FIXTURE_DIR/fail-id-lookup.txt"; then
      echo "gh: 404" >&2; exit 1
    fi
    # id-notice marker: a real gh writes SSO hints / deprecation notices to
    # stderr, which the caller folds in with 2>&1 — the id must still be picked
    if [ -f "$FIXTURE_DIR/id-notice.txt" ]; then cat "$FIXTURE_DIR/id-notice.txt" >&2; fi
    # id-ambiguous marker: a SECOND bare numeric line, so the capture no longer
    # identifies one id — the fail-closed branch, since guessing misparents
    if [ -f "$FIXTURE_DIR/id-ambiguous.txt" ]; then echo 9999; fi
    # serve a real issue object and apply the REQUESTED filter. The sub_issues
    # endpoint needs the database ID, not the issue NUMBER — a confusion that
    # misparents issues under the epic (one parent only, not trivially
    # reversible). Hardcoding 1000+n would keep every assertion green on a
    # regression from `--jq .id` to `--jq .number`, since the id is the stub's
    # own fiction; projecting a distinct id and number makes it redden.
    jq -nc --argjson n "$n" '{id: (1000 + $n), number: $n, node_id: "I_x\($n)"}' \
      | jq -r "${jqf:-.}" ;;
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
#
# Every usage test asserts the MESSAGE, not just exit 2: several guards fall
# through to a later guard that also exits 2. They run through the stub too, so
# a dropped guard fails as a legible assertion instead of reaching the real
# github.com — which matters more here than in the sibling suite, because this
# script's non-dry-run path WRITES (it POSTs sub-issues).

usage_run() {
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" POST_LOG="$POST_LOG" \
    zsh "$S" "$@"
}

@test "the migrator is executable and runs by BARE PATH" {
  # every other test runs `zsh "$S"`, which bypasses both the shebang and the
  # mode bit. The skill and ARCHITECTURE both invoke this bare-path, so a file
  # that ever ships without 755 makes E1's migration die "permission denied"
  # on every epic while this suite stays green.
  [ -x "$S" ]
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" POST_LOG="$POST_LOG" \
    "$S" --repo o/r --epic 746 --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.would_add')" = '[790,791,792]' ]
  [ ! -s "$POST_LOG" ]
}

@test "usage: --epic 0 is a usage error, not an exit-1 fetch failure" {
  # GitHub issue numbers start at 1, so 0 cannot name an epic. Without the
  # bound the fetch 404s and the run dies exit 1 as "failed to fetch epic #0" —
  # a malformed argument reported as a runtime failure. Mirrors the reader.
  usage_run --repo o/r --epic 0
  [ "$status" -eq 2 ]
  contains "$output" "--epic must be a positive number"
  [ ! -s "$POST_LOG" ]
}

@test "usage: missing --repo exits 2" {
  # assert the message: an empty --repo also trips the later OWNER/NAME shape
  # check, so a status-only assertion cannot fail for the branch it names
  usage_run --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo OWNER/NAME is required"
}

@test "usage: missing --epic exits 2" {
  usage_run --repo o/r
  [ "$status" -eq 2 ]
  contains "$output" "--epic N is required"
}

@test "usage: --repo without a slash exits 2" {
  usage_run --repo just-a-name --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
}

@test "usage: a --repo carrying extra path segments exits 2 before any call" {
  # $repo is spliced raw into four REST paths, one of which WRITES
  usage_run --repo 'o/r/../../x/y' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  [ ! -s "$POST_LOG" ]
}

@test "usage: a --repo whose half is a DOT SEGMENT exits 2 before any call" {
  # `.` and `..` pass the charset test but normalise away, aiming the request
  # at a path the caller never named — so the guard rejects EXACTLY those two
  # segments (and empty halves). Never "each half must start alphanumeric":
  # that would also refuse OWNER/.github — see the acceptance test below.
  usage_run --repo 'o/..' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo '../x' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  [ ! -s "$POST_LOG" ]
}

@test "usage: a --repo outside the slug charset, or with an empty half, exits 2" {
  # the guard's other branches: the header names a QUERY explicitly, and an
  # empty owner or name would splice a doubled slash into the four REST paths
  usage_run --repo 'o/r?x=1' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo '/r' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'o/' --epic 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  [ ! -s "$POST_LOG" ]
}

@test "usage: a leading-dot repo NAME is accepted — only the dot segments are refused" {
  # mirrors the classifier suite: the guard rejects exactly `.` and `..`, never
  # "must start alphanumeric". OWNER/.github is a real repo, and refusing it
  # would report a well-formed invocation as a caller error and make the
  # backfill unreachable for every epic in it. The mirrored pair must not drift.
  usage_run --repo 'o/.github' --epic 5
  [ "$status" -ne 2 ]
  lacks "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'o/_internal' --epic 5
  [ "$status" -ne 2 ]
  lacks "$output" "--repo must be OWNER/NAME"
}

@test "usage: non-numeric --epic exits 2" {
  usage_run --repo o/r --epic abc
  [ "$status" -eq 2 ]
  contains "$output" "--epic must be a positive number"
}

@test "usage: unknown argument exits 2" {
  usage_run --repo o/r --epic 5 --bogus
  [ "$status" -eq 2 ]
  contains "$output" "unknown argument: --bogus"
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  usage_run --repo o/r --epic
  [ "$status" -eq 2 ]
  contains "$output" "--epic needs a value"
}

@test "usage: a dangling --repo exits 2, not a nounset abort" {
  usage_run --epic 5 --repo
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
}

@test "usage: --help prints the usage line and exits 0" {
  usage_run --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: backfill-sub-issues.zsh --repo OWNER/NAME --epic N"
}

# ---- the conversion ---------------------------------------------------------

@test "converts the markdown task-list children into native sub-issues" {
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791,792]' ]
  # the LIVE branch's constant fields, pinned here because the two emitters are
  # separate jq programs: a slip in this one (a hardcoded skipped_self_ref, a
  # would_add leak, a dry_run:true on a WRITING run) is invisible otherwise
  [ "$(echo "$output" | jq -c '[.already_present, .failed, .skipped_self_ref, .skipped_cross_repo]')" = '[[],[],[],[]]' ]
  [ "$(echo "$output" | jq -c '[.dry_run, .would_add]')" = '[false,[]]' ]
  # one POST per child, carrying the resolved issue id
  [ "$(wc -l < "$POST_LOG")" -eq 3 ]
  # the PATH too, not just the id: a regression POSTing the right child to the
  # wrong parent endpoint would misparent every child with the ids still green
  grep -q '^POST repos/o/r/issues/746/sub_issues sub_issue_id=1790$' "$POST_LOG"
  grep -q '^POST repos/o/r/issues/746/sub_issues sub_issue_id=1791$' "$POST_LOG"
  grep -q '^POST repos/o/r/issues/746/sub_issues sub_issue_id=1792$' "$POST_LOG"
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

# ---- the two-sided invariant with the classification rule (#1260) ----------
#
# read-dependencies.zsh decides whether an issue IS an epic; this script
# decides which refs get migrated. They are different rules, but they must
# satisfy both directions, and each direction needs a test on THIS side too —
# the classifier's own suite (tests/read-dependencies.bats) carries the mirror:
#   (a) every line the classifier calls a child, this parser must resolve a ref
#       from — else an epic is detected that migrates nothing;
#   (b) every line the classifier skips as fenced, this parser must skip — else
#       a quoted ref is migrated and misparents an issue (one parent only).

@test "invariant (b): a checklist line inside a ~~~ fence is not migrated" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
~~~markdown
- [ ] #601 example syntax
~~~
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a shorter inner fence does not reopen a longer outer one" {
  # the inner fence is deliberately UNBALANCED: under a bare toggle the single
  # inner ``` closes the outer block, #601 is migrated, and .added becomes
  # [601,790] — so this test fails the moment the run-length rule is lost
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
````markdown
```
- [ ] #601 quoted, not a child
````
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a LONGER run closes a shorter fence, and the child after it migrates" {
  # the other half of `n >= fence_len`: narrowing it to `==` would leave the
  # real child fenced and migrate nothing
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
```markdown
- [ ] #601 quoted, not a child
````
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a quoted list in a SECOND fenced block is still skipped" {
  # the fence state must come back ON after the first block closes
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
```
some sample
```

prose in between

```markdown
- [ ] #601 quoted, not a child
```
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "a body of ONLY a cross-repo ref yields an EMPTY plan at exit 0" {
  # the state E1's empty-plan halt is specified against: the classifier calls
  # this an epic, and the migration resolves the ref but attaches nothing
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] other/repo#55 — cross-repo, unmigratable here
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[]' ]
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '["other/repo#55"]' ]
  [ ! -s "$POST_LOG" ]
  # E1 reads the halt off the DRY-RUN, which is emitted by a separate jq
  # program — pin markdown_children there too, or the halt could stop firing
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.markdown_children, .would_add, .added]')" = '[[],[],[]]' ]
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '["other/repo#55"]' ]
}

@test "a body of ONLY the epic's own tracker ref yields an EMPTY plan at exit 0" {
  # the second resolved-but-never-attached ref: an issue cannot parent itself
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #746 stays open as the tracker and closes only when all slices close.
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[]' ]
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '[]' ]
  [ ! -s "$POST_LOG" ]
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.markdown_children, .would_add, .added]')" = '[[],[],[]]' ]
}

@test "a decorated ref IS migrated — the classifier is stricter here, on purpose" {
  # pins the real asymmetry: read-dependencies.zsh does NOT call this a child,
  # this parser does resolve it. Widening the classifier is a one-sided change
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] **#790** — bolded child
- [ ] [#791](https://github.com/o/r/issues/791) — linked child
EOF
  backfill
  [ "$status" -eq 0 ]
  # BOTH decorated forms the per-shape record lists, pinned on the side that
  # owns the capability claim
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791]' ]
  # the ATTACH half too: the SKILL contract says a decorated ref is not a
  # cause of the empty-plan halt precisely because this parser attaches it
  [ "$(echo "$output" | jq -c '.added')" = '[790,791]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
}

@test "a hex colour is NOT a child ref (the trailing word boundary)" {
  # without the boundary, `#0055aa` yields #0055 and migrates issue 55 under
  # the epic — a misparent manufactured out of a colour token
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] Brand colour token updated to #0055aa
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "the first ref taken is the first one that ENDS on a boundary" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790abc is not a ref, but #791 is
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[791]' ]
}

@test "invariant (b): a line STARTING with an inline code span does not open a fence" {
  # the mirror of the classifier test: a fence needs three or more markers on
  # BOTH sides, else one parser fences a child line the other migrates
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
`backfill-sub-issues.zsh` runs first.

- [ ] #790 — a real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "a child line that ENDS at the ref migrates (the boundary at end-of-line)" {
  # every other fixture puts text after the ref, so `nxt` is never empty here.
  # Spelling the guard as a positive match (`nxt ~ /[^0-9A-Za-z_]/`) — the
  # natural way to write "followed by a non-word character" — would drop every
  # ref at end of line, while the classifier's \b still matches at end-of-string
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790
- [x] #791
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791]' ]
}

@test "invariant (a): an extra gap AFTER the checkbox migrates, as the classifier accepts it" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ]  #790 — extra gap after the checkbox
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (a): a TAB in any bullet position migrates, matching the classifier" {
  # the positive half of the shared [ \t] class. If either implementation read
  # the bracket escape as {space, backslash, t}, a tab-indented epic would
  # classify here and resolve no ref there — invariant (a), silently
  printf -- '\t- [ ] #790 — tab-indented\n-\t[ ] #791 — tab after the bullet\n- [ ]\t#792 — tab after the checkbox\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791,792]' ]
}

@test "a zero-padded --epic is normalised, not read as octal or passed through" {
  # 0746 is octal-distinct (octal 0746 = 486): un-normalised it reaches
  # --argjson only at the FINAL emit — after every child has been POSTed —
  # and an octal misreading would fetch and parent the WRONG epic
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790 — real child
- [ ] #746 stays open as the tracker
EOF
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" POST_LOG="$POST_LOG" \
    zsh "$S" --repo o/r --epic 0746
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.epic')" = "746" ]
  # the padded epic still excludes its own tracker ref (the self-ref guard
  # compares against the NORMALISED value)
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "an NBSP-indented bullet migrates NOTHING, matching the classifier" {
  # the position where a PARTIAL respelling would break invariant (a): both
  # sides must agree that a non-ASCII indent is not a child line
  printf '\xc2\xa0- [ ] #790 — NBSP-indented\n' > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "invariant (b): a line STARTING with a struck-through span does not open a fence" {
  # the TWO-marker mirror: a loosening of the awk opener to `(``|~~)` is caught
  # only here — the backtick mirror uses a one-marker line and would survive it
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
~~dropped~~ — see below.

- [ ] #790 — a real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a marker-leading prose line does not invert parity and migrate a quoted ref" {
  # the WRITE-side consequence of a spurious opener: the real fence below would
  # become a CLOSE and #601 would be POSTed as a sub-issue — a misparent
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
`gh` is required.

```
- [ ] #601 quoted, not a child
```
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
  lacks "$(cat "$POST_LOG")" "sub_issue_id=1601"
}

@test "invariant (b): a closing fence with TRAILING BLANKS still closes it" {
  # the close guard's [ \t]* is otherwise only ever matched against "" —
  # narrowing it would leave this body fenced here while the classifier closes
  # it, so a real child would yield no ref: invariant (a), an empty plan
  printf '```markdown\n- [ ] #601 quoted\n```  \t\n- [ ] #790 — real child\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  lacks "$(cat "$POST_LOG")" "sub_issue_id=1601"
}

@test "invariant (b): an INDENTED fence marker still opens a fence" {
  # dropping the opener's leading [ \t]* would unfence the quoted line here
  # while the classifier still fences it — the misparent direction
  # TAB-indented on purpose: the other member of the shared [ \t] class, which
  # a one-sided respelling to `[ ]*` would drop — the quoted ref would then be
  # POSTed here while the classifier still fenced it (a misparent)
  printf '\t```markdown\n- [ ] #601 quoted, not a child\n\t```\n- [ ] #790 — real child\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  # BOTH members of the shared class, as the classifier mirror covers both: a
  # narrowing that kept tabs but dropped spaces would unfence a space-indented
  # quote here while the classifier still fenced it — a misparent
  printf '  ```markdown\n- [ ] #601 quoted, not a child\n  ```\n- [ ] #791 — real child\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[791]' ]
  lacks "$(cat "$POST_LOG")" "sub_issue_id=1601"
}

@test "the epic's own tracker ref is REPORTED in skipped_self_ref, not dropped" {
  # E1's reverse vet requires every child-shaped line to surface somewhere;
  # an unreported drop would halt an epic whose migration is perfect
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #746 stays open as the tracker and closes only when all slices close.
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.skipped_self_ref')" = '[746]' ]
  # E1's reverse vet reads the DRY-RUN, emitted by a separate jq program —
  # dropping the field there alone would halt every epic with a tracker line
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.skipped_self_ref, .would_add]')" = '[[746],[790]]' ]
}

@test "TWO self-referencing lines still record the epic's number ONCE" {
  # the at-most-once guard's false branch is otherwise never taken: dropping
  # the guard (or inverting it) would emit [746,746] with the suite green
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #746 stays open as the tracker
- [ ] #746 closes only when all slices close
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.skipped_self_ref, .markdown_children]')" = '[[746],[790]]' ]
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.skipped_self_ref, .markdown_children]')" = '[[746],[790]]' ]
}

@test "skipped_self_ref is EMPTY on a dry-run with no self-reference" {
  # so a hardcoded non-empty array could not pass the test above
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790 — real child
EOF
  backfill --dry-run
  [ "$status" -eq 0 ]
  # assert the PLAN too, so the empty array is proven about a body that
  # demonstrably parsed a child rather than one that parsed nothing at all
  [ "$(echo "$output" | jq -c '[.would_add, .skipped_self_ref]')" = '[[790],[]]' ]
}

@test "a ref followed by a MULTIBYTE character does not abort the migration" {
  # extracting a single byte after the ref yields half a character, and
  # matching that aborts awk outright — which would fail the whole migration
  # on ordinary prose. Both shapes below are realistic epic-body text.
  printf -- '- [ ] #790\xe2\x80\x99s seam is implemented\n- [ ] #791\xe2\x80\x94the second child\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791]' ]
}

@test "a ref glued to a NON-ASCII word character still migrates (this parser is the looser side)" {
  # the documented one-sided strictness: the classifier refuses this line
  # (Oniguruma's \b is Unicode-aware), this parser resolves it
  printf -- '- [ ] #790\xc3\xa4 — glued to a non-ASCII word character\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "a ref glued to a following word migrates NOTHING (the shared word boundary)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #790x — glued to a word, not a ref
- [ ] #791_y — glued to an underscore, the class member a hand-written
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "a ref glued to the CHECKBOX still migrates (only the classifier is stricter there)" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ]#790 — no blank after the checkbox
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  # the ATTACH half: the SKILL names this shape a NON-cause of the empty-plan
  # halt precisely because the backfill resolves AND attaches it
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
}

@test "a NON-ASCII blank does not open a fence here, matching the classifier" {
  # jq's Oniguruma would read [[:blank:]] as Unicode-aware and awk's as ASCII;
  # both now use [ \t], so an NBSP-indented fence marker is a fence in NEITHER
  printf '\xc2\xa0```markdown\n- [ ] #790 — still a real child\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "a zero-padded ref normalises to a bare JSON number" {
  # `#0790` must emit 790, not 0790 — JSON forbids leading zeros, and every
  # downstream jq consumer would fail to parse the document at all
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] #0790 — zero-padded ref
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a tilde line inside a backtick fence does not close it" {
  # removing the same-character guard would migrate #601
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
```markdown
~~~
- [ ] #601 quoted, not a child
```
- [ ] #790 — real child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (b): a closing run carrying an info string does not close the block" {
  # removing the blank-remainder guard would migrate #601
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
```
```markdown
- [ ] #601 quoted, not a child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "invariant (b): an unclosed fence swallows the rest of the body" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
Here is the shape:

```markdown
- [ ] #601 quoted
- [ ] #602 quoted
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "invariant (b): a CRLF body still opens and closes its fences" {
  # real epic bodies come back CRLF; the fence close depends on the remainder
  # matching blanks-only, which must tolerate the trailing \r
  printf '```markdown\r\n- [ ] #601 quoted\r\n```\r\n- [ ] #790 — real child\r\n' \
    > "$FIXTURE_DIR/epic-body.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (a): an uppercase [X] checkbox migrates, as the classifier accepts it" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [X] #790 — uppercase checkmark
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (a): an indented child bullet migrates, as the classifier accepts it" {
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
## Children

  - [ ] #790 — nested child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (a): a multi-blank bullet gap migrates, as the classifier accepts it" {
  # the classifier allows any run of blanks after the bullet; if this parser
  # required exactly one space, such a body would classify as an epic and then
  # migrate nothing at all
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
-  [ ] #790 — hand-aligned child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
}

@test "invariant (a): a bare-issue-URL line is not migrated, so it is not an epic signal" {
  # the mirror of read-dependencies.bats' "a bare-issue-URL task list is NOT an
  # epic": this parser needs a #N ref, which is WHY the classifier omits it
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] https://github.com/o/r/issues/790 — child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
}

@test "invariant (a): an ordered-list checkbox is not migrated (the [-*+] bullet set)" {
  # the mirror of read-dependencies.bats' ordered-list rejection
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
1. [ ] #790 — child
EOF
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[]' ]
  [ ! -s "$POST_LOG" ]
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
  # HYPHENATED slug on purpose: every real slug in this world has one, and
  # narrowing the ref regex's `[A-Za-z0-9_.-]` class would make this line stop
  # matching as qualified — the bare `#55` inside it would then read as a
  # SAME-repo child and issue 55 of THIS repo would be POSTed. A write-side
  # misparent, with skipped_cross_repo reported empty.
  cat > "$FIXTURE_DIR/epic-body.txt" <<'EOF'
- [ ] other-org/other.repo_2#55 — cross-repo, unmigratable
- [ ] third/repo#66 — a SECOND cross-repo ref
- [ ] #790 — same-repo child
EOF
  backfill
  [ "$status" -eq 0 ]
  # TWO elements: with one, the array's newline join never runs, so dropping
  # the (p) flag would collapse both into a single bogus entry unnoticed —
  # and this array is one of the four E1's reverse vet reads
  [ "$(echo "$output" | jq -c '.skipped_cross_repo')" = '["other-org/other.repo_2#55","third/repo#66"]' ]
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

@test "a CROSS-REPO native sub-issue does not mask a same-numbered markdown child" {
  # sub-issues may live in another repository (read-sub-issues.zsh documents the
  # same hazard). Keying `present` by a bare foreign number collides: the epic
  # holds native other/elsewhere#790 while its body declares `- [ ] #790`
  # meaning o/r#790. Without the repository filter the real child is reported
  # already_present and NEVER attached — and E1's reverse vet reads the ref as
  # accounted for, so the epic ships looking migrated but permanently missing a
  # child. The other two children are genuinely attached and must stay present.
  cat > "$FIXTURE_DIR/sub-issues.json" <<'JSON'
[{"number":790,"repository_url":"https://api.github.com/repos/other/elsewhere"},
 {"number":791,"repository_url":"https://api.github.com/repos/o/r"},
 {"number":792,"repository_url":"https://api.github.com/repos/o/r"}]
JSON
  # capture the streams SEPARATELY: the note goes to stderr (as
  # read-sub-issues.zsh does for the same hazard), and stdout must stay pure
  # JSON — a note leaking onto stdout would corrupt the document for every
  # consumer, which is the failure the split is here to catch
  run --separate-stderr env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    POST_LOG="$POST_LOG" zsh "$S" --repo o/r --epic 746
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.already_present')" = '[791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 1 ]
  contains "$(cat "$POST_LOG")" "sub_issue_id=1790"
  # the exclusion is surfaced, never silent: an unexplained re-attach is
  # exactly what would otherwise confuse whoever vets the plan
  contains "$stderr" "other/elsewhere#790"
  lacks "$output" "other/elsewhere"
}

@test "a same-repo slug on a native sub-issue still counts as present" {
  # the other side of the filter: a child carrying THIS repo's slug must not be
  # excluded — treating it as foreign would re-POST an attached child, and
  # GitHub rejects that, turning a clean no-op into a reported failure.
  cat > "$FIXTURE_DIR/sub-issues.json" <<'JSON'
[{"number":790,"repository_url":"https://api.github.com/repos/o/r"},
 {"number":791,"repository_url":"https://api.github.com/repos/O/R"},
 {"number":792,"repository_url":"https://api.github.com/repos/o/r"}]
JSON
  backfill
  [ "$status" -eq 0 ]
  # 791 differs only by case — GitHub slugs are case-insensitive
  [ "$(echo "$output" | jq -c '.already_present')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.added')" = '[]' ]
  [ ! -s "$POST_LOG" ]
  lacks "$output" "cross-repo sub-issues already attached"
}

@test "a partially-backfilled epic attaches only the missing children" {
  echo '[{"number":790}]' > "$FIXTURE_DIR/sub-issues.json"
  backfill
  [ "$status" -eq 0 ]
  # all three arrays PAIRWISE DISTINCT, on both emitters: elsewhere
  # markdown_children always equals added, so cross-wiring `--argjson md` to
  # `$added` would ship green — and E1's reverse vet reconciles the body
  # against markdown_children, i.e. it would reconcile the WRITE result
  [ "$(echo "$output" | jq -c '[.markdown_children, .already_present, .added]')" \
    = '[[790,791,792],[790],[791,792]]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
  : > "$POST_LOG"
  backfill --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.markdown_children, .already_present, .would_add]')" \
    = '[[790,791,792],[790],[791,792]]' ]
  [ ! -s "$POST_LOG" ]
}

# ---- dry-run ----------------------------------------------------------------

@test "--dry-run reports the plan and writes NOTHING" {
  backfill --dry-run
  [ "$status" -eq 0 ]
  # the whole DRY-RUN empty case in one line: a mis-wired skipped_cross_repo
  # here would halt EVERY migration before any write, and nothing else pins
  # that field as empty on this branch
  # `.epic` included: it was pinned on the LIVE emitter only, and E1 reads the
  # PLAN from this one — a slip here would vet a plan naming the wrong epic
  [ "$(echo "$output" | jq -c '[.epic, .dry_run, .would_add, .added, .skipped_cross_repo, .skipped_self_ref, .failed]')" \
    = '[746,true,[790,791,792],[],[],[],[]]' ]
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

@test "TWO failing children both land in failed (the array's comma join)" {
  # the realistic shape — an auth problem fails every child. With one entry the
  # join never runs; if it regressed, --argjson failed would be invalid JSON,
  # the emitter would take its || exit 1 path, and a run that had already
  # POSTed would report exit 1 instead of the documented exit 5
  printf '791\n792\n' > "$FIXTURE_DIR/fail-posts.txt"
  backfill
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790]' ]
  [ "$(echo "$output" | jq -c '[.failed[].number]')" = '[791,792]' ]
}

@test "a child whose POST fails is recorded in failed and the run exits 5 (partial)" {
  echo '791' > "$FIXTURE_DIR/fail-posts.txt"
  backfill
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,792]' ]
  # markdown_children is the PARSE result and must not track the write result
  [ "$(echo "$output" | jq -c '.markdown_children')" = '[790,791,792]' ]
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
  # gh's REAL reason is surfaced, not an opaque fixed string: both skills tell
  # the operator to report the failure naming the children, and a 404, a 403
  # and a 502 must be distinguishable (a body problem vs an auth problem)
  contains "$(echo "$output" | jq -r '.failed[0].error')" "404"
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
}

@test "a gh notice folded into the id capture still attaches every child" {
  # the id GET is captured with 2>&1, so a real gh's SSO hint or deprecation
  # notice lands in the same string as the id. Taking the capture whole (or
  # taking its first line) passes every other test, because under the stub the
  # capture is clean — but in production one notice makes child_id the notice
  # TEXT, every POST fails, and a healthy epic reports exit 5 with all three
  # children in failed[]: the operator is told the migration failed.
  printf 'gh: SSO enforcement is enabled for this org\n' > "$FIXTURE_DIR/id-notice.txt"
  backfill
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,791,792]' ]
  [ "$(echo "$output" | jq -c '.failed')" = '[]' ]
  [ "$(wc -l < "$POST_LOG")" -eq 3 ]
  # the id itself is still the right one, not the notice
  contains "$(cat "$POST_LOG")" "sub_issue_id=1790"
}

@test "an AMBIGUOUS id response fails closed for that child, and never guesses" {
  # two bare numeric lines: the capture no longer identifies one id. Dropping
  # the count check turns this into a guessed sub_issue_id that gets POSTed —
  # misparenting an unrelated issue under the epic, and GitHub allows one
  # parent only, so it is not trivially reversible. The other children must
  # still migrate: one ambiguous response is not a reason to abandon the run.
  echo x > "$FIXTURE_DIR/id-ambiguous.txt"
  backfill
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[]' ]
  [ "$(echo "$output" | jq -c '[.failed[].number]')" = '[790,791,792]' ]
  contains "$(echo "$output" | jq -r '.failed[0].error')" "unexpected id response"
  # the decisive assertion: nothing was POSTed on a guess
  [ ! -s "$POST_LOG" ]
}

@test "an ambiguous id response for ONE child does not stop the others" {
  # scoped variant of the above: the fail-closed branch is per-child, so a
  # regression that aborted the whole run on the first ambiguity would strand
  # migratable children in an epic reported as failed.
  cat > "$STUB.wrap" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in repos/o/r/issues/791) echo 9999 ;; esac; done
exec "$GH_REAL" "$@"
EOF
  chmod +x "$STUB.wrap"
  run env GH_BIN="$STUB.wrap" GH_REAL="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    POST_LOG="$POST_LOG" zsh "$S" --repo o/r --epic 746
  [ "$status" -eq 5 ]
  [ "$(echo "$output" | jq -c '.added')" = '[790,792]' ]
  [ "$(echo "$output" | jq -c '[.failed[].number]')" = '[791]' ]
  contains "$(echo "$output" | jq -r '.failed[0].error')" "unexpected id response"
  [ "$(wc -l < "$POST_LOG")" -eq 2 ]
  lacks "$(cat "$POST_LOG")" "sub_issue_id=9999"
}

@test "a missing jq is a named exit 1, before any write" {
  mkdir -p "$BATS_TEST_TMPDIR/nobin"
  run env PATH="$BATS_TEST_TMPDIR/nobin" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    POST_LOG="$POST_LOG" "$(command -v zsh)" "$S" --repo o/r --epic 746
  [ "$status" -eq 1 ]
  contains "$output" "jq not found on PATH"
  [ ! -s "$POST_LOG" ]
}

@test "a missing awk is a named exit 1, before any write" {
  # awk owns the whole migration rule, so its absence must not degrade to the
  # empty plan that means "nothing to migrate"
  mkdir -p "$BATS_TEST_TMPDIR/nawk"
  ln -sf "$(command -v jq)" "$BATS_TEST_TMPDIR/nawk/jq"
  run env PATH="$BATS_TEST_TMPDIR/nawk" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    POST_LOG="$POST_LOG" "$(command -v zsh)" "$S" --repo o/r --epic 746
  [ "$status" -eq 1 ]
  contains "$output" "awk not found on PATH"
  [ ! -s "$POST_LOG" ]
}

@test "a FAILING awk is a named exit 1, not an empty plan at exit 0" {
  # the guard's whole purpose: a failed parse must be distinguishable from a
  # genuine no-op epic, from both the status and the message
  # a FULL PATH with only awk shadowed: the epic fetch must succeed so the
  # failure under test is the parse, not the fetch
  mkdir -p "$BATS_TEST_TMPDIR/badawk"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/badawk/awk"
  chmod +x "$BATS_TEST_TMPDIR/badawk/awk"
  run env PATH="$BATS_TEST_TMPDIR/badawk:$PATH" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    POST_LOG="$POST_LOG" "$(command -v zsh)" "$S" --repo o/r --epic 746
  [ "$status" -eq 1 ]
  contains "$output" "failed to parse the epic body (awk)"
  [ ! -s "$POST_LOG" ]
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
