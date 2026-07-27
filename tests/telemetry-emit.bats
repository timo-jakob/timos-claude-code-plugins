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
# NOTE: every test points --repo-dir / --telemetry-file / --telemetry-dir at
# BATS_TEST_TMPDIR, so the suite never writes into this repo's own
# .claude/telemetry sink. All three flags decide a sink — keep any new one
# tmpdir-scoped too.

bats_require_minimum_version 1.5.0

load assertions

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

  # The cross-repo directory (#1006). Deliberately NOT created: several tests
  # assert the emitter creates it, and one asserts a --telemetry-dir SHADOWED by
  # --telemetry-file creates nothing — so its absence at setup time is
  # load-bearing. (The usage-error case uses its own path, not this one.)
  DIR="$BATS_TEST_TMPDIR/cross-repo"
}


emit() { run zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" "$@"; }
# Plain `run` MERGES stderr into $output, so it cannot tell the record apart
# from a diagnostic. The emitter's consumer contract is "record on stdout,
# diagnostics on stderr" — `emit … | jq` depends on it — so the stream-sensitive
# tests use this variant instead.
emit_split() { run --separate-stderr zsh "$S" --repo-dir "$RD" --telemetry-file "$SINK" "$@"; }
# The same pair for cross-repo mode, so the sink flag is fixed in ONE place
# rather than copy-pasted per test — the header's "keep every sink flag
# tmpdir-scoped" rule is then enforced here instead of by 15 careful copies.
# Tests whose SUBJECT is the invocation shape (a relative or dash-leading DIR, a
# non-default directory) keep an explicit `run` on purpose.
emit_dir() { run zsh "$S" --repo-dir "$RD" --telemetry-dir "$DIR" "$@"; }
emit_dir_split() { run --separate-stderr zsh "$S" --repo-dir "$RD" --telemetry-dir "$DIR" "$@"; }

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
  # No pipeline forwards --telemetry-dir, so --help is a caller's only discovery
  # path for it: a usage block that drifts from the implemented precedence must
  # go red rather than quietly hiding the flag.
  contains "$output" "--telemetry-dir"
  contains "$output" "DIR/<repo-slug>.jsonl"
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
  # --separate-stderr: these two failures happen AFTER the record is on stdout,
  # so merged output could not tell a correctly-routed diagnostic from one that
  # regressed onto stdout and corrupted the JSON line every `emit … | jq` reads.
  local blocker="$BATS_TEST_TMPDIR/iam-a-file"
  : > "$blocker"
  run --separate-stderr zsh "$S" --repo-dir "$RD" \
    --telemetry-file "$blocker/telemetry.jsonl" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot create sink directory"
  # the OS's own reason, not the "(unknown error)" fallback — a regression back
  # to `2>/dev/null` would still satisfy a bare parenthesis match
  matches "$stderr" ".*\(.+\).*"
  lacks "$stderr" "unknown error"
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null
}

