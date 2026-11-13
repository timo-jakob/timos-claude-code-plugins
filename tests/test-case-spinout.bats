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

bats_require_minimum_version 1.5.0
load assertions

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
  contains "$(cat "$ERR")" "--repo is required"
}

@test "missing --story is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 2 ]
  contains "$(cat "$ERR")" "--story is required"
}

@test "non-numeric --story is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story abc --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 2 ]
  contains "$(cat "$ERR")" "must be a number"
}

@test "missing spec file is a runtime error (exit 1)" {
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  contains "$(cat "$ERR")" "spec file not found"
}

@test "unknown arg is a usage error (exit 2)" {
  write spec.json "$NEW_TWO"
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json" --bogus x
  [ "$status" -eq 2 ]
  contains "$(cat "$ERR")" "unknown arg"
}

@test "a dangling final option (no value) is a clean usage error, not a shift abort" {
  # --spec with no following value must yield exit 2 + the required-field message,
  # not a cryptic `shift count must be <= $#` abort under set -e.
  spinout --repo o/r --story 671 --spec
  [ "$status" -eq 2 ]
  contains "$(cat "$ERR")" "--spec is required"
  lacks "$(cat "$ERR")" "shift"
}

@test "invalid JSON spec is a runtime error (exit 1)" {
  write spec.json '{not json'
  spinout --repo o/r --story 671 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 1 ]
  contains "$(cat "$ERR")" "not valid JSON"
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
  run ! grep -q '^#55 ::' "$CLOSE_LOG"
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

# --- #2939: the prose that runs this script, and the chained mode's relay -------

@test "#2939 Step 2.5 spins out the test cases without asking, in every run, chained or direct" {
  local t; t="$(tr '\n' ' ' < "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s ' ')"
  contains "$t" "**In every refine-issue run, chained or direct, Step 2.5 files, edits and closes the story's test-case issues through \`test-case-spinout.zsh\` without asking (#2939).**"
  contains "$t" 'Approving the rewrite, or the all-auto or chained write-back that replaces the approval, also covers the test-case issues, and no branch puts their filing to the human.'
  lacks "$t" 'ask whether test-case issues'
}

@test "#2939 a chained refinement relays a below-threshold intent or gap question as questions-pending, never asks it" {
  local t; t="$(tr '\n' ' ' < "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s ' ')"
  contains "$t" 'In a chained refinement, a below-threshold intent or gap question is never asked in place or through a side channel. When a round'"'"'s split leaves any `ask` entry, the run writes nothing back, and the needs-decision park is never taken.'
  contains "$t" 'Then it returns `questions-pending` with `chain-result.zsh emit --issue <N> --outcome questions-pending'
  contains "$t" 'Nothing is posted to GitHub between dispatches.'
  contains "$t" '`ROUNDS` counts across dispatches, through the resume file. Once `ROUNDS` is at or past 3, whatever would start another round returns `stopped` instead, with the reason "no convergence within the round cap"'
  contains "$t" 'Only the dispatch that ends `ready`, `split` or `stopped` emits Step 7'"'"'s record, with `T0`, `PAUSED_S`, `ROUNDS`, `RAISED` and `RESOLVED` carried across dispatches through the resume file. A `questions-pending` dispatch emits none.'
  contains "$t" '`provenance.generated_by` set to `issue-refiner via /development:resolve-issue`.'
  contains "$t" 'On exit 2 or 1, return `stopped` with the reason "unreadable step handoff" and write nothing.'
  contains "$t" 'The `already-attempted` and `second-generation` refusals do not apply to it: `eligible` is not run.'
}

# --- #3079: provisional test cases, and bodies reconciled before close ----------

@test "#3079 the story-spec contract carries an optional provisional marker naming the assumption" {
  local t; t="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$t" 'and **optional (#3079)** `provisional` — `{ assumption }`, present when the expectation rests on third-party behaviour the refiner did not verify, naming that behaviour; absent or `null` when it was verified;'
}

