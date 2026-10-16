#!/usr/bin/env bats
#
# epic-clean-stop-triage.zsh (#2585): which children an unattended epic walk
# resolves, parks or skips once a child has clean-stopped (#2579). Pure — the
# --deps records stand in for read-dependencies.zsh, and --marker-root points
# the marker lookup at a temp dir — so every arm is driven without GitHub. The
# last cases pin E3's call to the script in SKILL.md.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$REPO_ROOT/development/skills/resolve-issue/scripts/epic-clean-stop-triage.zsh"
  DEPS="$BATS_TEST_TMPDIR/deps.jsonl"
  ROOT="$BATS_TEST_TMPDIR/markers"
  mkdir -p "$ROOT"
}

# a read-dependencies.zsh record: $1 = issue, $2 = blockers as "N:depth" words
rec() {
  local issue="$1"; shift
  local b="" items=""
  for b in "$@"; do
    items+="${items:+,}{\"number\":${b%%:*},\"state\":\"OPEN\",\"open\":true,\"kind\":\"issue\",\"depth\":${b##*:}}"
  done
  printf '{"issue":%s,"blocked":%s,"open_blockers":[],"blockers":[%s],"foreign_blockers":[],"cycles":[],"truncated":false}\n' \
    "$issue" "$([ -n "$items" ] && echo true || echo false)" "$items"
}

# the A <- B <- C chain plus an independent D: B is blocked by A, C by B (so
# transitively by A), D by nothing
chain() {
  { rec 11; rec 12 11:1; rec 13 12:1 11:2; rec 14; } > "$DEPS"
}

triage() { run --separate-stderr zsh "$T" --repo Acme/Widget --deps "$DEPS" --marker-root "$ROOT" "$@"; }

@test "#2585 AC1 a child with no blockedBy path to the clean-stopped one walks in the same invocation" {
  chain
  triage --children 11,12,13,14 --clean-stopped 11
  [ "$status" -eq 0 ]
  [ "$(jq -c '.walk' <<<"$output")" = '[14]' ]
  [ "$(jq -c '.skip' <<<"$output")" = '[11]' ]
  # nothing clean-stopped: every child walks
  triage --children 11,12,13,14
  [ "$status" -eq 0 ]
  [ "$(jq -c '{walk, skip, parked}' <<<"$output")" = '{"walk":[11,12,13,14],"skip":[],"parked":[]}' ]
}