@test "an unappendable sink is an internal error" {
  # The sink path IS a directory, so the append fails while mkdir -p succeeds.
  # Deliberately NOT given the up-front check --telemetry-dir has: this is
  # --telemetry-file's SHIPPED contract, and tightening it would be an
  # incompatible change riding along with an additive feature (#1006).
  # --telemetry-dir may be strict precisely because it is a NEW flag whose
  # exit-2 contract was set from the start, with nothing to break.
  run --separate-stderr zsh "$S" --repo-dir "$RD" --telemetry-file "$BATS_TEST_TMPDIR" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot append to sink"
  matches "$stderr" ".*\(.+\).*"         # a reason is PRESENT…
  lacks "$stderr" "unknown error"        # …and it is the OS's, not the fallback
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null
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

# -------------------------------------------- cross-repo sink (--telemetry-dir)
#
# Cross-repo mode (#1006) exists so many repos can emit into ONE directory that a
# reporting stack globs as `*.jsonl`. Two properties carry that: a slug that is
# STABLE per repo (so a repo's stream never shatters across files) and a filename
# the glob can actually see. The slug is deliberately NOT injective — two repos
# can share a file — so the collision case is pinned too: they interleave in one
# append-only file and the verbatim `repo` field is what still tells them apart.
# The identities the basename fallback produces are not GitHub slugs, so they get
# their own coverage.
#
# These tests say "cross-repo", never "shared": within this file "the shared
# sink" already means the LOCAL one-file-many-pipelines default, and letting one
# term cover both axes is exactly what ARCHITECTURE.md renamed the mode to stop.

@test "--telemetry-dir appends to DIR/<repo-slug>.jsonl (owner/name case)" {
  git -C "$RD" remote add origin "https://github.com/timo-jakob/foo.git"
  emit_dir --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$DIR/timo-jakob-foo.jsonl" ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 1 ]
  [ "$(cat "$DIR/timo-jakob-foo.jsonl")" = "$output" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "the cross-repo filename is stable across runs, and records append to it" {
  # The reporting repo reads one file per repo, so a slug that varied per run
  # would shatter a single repo's stream across files that no glob reassembles.
  # The identity is DERIVED on every run (no --repo), because that is the half
  # that can actually vary at runtime — a derivation that started picking up,
  # say, a worktree path would go red here; pinning a constant --repo would only
  # re-prove that _repo_slug is a pure function.
  local i
  git -C "$RD" remote add origin "https://github.com/timo-jakob/foo.git"
  for i in 1 2 3; do
    emit_dir --pipeline p --outcome success --wall-s "$i"
    [ "$status" -eq 0 ]
  done
  [ "$(ls -A "$DIR")" = "timo-jakob-foo.jsonl" ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 3 ]
  [ "$(jq -r -s '.[0].wall_s' "$DIR/timo-jakob-foo.jsonl")" -eq 1 ]
  [ "$(jq -r -s '.[2].wall_s' "$DIR/timo-jakob-foo.jsonl")" -eq 3 ]
  # close the loop the way every other sink test does: the accumulated file is
  # itself contract-conformant, not merely the right number of lines.
  run zsh "$V" "$DIR/timo-jakob-foo.jsonl" --require-records
  [ "$status" -eq 0 ]
}

@test "the slug is case-folded, so one repo cannot split across two files" {
  # GitHub identities are case-insensitive but case-preserving, so the SAME repo
  # can arrive as Foo/Bar from a remote and foo/bar from a caller's --repo. On a
  # case-sensitive filesystem an unfolded slug would silently shatter that repo's
  # stream across two files — the exact failure the stable-slug promise forbids.
  # The two spellings deliberately enter by DIFFERENT routes: passing --repo
  # twice would only re-prove _repo_slug is a pure function, and would leave the
  # derivation path free to fold case itself — which would corrupt the `repo`
  # field every case-sensitive consumer groups on, invisibly.
  git -C "$RD" remote add origin "https://github.com/Timo-Jakob/Foo.git"
  emit_dir --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  # derived: case PRESERVED in the field, folded only in the filename
  [ "$(echo "$output" | jq -r '.repo')" = "Timo-Jakob/Foo" ]
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "timo-jakob/foo" ]   # identity verbatim
  [ "$(ls -A "$DIR")" = "timo-jakob-foo.jsonl" ]
  [ "$(ls -A "$DIR" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 2 ]
}

@test "--telemetry-file wins over --telemetry-dir" {
  run zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-file "$SINK" --telemetry-dir "$DIR" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SINK")" -eq 1 ]
  [ ! -e "$DIR" ]                                  # the ignored flag creates nothing
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "--telemetry-dir is still VALIDATED when --telemetry-file shadows it" {
  # "Ignored when --telemetry-file is also given" is true of sink SELECTION only:
  # the operand check runs before precedence, so a nonsense value is still a
  # usage error. Pinning it stops the check from being quietly relaxed (or the
  # doc from quietly re-overclaiming) — and a caller forwarding both flags from
  # config needs to know a stale dir value fails loudly rather than silently.
  local blocker="$BATS_TEST_TMPDIR/iam-a-file"
  : > "$blocker"
  run --separate-stderr zsh "$S" --repo-dir "$RD" \
    --telemetry-file "$SINK" --telemetry-dir "$blocker" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$stderr" "--telemetry-dir is not a directory"
  [ -z "$output" ]
  [ ! -f "$SINK" ]
}

@test "--telemetry-dir wins over the local default" {
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$DIR/timo-jakob-foo.jsonl" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "the cross-repo directory is created when absent, including missing parents" {
  local deep="$BATS_TEST_TMPDIR/a/b/c/cross-repo"
  run zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" --telemetry-dir "$deep" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$deep/timo-jakob-foo.jsonl" ]
}

@test "a dash-leading --telemetry-dir is an operand, not options, to mkdir" {
  # `_need_val` rejects only `--*`-shaped values, so a single-dash DIR is a
  # reachable invocation — and the `--` in `mkdir -p -- "$sink_dir"` is the only
  # thing keeping it from being parsed as options and reported as an
  # UNCREATABLE sink (exit 3). Dropping that `--` reads as harmless cleanup,
  # so pin it. Explicit `run`: the invocation shape IS this test's subject.
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' --repo 'timo-jakob/foo' \
    --repo-dir '$RD' --telemetry-dir -drop --pipeline p --outcome success --wall-s 1"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/-drop/timo-jakob-foo.jsonl" ]
}

@test "a dash-leading --repo-dir still resolves its default sink" {
  # The same hazard on the other flag that feeds `mkdir`: the default sink path
  # is built from --repo-dir, so `-work/.claude/telemetry` is the operand.
  local rd="$BATS_TEST_TMPDIR/-work"
  mkdir -p "$rd"
  git init -q "$rd"
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' --repo-dir -work \
    --pipeline p --outcome success --wall-s 1"
  [ "$status" -eq 0 ]
  [ -f "$rd/.claude/telemetry/telemetry.jsonl" ]
}

@test "a relative --telemetry-dir resolves against the CWD, not --repo-dir" {
  # The two flags are deliberately different concepts (a path to derive `repo`
  # from vs. a path to write to), so a relative DIR must not silently follow
  # --repo-dir — a plausible "fix" that would relocate every record.
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' --repo 'timo-jakob/foo' \
    --repo-dir '$RD' --telemetry-dir drop --pipeline p --outcome success --wall-s 1"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/drop/timo-jakob-foo.jsonl" ]
  [ ! -e "$RD/drop" ]
}

@test "a --telemetry-dir with a trailing slash resolves the same file" {
  # Asserting only that a file exists would be vacuous: "$DIR//x.jsonl" IS
  # "$DIR/x.jsonl" on POSIX, so any implementation passes. Emit under BOTH
  # spellings and assert they land in ONE file with TWO lines — that pins
  # "same file", which is the property the trailing-slash strip is for.
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  run zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" --telemetry-dir "$DIR/" \
    --pipeline p --outcome success --wall-s 2
  [ "$status" -eq 0 ]
  [ "$(ls -A "$DIR")" = "timo-jakob-foo.jsonl" ]
  [ "$(ls -A "$DIR" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 2 ]
}

@test "two repos sharing one directory get two files, neither truncating the other" {
  # The whole point of the mode: no cross-repo clobbering.
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  emit_dir --repo "someone-else/bar" --pipeline q --outcome failed --wall-s 2
  [ "$status" -eq 0 ]
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome parked --wall-s 3
  [ "$status" -eq 0 ]

  [ "$(ls -A "$DIR" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 2 ]
  [ "$(wc -l < "$DIR/someone-else-bar.jsonl")" -eq 1 ]
  # the exact identities, not merely how many: a cardinality check is satisfied
  # by any distinct pair, including one that recorded a slug instead of the
  # identity the consumer actually groups on.
  [ "$(jq -r -s -c 'map(.repo) | unique' "$DIR/someone-else-bar.jsonl")" = '["someone-else/bar"]' ]
  [ "$(jq -r -s -c 'map(.repo) | unique' "$DIR/timo-jakob-foo.jsonl")" = '["timo-jakob/foo"]' ]
}

@test "a basename-fallback repo still yields a filesystem-safe filename" {
  # No remote, and a directory name a GitHub slug could never be: the identity
  # is kept verbatim in the record, only the FILENAME is sanitized.
  local rd="$BATS_TEST_TMPDIR/my repo"
  mkdir -p "$rd"
  git init -q "$rd"
  run zsh "$S" --repo-dir "$rd" --telemetry-dir "$DIR" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "my repo" ]
  [ -f "$DIR/my-repo.jsonl" ]
  [ "$(ls -A "$DIR")" = "my-repo.jsonl" ]
}

@test "a dot-leading repo name does not become a file the *.jsonl glob misses" {
  # `.dotrepo.jsonl` is a dotfile, invisible to the reporting repo's glob — the
  # stream would be silently stranded rather than visibly missing.
  local rd="$BATS_TEST_TMPDIR/.dotrepo"
  mkdir -p "$rd"
  git init -q "$rd"
  run zsh "$S" --repo-dir "$rd" --telemetry-dir "$DIR" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = ".dotrepo" ]
  [ -f "$DIR/_dotrepo.jsonl" ]
  [ "$(ls -A "$DIR")" = "_dotrepo.jsonl" ]
}

@test "a dash-leading repo name does not become a file CLIs read as an option" {
  # The other half of the leading-character rule. Without it the file is
  # `-weird-name.jsonl`, which rm/cat/jq/tar downstream of the glob all parse as
  # an option — so a regression narrowing `[.-]*` to `.*` must go red here.
  emit_dir --repo "-weird/name" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "-weird/name" ]   # identity verbatim
  [ -f "$DIR/_weird-name.jsonl" ]
  [ "$(ls -A "$DIR")" = "_weird-name.jsonl" ]
}

@test "a colon is sanitized while an underscore survives" {
  # The docs name "spaces, colons, newlines and the like" as the mapped class,
  # but a space is the only member any other test exercises. `_` is on the other
  # side of the line (GitHub allows it in a repo name), so one case pins both
  # edges of the charset at once.
  emit_dir --repo "acme/wid:get_v1" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "acme/wid:get_v1" ]   # identity verbatim
  [ "$(ls -A "$DIR")" = "acme-wid-get_v1.jsonl" ]
}