@test "#3079 the refiner marks a test case provisional when it rests on unverified third-party behaviour" {
  local t; t="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/agents/issue-refiner.md")"
  contains "$t" '**Mark a test case provisional when its expectation rests on third-party behaviour you did not verify** (#3079)'
  contains "$t" '`"provisional": {"assumption": "<the unverified behaviour>"}`, naming that behaviour in one sentence.'
}

@test "#3079 resolve-issue §6 reconciles a contradicted test-case body, with a one-line note, before the PR opens" {
  local s t r
  s="$(awk '/^### 6\. /{f=1} f && /^### 7\. /{exit} f' "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  t="$(tr -s '[:space:]' ' ' <<<"$s")"
  contains "$t" '**Reconcile the test-case bodies before the PR opens (#3079).** When the same-PR test-case lifecycle ran, and before open-pr runs, compare each plan entry'"'"'s `test-case` issue with the acceptance test written for it, and update a body the test contradicts: see `reference/checkpoint.md` § Reconciling the test-case bodies before the PR (#3079)'
  # The procedure lives in the section §6 points at, so the conductor stays under its ceiling.
  s="$(awk '/^## Reconciling the test-case bodies before the PR \(#3079\)$/{f=1; print; next} f && /^## /{exit} f' "$REPO_ROOT/development/skills/resolve-issue/reference/checkpoint.md")"
  [ -n "$s" ] || { echo "checkpoint.md has no #3079 reconciliation section" >&2; return 1; }
  r="$(tr -s '[:space:]' ' ' <<<"$s")"
  contains "$r" 'Compare each plan entry'"'"'s `test-case` issue with the acceptance test written for it.'
  contains "$r" 'A `provisional` entry'"'"'s `assumption` names the expectation to check first.'
  contains "$r" '"note": "Reconciled before close: the build found <shipped behaviour>, not <the old expectation> (story #<N>)."'
  contains "$r" 'An entry that already matches is left alone, so a re-run writes nothing.'
  contains "$r" 'On a non-zero exit, re-run it once; if it fails again, name that issue and the shipped expectation in the PR'"'"'s Summary and open the PR all the same.'
  contains "$r" 'The Summary also names every body this step updated'
}

# --- #3089: the story-spec block is the single source of a reconciled expectation

@test "#3089 checkpoint.md reconciles the story-spec entry and never hand-edits a test-case body" {
  local s r
  s="$(awk '/^## Reconciling the test-case bodies before the PR \(#3079\)$/{f=1; print; next} f && /^## /{exit} f' "$REPO_ROOT/development/skills/resolve-issue/reference/checkpoint.md")"
  [ -n "$s" ] || { echo "checkpoint.md has no reconciliation section" >&2; return 1; }
  r="$(tr -s '[:space:]' ' ' <<<"$s")"
  contains "$r" 'whether or not that entry is `provisional`, reconcile the entry in the story'"'"'s `story-spec/v1` block (#3089), the single source of truth for that expectation.'
  contains "$r" 'Never edit a test-case body by hand: `test-case-spinout.zsh` generates it and regenerates it on every refine write-back.'
  contains "$r" '"<skill-base-dir>/scripts/reconcile-test-case-spec.zsh" --repo "$REPO" --story <N> --map <map.json>'
  contains "$r" 'For each mapped entry whose `shape` differs, it sets `shape` to the shipped expectation, removes `provisional` and sets `reconciled` to the note.'
  contains "$r" 'It then re-renders the linked bodies with `test-case-spinout.zsh`, which prints the note beneath each body'"'"'s `## Shape` section, and writes the block back.'
  contains "$r" 'so the prose region and `provenance` stay byte-identical and `prose_sha256` still verifies.'
  lacks "$r" 'gh issue edit <issue>'
  lacks "$r" 'the story'"'"'s spec block is left as it is'
}

