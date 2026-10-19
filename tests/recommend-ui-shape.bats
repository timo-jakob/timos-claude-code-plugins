#!/usr/bin/env bats
#
# Behavioural tests for recommend-ui-shape.zsh (#1127, epic #1122) — the UI shape
# recommender behind the bootstrap SKILL's Shared questions Q7. It reads
# detect-stack's languages, §3k.5's React overlay verdict and the shell/remote
# shape markers on disk, and its EXIT CODE is the signal §3k.7 branches on:
# 0 = show the shell plan line, 3 = show nothing (with a typed reason),
# 2 = usage/precondition error with empty stdout. jq-driven, so hermetic.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REC="$REPO_ROOT/development/skills/bootstrap/scripts/recommend-ui-shape.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MAINT="$REPO_ROOT/MAINTAINING.md"
  WORK="$BATS_TEST_TMPDIR/repo"
  # ISO holds only zsh — not jq — so the jq-absent branch runs hermetically.
  ISO="$BATS_TEST_TMPDIR/iso-bin"
  mkdir -p "$WORK" "$ISO"
  ln -sf "$(command -v zsh)" "$ISO/zsh"
}

PLAN_LINE='React UI shape: shell (default) — reply `remote: page` or `remote: widget` to scaffold a remote instead (#1127)'

marker() { mkdir -p "$WORK/$(dirname "$1")"; : > "$WORK/$1"; }

recommend() { run --separate-stderr zsh "$REC" "$@"; }

# exit3 <reason> <shape|null> <remote_kind|null> <marker|null> — the exit-3 document
exit3() {
  [ "$status" -eq 3 ] || { echo "status $status: $output $stderr"; return 1; }
  [ "$(jq -c . <<<"$output")" = "$(jq -nc --arg r "$1" --argjson s "$2" --argjson k "$3" --argjson m "$4" \
    '{applicable: false, reason: $r, shape: $s, remote_kind: $k, marker: $m}')" ]
}

# --- gates 1-3: no shape to choose -----------------------------------------------

@test "recommend-ui-shape: javascript absent from --languages → exit 3, no-javascript, every field null" {
  recommend --languages python,go --react-overlay applies "$WORK"
  exit3 no-javascript null null null
}

@test "recommend-ui-shape: --react-overlay absent → exit 3, no-browser-ui" {
  recommend --languages javascript --react-overlay absent "$WORK"
  exit3 no-browser-ui null null null
}

@test "recommend-ui-shape: --react-overlay skipped → exit 3, react-overlay-skipped, never reported as no UI" {
  recommend --languages javascript --react-overlay skipped "$WORK"
  exit3 react-overlay-skipped null null null
  lacks "$output" 'no-browser-ui'
}

@test "recommend-ui-shape: the gates run in order — no-javascript first, the overlay before any marker" {
  marker src/shell/loader.ts
  recommend --languages python --react-overlay absent "$WORK"
  exit3 no-javascript null null null
  recommend --languages javascript --react-overlay absent "$WORK"
  exit3 no-browser-ui null null null
  recommend --languages javascript --react-overlay skipped "$WORK"
  exit3 react-overlay-skipped null null null
}

@test "recommend-ui-shape: javascript is found anywhere in the comma-separated list, spaces tolerated" {
  recommend --languages 'python, javascript ,go' --react-overlay applies "$WORK"
  [ "$status" -eq 0 ]
  recommend --languages '' --react-overlay applies "$WORK"
  exit3 no-javascript null null null
  recommend --languages javascripts --react-overlay applies "$WORK"
  exit3 no-javascript null null null
}

# --- gates 4-5: the shape is already on disk ----------------------------------------

@test "recommend-ui-shape: src/shell/loader.ts → exit 3, shape-marker, shape shell" {
  marker src/shell/loader.ts
  recommend --languages javascript --react-overlay applies "$WORK"
  exit3 shape-marker '"shell"' null '"src/shell/loader.ts"'
}

@test "recommend-ui-shape: src/remote/entry.tsx → shape remote, kind page" {
  marker src/remote/entry.tsx
  recommend --languages javascript --react-overlay applies "$WORK"
  exit3 shape-marker '"remote"' '"page"' '"src/remote/entry.tsx"'
}

@test "recommend-ui-shape: src/remote/entry.tsx with src/remote/manifest.ts → kind widget" {
  marker src/remote/entry.tsx
  marker src/remote/manifest.ts
  recommend --languages javascript --react-overlay applies "$WORK"
  exit3 shape-marker '"remote"' '"widget"' '"src/remote/entry.tsx"'
}

