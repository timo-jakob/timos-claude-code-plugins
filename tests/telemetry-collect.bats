#!/usr/bin/env bats
#
# Behavioral tests for collect-telemetry.zsh (#1972): the one-off salvage of
# telemetry/v1 records from in-repo sinks — a checkout's, its linked
# worktrees', and any second clone passed explicitly — into the user-level
# default directory, $HOME/.claude/telemetry/<repo-slug>.jsonl.
#
# The script COPIES: every test that reads a source also proves the source is
# byte-identical afterwards. HOME is the test's own, so the suite never writes
# into the maintainer's real ~/.claude/telemetry.
#
# Exit codes are asserted EXACTLY: 0 ok, 2 usage, 3 internal.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  C="$REPO_ROOT/development/scripts/telemetry/collect-telemetry.zsh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  export HOME="$BATS_TEST_TMPDIR/home"
  UDIR="$HOME/.claude/telemetry"

  # The main clone, one linked worktree, and a second clone of the same remote.
  MAIN="$BATS_TEST_TMPDIR/main"
  WT="$BATS_TEST_TMPDIR/wt"
  SECOND="$BATS_TEST_TMPDIR/second"
  git init -q "$MAIN"
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q "$WT"
  git init -q "$SECOND"
  mkdir -p "$MAIN/.claude/telemetry" "$WT/.claude/telemetry" "$SECOND/.claude/telemetry"
}

# One telemetry/v1 run record of repo $1 and issue $2, compact as emit writes it.
_rec() {
  printf '{"schema":"telemetry/v1","kind":"run","run_id":"review-loop-17900000%02d-ab%02d","parent_run_id":null,"ts":17900000%02d,"repo":"%s","repo_type":"claude-plugin","pipeline":"review-loop","issue":%d,"pr":null,"outcome":"success","wall_s":60,"tokens":null,"payload":{"rounds":1}}\n' \
    "$2" "$2" "$2" "$1" "$2"
}

# A checksum of every file under the three checkouts' sinks.
_sources_sum() {
  find "$MAIN/.claude" "$WT/.claude" "$SECOND/.claude" -type f -print0 | sort -z \
    | xargs -0 cksum
}

@test "copies v1 records from the root, its linked worktree and a second clone, sources untouched" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  _rec acme/widget 2 > "$WT/.claude/telemetry/telemetry.jsonl"
  _rec acme/widget 3 > "$SECOND/.claude/telemetry/telemetry.jsonl"
  local before; before="$(_sources_sum)"
  run --separate-stderr zsh "$C" "$MAIN" "$SECOND"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 3, duplicate 0, skipped 0" ]
  [ "$(ls "$UDIR")" = "acme-widget.jsonl" ]
  [ "$(jq -c -s '[.[].issue] | sort' "$UDIR/acme-widget.jsonl")" = "[1,2,3]" ]
  [ "$(_sources_sum)" = "$before" ]
}

@test "a linked worktree is discovered from any of its checkouts, never swept twice" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  _rec acme/widget 2 > "$WT/.claude/telemetry/telemetry.jsonl"
  # Naming the worktree AND the main checkout lists every sink twice over.
  run --separate-stderr zsh "$C" "$WT" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 2, duplicate 0, skipped 0" ]
  [ "$(wc -l < "$UDIR/acme-widget.jsonl")" -eq 2 ]
}

@test "each record goes to the file of its OWN repo, whatever file it came from" {
  { _rec acme/widget 1; _rec Other/Thing 2; } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$(ls "$UDIR" | sort | tr '\n' ' ')" = "acme-widget.jsonl other-thing.jsonl " ]
  [ "$(jq -r .repo "$UDIR/other-thing.jsonl")" = "Other/Thing" ]
}

@test "a record is copied VERBATIM, byte for byte" {
  # Key order and spacing emit never produces: a re-serialised copy would differ.
  local line='{"payload": {"rounds": 2},  "repo":"acme/widget","schema":"telemetry/v1","kind":"run","run_id":"r-1","ts":5,"pipeline":"p","outcome":"success","wall_s":1,"issue":null,"pr":null,"tokens":null,"parent_run_id":null,"repo_type":null}'
  printf '%s\n' "$line" > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$(cat "$UDIR/acme-widget.jsonl")" = "$line" ]
}