@test "#2585 AC2 the chain A <- B <- C: B and C parked behind A, D walks, and the summary names the resume and the blocker" {
  chain
  triage --children 11,12,13,14 --clean-stopped 11
  [ "$status" -eq 0 ]
  [ "$(jq -c '.parked' <<<"$output")" = '[{"child":12,"blocked_by":[11]},{"child":13,"blocked_by":[11]}]' ]
  [ "$(jq -c '.clean_stopped' <<<"$output")" = '[{"child":11,"marker":null,"resume":"/development:resolve-issue 11 --resume"}]' ]
  [ "$(jq -r '.summary[]' <<<"$output")" = "#11 clean-stopped — resume with /development:resolve-issue 11 --resume
#12 parked — blocked by clean-stopped #11
#13 parked — blocked by clean-stopped #11" ]
  [ "$(jq -c '.counts' <<<"$output")" = '{"clean_stopped":1,"parked_behind_clean_stop":2}' ]
}

@test "#2585 a dependant reaching two clean-stopped children names both, ascending; a clean-stopped child is never also parked" {
  { rec 21; rec 22 21:1; rec 23 22:1 21:2 24:1; rec 24; } > "$DEPS"
  triage --children 24,21,22,23 --clean-stopped 24,21,22
  [ "$status" -eq 0 ]
  [ "$(jq -c '.skip' <<<"$output")" = '[24,21,22]' ]
  [ "$(jq -c '.parked' <<<"$output")" = '[{"child":23,"blocked_by":[21,22,24]}]' ]
  [ "$(jq -r '.summary[-1]' <<<"$output")" = "#23 parked — blocked by clean-stopped #21, #22, #24" ]
  [ "$(jq -c '.walk' <<<"$output")" = '[]' ]
}

@test "#2585 walk, skip and parked keep --children order when --children is not ascending" {
  # 12 is blocked by 11, 15 by 12 (so transitively by 11); 13 and 14 are independent
  { rec 11; rec 12 11:1; rec 13; rec 14; rec 15 12:1 11:2; } > "$DEPS"
  # nothing clean-stopped: every child walks, in --children order
  triage --children 14,15,11,13,12
  [ "$status" -eq 0 ]
  [ "$(jq -c '{walk, skip, parked}' <<<"$output")" = '{"walk":[14,15,11,13,12],"skip":[],"parked":[]}' ]
  # 11 clean-stopped: walk is a proper subset, still in --children order
  triage --children 14,15,11,13,12 --clean-stopped 11
  [ "$status" -eq 0 ]
  [ "$(jq -c '.walk' <<<"$output")" = '[14,13]' ]
  [ "$(jq -c '.skip' <<<"$output")" = '[11]' ]
  [ "$(jq -c '.parked' <<<"$output")" = '[{"child":15,"blocked_by":[11]},{"child":12,"blocked_by":[11]}]' ]
}

@test "#2585 AC5 a kept marker makes a child clean-stopped without --clean-stopped, and keeps its dependants parked" {
  chain
  mkdir -p "$ROOT/acme-widget/11"
  echo '{}' > "$ROOT/acme-widget/11/clean-stop.json"
  triage --children 11,12,13,14
  [ "$status" -eq 0 ]
  [ "$(jq -c '.skip' <<<"$output")" = '[11]' ]
  [ "$(jq -c '.clean_stopped' <<<"$output")" = "[{\"child\":11,\"marker\":\"$ROOT/acme-widget/11/clean-stop.json\",\"resume\":\"/development:resolve-issue 11 --resume\"}]" ]
  [ "$(jq -c '[.parked[].child]' <<<"$output")" = '[12,13]' ]
  [ "$(jq -c '.walk' <<<"$output")" = '[14]' ]
  # the slug is tlm_repo_slug of --repo: another repo's marker does not count
  rm -rf "$ROOT/acme-widget"
  mkdir -p "$ROOT/other-widget/11"; echo '{}' > "$ROOT/other-widget/11/clean-stop.json"
  triage --children 11,12,13,14
  [ "$(jq -c '.skip' <<<"$output")" = '[]' ]
}

@test "#2585 the default marker root is HOME/.claude/resolve-issue, and an unset HOME cannot decide (exit 3)" {
  chain
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude/resolve-issue/acme-widget/13"
  echo '{}' > "$BATS_TEST_TMPDIR/home/.claude/resolve-issue/acme-widget/13/clean-stop.json"
  run --separate-stderr env HOME="$BATS_TEST_TMPDIR/home" zsh "$T" --repo Acme/Widget --deps "$DEPS" --children 11,12,13,14
  [ "$status" -eq 0 ]
  [ "$(jq -c '.skip' <<<"$output")" = '[13]' ]
  # an EMPTY HOME (zsh refills an unset one from the password database, so empty
  # is the reachable form of "no home")
  run --separate-stderr env HOME= zsh "$T" --repo Acme/Widget --deps "$DEPS" --children 11,12,13,14
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "no --marker-root and HOME is unset or empty"
  # an explicit --marker-root needs no HOME at all
  run --separate-stderr env HOME= zsh "$T" --repo Acme/Widget --deps "$DEPS" --children 11,12,13,14 --marker-root "$ROOT"
  [ "$status" -eq 0 ]
}

@test "#2585 a truncated record while a child has clean-stopped cannot decide (exit 3); with nothing clean-stopped it is fine" {
  { rec 11; rec 12 11:1; rec 14; } > "$DEPS"
  printf '%s\n' '{"issue":13,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":true}' >> "$DEPS"
  triage --children 11,12,13,14 --clean-stopped 11
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "the dependency walk was truncated for #13 while a child has clean-stopped"
  triage --children 11,12,13,14
  [ "$status" -eq 0 ]
  [ "$(jq -c '.walk' <<<"$output")" = '[11,12,13,14]' ]
}

@test "#2585 a truncated record while only a kept marker makes a child clean-stopped cannot decide (exit 3)" {
  { rec 11; rec 12 11:1; rec 14; } > "$DEPS"
  printf '%s\n' '{"issue":13,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":true}' >> "$DEPS"
  mkdir -p "$ROOT/acme-widget/11"
  echo '{}' > "$ROOT/acme-widget/11/clean-stop.json"
  triage --children 11,12,13,14
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "the dependency walk was truncated for #13 while a child has clean-stopped"
}

@test "#2585 usage and malformed input are exit 2" {
  chain
  local -a bad
  triage --children 11,12 --clean-stopped 13
  [ "$status" -eq 2 ]; contains "$stderr" "--clean-stopped #13 is not in --children"
  triage --children 11,99
  [ "$status" -eq 2 ]; contains "$stderr" "--deps has no record for #99"
  triage --children 11,11
  [ "$status" -eq 2 ]; contains "$stderr" "--children lists #11 twice"
  triage --children 11,x
  [ "$status" -eq 2 ]; contains "$stderr" "--children must be a comma list of issue numbers"
  triage --children 011
  [ "$status" -eq 2 ]
  triage --children 11 --bogus
  [ "$status" -eq 2 ]; contains "$stderr" "unknown flag: --bogus"
  triage --children 11 extra
  [ "$status" -eq 2 ]; contains "$stderr" "unexpected argument: extra"
  triage --children
  [ "$status" -eq 2 ]; contains "$stderr" "--children requires a value"
  triage --children --clean-stopped 11
  [ "$status" -eq 2 ]; contains "$stderr" "--children requires a non-empty value"
  run --separate-stderr zsh "$T" --repo widget --deps "$DEPS" --children 11
  [ "$status" -eq 2 ]; contains "$stderr" "--repo must be OWNER/NAME"
  run --separate-stderr zsh "$T" --repo Acme/Widget --children 11
  [ "$status" -eq 2 ]; contains "$stderr" "usage: epic-clean-stop-triage.zsh"
  run --separate-stderr zsh "$T" --repo Acme/Widget --deps "$BATS_TEST_TMPDIR/none.jsonl" --children 11 --marker-root "$ROOT"
  [ "$status" -eq 2 ]; contains "$stderr" "--deps is not a readable file"
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.jsonl"
  run --separate-stderr zsh "$T" --repo Acme/Widget --deps "$BATS_TEST_TMPDIR/bad.jsonl" --children 11 --marker-root "$ROOT"
  [ "$status" -eq 2 ]; contains "$stderr" "--deps must be JSON Lines of read-dependencies.zsh records"
  echo '{"issue":"11","blockers":[]}' > "$BATS_TEST_TMPDIR/bad.jsonl"
  run --separate-stderr zsh "$T" --repo Acme/Widget --deps "$BATS_TEST_TMPDIR/bad.jsonl" --children 11 --marker-root "$ROOT"
  [ "$status" -eq 2 ]
  run -0 zsh "$T" --help
  contains "$output" "usage: epic-clean-stop-triage.zsh --repo OWNER/NAME --children"
}

@test "#2585 it writes nothing: the marker root and the deps file are unchanged" {
  chain
  local before
  before=$(find "$ROOT" "$DEPS" -exec ls -ld {} + | cksum)
  triage --children 11,12,13,14 --clean-stopped 11
  [ "$status" -eq 0 ]
  [ "$(find "$ROOT" "$DEPS" -exec ls -ld {} + | cksum)" = "$before" ]
}

# --- E3's use of the script, and the contract, pinned ---------------------------

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

@test "#2585 AC4 E3 resolves the walk mode once, before E1, and every child runs in it" {
  local skill
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  contains "$skill" '**Also before E1, resolve the walk mode once (#2585):** `"<skill-base-dir>/scripts/resolve-session.zsh" --inferred unattended`.'
  contains "$skill" 'The walk is **attended** only when its line says `attended`; otherwise it is **unattended**.'
  contains "$skill" 'Every child E3 drives runs in that mode — its §0a takes the walk mode rather than resolving its own, and a parallel sub-agent receives the mode in its prompt next to `child_start_args`.'
  contains "$skill" 'A child of an attended walk never takes the clean stop (#2579): an escalation takes today'"'"'s terminal, and E3'"'"'s triage of it below is unchanged.'
}

@test "#2585 AC1 AC2 AC5 E3 calls the triage script and acts on skip, parked and walk" {
  local skill
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  contains "$skill" '`"<skill-base-dir>/scripts/epic-clean-stop-triage.zsh" --repo "$REPO" --children <open children in walk order> --deps <file>`'
  contains "$skill" 'Call it once before the first child and again after each child that clean-stops.'
  contains "$skill" '`--deps` is a JSON Lines file holding one `read-dependencies.zsh --repo "$REPO" --issue <N>` record per child.'
  contains "$skill" 'never walk a child in `skip` — a kept `clean-stop.json` marker makes a child clean-stopped on a later walk too, so its kept work-dir is never overwritten;'
  contains "$skill" '**In an unattended walk, a clean stop is triaged by one script (#2585).**'
  contains "$skill" 'A clean-stopped child (#2579) is a typed escalation, so the triage above holds, but who walks, who is parked and who is skipped is decided by'
  contains "$skill" 'park every child in `parked` not yet handled this invocation, never branch it, and leave the epic note that it is blocked on the `blocked_by` children;'
  contains "$skill" 'walk, in `walk` order, only the children of `walk` E3 has not yet handled this invocation.'
  contains "$skill" '`--children` is the epic'"'"'s full open list from E1 on every call, so a re-call'"'"'s `walk` can list children already resolved, escalated or parked.'
  contains "$skill" 'Exit 3 means the script cannot prove any child independent: park every child not yet resolved and quote its stderr in the summary.'
  contains "$skill" 'Exit 2 is your own call: fix it and re-run once.'
  contains "$skill" 'The summary comment below prints the script'"'"'s `summary` lines, adding to each clean-stopped child'"'"'s line a link to its clean-stop comment.'
  # the script E3 names is the script under test
  [ -x "$T" ]
}

@test "#2585 AC3 ARCHITECTURE.md and reference/epic-telemetry.md name both sub-counts" {
  local arch tel
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  tel="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/epic-telemetry.md")"
  contains "$arch" 'Two **sub-counts** (#2585) ride beside the buckets and are kept out of that sum: `clean_stopped`, the escalated children in the clean-stop triage'"'"'s `skip` (clean-stopped this invocation or kept by an earlier walk'"'"'s marker), and `parked_behind_clean_stop`, the parked children blocked through a clean-stopped child.'
  contains "$arch" 'the builder refuses `clean_stopped > escalated` and `parked_behind_clean_stop > parked`'
  contains "$tel" '| `children.clean_stopped`, `children.parked_behind_clean_stop` | E3 | sub-counts (#2585), kept **out** of the bucket sum above'
  contains "$tel" 'The builder refuses `clean_stopped` above `escalated` and `parked_behind_clean_stop` above `parked` |'
  contains "$tel" 'Both `0` in an attended walk and when no child clean-stopped.'
  contains "$arch" '`escalated` (ended on a typed escalation, or in the `skip` of E3'"'"'s clean-stop triage — a child skipped for a kept marker from an earlier walk counts here too)'
  contains "$tel" 'both from `epic-clean-stop-triage.zsh`'"'"'s `counts` at E3'"'"'s last call that exited 0: `clean_stopped` is its `counts.clean_stopped` — every child in its `skip`, clean-stopped this invocation or skipped for a kept marker from an earlier walk, each counted `escalated`; `parked_behind_clean_stop` is its `counts.parked_behind_clean_stop`, each of those children counted `parked`.'
  contains "$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")" 'How its `counts` and its `skip` feed the epic record is stated in `reference/epic-telemetry.md`.'
}
