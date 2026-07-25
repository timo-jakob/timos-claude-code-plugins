#!/usr/bin/env bats
#
# Behavioral tests for emit-telemetry.zsh (#1003, epic #740 child (a)): the ONE
# shared `telemetry/v1` emitter every pipeline writes through.
#
# The envelope is CLOSED and the sink is append-only, so these tests pin both:
# the exact 14 keys and their null-vs-absent shape, and the rule that a rejected
# record never lands in the sink.
#
# Exit codes are asserted EXACTLY, never merely non-zero: the script documents
# 2 = usage (caller error) and 3 = internal (environment/tool), and callers are
# meant to tell those apart. A `-ne 0` assertion would let a regression that
# collapses the taxonomy ship green.
#
# NOTE: every test points --repo-dir / --telemetry-file at BATS_TEST_TMPDIR, so
# the suite never writes into this repo's own .claude/telemetry sink.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  V="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  ZSH_BIN="$(command -v zsh)"
  SINK="$BATS_TEST_TMPDIR/t.jsonl"

  # Pin git away from the host's config: a global init.templateDir, core.hooksPath
  # or url.insteadOf rewrite would otherwise change what `git init` and
  # `git remote get-url` produce and make the derivation tests machine-dependent.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  RD="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$RD"
  git init -q "$RD"
}

# `[[ ... ]]` is a shell KEYWORD and does not trip bats' failure detection when
# it is not the final statement of a test — a failing `[[ ]]` in the middle of a
# test body is silently ignored. These helpers are ordinary commands, so a
# failure fails the test wherever it appears. Never assert with a bare `[[ ]]`
# here.
contains()    { [ "${1#*"$2"}" != "$1" ]; }
lacks()       { [ "${1#*"$2"}" = "$1" ]; }
starts_with() { case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac; }

emit() { run zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" "$@"; }
# Plain `run` MERGES stderr into $output, so it cannot tell the record apart
# from a diagnostic. The emitter's consumer contract is "record on stdout,
# diagnostics on stderr" — `emit … | jq` depends on it — so the stream-sensitive
# tests use this variant instead.
emit_split() { run --separate-stderr zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" "$@"; }

# ---------------------------------------------------------------- happy path

@test "a run emits exactly one line carrying all 14 envelope keys" {
  emit --pipeline review-loop --outcome success --wall-s 312 --issue 123 --pr 456
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]       # a single line
  echo "$output" | jq -e '.' >/dev/null                    # valid JSON
  [ "$(echo "$output" | jq 'keys | length')" -eq 14 ]
  [ "$(echo "$output" | jq -r '.schema')" = "telemetry/v1" ]
  [ "$(echo "$output" | jq -r '.kind')" = "run" ]          # kind defaults to run
  [ "$(echo "$output" | jq -r '.pipeline')" = "review-loop" ]
  [ "$(echo "$output" | jq -r '.outcome')" = "success" ]
  [ "$(echo "$output" | jq '.wall_s')" -eq 312 ]
  [ "$(echo "$output" | jq '.issue')" -eq 123 ]
  [ "$(echo "$output" | jq '.pr')" -eq 456 ]
}

@test "the same line is appended to the resolved sink" {
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SINK")" -eq 1 ]
  [ "$(cat "$SINK")" = "$output" ]
}