@test "a non-ASCII identity yields a safe, glob-visible, single-record file" {
  # Reachable via --repo or a non-ASCII remote (the basename fallback reaches the
  # same charset branch, though it can only ever yield a slash-less identity like
  # `café`). It is the one slug input whose EXACT filename is locale-dependent: `[^A-Za-z0-9._-]`
  # maps one dash per character under a multibyte locale and one per BYTE
  # otherwise. So assert the properties that hold either way — pinning the exact
  # name would make this a test of the runner's locale, not of the emitter.
  emit_dir --repo "café/widget" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "café/widget" ]   # identity verbatim
  local f; f="$(ls -A "$DIR")"
  [ "$(ls -A "$DIR" | wc -l | tr -d ' ')" -eq 1 ]
  # glob-visible (no leading dot), option-safe (no leading dash), sanitized
  matches "$f" '^[A-Za-z0-9_][A-Za-z0-9._-]*\.jsonl$'
  # the title's third claim: ONE record. --require-records only demands >= 1.
  [ "$(wc -l < "$DIR/$f")" -eq 1 ]
  run zsh "$V" "$DIR/$f" --require-records
  [ "$status" -eq 0 ]
}

@test "a DANGLING symlink --telemetry-dir falls to the append-time error, not the operand check" {
  # The 2-vs-3 boundary's one ambiguous input. The up-front check tests `-e`,
  # which FOLLOWS symlinks, so a dangling link is not "exists and is not a
  # directory" and reaches mkdir instead — exit 3. Pinned so the boundary
  # cannot drift silently in either direction.
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$BATS_TEST_TMPDIR/dangling"
  run --separate-stderr zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-dir "$BATS_TEST_TMPDIR/dangling" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot create sink directory"
  matches "$stderr" ".*\(.+\).*"                   # …carrying the OS's own reason
  lacks "$stderr" "unknown error"
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null  # stdout: record only
  [ ! -e "$BATS_TEST_TMPDIR/nowhere" ]              # the link's target stays absent
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "a symlink to a real directory is accepted, and the record lands in the target" {
  # The other side of the same boundary: `-d` follows the link, so this is a
  # perfectly good DIR and must not be rejected by the operand check.
  local target="$BATS_TEST_TMPDIR/real-target"
  mkdir -p "$target"
  ln -s "$target" "$BATS_TEST_TMPDIR/link"
  run zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-dir "$BATS_TEST_TMPDIR/link" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ -f "$target/timo-jakob-foo.jsonl" ]
}

