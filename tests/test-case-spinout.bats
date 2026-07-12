#!/usr/bin/env bats
#
# Behavioral tests for test-case-spinout.zsh (#671, epic #573) — the reconcile
# primitive refine-issue runs to spin a story's story-spec/v1 `test_cases[]` out
# into linked `test-case` issues. The contract that matters:
#   - one linked test-case issue per case, body generated from the spec entry;
#   - the reconciled test_cases array (printed to stdout) carries the issue links;
#   - a re-refinement that drops a case closes the now-orphaned issue + comment;
#   - a no-surface story (empty test_cases) creates nothing.
# `gh` is shadowed via PATH with a fake that logs every subcommand, so the whole
# reconcile is exercised deterministically without network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/test-case-spinout.zsh"

  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CREATE_LOG="$BATS_TEST_TMPDIR/create.log"
  EDIT_LOG="$BATS_TEST_TMPDIR/edit.log"
  CLOSE_LOG="$BATS_TEST_TMPDIR/close.log"
  LABEL_LOG="$BATS_TEST_TMPDIR/label.log"
  ERR="$BATS_TEST_TMPDIR/stderr"
  : > "$CREATE_LOG"; : > "$EDIT_LOG"; : > "$CLOSE_LOG"; : > "$LABEL_LOG"; : > "$ERR"
  printf '100\n' > "$BATS_TEST_TMPDIR/counter"

  # Fake gh: `issue create` returns a fresh issue URL (monotonic counter) and
  # records the --title/--body/--label; edit/close/label append their argv.
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
sub="\$1 \$2"
case "\$sub" in
  "label create") printf '%s\n' "\$*" >> "$LABEL_LOG"; exit 0 ;;
  "issue create")
    n=\$(cat "$BATS_TEST_TMPDIR/counter"); n=\$((n+1)); printf '%s\n' "\$n" > "$BATS_TEST_TMPDIR/counter"
    title=""; body=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --title) title="\$2"; shift 2;; --body) body="\$2"; shift 2;; *) shift;; esac
    done
    printf '=== #%s ===\ntitle: %s\n%s\n' "\$n" "\$title" "\$body" >> "$CREATE_LOG"
    printf 'https://github.com/o/r/issues/%s\n' "\$n"; exit 0 ;;
  "issue edit")
    num="\$3"; body=""
    while [ \$# -gt 0 ]; do case "\$1" in --body) body="\$2"; shift 2;; *) shift;; esac; done
    printf '=== edit #%s ===\n%s\n' "\$num" "\$body" >> "$EDIT_LOG"; exit 0 ;;
  "issue close")
    num="\$3"; comment=""
    while [ \$# -gt 0 ]; do case "\$1" in --comment) comment="\$2"; shift 2;; *) shift;; esac; done
    printf '#%s :: %s\n' "\$num" "\$comment" >> "$CLOSE_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/gh"
}

# Send stderr (progress diagnostics) to $ERR so $output is the reconciled JSON
# on stdout alone and parses cleanly; validation tests read $ERR for messages.
spinout() { run env ERR="$ERR" PATH="$STUB:$PATH" bash -c 'zsh "$@" 2>"$ERR"' _ "$S" "$@"; }
write() { printf '%s' "$2" > "$BATS_TEST_TMPDIR/$1"; }

# A two-case (happy + error) REST story spec.
NEW_TWO='{"schema":"story-spec/v1","test_cases":[
  {"id":"tc-happy-file-job","kind":"happy","shape":"POST /jobs {job_ref} -> 201","tooling":"curl","issue":null},
  {"id":"tc-error-oversized","kind":"error","shape":"POST /jobs 40KB note -> 413","tooling":"curl","issue":null}]}'

# ---- argument validation -----------------------------------------------------

@test "missing --repo is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 2 ]
  [[ "$(cat "$ERR")" == *"--repo is required"* ]]
}

@test "missing --story is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 2 ]
  [[ "$(cat "$ERR")" == *"--story is required"* ]]
}

@test "non-numeric --story is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story abc --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 2 ]
  [[ "$(cat "$ERR")" == *"must be a number"* ]]
}

@test "missing spec file is a runtime error (exit 1)" {
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == *"spec file not found"* ]]
}

@test "unknown arg is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json" --bogus x
  [ "$status" -eq 2 ]
  [[ "$(cat "$ERR")" == *"unknown arg"* ]]
}

@test "a dangling final option (no value) is a clean usage error, not a shift abort" {
  # --spec with no following value must yield exit 2 + the required-field message,
  # not a cryptic `shift count must be <= $#` abort under set -e.
  spinout --repo o/r --story 671 --spec
  [ "$status" -eq 2 ]
  [[ "$(cat "$ERR")" == *"--spec is required"* ]]
  [[ "$(cat "$ERR")" != *"shift"* ]]
}