@test "#3089 ARCHITECTURE.md records the optional reconciled field and the lifecycle's re-render" {
  local t; t="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$t" 'and **optional (#3089)** `reconciled` — a string: the one-line `Reconciled before close: the build found <shipped behaviour>, not <the old expectation> (story #<N>).` note, which resolve-issue §6 writes when it reconciles the entry'"'"'s `shape` to the shipped expectation. test-case-spinout.zsh renders it beneath the body'"'"'s `## Shape` section, so the note survives every re-render. It is absent or `null` on an entry that was never reconciled |'
  contains "$t" 'Before that PR opens, a test case whose expectation the build'"'"'s tests contradict, provisional or not, is reconciled to the shipped behaviour with a one-line note (#3079): the reconcile updates the story-spec block'"'"'s entry and re-renders the body through `test-case-spinout.zsh` (#3089)'
  lacks "$t" 'has its body updated to the shipped behaviour'
}

@test "#3089 the refiner carries a reconciled test case forward unchanged" {
  local t; t="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/agents/issue-refiner.md")"
  contains "$t" '**Carry a reconciled test case forward unchanged** (#3089): when the issue body'"'"'s current `story-spec/v1` block gives a `test_cases[]` entry a `reconciled` note, copy that entry'"'"'s `shape` and `reconciled` into your draft exactly as they stand, even where the prose still states the old expectation, unless the human changes that case in this conversation. A case whose `shape` you change drops `reconciled`.'
  contains "$t" 'A case whose `shape` you change drops `reconciled`.'
}

RECONCILED='{"schema":"story-spec/v1","test_cases":[
  {"id":"tc-error-bad-token","kind":"error","shape":"GET /jobs expired token -> 403","tooling":"curl","issue":501,
   "reconciled":"Reconciled before close: the build found 403, not 401 (story #3089)."},
  {"id":"tc-happy-list","kind":"happy","shape":"GET /jobs -> 200","tooling":"curl","issue":502}]}'

@test "#3089 a non-empty reconciled note renders as its own line directly beneath ## Shape" {
  write spec.json "$RECONCILED"
  spinout --repo o/r --story 3089 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  local e; e="$(awk '/^=== edit #501 ===$/{f=1; next} /^=== edit /{f=0} f' "$EDIT_LOG")"
  contains "$e" $'## Shape\n\nGET /jobs expired token -> 403\n\nReconciled before close: the build found 403, not 401 (story #3089).\n\n---\n'
}

@test "#3089 an entry without reconciled (absent, null or empty) renders exactly as before" {
  write spec.json '{"schema":"story-spec/v1","test_cases":[
    {"id":"a","kind":"happy","shape":"GET / -> 200","tooling":"curl","issue":601},
    {"id":"b","kind":"happy","shape":"GET / -> 200","tooling":"curl","issue":602,"reconciled":null},
    {"id":"c","kind":"happy","shape":"GET / -> 200","tooling":"curl","issue":603,"reconciled":""}]}'
  spinout --repo o/r --story 3089 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  local n; for n in 601 602 603; do
    contains "$(awk -v h="=== edit #$n ===" '$0 == h {f=1; next} /^=== edit /{f=0} f' "$EDIT_LOG")" $'## Shape\n\nGET / -> 200\n\n---\n'
  done
  lacks "$(cat "$EDIT_LOG")" 'Reconciled before close'
}

@test "#3089 re-running the spin-out on a reconciled block yields a byte-identical body" {
  write spec.json "$RECONCILED"
  spinout --repo o/r --story 3089 --spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  cp "$EDIT_LOG" "$BATS_TEST_TMPDIR/first.log"; : > "$EDIT_LOG"
  spinout --repo o/r --story 3089 --spec "$BATS_TEST_TMPDIR/spec.json" --old-spec "$BATS_TEST_TMPDIR/spec.json"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.log" "$EDIT_LOG"
  contains "$(cat "$EDIT_LOG")" 'Reconciled before close: the build found 403, not 401 (story #3089).'
}
