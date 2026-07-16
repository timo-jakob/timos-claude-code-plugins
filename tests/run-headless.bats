#!/usr/bin/env bats
#
# Behavioral tests for run-headless.zsh (#811): the test harness's "system
# under test" launcher. Foreground mode mirrors the child's exit code and
# always writes the transcript. The NEW --detach mode exists because a judge
# subagent cannot hold a >10-min foreground Bash call and a harness background
# task is killed the moment the subagent's turn ends (#811) — so the script
# must detach the child itself (nohup + disown), return immediately, and
# signal completion through an exit-marker file (`<out>.exit`) any later turn
# can wait on. Drives the script against a FAKE claude on PATH so every exit
# path is deterministic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development-claude-plugin/skills/test/scripts/run-headless.zsh"
  TARGET="$BATS_TEST_TMPDIR/target"
  PLUG="$BATS_TEST_TMPDIR/plug"
  OUT="$BATS_TEST_TMPDIR/transcript.jsonl"
  mkdir -p "$TARGET" "$PLUG"
  # Fake claude: emits one transcript line, honors FAKE_CLAUDE_SLEEP /
  # FAKE_CLAUDE_EXIT so tests control duration and exit code.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
sleep "${FAKE_CLAUDE_SLEEP:-0}"
echo '{"type":"result","subtype":"success","result":"fake child done"}'
exit "${FAKE_CLAUDE_EXIT:-0}"
EOF
  chmod +x "$BIN/claude"
  PATH="$BIN:$PATH"
}

headless() { run zsh "$S" --cwd "$TARGET" --out "$OUT" --plugins "$PLUG" --prompt "/noop" "$@"; }

# Poll for the exit marker — detached completion outlives the launch call.
wait_marker() {
  local i
  for i in $(seq 1 50); do
    [ -f "$OUT.exit" ] && return 0
    sleep 0.2
  done
  return 1
}

# --- foreground mode (characterization — pre-#811 behavior) -----------------

@test "foreground: green child -> exit 0, transcript written" {
  headless
  [ "$status" -eq 0 ]
  grep -q '"fake child done"' "$OUT"
}

@test "foreground: child exit code is mirrored" {
  FAKE_CLAUDE_EXIT=3 headless
  [ "$status" -eq 3 ]
}

@test "foreground: missing required argument -> exit 2 usage error" {
  run zsh "$S" --cwd "$TARGET" --out "$OUT" --plugins "$PLUG"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- "--prompt"
}

# --- detach mode (#811) ------------------------------------------------------

@test "detach: #811 returns immediately with pid + marker path while child still runs" {
  FAKE_CLAUDE_SLEEP=2 headless --detach
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "detached_pid="
  echo "$output" | grep -q "exit_marker=$OUT.exit"
  # the launch returned while the child sleeps: no marker yet
  [ ! -f "$OUT.exit" ]
  wait_marker
  [ "$(cat "$OUT.exit")" = "0" ]
  grep -q '"fake child done"' "$OUT"
}

@test "detach: #811 failing child -> launch still exit 0, marker carries the child's code" {
  FAKE_CLAUDE_EXIT=7 headless --detach
  [ "$status" -eq 0 ]
  wait_marker
  [ "$(cat "$OUT.exit")" = "7" ]
}

@test "detach: #811 stale marker from a previous run is removed at launch" {
  echo "0" > "$OUT.exit"
  FAKE_CLAUDE_SLEEP=2 headless --detach
  [ "$status" -eq 0 ]
  # stale marker must be gone the moment the launch returns — a waiter polling
  # now must not read the previous run's exit code
  [ ! -f "$OUT.exit" ]
  wait_marker
  [ "$(cat "$OUT.exit")" = "0" ]
}