@test "a newline in the identity is sanitized and the sink stays one-line-per-record" {
  # The third member of the documented hostile class, and the only one that is
  # dangerous twice over: it would make the filename hostile AND, if the
  # identity ever reached the record unescaped, break the one-line-per-record
  # JSONL invariant every downstream `jq -s` depends on. So pin both — and pin
  # the identity itself, because the tempting "fix the newline at the source"
  # change (slugging `repo` BEFORE the record is built) leaves the filename, the
  # line count and the validator all green while silently rewriting the field
  # the whole cross-repo grouping contract rests on.
  local id; id="$(printf 'acme/wid\nget')"
  emit_dir --repo "$id" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "$id" ]              # identity verbatim
  [ "$(ls -A "$DIR")" = "acme-wid-get.jsonl" ]
  [ "$(wc -l < "$DIR/acme-wid-get.jsonl")" -eq 1 ]
  # read it back too: this is the one identity whose JSON escaping is what keeps
  # the sink one-line-per-record, so prove the round-trip, not just the emit.
  [ "$(jq -r -s '.[0].repo' "$DIR/acme-wid-get.jsonl")" = "$id" ]
  run zsh "$V" "$DIR/acme-wid-get.jsonl" --require-records
  [ "$status" -eq 0 ]
}

@test "only the LEADING character is rewritten — a later dot or dash survives" {
  # The complement of the two tests above: over-applying the rule would mangle
  # ordinary names (`acme/widget.js` is a perfectly good repo).
  emit_dir --repo "acme/widget.js-2" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.repo')" = "acme/widget.js-2" ]   # identity verbatim
  [ "$(ls -A "$DIR")" = "acme-widget.js-2.jsonl" ]
}