@test "nullable fields are JSON null — never the string \"null\", never omitted" {
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  for f in parent_run_id repo_type issue pr tokens; do
    [ "$(echo "$output" | jq "has(\"$f\")")" = "true" ]     # present…
    [ "$(echo "$output" | jq -r ".$f | type")" = "null" ]   # …and a real null
  done
}

@test "every outcome enum value is accepted" {
  for o in success parked escalated failed; do
    emit --pipeline p --outcome "$o" --wall-s 1
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.outcome')" = "$o" ]
  done
}

@test "optional linkage and provenance fields round-trip" {
  emit --pipeline resolve-issue --outcome escalated --wall-s 7 \
    --repo-type claude-plugin --parent-run-id "parent-1-abcd" --issue 42 --pr 99
  [ "$status" -eq 0 ]
  [ "$(cat "$SINK")" = "$output" ]
  [ "$(echo "$output" | jq -r '.repo_type')" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r '.parent_run_id')" = "parent-1-abcd" ]
  [ "$(echo "$output" | jq '.issue')" -eq 42 ]
  [ "$(echo "$output" | jq '.pr')" -eq 99 ]
}

@test "--help prints usage, exits 0, and writes no record" {
  emit --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage"
  contains "$output" "emit-telemetry.zsh"
  [ ! -f "$SINK" ]
}

# ------------------------------------------------------------------- run_id

@test "generated run_id matches the contract format" {
  emit --pipeline review-loop --outcome success --wall-s 1 --ts 1720000000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.run_id' | grep -Eq '^review-loop-1720000000-[0-9a-f]{4}$'
}

@test "run_id randomness is not derived from ts — same pinned ts, distinct ids" {
  # 8 draws from a 16-bit space: a ts-derived suffix collapses to exactly 1
  # unique id, while a correct implementation is overwhelmingly likely to give 8.
  # Allowing one legitimate collision keeps this from being a 1-in-65536 flake.
  for _ in 1 2 3 4 5 6 7 8; do
    emit --pipeline x --outcome success --wall-s 1 --ts 1000
    [ "$status" -eq 0 ]
  done
  local uniq
  uniq="$(jq -r '.run_id' < "$SINK" | sort -u | wc -l | tr -d ' ')"
  [ "$uniq" -ge 7 ]
}

@test "--run-id is used verbatim" {
  emit --pipeline p --outcome success --wall-s 1 --run-id "handed-down-id"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.run_id')" = "handed-down-id" ]
}

# ---------------------------------------------------------------------- kind

@test "an enrichment record needs no --wall-s but MUST carry --run-id" {
  # run_id is the join key: a minted id would validate cleanly and still be
  # permanently orphaned from the run it enriches.
  emit --pipeline p --kind enrichment --outcome success --run-id "review-loop-1-aaaa"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.kind')" = "enrichment" ]
  [ "$(echo "$output" | jq -r '.run_id')" = "review-loop-1-aaaa" ]
  [ "$(echo "$output" | jq -r '.wall_s | type')" = "null" ]
}

@test "an enrichment without --run-id is rejected as usage" {
  emit --pipeline p --kind enrichment --outcome success
  [ "$status" -eq 2 ]
  contains "$output" "--run-id"
  contains "$output" "join key"
  [ ! -f "$SINK" ]
}

@test "--wall-s is REJECTED on an enrichment — it is a run measure" {
  emit --pipeline p --kind enrichment --outcome success --run-id "x-1-aaaa" --wall-s 5
  [ "$status" -eq 2 ]
  contains "$output" "run measure"
  [ ! -f "$SINK" ]
}

@test "an empty --payload is rejected" {
  run bash -c "printf '' | zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 --payload -"
  [ "$status" -eq 2 ]
  contains "$output" "--payload must be a single JSON object"
  [ ! -f "$SINK" ]
}

@test "an unknown --kind is rejected as usage" {
  emit --pipeline p --kind sideways --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "--kind must be run|enrichment"
  [ ! -f "$SINK" ]
}

# ------------------------------------------------------------------ ts/tokens

@test "--ts pins the timestamp; omitted it is now" {
  emit --pipeline p --outcome success --wall-s 1 --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.ts')" -eq 1720000000 ]
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.ts')" -gt 1700000000 ]
}

@test "tokens is null unless supplied — never estimated" {
  emit --pipeline p --outcome success --wall-s 60
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tokens | type')" = "null" ]
  emit --pipeline p --outcome success --wall-s 60 --tokens 4096
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.tokens')" -eq 4096 ]
}

# ------------------------------------------------------------- repo identity

@test "repo is derived owner/name from an ssh remote" {
  git -C "$RD" remote add origin git@github.com:timo-jakob/widget.git
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "timo-jakob/widget" ]
}

@test "repo is derived owner/name from an https remote" {
  git -C "$RD" remote add origin https://github.com/acme/widget.git
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "acme/widget" ]
}

@test "repo falls back to the basename when there is no remote" {
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]          # basename of $RD
}

