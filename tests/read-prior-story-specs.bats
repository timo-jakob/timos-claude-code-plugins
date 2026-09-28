#!/usr/bin/env bats
#
# Behavioral tests for read-prior-story-specs.zsh (#1363, slice 3 of #1266) —
# the bounded reader issue-refiner's consistency slice uses to fetch the
# story-spec/v1 blocks of the newest completed stories on one surface. The
# contract that matters:
#   - ONE `gh issue list --state closed --limit 30 --json number,body,stateReason`
#     call, no paging, and no `--limit` of its own (a usage error);
#   - only issues closed as COMPLETED count — a not-planned or duplicate story
#     settled nothing;
#   - at most five {issue, spec} JSON Lines, newest (highest number) first,
#     restricted to blocks declaring the surface, from the 30 newest candidates;
#   - extraction delegated to resolve-issue's read-story-spec.zsh: a candidate
#     with no usable block (or no interface_surfaces array) is skipped with one
#     stderr line, another surface is skipped silently, an extractor failure is 3;
#   - exit 1 with empty stdout when nothing matches — the normal early state.
#
# gh is stubbed via the GH_BIN seam. The stub logs its argv to $GH_LOG and
# serves $FIXTURE (a JSON array of {number, body, stateReason}) as the list.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/read-prior-story-specs.zsh"
  FIXTURE="$BATS_TEST_TMPDIR/issues.json"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  echo '[]' > "$FIXTURE"

  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ -f "$FIXTURE.fail" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
cat "$FIXTURE"
EOF
  chmod +x "$STUB"
  export GH_BIN="$STUB" FIXTURE GH_LOG
}

# A refined issue body carrying a story-spec/v1 block. $2 is the
# interface_surfaces JSON array, or the literal "absent" to omit the field.
body_with_spec() {
  local ac="$1" surfaces="$2" field=""
  [ "$surfaces" = absent ] || field=",\"interface_surfaces\":$surfaces"
  printf 'Prose about the story.\n\n<details>\n<summary>story-spec</summary>\n\n```json\n{"schema":"story-spec/v1","acceptance_criteria":["%s"]%s}\n```\n\n</details>\n' "$ac" "$field"
}

# Append {number, body, stateReason} to the fixture array; the reason defaults
# to COMPLETED.
add_issue() {
  local n="$1" body="$2" reason="${3:-COMPLETED}" tmp="$BATS_TEST_TMPDIR/fx.tmp"
  jq --argjson n "$n" --arg b "$body" --arg r "$reason" \
    '. + [{number: $n, body: $b, stateReason: $r}]' "$FIXTURE" > "$tmp"
  mv "$tmp" "$FIXTURE"
}

# A copy of the script beside a stub extractor, for the extractor-failure arms:
# the script finds read-story-spec.zsh by its own relative path, so the copy
# sees the stub. $1 is the stub's exit status, or "none" to leave it out.
script_with_extractor() {
  local t="$BATS_TEST_TMPDIR/t"
  mkdir -p "$t/refine-issue/scripts" "$t/resolve-issue/scripts"
  cp "$S" "$t/refine-issue/scripts/"
  if [ "$1" != none ]; then
    printf '#!/usr/bin/env zsh\nexit %s\n' "$1" > "$t/resolve-issue/scripts/read-story-spec.zsh"
  fi
  echo "$t/refine-issue/scripts/read-prior-story-specs.zsh"
}

@test "happy path: each line carries the issue number and its block, newest first (AC 1, 2)" {
  add_issue 1201 "$(body_with_spec 'Validation failures return RFC 9457 problem+json' '["rest"]')"
  add_issue 1244 "$(body_with_spec 'List endpoints paginate with a cursor' '["rest","web-ui"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  echo "${lines[0]}" | jq -e '.issue == 1244 and .spec.schema == "story-spec/v1" and .spec.acceptance_criteria[0] == "List endpoints paginate with a cursor"' >/dev/null
  echo "${lines[1]}" | jq -e '.issue == 1201 and .spec.acceptance_criteria[0] == "Validation failures return RFC 9457 problem+json"' >/dev/null
  # the block only — no surrounding issue prose on the line
  echo "${lines[0]}" | jq -e 'keys == ["issue","spec"]' >/dev/null
  lacks "$output" 'Prose about the story.'
}

@test "a surface later in interface_surfaces matches too — contains, not first-equals" {
  add_issue 600 "$(body_with_spec 'x' '["web-ui","rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | jq -e '.issue == 600' >/dev/null
}

@test "exactly one gh call, closed, capped at 30, number+body+stateReason only" {
  add_issue 1201 "$(body_with_spec 'x' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$GH_LOG")" = "issue list --repo o/r --state closed --limit 30 --json number,body,stateReason" ]
}

@test "a story closed as not planned or as a duplicate is not precedent" {
  add_issue 710 "$(body_with_spec 'abandoned design' '["rest"]')" NOT_PLANNED
  add_issue 709 "$(body_with_spec 'duplicate design' '["rest"]')" DUPLICATE
  add_issue 700 "$(body_with_spec 'shipped design' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.issue == 700' >/dev/null
  [ -z "$stderr" ]
}

@test "empty result: exit 1 with empty stdout (AC 2)" {
  add_issue 10 'An unrefined issue with prose only.'
  add_issue 11 "$(body_with_spec 'a cli thing' '["cli"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "no closed issues at all: exit 1 with empty stdout" {
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "cap: seven matches emit the five highest issue numbers, descending, and nothing older is read (AC 5)" {
  # Deliberately out of order, so the sort — not the fixture order — decides.
  for n in 103 107 101 105 102 106 104; do
    add_issue "$n" "$(body_with_spec "criterion $n" '["rest"]')"
  done
  # Older than every match: reading it would print a skip line.
  add_issue 100 'prose only'
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "$(printf '%s\n' "${lines[@]}" | jq -r .issue | tr '\n' ' ')" = "107 106 105 104 103 " ]
  [ -z "$stderr" ]
}