@test "two repos whose identities sanitize alike share one file without loss" {
  # The slug is many-to-one by design, so this is the documented behaviour, not
  # a defect: `my repo` and `my-repo` co-locate, and the verbatim `repo` field
  # is what still separates them. Pinning the exact identities — not just that
  # there are two of them — stops a future "fix" (hashing, truncating, or
  # recording the slug) from silently changing the contract consumers read.
  emit_dir --repo "my repo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  emit_dir --repo "my-repo" --pipeline p --outcome failed --wall-s 2
  [ "$status" -eq 0 ]
  [ "$(ls -A "$DIR")" = "my-repo.jsonl" ]
  [ "$(wc -l < "$DIR/my-repo.jsonl")" -eq 2 ]
  [ "$(jq -r -s -c 'map(.repo) | unique' "$DIR/my-repo.jsonl")" = '["my repo","my-repo"]' ]
}

@test "a slug can never escape the cross-repo directory" {
  # `repo` reaches the filename, so a `/` that survived would write OUTSIDE DIR
  # — or, with `..`, above it. The sink an UNSANITIZED slug would resolve to is
  # "$dir/../../etc/evil.jsonl", i.e. two levels above DIR — so DIR is nested
  # two deep here, putting that escape target back inside this test's OWN
  # tmpdir. (A shallower DIR would push the assertion into the suite-shared
  # BATS_SUITE_TMPDIR, making it depend on state no single test owns.)
  local dir="$BATS_TEST_TMPDIR/deep/cross-repo"
  run zsh "$S" --repo "../../etc/evil" --repo-dir "$RD" --telemetry-dir "$dir" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  # the identity is NOT hardened — only the filename is. A traversal fix applied
  # to `repo` itself would keep every path assertion below green.
  [ "$(echo "$output" | jq -r '.repo')" = "../../etc/evil" ]   # identity verbatim
  # the exact name, not just a count: it also pins the composition order
  # (`/`→`-` first, THEN the leading-character rewrite).
  [ -f "$dir/_.-..-etc-evil.jsonl" ]
  [ "$(ls -A "$dir")" = "_.-..-etc-evil.jsonl" ]
  [ ! -e "$BATS_TEST_TMPDIR/etc" ]
  # nothing nested either: everything the mode writes sits DIRECTLY in DIR
  [ "$(find "$dir" -mindepth 2 | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a --telemetry-dir naming an existing FILE is a usage error, caught up front" {
  # Naming the wrong KIND of thing is knowable from the arguments alone, so it
  # is exit 2 — the same class as --repo-dir not being a directory. Left to be
  # discovered at mkdir time it would exit 3 and tell a wrapper "the environment
  # broke, retry" about what is really a typo.
  local blocker="$BATS_TEST_TMPDIR/iam-a-file"
  : > "$blocker"
  run --separate-stderr zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-dir "$blocker" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$stderr" "--telemetry-dir is not a directory"
  [ -z "$output" ]                                 # rejected BEFORE the record is emitted
  [ ! -s "$blocker" ]                              # nothing landed in it
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ] # and no silent fallback
}

@test "a diagnostic reproduces a backslash-bearing operand verbatim" {
  # Pins the `print -ru2` (raw) form of every diagnostic. Without `-r`, zsh's
  # `print` processes echo escapes: `\t` in a caller's path becomes a tab where
  # the operator needs the literal name they must fix, and `\c` TRUNCATES the
  # rest of the line — silently halving the very message whose job is to say
  # which operand to edit. Nothing else in the suite can tell the two forms
  # apart, so a revert (or a new diagnostic added with plain -u2) would ship
  # green without this.
  local blocker="$BATS_TEST_TMPDIR/a\tb\cdir"      # literal backslashes
  : > "$blocker"
  run --separate-stderr zsh "$S" --repo-dir "$RD" --telemetry-dir "$blocker" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$stderr" "--telemetry-dir is not a directory: $blocker"
  [ -z "$output" ]
}

@test "an uncreatable cross-repo directory is an internal error, and nothing is written" {
  # The other side of that line: a bad path COMPONENT is NOT knowable from the
  # arguments, so it is still found at mkdir time and still exits 3 — now with
  # the OS's own reason attached.
  # --separate-stderr, not plain `run`: the record is written to stdout BEFORE
  # the sink is resolved, so a `print -u2` → `print` regression would append this
  # diagnostic to the JSON line and break every `emit … | jq` consumer.
  local blocker="$BATS_TEST_TMPDIR/iam-a-file"
  : > "$blocker"
  run --separate-stderr zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-dir "$blocker/below" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot create sink directory"
  matches "$stderr" ".*\(.+\).*"                   # …carrying the OS's own reason
  lacks "$stderr" "unknown error"                  # …not the fallback string
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null  # stdout: record only
  [ ! -s "$blocker" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "an unappendable cross-repo sink is an internal error, and nothing is written" {
  # The resolved per-repo path IS a directory. That path is DERIVED, not typed by
  # the caller, so it is not knowable up front — hence exit 3, unlike the operand
  # checks above.
  mkdir -p "$DIR/timo-jakob-foo.jsonl"
  emit_dir_split --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot append to sink"
  matches "$stderr" ".*\(.+\).*"                   # …carrying the OS's own reason
  lacks "$stderr" "unknown error"
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null
  [ -z "$(ls -A "$DIR/timo-jakob-foo.jsonl")" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "an existing but unwritable cross-repo directory fails without falling back" {
  # The criterion's literal case: a reporting drop-box owned by someone else.
  # mkdir -p on an existing directory succeeds, so the failure surfaces from the
  # append — the same branch, reached the way an operator would actually hit it.
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  mkdir -p "$DIR"
  chmod 555 "$DIR"
  emit_dir_split --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$stderr" "cannot append to sink"
  # name the RESOLVED per-repo path: with DIR unwritable every path under it
  # fails, so a needle that stopped at the prefix would survive a regression
  # that dropped _repo_slug and always wrote DIR/telemetry.jsonl
  contains "$stderr" "$DIR/timo-jakob-foo.jsonl"
  matches "$stderr" ".*\(.+\).*"                   # …and the OS's own reason
  lacks "$stderr" "unknown error"
  echo "$output" | jq -e '.schema == "telemetry/v1"' >/dev/null
  [ -z "$(ls -A "$DIR")" ]
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "a rejected record leaves an EXISTING cross-repo sink byte-identical" {
  # The --telemetry-file section pins this; the dir path deserves its own, because
  # the plausible "fail fast on a bad DIR" refactor — hoisting the mkdir above the
  # validation block — would litter a reporting drop-box on every rejected
  # invocation while every other test stayed green.
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 0 ]
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 2
  [ "$status" -eq 0 ]
  local before; before="$(cksum < "$DIR/timo-jakob-foo.jsonl")"

  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome merged --wall-s 1    # bad enum
  [ "$status" -eq 2 ]
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s abc # bad numeric
  [ "$status" -eq 2 ]
  emit_dir --repo "timo-jakob/foo" --pipeline p --outcome success --wall-s 1 --nope 1
  [ "$status" -eq 2 ]                                                          # unknown flag

  [ "$(cksum < "$DIR/timo-jakob-foo.jsonl")" = "$before" ]
  [ "$(wc -l < "$DIR/timo-jakob-foo.jsonl")" -eq 2 ]
  [ "$(ls -A "$DIR" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a usage error never even creates the cross-repo directory" {
  # The cheaper half of the same promise: DIR must not appear as a side effect
  # of an invocation that was rejected before any sink was resolved.
  run zsh "$S" --repo "timo-jakob/foo" --repo-dir "$RD" \
    --telemetry-dir "$BATS_TEST_TMPDIR/never" --pipeline p --outcome merged --wall-s 1
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/never" ]
}

@test "an explicitly empty --telemetry-dir is rejected, never the default sink" {
  # Same slip as --telemetry-file: `--telemetry-dir "$VAR"` with VAR unset would
  # otherwise degrade to "omitted" and land the record in the LOCAL sink, exit 0
  # — invisible to the directory the caller believed they were writing to.
  run zsh "$S" --repo-dir "$RD" --telemetry-dir "" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 2 ]
  contains "$output" "--telemetry-dir requires a non-empty value"
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "a dangling --telemetry-dir does NOT fall through to the default sink" {
  run zsh "$S" --repo-dir "$RD" --pipeline p --outcome success --wall-s 1 --telemetry-dir
  [ "$status" -eq 2 ]
  contains "$output" "--telemetry-dir requires a value"
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
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
  # the file's standing promise: a rejected record never lands. Without this a
  # regression moving the check below the append would exit 2 AND write.
  [ ! -f "$SINK" ]
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
  contains "$output" "--telemetry-file requires a value"
  [ ! -f "$RD/.claude/telemetry/telemetry.jsonl" ]
}

@test "a flag-shaped value is rejected rather than swallowed" {
  emit --pipeline p --outcome success --wall-s 1 --repo --tokens
  [ "$status" -eq 2 ]
  # name the branch: "requires a value" is also _need_val's argument-COUNT
  # diagnostic, so on its own it does not distinguish the guard under test.
  contains "$output" "got the flag"
  [ ! -f "$SINK" ]
}

@test "a clock that cannot be read is an internal error, not a math abort" {
  # Without the guarded assignment an empty `ts` reaches $(( 10#$ts )), a zsh
  # math error that aborts with status 1 — the one code this taxonomy declares
  # unused. Same PATH-stub seam the jq and od tests use.
  local stub="$BATS_TEST_TMPDIR/datestub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/date"
  chmod +x "$stub/date"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  [ "$status" -ne 1 ]                    # the regression the guard exists to stop
  contains "$output" "could not read the clock"
  [ ! -f "$SINK" ]
}

@test "a clock that SUCCEEDS with junk output is also an internal error" {
  # A status-only guard would pass this through to the same math abort.
  local stub="$BATS_TEST_TMPDIR/datestub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nprintf %%s "%%s"\n' > "$stub/date"
  chmod +x "$stub/date"
  run env PATH="$stub:$PATH" "$ZSH_BIN" "$S" --repo-dir "$RD" --telemetry-file "$SINK" \
    --pipeline p --outcome success --wall-s 1
  [ "$status" -eq 3 ]
  contains "$output" "could not read the clock"
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
  contains "$output" "--telemetry-file requires a non-empty value"
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