@test "a path-style remote falls back to the basename, never a fabricated owner" {
  # /Users/x/mirrors/widget.git must NOT become "mirrors/widget": a fabricated
  # owner/name poisons the cross-repo grouping key this field exists to be.
  git -C "$RD" remote add origin "$BATS_TEST_TMPDIR/mirrors/widget.git"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
  git -C "$RD" remote set-url origin "file://$BATS_TEST_TMPDIR/mirrors/widget.git"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
}

@test "a non-git --repo-dir still yields an identity from the directory name" {
  local plain="$BATS_TEST_TMPDIR/not-a-git-repo"
  mkdir -p "$plain"
  run zsh "$S" --repo-dir "$plain" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "not-a-git-repo" ]
}

@test "--repo overrides derivation" {
  git -C "$RD" remote add origin git@github.com:derived/from-remote.git
  emit --pipeline p --outcome success --wall-s 1 --repo explicit/identity
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "explicit/identity" ]
}

# ------------------------------------------------------------------- payload

@test "--payload embeds arbitrary JSON unmodified; omitted it is {}" {
  local pf="$BATS_TEST_TMPDIR/payload.json"
  cat > "$pf" <<'EOF'
{"rounds":3,"findings_by_round":[{"round":1,"by_severity":{"Critical":2}}],"a key with spaces":true}
EOF
  emit --pipeline review-loop --outcome success --wall-s 9 --payload "$pf"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -cS '.payload')" = "$(jq -cS '.' "$pf")" ]

  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.payload')" = "{}" ]
}

@test "a pretty-printed multi-line payload still yields ONE sink line" {
  # The realistic caller input is `jq . > payload.json`. If the record ever
  # stopped being compacted, a multi-line blob would corrupt the append-only
  # JSONL sink for every downstream `jq -s` consumer.
  local pf="$BATS_TEST_TMPDIR/pretty.json"
  cat > "$pf" <<'EOF'
{
  "rounds": 2,
  "note": "has a \"quote\" and a\nnewline inside a string",
  "nested": {
    "deep": [1, 2, 3]
  }
}
EOF
  emit --pipeline review-loop --outcome success --wall-s 4 --payload "$pf"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  [ "$(wc -l < "$SINK")" -eq 1 ]
  [ "$(cat "$SINK")" = "$output" ]
  [ "$(echo "$output" | jq -cS '.payload')" = "$(jq -cS '.' "$pf")" ]
  run zsh "$V" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

@test "--payload - reads stdin" {
  run bash -c "echo '{\"k\":1}' | zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 --payload -"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.payload.k')" -eq 1 ]
}

@test "an invalid --payload is a usage error and writes nothing" {
  run bash -c "echo 'not json' | zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 --payload -"
  [ "$status" -eq 2 ]
  contains "$output" "--payload must be a single JSON object"
  [ ! -f "$SINK" ]
}

@test "a non-object --payload is rejected — the contract's payload is an object" {
  run bash -c "echo '[1,2]' | zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 --payload -"
  [ "$status" -eq 2 ]
  contains "$output" "--payload must be a single JSON object"
  [ ! -f "$SINK" ]
}

@test "an absent --payload FILE is a usage error and writes nothing" {
  emit --pipeline p --outcome success --wall-s 1 --payload "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
  contains "$output" "--payload file does not exist"
  [ ! -f "$SINK" ]
}

@test "--payload accepts process substitution, matching the validator's policy" {
  run zsh -c "zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 --payload <(echo '{\"k\":7}')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.payload.k')" -eq 7 ]
}

@test "a remote URL with a trailing slash after .git still derives owner/name" {
  git -C "$RD" remote add origin "https://github.com/acme/widget.git/"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "acme/widget" ]
}

@test "an unreadable --payload FILE reports unreadability, not shape" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local pf="$BATS_TEST_TMPDIR/locked.json"
  echo '{"k":1}' > "$pf"
  chmod 000 "$pf"
  emit --pipeline p --outcome success --wall-s 1 --payload "$pf"
  [ "$status" -eq 2 ]
  contains "$output" "--payload file not readable"
  [ ! -f "$SINK" ]
}