@test "recommend-ui-shape: a widget marker alone is no remote marker — the shell is still recommended" {
  marker src/remote/manifest.ts
  recommend --languages javascript --react-overlay applies "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .shape <<<"$output")" = shell ]
}

@test "recommend-ui-shape: both shell and remote markers → exit 3, conflicting-markers, naming the remote marker" {
  marker src/shell/loader.ts
  marker src/remote/entry.tsx
  marker src/remote/manifest.ts
  recommend --languages javascript --react-overlay applies "$WORK"
  exit3 conflicting-markers null null '"src/remote/entry.tsx"'
}

# --- gate 6: the recommendation ------------------------------------------------------

@test "recommend-ui-shape: a JavaScript repo with the overlay and no marker → exit 0, the shell by default" {
  recommend --languages javascript --react-overlay applies "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = "$(jq -nc --arg l "$PLAN_LINE" \
    '{applicable: true, shape: "shell", remote_kind: null, basis: "default", plan_line: $l}')" ]
  [ -z "$stderr" ]
}

@test "recommend-ui-shape: plan_line is §3k.7's Step 2 plan line verbatim" {
  local section
  recommend --languages javascript --react-overlay applies "$WORK"
  section="$(sed -n '/^### 3k\.7\. Shell overlay/,/^### /p' "$SKILL")"
  contains "$section" "$(jq -r .plan_line <<<"$output")"
  [ "$(jq -r .plan_line <<<"$output")" = "$PLAN_LINE" ]
}

@test "recommend-ui-shape: it writes no file under the repo path, on any outcome" {
  local before after o
  mkdir -p "$WORK/src"
  before="$(cd "$WORK" && find . | LC_ALL=C sort)"
  for o in applies absent skipped; do
    recommend --languages javascript --react-overlay "$o" "$WORK"
  done
  recommend --languages python --react-overlay applies "$WORK"
  after="$(cd "$WORK" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  marker src/remote/entry.tsx
  before="$(cd "$WORK" && find . | LC_ALL=C sort)"
  recommend --languages javascript --react-overlay applies "$WORK"
  [ "$status" -eq 3 ]
  after="$(cd "$WORK" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
}

# --- usage and precondition errors: exit 2, empty stdout ---------------------------

@test "recommend-ui-shape: a missing --languages or --react-overlay exits 2 with empty stdout" {
  recommend --react-overlay applies "$WORK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" '--languages is required'
  recommend --languages javascript "$WORK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" '--react-overlay is required'
}

@test "recommend-ui-shape: an unknown flag, an unknown overlay value or a flag without its value exits 2" {
  recommend --languages javascript --react-overlay applies --plan "$WORK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown flag '--plan'"
  recommend --languages javascript --react-overlay maybe "$WORK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown --react-overlay 'maybe'"
  recommend --languages javascript --react-overlay
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: recommend-ui-shape.zsh'
  recommend --react-overlay applies --languages
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: recommend-ui-shape.zsh'
}

@test "recommend-ui-shape: a malformed --languages value exits 2, never read as no-javascript" {
  local v
  for v in 'javascript,,go' ',javascript' 'javascript,' 'go, ,javascript' '["javascript","go"]' \
    '"javascript"' 'JavaScript' 'java script'; do
    recommend --languages "$v" --react-overlay applies "$WORK"
    [ "$status" -eq 2 ] || { echo "status $status for '$v': $output"; return 1; }
    [ -z "$output" ]
    contains "$stderr" "malformed --languages '$v'"
  done
}

@test "recommend-ui-shape: a missing or non-directory repo path, or an argument after it, exits 2" {
  recommend --languages javascript --react-overlay applies
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  recommend --languages javascript --react-overlay applies "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'is not a directory'
  : > "$BATS_TEST_TMPDIR/file"
  recommend --languages javascript --react-overlay applies "$BATS_TEST_TMPDIR/file"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  recommend --languages javascript --react-overlay applies "$WORK" --plan
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unexpected argument after the repo path: '--plan'"
}

@test "recommend-ui-shape: jq not on PATH exits 2 with empty stdout" {
  run --separate-stderr env PATH="$ISO" zsh "$REC" --languages javascript --react-overlay applies "$WORK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'jq is required'
}

# --- the bootstrap SKILL --------------------------------------------------------------