@test "invalid JSON spec is a runtime error (exit 1)" {
  write spec.json '{not json'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == *"not valid JSON"* ]]
}

# ---- create path (AC1 + AC2) -------------------------------------------------

@test "creates one test-case issue per case (AC1) and fills issue links (AC2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  # two issues created (#101, #102)
  [ "$(grep -c '^=== #' "$CREATE_LOG")" -eq 2 ]
  # the reconciled array on stdout carries numeric issue links for both cases
  echo "$output" | jq -e 'length == 2' >/dev/null
  echo "$output" | jq -e '.[0].issue == 101 and .[1].issue == 102' >/dev/null
  echo "$output" | jq -e 'all(.[]; .issue|type=="number")' >/dev/null
}

@test "created body is generated from the spec entry (kind, tooling, shape, parent)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  grep -q 'Parent story: #671' "$CREATE_LOG"
  grep -q 'tc-happy-file-job' "$CREATE_LOG"
  grep -q 'POST /jobs {job_ref} -> 201' "$CREATE_LOG"
  grep -q '\*\*Kind:\*\* `happy`' "$CREATE_LOG"
  grep -q '\*\*Tooling:\*\* `curl`' "$CREATE_LOG"
  # the same-PR / no-blockedBy lifecycle note rides along
  grep -q 'same PR' "$CREATE_LOG"
}

@test "the test-case label is ensured" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  grep -q 'test-case' "$LABEL_LOG"
}

# ---- reconcile path ----------------------------------------------------------

@test "an existing linked case is edited, not re-created" {
  write spec.json "$NEW_TWO"
  # old block already links the happy case to #55
  write old.json '{"test_cases":[{"id":"tc-happy-file-job","kind":"happy","shape":"old","tooling":"curl","issue":55}]}'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json" --old-spec "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 0 ]
  # #55 edited (reused), only the error case newly created
  grep -q '=== edit #55 ===' "$EDIT_LOG"
  [ "$(grep -c '^=== #' "$CREATE_LOG")" -eq 1 ]
  # output preserves the reused link and adds the new one
  echo "$output" | jq -e '.[0].issue == 55' >/dev/null
  echo "$output" | jq -e '.[1].issue|type=="number"' >/dev/null
}

# ---- orphan close (AC3) ------------------------------------------------------

@test "a dropped case closes the orphaned issue with a comment (AC3)" {
  # new spec keeps only the happy case; old linked BOTH happy(#55) and error(#56)
  write spec.json '{"test_cases":[{"id":"tc-happy-file-job","kind":"happy","shape":"s","tooling":"curl","issue":null}]}'
  write old.json '{"test_cases":[
    {"id":"tc-happy-file-job","kind":"happy","shape":"s","tooling":"curl","issue":55},
    {"id":"tc-error-oversized","kind":"error","shape":"s","tooling":"curl","issue":56}]}'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json" --old-spec "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 0 ]
  # #56 (the dropped error case) closed with an explanatory comment
  grep -q '^#56 ::' "$CLOSE_LOG"
  grep -q 'tc-error-oversized' "$CLOSE_LOG"
  # #55 kept (edited), not closed
  ! grep -q '^#55 ::' "$CLOSE_LOG"
  grep -q '=== edit #55 ===' "$EDIT_LOG"
}

# ---- no-surface story --------------------------------------------------------

@test "a no-surface story (empty test_cases) creates nothing and prints []" {
  write spec.json '{"schema":"story-spec/v1","test_cases":[]}'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  [ ! -s "$CREATE_LOG" ]
  echo "$output" | jq -e 'length == 0' >/dev/null
}

@test "clearing all cases closes every prior link as an orphan" {
  write spec.json '{"test_cases":[]}'
  write old.json '{"test_cases":[
    {"id":"tc-a","kind":"happy","shape":"s","tooling":"cli","issue":55},
    {"id":"tc-b","kind":"error","shape":"s","tooling":"cli","issue":56}]}'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json" --old-spec "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 0 ]
  grep -q '^#55 ::' "$CLOSE_LOG"
  grep -q '^#56 ::' "$CLOSE_LOG"
  [ ! -s "$CREATE_LOG" ]
}

# ---- idempotent no-op re-run (new spec already carries links, no old-spec) ---

@test "a case already carrying a numeric issue is reused (edit) without --old-spec" {
  write spec.json '{"test_cases":[{"id":"tc-a","kind":"happy","shape":"s","tooling":"cli","issue":77}]}'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  grep -q '=== edit #77 ===' "$EDIT_LOG"
  [ ! -s "$CREATE_LOG" ]
  echo "$output" | jq -e '.[0].issue == 77' >/dev/null
}