# ---------------------------------------------------------------------- sink

@test "the sink's parent directory is created when absent" {
  local deep="$BATS_TEST_TMPDIR/a/b/c/telemetry.jsonl"
  run zsh "$S" --repo-dir "$RD" --telemetry-file "$deep" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$deep" ]
}

@test "records append, never truncate" {
  emit --pipeline p --outcome success --wall-s 1
  emit --pipeline p --outcome failed --wall-s 2
  emit --pipeline q --outcome parked --wall-s 3
  [ "$(wc -l < "$SINK")" -eq 3 ]
  [ "$(jq -r -s '.[1].outcome' "$SINK")" = "failed" ]
  [ "$(jq -r -s '.[2].pipeline' "$SINK")" = "q" ]
}

@test "a rejected record leaves an EXISTING sink byte-identical" {
  # The `! -f $SINK` assertions elsewhere only prove nothing was created. The
  # operational case is a sink that already holds records.
  emit --pipeline p --outcome success --wall-s 1
  emit --pipeline p --outcome success --wall-s 2
  local before; before="$(cksum < "$SINK")"

  emit --pipeline p --outcome merged --wall-s 1                  # bad enum
  [ "$status" -eq 2 ]
  emit --pipeline p --outcome success --wall-s abc               # bad numeric
  [ "$status" -eq 2 ]
  emit --pipeline p --outcome success --wall-s 1 --payload "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  emit --pipeline p --outcome success --wall-s 1 --nope 1        # unknown flag
  [ "$status" -eq 2 ]

  [ "$(cksum < "$SINK")" = "$before" ]
  [ "$(wc -l < "$SINK")" -eq 2 ]
}

@test "an unbuildable sink path is an internal error, not a usage error" {
  # A regular file where a directory must go: mkdir -p fails. Chosen over a
  # chmod seam because the suite can run as root, where chmod proves nothing.
  local blocker="$BATS_TEST_TMPDIR/iam-a-file"
  : > "$blocker"
  run zsh "$S" --repo-dir "$RD" --telemetry-file "$blocker/telemetry.jsonl" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$output" "cannot create sink directory"
}

@test "an unappendable sink is an internal error" {
  # The sink path IS a directory, so the append fails while mkdir -p succeeds.
  run zsh "$S" --repo-dir "$RD" --telemetry-file "$BATS_TEST_TMPDIR" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$output" "cannot append to sink"
}

@test "the local default sink is <repo-dir>/.claude/telemetry/telemetry.jsonl" {
  run zsh "$S" --repo-dir "$RD" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$RD/.claude/telemetry/telemetry.jsonl" ]
  [ "$(wc -l < "$RD/.claude/telemetry/telemetry.jsonl")" -eq 1 ]
}

@test "--telemetry-file wins over the local default" {
  run zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$SINK" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "paths containing spaces are handled everywhere" {
  local sd="$BATS_TEST_TMPDIR/dir with space"
  local rd="$sd/my repo"
  local pf="$sd/my payload.json"
  mkdir -p "$rd"
  git init -q "$rd"
  echo '{"k":1}' > "$pf"
  run zsh "$S" --repo-dir "$rd" --telemetry-file "$sd/sink dir/t.jsonl" \
    --pipeline p --outcome success --wall-s 1 --payload "$pf"
  [ "$status" -eq 0 ]
  [ -f "$sd/sink dir/t.jsonl" ]
  [ "$(wc -l < "$sd/sink dir/t.jsonl")" -eq 1 ]
  [ "$(echo "$output" | jq -r '.repo')" = "my repo" ]
  [ "$(echo "$output" | jq '.payload.k')" -eq 1 ]
}