@test "v0 lines, malformed lines and other schemas are skipped and counted; blank lines are not" {
  {
    _rec acme/widget 1
    printf '%s\n' '{"status":"CONVERGED","findings_by_round":[],"rounds":1,"wall_s":7}'   # v0
    printf '%s\n' '{not json'                                                           # malformed
    printf '%s\n' '[1,2]'                                                               # not an object
    printf '%s\n' '{"schema":"telemetry/v2","repo":"acme/widget","run_id":"x"}'          # other schema
    printf '%s\n' '{"schema":"telemetry/v1","repo":null,"run_id":"y"}'                   # no usable repo
    printf '\n   \n'                                                                    # blank
  } > "$MAIN/.claude/telemetry/review-loop.jsonl"
  local before; before="$(_sources_sum)"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 1, duplicate 0, skipped 5" ]
  [ "$(wc -l < "$UDIR/acme-widget.jsonl")" -eq 1 ]
  [ "$(_sources_sum)" = "$before" ]
}

@test "a second run over the same roots appends nothing" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  _rec acme/widget 2 > "$WT/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  local after_first; after_first="$(cksum < "$UDIR/acme-widget.jsonl")"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 0, duplicate 2, skipped 0" ]
  [ "$(cksum < "$UDIR/acme-widget.jsonl")" = "$after_first" ]
}

@test "a record already in the destination — emitted there directly — is a duplicate" {
  mkdir -p "$UDIR"
  _rec acme/widget 1 > "$UDIR/acme-widget.jsonl"
  { _rec acme/widget 1; _rec acme/widget 2; } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 1, duplicate 1, skipped 0" ]
  [ "$(jq -c -s '[.[].issue]' "$UDIR/acme-widget.jsonl")" = "[1,2]" ]
}

@test "the same record in two sinks is copied once" {
  _rec acme/widget 7 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  _rec acme/widget 7 > "$SECOND/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN" "$SECOND"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 1, duplicate 1, skipped 0" ]
}

@test "payload.event is part of the identity: two enrichments of one run are both kept" {
  local base='"schema":"telemetry/v1","kind":"enrichment","run_id":"review-loop-1-aaaa","parent_run_id":null,"ts":9,"repo":"acme/widget","repo_type":null,"pipeline":"review-loop","issue":1,"pr":null,"outcome":"success","wall_s":null,"tokens":null'
  {
    printf '{%s,"payload":{"event":"suggestion_promotion"}}\n' "$base"
    printf '{%s,"payload":{"event":"pr_outcome"}}\n' "$base"
  } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 2, duplicate 0, skipped 0" ]
}

# Two records identical except for ONE key component each. The key is spelled
# twice in the script (the source rows and the destination's existing keys), so
# dropping a component from both collapses the pair and loses a record from an
# append-only salvage; the pair is the one shape that catches it.
_pair_base='"schema":"telemetry/v1","parent_run_id":null,"repo":"acme/widget","repo_type":null,"pipeline":"review-loop","issue":1,"pr":null,"outcome":"success","wall_s":null,"tokens":null,"payload":{"event":"pr_outcome"}'

@test "run_id is part of the identity: two runs stamped with one ts are both kept" {
  {
    printf '{%s,"kind":"enrichment","run_id":"review-loop-1-aaaa","ts":9}\n' "$_pair_base"
    printf '{%s,"kind":"enrichment","run_id":"review-loop-1-bbbb","ts":9}\n' "$_pair_base"
  } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 2, duplicate 0, skipped 0" ]
}

@test "kind is part of the identity: a run and its enrichment at one ts are both kept" {
  {
    printf '{%s,"kind":"run","run_id":"review-loop-1-aaaa","ts":9}\n' "$_pair_base"
    printf '{%s,"kind":"enrichment","run_id":"review-loop-1-aaaa","ts":9}\n' "$_pair_base"
  } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 2, duplicate 0, skipped 0" ]
}

