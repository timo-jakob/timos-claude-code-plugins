#!/usr/bin/env bats
#
# Behavioral tests for review-dispatch.zsh (#560): the review-panel invocation
# contract for the autonomous review loop (epic #557). The orchestrator must
# pick the right language panel WITHOUT language-specific knowledge (mirroring
# /development:maintenance dispatch), scope review to the STORY'S DIFF (so the
# loop never re-litigates untouched legacy code), and turn an unsupported repo
# type into a TYPED escalation rather than a crash.
#
# Detection is stubbed via the DETECT_STACK_BIN seam so language selection is
# deterministic and needs no git/gh probing; git itself runs against real temp
# repos so the diff-scoping is exercised for real.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"

  # Fake detect-stack.sh: echoes the languages JSON from $DETECT_LANGS_JSON.
  STUB="$BATS_TEST_TMPDIR/detect-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$DETECT_LANGS_JSON"
EOF
  chmod +x "$STUB"

  # A real temp git repo with a committed base on `main`.
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  echo old > "$R/legacy.py"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
}

plan() {  # $1 = languages json ; rest = extra flags
  local langs="$1"; shift
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON="$langs" \
    zsh "$S" plan --repo "$R" --base main "$@"
}

# ---- repo-type → panel mapping (adding a language needs no orchestrator edit)

@test "plan: python repo maps to development-python:review" {
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: swift repo maps to development-swift:review (same invocation)" {
  plan '{"languages":["swift"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-swift:review" ]
}

@test "plan: java repo maps to development-java:review" {
  plan '{"languages":["java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-java:review" ]
}

@test "plan: findings_path is a well-known per-round path in the worktree" {
  plan '{"languages":["python"]}' --round 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "2" ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$R/.review/findings-round-2.json" ]
}

# ---- diff-scoping: only the story's changed files are the review scope

@test "plan: changed_files are the story's diff, not the whole repo" {
  echo "print(1)" > "$R/app.py"        # new (untracked) file = the story
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  # app.py is in scope; the untouched committed legacy.py is not
  echo "$output" | jq -e '.changed_files | index("app.py")' >/dev/null
  echo "$output" | jq -e '.changed_files | index("legacy.py") | not' >/dev/null
}

# ---- unsupported / ambiguous repo type is a TYPED escalation, not a crash

@test "plan: unsupported repo type (go/ts) exits 3 with a typed error" {
  plan '{"languages":["go","typescript"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: no detected languages exits 3 with a typed error" {
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: multiple panels with no primary is an ambiguous typed error (exit 3)" {
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
  echo "$output" | jq -e '.candidates | index("python") and index("java")' >/dev/null
}

@test "plan: .maintenance.yml primary disambiguates multiple panels" {
  printf 'primary: java\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

# ---- claude-plugin fallback repo_type (#809): a plugin repo detects no
# language, so is_claude_plugin selects the plugin panel — but ONLY as a
# fallback: a language always wins, and ambiguity is never defused by it.

@test "plan: #809 no language + is_claude_plugin maps to the plugin panel" {
  plan '{"languages":[],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-claude-plugin:review" ]
}

@test "plan: #809 a language always wins over the plugin fallback (no regression)" {
  plan '{"languages":["python"],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: #809 no language and is_claude_plugin false stays a typed error" {
  plan '{"languages":[],"is_claude_plugin":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 absent is_claude_plugin key defaults to false, no crash" {
  # an older detect-stack that omits the key must fall through cleanly
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 the plugin fallback does not defuse language ambiguity" {
  plan '{"languages":["python","java"],"is_claude_plugin":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

# ---- scope-findings: findings outside the story's diff do not appear

@test "scope-findings: drops findings in untouched files, keeps in-diff ones" {
  echo "print(1)" > "$R/app.py"         # the story touches only app.py
  cat > "$R/findings.json" <<'EOF'
[
  {"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"in-diff"},
  {"severity":"WARNING","dimension":"code_quality","file":"legacy.py","line":3,"title":"out-of-diff"},
  {"severity":"SUGGESTION","dimension":"tests","file":"./app.py","line":1,"title":"in-diff-dot"}
]
EOF
  run env GIT_BIN=git zsh "$S" scope-findings --repo "$R" --base main --findings "$R/findings.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  echo "$output" | jq -e 'all(.[]; .title != "out-of-diff")' >/dev/null
}

@test "scope-findings: missing findings file yields an empty array" {
  run zsh "$S" scope-findings --repo "$R" --base main --findings "$R/absent.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

# ---- usage

@test "plan: --repo is required (usage error, exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --base main
  [ "$status" -eq 2 ]
}

@test "no subcommand is a usage error (exit 2)" {
  run zsh "$S"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand is a usage error (exit 2)" {
  run zsh "$S" frobnicate
  [ "$status" -eq 2 ]
}