@test "a --repo-dir with a trailing slash still resolves the default sink" {
  run zsh "$S" --repo-dir "$RD/" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

# ------------------------------------------------------------ usage rejection

@test "--wall-s is REQUIRED on a run: omitting it is a usage error, writes nothing" {
  emit --pipeline p --outcome success
  [ "$status" -eq 2 ]
  contains "$output" "--wall-s is required for --kind run"
  [ ! -f "$SINK" ]
}

@test "an outcome outside the 4-value enum is a usage error" {
  emit --pipeline p --outcome merged --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "--outcome must be success|parked|escalated|failed"
  [ ! -f "$SINK" ]
}

@test "--outcome is required" {
  emit --pipeline p --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "--outcome is required"
  [ ! -f "$SINK" ]
}

@test "--pipeline is required" {
  emit --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "--pipeline is required"
  [ ! -f "$SINK" ]
}

@test "--pipeline must match the run_id-safe charset" {
  # pipeline seeds the contractual run_id format, so a space or slash in it
  # would produce an id that cannot be parsed back.
  for bad in "review loop" "a/b" "pipe|line"; do
    emit --pipeline "$bad" --outcome success --wall-s 1
    [ "$status" -eq 2 ]
    contains "$output" "must match [A-Za-z0-9._-]+"
  done
  # the empty string exits via a DIFFERENT branch — the uniform non-empty guard
  emit --pipeline "" --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  [ ! -f "$SINK" ]
}

@test "--repo-dir must be a directory" {
  emit --pipeline p --outcome success --wall-s 1 --repo-dir "$BATS_TEST_TMPDIR/absent-dir"
  [ "$status" -eq 2 ]
  contains "$output" "--repo-dir is not a directory"
}

@test "an unexpected positional argument is rejected" {
  emit --pipeline p --outcome success --wall-s 1 stray-arg
  [ "$status" -eq 2 ]
  contains "$output" "unexpected argument"
  [ ! -f "$SINK" ]
}

@test "an unknown flag is rejected" {
  emit --pipeline p --outcome success --wall-s 1 --nope 1
  [ "$status" -eq 2 ]
  contains "$output" "unknown flag"
  [ ! -f "$SINK" ]
}

@test "non-numeric and negative numeric flags are rejected, not silently coerced" {
  for pair in "--wall-s:soon" "--issue:abc" "--pr:#12" "--ts:yesterday" "--tokens:lots" \
              "--wall-s:-1" "--issue:-3" "--tokens:1.5" "--ts:-5"; do
    emit --pipeline p --outcome success --wall-s 1 "${pair%%:*}" "${pair#*:}"
    [ "$status" -eq 2 ]
    contains "$output" "must be a non-negative integer"
  done
  [ ! -f "$SINK" ]
}

@test "zero is a legitimate numeric value, emitted as 0 rather than null" {
  emit --pipeline p --outcome success --wall-s 0 --issue 0 --tokens 0
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.wall_s')" -eq 0 ]
  [ "$(echo "$output" | jq '.issue')" -eq 0 ]
  [ "$(echo "$output" | jq '.tokens')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.wall_s | type')" = "number" ]
}

@test "leading zeros are normalized rather than exploding at JSON build time" {
  # `<->` accepts 007 but JSON forbids it — without normalization this reached
  # --argjson and surfaced as a generic internal error.
  emit --pipeline p --outcome success --wall-s 007 --issue 012 --tokens 0004096
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.wall_s')" -eq 7 ]
  [ "$(echo "$output" | jq '.issue')" -eq 12 ]
  [ "$(echo "$output" | jq '.tokens')" -eq 4096 ]
}

@test "a dangling final value flag is a usage error, not a silent 'omitted'" {
  # Coercing a missing value to empty is worse than it looks: a dangling
  # --telemetry-file would append to the DEFAULT sink and exit 0.
  emit --pipeline p --outcome success --wall-s
  [ "$status" -eq 2 ]
  contains "$output" "requires a value"
  [ ! -f "$SINK" ]
}

@test "a dangling --telemetry-file does NOT fall through to the default sink" {
  run zsh "$S" --repo-dir "$RD" --pipeline p --outcome success --wall-s 1 --telemetry-file
  [ "$status" -eq 2 ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "a flag-shaped value is rejected rather than swallowed" {
  emit --pipeline p --outcome success --wall-s 1 --repo --tokens
  [ "$status" -eq 2 ]
  contains "$output" "requires a value"
  [ ! -f "$SINK" ]
}

@test "the arg loop terminates on a dangling flag instead of spinning" {
  # A bare `shift 2` when $# < 2 fails WITHOUT consuming, spinning forever.
  # Guarded by a hand-rolled watchdog rather than `timeout`, which is absent on
  # macOS — with `timeout` this test exits 127 and passes vacuously.
  # The watchdog's fds are detached so an orphaned `sleep` cannot hold bats'
  # output pipe open after the script exits.
  run bash -c '
    zsh "$1" --repo-dir "$2" --telemetry-file "$3" \
      --pipeline p --outcome success --wall-s &
    pid=$!
    ( sleep 5; kill -9 $pid 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    wd=$!
    wait $pid; rc=$?
    kill -9 $wd 2>/dev/null; pkill -P $wd 2>/dev/null
    exit $rc
  ' _ "$S" "$RD" "$SINK"
  [ "$status" -ne 137 ]                                     # not killed => no hang
  [ "$status" -eq 2 ]
  [ ! -f "$SINK" ]
}

# --------------------------------------------------------------- environment

@test "a missing jq is an internal error with a named diagnostic" {
  run env PATH="$BATS_TEST_TMPDIR/empty-path" "$ZSH_BIN" "$S" \
    --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$output" "jq not found on PATH"
  [ ! -f "$SINK" ]
}

# ---------------------------------------------------------------- round-trip

@test "every emitter output validates against the contract" {
  emit --pipeline review-loop --outcome success --wall-s 312 --issue 1 --pr 2 \
    --repo-type python --parent-run-id par-1-0000 --tokens 10
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' '$output' | zsh '$V' - --require-records"
  [ "$status" -eq 0 ]

  # …and so does a whole multi-record sink, runs and enrichments together
  emit --pipeline refine-issue --outcome parked --wall-s 4
  emit --pipeline p --kind enrichment --outcome success --run-id "refine-issue-1-bbbb"
  run zsh "$V" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------- streams and ordering

@test "the record goes to STDOUT and diagnostics go to STDERR" {
  emit_split --pipeline review-loop --outcome success --wall-s 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null   # record on stdout
  [ -z "$stderr" ]                                                # nothing on stderr

  emit_split --pipeline p --outcome merged --wall-s 1             # a usage error
  [ "$status" -eq 2 ]
  [ -z "$output" ]                                                # no partial record on stdout
  contains "$stderr" "--outcome must be"                        # diagnostic on stderr
}

@test "a closed stdout fails BEFORE the append, leaving an existing sink intact" {
  # The ordering promise: the record is written to stdout before the sink append,
  # so a caller retrying on a non-zero exit can never duplicate a record.
  emit --pipeline p --outcome success --wall-s 1
  emit --pipeline p --outcome success --wall-s 2
  local before; before="$(cksum < "$SINK")"

  run bash -c "zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 3 >&-"
  [ "$status" -eq 3 ]
  contains "$output" "stdout is closed; refusing to emit"
  [ "$(cksum < "$SINK")" = "$before" ]
  [ "$(wc -l < "$SINK")" -eq 2 ]
}

@test "a pipe that closes early exits 3 and leaves no record in the sink" {
  # Asserting only "no record" would pass on ANY failure — including the 141 the
  # `trap '"'"''"'"' PIPE` exists to prevent — so propagate the emitter's own status.
  run bash -c "set -o pipefail; zsh '$S' --repo-dir '$RD' --telemetry-file '$SINK' \
    --pipeline p --outcome success --wall-s 1 | head -0; exit \${PIPESTATUS[0]}"
  [ "$status" -eq 3 ]                       # not 141 => the trap is still installed
  contains "$output" "failed to write the record to stdout"
  [ ! -s "$SINK" ]
}

@test "concurrent emitters append whole lines, never a torn one" {
  # One shared sink per repo is the design, and nested runs are explicitly
  # supported, so simultaneous appends are designed-for rather than exotic.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
      --pipeline p --outcome success --wall-s 1 --issue "$i" >/dev/null &
  done
  wait
  [ "$(wc -l < "$SINK")" -eq 10 ]
  run zsh "$V" "$SINK" --require-records
  [ "$status" -eq 0 ]
  [ "$(jq -c -s '[.[].issue] | sort' "$SINK")" = "[1,2,3,4,5,6,7,8,9,10]" ]
}

# ----------------------------------------------------------- invocation shape

@test "the script is executable and runs by bare path" {
  # Skills invoke it as <skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh,
  # which a lost exec bit would break while `zsh <path>` kept the suite green.
  [ -x "$S" ]
  [ -x "$V" ]
  run "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage"
}

@test "--repo-dir defaults to the current directory" {
  # The bare form a skill uses when it runs the emitter from the repo it is
  # working in. Every other test passes --repo-dir explicitly.
  local repo_sink_before
  repo_sink_before="$( [ -f "$REPO_ROOT/.claude/telemetry/telemetry.jsonl" ] \
      && cksum < "$REPO_ROOT/.claude/telemetry/telemetry.jsonl" || echo none )"
  run bash -c "cd '$RD' && zsh '$S' --pipeline p --outcome success --wall-s 1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
  [ -f "$RD/.claude/telemetry/telemetry.jsonl" ]
  [ "$(wc -l < "$RD/.claude/telemetry/telemetry.jsonl")" -eq 1 ]
  # the real leak guard: this repo's own sink must be untouched by the suite
  [ "$repo_sink_before" = "$( [ -f "$REPO_ROOT/.claude/telemetry/telemetry.jsonl" ] \
      && cksum < "$REPO_ROOT/.claude/telemetry/telemetry.jsonl" || echo none )" ]
}

@test "the full [A-Za-z0-9._-]+ charset is ACCEPTED for --pipeline" {
  # The rejecting half is tested above; without this, a tightening regression
  # (e.g. ^[a-z][a-z-]*$) would break every future pipeline name and stay green.
  for name in acceptance.rest my_pipeline Bootstrap a1.b_c-D9; do
    emit --pipeline "$name" --outcome success --wall-s 1 --ts 1720000000
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.pipeline')" = "$name" ]
    echo "$output" | jq -r '.run_id' | grep -Eq "^${name}-1720000000-[0-9a-f]{4}$"
  done
}

# ------------------------------------------------------------ more rejections

@test "a concatenated multi-object --payload is rejected" {
  # The realistic caller slip is `jq -c '.[]' > payload.json`.
  run bash -c "printf '{\"a\":1}\n{\"b\":2}\n' | zsh '$S' --repo-dir '$RD' \
    --telemetry-file '$SINK' --pipeline p --outcome success --wall-s 1 --payload -"
  [ "$status" -eq 2 ]
  contains "$output" "--payload must be a single JSON object"
  [ ! -f "$SINK" ]
}

@test "a directory as --payload reports what it is, not a JSON complaint" {
  emit --pipeline p --outcome success --wall-s 1 --payload "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$output" "--payload is a directory"
  [ ! -f "$SINK" ]
}

@test "19 digits is the FIRST rejected width — pins the cap at 18, not 19" {
  # Without this, loosening the guard to `-le 19` (the likeliest regression)
  # keeps both the 18-digit accept and the 20-digit reject green, while a
  # 19-digit value above 2^63-1 reaches the arithmetic the cap exists to avoid.
  emit --pipeline p --outcome success --wall-s 1 --ts 9999999999999999999
  [ "$status" -eq 2 ]
  contains "$output" "out of range"
  contains "$output" "max 18 digits"
  [ ! -f "$SINK" ]
}

@test "the four enum/required value flags also reject an empty value" {
  # Completes the "applied to EVERY value flag" rule. These four would still
  # exit 2 via a downstream guard, so only the diagnostic proves _need_nonempty.
  for flag in --kind --outcome --repo-dir; do
    emit --pipeline p --outcome success --wall-s 1 "$flag" ""
    [ "$status" -eq 2 ]
    contains "$output" "requires a non-empty value"
  done
  run zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" --pipeline p --outcome success --wall-s ""
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  [ ! -f "$SINK" ]
}

@test "an out-of-range numeric is a usage error, not an arithmetic crash" {
  # 19+ digits makes zsh's 64-bit `10#` normalization abort outright, which
  # previously surfaced as a generic internal failure.
  emit --pipeline p --outcome success --wall-s 1 --ts 18446744073709551615
  [ "$status" -eq 2 ]
  contains "$output" "out of range"
  [ ! -f "$SINK" ]
}

@test "a jq that exists but fails is an internal error, not a usage error" {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/jq"
  chmod +x "$stub/jq"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$output" "failed to build the record"
  [ ! -f "$SINK" ]
}

# -------------------------------------------------------- derivation edges

@test "a nested-namespace remote is truncated to the last two segments" {
  # The contract's repo is owner/name, so group/subgroup/widget becomes
  # subgroup/widget rather than widening the field's shape. Pinned so the
  # truncation is a stated contract rather than an accident.
  git -C "$RD" remote add origin https://gitlab.example.com/group/subgroup/widget.git
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "subgroup/widget" ]
}

@test "an scp-like remote with no slash falls back to the basename" {
  git -C "$RD" remote add origin git@host:project.git
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
}

@test "an empty-host URL falls back to the basename rather than fabricating one" {
  git -C "$RD" remote add origin "https:///owner/name.git"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
}

# ------------------------------------------------------ explicit empty values

@test "an explicitly empty --telemetry-file is rejected, never the default sink" {
  # The realistic shape is `--telemetry-file "$VAR"` with VAR unset in a caller
  # glue script. Treated as "omitted" it would land the record in the DEFAULT
  # sink and exit 0 — the wrong file, silently.
  emit_no_sink() { run zsh "$S" --repo-dir "$RD" "$@"; }
  emit_no_sink --telemetry-file "" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "an explicitly empty --payload is rejected, never a silent {} payload" {
  emit --pipeline p --outcome success --wall-s 1 --payload ""
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  [ ! -f "$SINK" ]
}

@test "a local path containing a colon is not mistaken for an scp-like remote" {
  # git treats a colon as scp syntax only when it precedes the first slash, so
  # /…/backup-10:30/widget.git is a local path and must fall back to the basename.
  git -C "$RD" remote add origin "$BATS_TEST_TMPDIR/backup-10:30/widget.git"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "repo" ]
}

@test "the 18-digit numeric boundary is ACCEPTED" {
  # Pins the accept side of the width cap: an off-by-one to 19 would reintroduce
  # the zsh arithmetic abort the cap exists to prevent.
  # Assert the cap, not jq's large-integer round-tripping (which differs
  # between jq 1.6 and 1.7 and would make this a tool-version test).
  emit --pipeline p --outcome success --wall-s 1 --ts 999999999999999999
  [ "$status" -eq 0 ]
  lacks "$output" "out of range"
  [ "$(echo "$output" | jq -r '.ts | type')" = "number" ]
}

@test "-h is accepted as well as --help" {
  emit -h
  [ "$status" -eq 0 ]
  starts_with "$output" "usage"
  [ ! -f "$SINK" ]
}

@test "every value flag rejects an explicitly empty value" {
  # `--flag "$VAR"` with VAR unset is the realistic caller slip; each of these
  # would otherwise degrade to "omitted" and exit 0 — stamping NOW for --ts,
  # minting an unjoinable id for --run-id, severing the link for --parent-run-id.
  for flag in --ts --run-id --parent-run-id --repo --repo-type --issue --pr --tokens; do
    emit --pipeline p --outcome success --wall-s 1 "$flag" ""
    [ "$status" -eq 2 ]
    contains "$output" "requires a non-empty value"
  done
  [ ! -f "$SINK" ]
}

@test "a bracketed IPv6 scp-like remote derives owner/name, not a fabricated one" {
  git -C "$RD" remote add origin "git@[::1]:owner/name.git"
  emit --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "owner/name" ]
}

@test "the run_id keeps its contract shape when /dev/urandom is unavailable" {
  # Exercises the RANDOM fallback in _rand4, otherwise only the urandom arm runs.
  local stub="$BATS_TEST_TMPDIR/odstub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/od"
  chmod +x "$stub/od"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1 --ts 1720000000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.run_id' | grep -Eq '^p-1720000000-[0-9a-f]{4}$'
}