@test "ts is part of the identity: two records of one run differing only by ts are both kept" {
  {
    printf '{%s,"kind":"enrichment","run_id":"review-loop-1-aaaa","ts":9}\n' "$_pair_base"
    printf '{%s,"kind":"enrichment","run_id":"review-loop-1-aaaa","ts":10}\n' "$_pair_base"
  } > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 2, duplicate 0, skipped 0" ]
}

@test "a root that is not a git checkout has its own sink swept" {
  local plain="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$plain/.claude/telemetry"
  _rec acme/widget 4 > "$plain/.claude/telemetry/x.jsonl"
  run --separate-stderr bash -c "GIT_CEILING_DIRECTORIES='$BATS_TEST_TMPDIR' zsh '$C' '$plain'"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 1, duplicate 0, skipped 0" ]
}

@test "nothing to copy is a clean exit 0" {
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "copied 0, duplicate 0, skipped 0" ]
}

@test "a missing ROOT is a usage error, checked before anything is written" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr zsh "$C" "$MAIN" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  contains "$stderr" "no such directory: $BATS_TEST_TMPDIR/nope"
  [ -z "$output" ]
  [ ! -e "$UDIR" ]
}

@test "a ROOT that is a file is a usage error, and nothing is written" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  : > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr zsh "$C" "$MAIN" "$BATS_TEST_TMPDIR/a-file"
  [ "$status" -eq 2 ]
  contains "$stderr" "not a directory: $BATS_TEST_TMPDIR/a-file"
  [ ! -e "$UDIR" ]
}

@test "no ROOT, or an unknown flag, is a usage error" {
  run --separate-stderr zsh "$C"
  [ "$status" -eq 2 ]
  contains "$stderr" "at least one ROOT is required"
  run --separate-stderr zsh "$C" --bogus "$MAIN"
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag: --bogus"
  [ ! -e "$UDIR" ]
}

@test "--help prints usage and exits 0" {
  run zsh "$C" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: collect-telemetry.zsh"
}

@test "an empty HOME is an internal error, never a write to /.claude" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  run --separate-stderr env HOME= zsh "$C" "$MAIN"
  [ "$status" -eq 3 ]
  contains "$stderr" "HOME is not set"
}

@test "an unappendable destination exits 3 with the OS error" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  mkdir -p "$UDIR/acme-widget.jsonl"            # a directory where the file goes
  run --separate-stderr zsh "$C" "$MAIN"
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot append to $UDIR/acme-widget.jsonl"
  matches "$stderr" ".*\(.+\).*"
  lacks "$stderr" "unknown error"
}

@test "the append holds emit's lock: a destination locked beyond 10 s exits 3, appending nothing" {
  _rec acme/widget 1 > "$MAIN/.claude/telemetry/telemetry.jsonl"
  mkdir -p "$UDIR"
  : > "$UDIR/acme-widget.jsonl"
  local ready="$BATS_TEST_TMPDIR/locked"
  zsh -c 'zmodload zsh/system; zsystem flock -f fd "$1" || exit 1; : > "$2"; sleep 14' \
    _ "$UDIR/acme-widget.jsonl" "$ready" &
  local holder=$!
  local i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$ready" ]
  run --separate-stderr zsh "$C" "$MAIN"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 3 ]
  contains "$stderr" "timed out after 10s waiting for the lock"
  [ ! -s "$UDIR/acme-widget.jsonl" ]
}

@test "the script is executable and runs by bare path" {
  [ -x "$C" ]
  run "$C" --help
  [ "$status" -eq 0 ]
}

@test "ARCHITECTURE.md states the collect contract this suite proves" {
  # The dedupe key, the output line and the exit split, pinned on a
  # whitespace-flattened haystack so a line wrap cannot defeat a needle.
  local arch
  arch="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" '`(run_id, kind, ts, payload.event)` is already in the destination'
  contains "$arch" 'it prints `copied N, duplicate N, skipped N`.'
  contains "$arch" 'Exit 2 is a missing or non-directory root, checked before anything is written; exit 3 an environment failure.'
}