@test "only the 30 newest candidates are considered: a 31st, older match is never read" {
  local n
  for n in $(seq 1 30); do add_issue "$n" 'prose only'; done
  add_issue 0 "$(body_with_spec 'too old' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  lacks "$stderr" '#0:'
}

@test "malformed block: skipped with its stderr line, the rest still emitted (AC 3, 5)" {
  add_issue 301 "$(body_with_spec 'good one' '["rest"]')"
  add_issue 302 $'Prose.\n\n```json\n{"schema":"story-spec/v1", not json\n```\n'
  add_issue 303 "$(body_with_spec 'another good one' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  echo "${lines[0]}" | jq -e '.issue == 303' >/dev/null
  echo "${lines[1]}" | jq -e '.issue == 301' >/dev/null
  [ "$stderr" = "read-prior-story-specs.zsh: #302: no usable story-spec/v1 block, skipped" ]
}

@test "a block without an interface_surfaces array is skipped with its stderr line (AC 3)" {
  add_issue 401 "$(body_with_spec 'no surfaces field' absent)"
  add_issue 402 "$(body_with_spec 'surfaces not an array' '"rest"')"
  add_issue 400 "$(body_with_spec 'fine' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.issue == 400' >/dev/null
  contains "$stderr" '#402: no usable story-spec/v1 block, skipped'
  contains "$stderr" '#401: no usable story-spec/v1 block, skipped'
}

@test "a parseable block naming another surface is skipped silently (AC 3)" {
  add_issue 501 "$(body_with_spec 'grpc only' '["grpc"]')"
  add_issue 500 "$(body_with_spec 'rest one' '["rest"]')"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.issue == 500' >/dev/null
  [ -z "$stderr" ]
}

@test "--limit 3 is a usage error, and gh is never called (AC 1)" {
  run --separate-stderr zsh "$S" --repo o/r --surface rest --limit 3
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "missing --surface is a usage error (AC 1)" {
  run --separate-stderr zsh "$S" --repo o/r
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "missing --repo is a usage error" {
  run --separate-stderr zsh "$S" --surface rest
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "an empty --surface is a usage error" {
  run --separate-stderr zsh "$S" --repo o/r --surface ''
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "a dangling --surface is a usage error" {
  run --separate-stderr zsh "$S" --repo o/r --surface
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "every surface in the taxonomy is accepted: grpc, web-ui and cli as well as rest" {
  local s
  for s in grpc web-ui cli; do
    echo '[]' > "$FIXTURE"
    add_issue 900 "$(body_with_spec "x $s" "[\"$s\"]")"
    run --separate-stderr zsh "$S" --repo o/r --surface "$s"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | jq -e '.issue == 900' >/dev/null
  done
}

@test "a surface outside the taxonomy is a usage error, never a silent 'no precedent'" {
  run --separate-stderr zsh "$S" --repo o/r --surface webui
  [ "$status" -eq 2 ]
  contains "$stderr" 'must be one of rest|grpc|web-ui|cli'
  [ ! -s "$GH_LOG" ]
}

@test "--help prints the usage and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" 'usage: read-prior-story-specs.zsh'
}

@test "a failing gh call is a runtime error, exit 3 (AC 4)" {
  touch "$FIXTURE.fail"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a gh response that is not a JSON array is a runtime error, exit 3" {
  echo '{"message":"Not Found"}' > "$FIXTURE"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "an array of non-issues is a runtime error, exit 3 — not jq's own exit 5" {
  echo '[1,2]' > "$FIXTURE"
  run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a missing gh binary is a runtime error, exit 3 (AC 4)" {
  GH_BIN="$BATS_TEST_TMPDIR/no-such-gh" run --separate-stderr zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  contains "$stderr" "gh binary not found: $BATS_TEST_TMPDIR/no-such-gh"
}

@test "a missing jq is a runtime error, exit 3 (AC 4)" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  # PATH is set for the script only: bats' own `run` needs mktemp.
  run --separate-stderr /usr/bin/env PATH="$BATS_TEST_TMPDIR/empty" /bin/zsh "$S" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  contains "$stderr" 'jq not found'
}

@test "the extractor's exit 3 propagates as 3 (AC 3)" {
  add_issue 800 'any body'
  local s; s="$(script_with_extractor 3)"
  run --separate-stderr zsh "$s" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" '#800: read-story-spec.zsh failed (exit 3)'
}

@test "any other extractor failure is a runtime error, exit 3" {
  add_issue 801 'any body'
  local s; s="$(script_with_extractor 2)"
  run --separate-stderr zsh "$s" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  contains "$stderr" '#801: read-story-spec.zsh exited 2'
}

@test "a missing extractor is a runtime error, exit 3, before gh is called" {
  local s; s="$(script_with_extractor none)"
  run --separate-stderr zsh "$s" --repo o/r --surface rest
  [ "$status" -eq 3 ]
  contains "$stderr" 'extractor not found'
  [ ! -s "$GH_LOG" ]
}

@test "extraction is delegated to read-story-spec.zsh, never reimplemented (AC 3)" {
  run grep -F 'resolve-issue/scripts/read-story-spec.zsh' "$S"
  [ "$status" -eq 0 ]
  # no fence parsing of its own: no awk, no backtick-fence matching
  run grep -E '(^|[^[:alnum:]_])awk([^[:alnum:]_]|$)|```' "$S"
  [ "$status" -eq 1 ]
}