@test "recommend-ui-shape: SKILL.md's Shared questions table carries the Q7 row" {
  local row
  row="$(grep -F '| **Q7: UI shape** |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'Never as a separate prompt: shown in the Step 2 plan only when `recommend-ui-shape.zsh` exits 0 (§3k.7). Exit 3 shows nothing, and on a `shape-marker` repo the shape step'"'"'s own State D line stands.'
  contains "$row" '"This React app will be scaffolded as a **shell** (the default: a single-page app that can later host remotes). To scaffold a remote instead, reply `remote: page` for a route-owned page or `remote: widget` for a canvas widget."'
  contains "$row" 'Approving the plan unchanged keeps §3k.7 Shell overlay (and §3k.8 as #1939 offers it). `remote: page` or `remote: widget` drops the §3k.7 and §3k.8 lines and adds §3k.9 Remote overlay with that kind.'
  # Q7 follows Q6 in the table
  [ "$(grep -n -F '| **Q6: Security contact email** |' "$SKILL" | cut -d: -f1)" -lt \
    "$(grep -n -F '| **Q7: UI shape** |' "$SKILL" | cut -d: -f1)" ]
}

@test "recommend-ui-shape: §3k.7 runs the recommender and branches on its exit; §3k.9 reads the Q7 reply" {
  local shell remote reasons
  shell="$(sed -n '/^### 3k\.7\. Shell overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' ')"
  remote="$(sed -n '/^### 3k\.9\. Remote overlay/,/^### /p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$shell" '"<skill-base-dir>/scripts/recommend-ui-shape.zsh" \ --languages "<languages, comma-separated>" --react-overlay <applies|absent|skipped> "<repo>"'
  contains "$shell" 'The shape is Shared questions **Q7**, recommended — never asked as a separate prompt — by `recommend-ui-shape.zsh`, run while assembling the plan with detect-stack'"'"'s `languages` and §3k.5'"'"'s verdict (`applies`, `absent` or `skipped`):'
  contains "$shell" '**Exit 2** is a malformed call: fix it and re-run, never read it as "no UI here".'
  contains "$shell" '**Exit 0** puts its `plan_line` in the Step 2 plan, and approving the plan approves the shell:'
  reasons='**Exit 3** shows no line. Its `reason` is `no-javascript`, `no-browser-ui` or `react-overlay-skipped`'
  reasons+=' when there is no shape to choose; `shape-marker` when the shape is already on disk, so that shape'
  reasons+=' step'"'"'s own State D line stands; and `conflicting-markers` for §3k.9'"'"'s both-markers refusal.'
  contains "$shell" "$reasons"
  contains "$shell" '`conflicting-markers` for §3k.9'"'"'s both-markers refusal. **Exit 2** is a malformed call: fix it and re-run, never read it as "no UI here".'
  lacks "$shell" 'React shell overlay (default shape)'
  contains "$remote" 'the user replied `remote: page` or `remote: widget` to Q7'"'"'s Step 2 plan line (§3k.7)'
  lacks "$remote" 'until the shell-or-remote recommender (#1127) lands'
}

@test "recommend-ui-shape: ARCHITECTURE.md and MAINTAINING.md document the recommender and its exit codes" {
  local arch maint
  arch="$(tr -s '[:space:]' ' ' < "$ARCH")"
  maint="$(tr -s '[:space:]' ' ' < "$MAINT")"
  contains "$arch" '**The UI shape recommender (#1127).**'
  contains "$arch" '**Exit 3** prints those as `{applicable: false, reason, shape, remote_kind, marker}` and shows no plan line.'
  contains "$arch" '**Exit 2** is a usage or precondition error with empty stdout. It never writes a file.'
  contains "$arch" 'Otherwise **exit 0** recommends the shell with `basis: "default"` and the Step 2 `plan_line`, to which the user may reply `remote: page` or `remote: widget`.'
  contains "$arch" 'Browser UI is never asked about: it is §3k.5'"'"'s verdict, passed in.'
  contains "$arch" 'Its gates, in order: `javascript` absent → `no-javascript`; an `absent` overlay → `no-browser-ui`; a `skipped` one → `react-overlay-skipped`; both shape markers → `conflicting-markers`; one marker → `shape-marker`, naming the shape it marks.'
  lacks "$arch" 'until the shell-or-remote recommender (#1127) lands'
  contains "$maint" '**The UI shape recommender** (#1127, `scripts/recommend-ui-shape.zsh`, SKILL.md Q7)'
  contains "$maint" 'Its exit codes are a contract with §3k.7: 0 shows the shell plan line, 3 shows none, 2 is a malformed call.'
  contains "$maint" 'Keep its `plan_line` byte-identical to §3k.7'"'"'s plan line, which'
  contains "$maint" 'plan line, which `tests/recommend-ui-shape.bats` pins; the Q7 row carries the question'"'"'s own wording, pinned separately.'
  lacks "$maint" 'pins all three'
}
