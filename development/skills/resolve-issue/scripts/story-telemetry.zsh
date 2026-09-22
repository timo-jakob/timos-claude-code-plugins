#!/usr/bin/env zsh
# story-telemetry.zsh — the resolve-issue run's own telemetry, as three
# deterministic steps the skill calls instead of improvising them (epic #741,
# child (a) — issue #1226). The judgement stays in the skill (what the run's
# facts were); everything mechanical — parsing the invocation, pre-minting the
# run_id, and the never-fatal build + emit — lives here, where bats can reach it.
#
#   story-telemetry.zsh args [WORD ...]
#       Parse the skill's $ARGUMENTS: exactly one issue reference, plus
#       --telemetry-file PATH, --telemetry-dir DIR and --no-review in ANY
#       position. Prints {"issue_ref", "telemetry_file", "telemetry_dir",
#       "no_review"} (absent sink flags → null, absent --no-review → false). The
#       two paths are made ABSOLUTE against this call's cwd, so every later
#       caller — each loop invocation, the emitter — names the same file
#       whatever directory it runs from. No arguments, an unknown flag, a sink
#       flag with no (or an empty, or a flag-shaped) value, a repeated sink flag,
#       an empty issue reference, or more than one issue reference prints the
#       invocation help on stderr and exits 2. It writes NOTHING, so a Step 0
#       stop can never leave a record behind. Exit 1 is internal (jq missing or
#       failing).
#
#   story-telemetry.zsh start --run-file FILE [--telemetry-file PATH]
#       [--telemetry-dir DIR] [--ts EPOCH]
#       Stamp the run's start and PRE-MINT its run_id in the emitter's own
#       format, `resolve-issue-<ts>-<4 hex>`, so the id can be handed to every
#       review-loop invocation as --parent-run-id BEFORE the run's own record
#       exists. Writes {run_id, ts, telemetry_file, telemetry_dir, loop_args} to
#       FILE (a scratch path outside the repo) and prints it; the paths are made
#       absolute exactly as `args` does (a leading `~` expanded first).
#       `loop_args` is the exact flag list to append to EVERY
#       resolve-story-loop.zsh invocation of this run. Every call mints a NEW
#       run and overwrites FILE: `start` cannot tell a fresh invocation from a
#       re-entry, so it is called exactly once per invocation, and a re-entering
#       skill re-reads FILE instead of calling it again. Touches no sink.
#
#   story-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR
#       --issue N [--repo-type T] [--loop-work-dir DIR ...] [--now EPOCH]
#       Build the payload (build-story-telemetry-record.zsh), narrow the outcome,
#       and emit ONE `kind: "run"` record through the shared emitter with
#       `--pipeline resolve-issue`, the pre-minted `--run-id`, `--ts` = the start
#       stamp, and the run's sink flags. Each --loop-work-dir contributes the ids
#       in its `.telemetry-run-ids` ledger (written by resolve-story-loop.zsh) to
#       payload.review_loop_run_ids; a --loop-work-dir that is not a directory at
#       all is warned about and contributes nothing. Prints the emitted record on
#       success, and marks the run file `emitted: true`, so a repeated `emit` for
#       the same run is refused with the advisory instead of appending a second
#       record under the same run_id.
#       NEVER FATAL: any failure past argument parsing — a missing or unreadable
#       run file, a run already emitted, a state the builder rejects, an emitter
#       that is absent, non-executable or exits non-zero (its exit 2 for a
#       --telemetry-dir that names a file, or for a --repo-dir that is not a
#       directory, included) — prints ONE advisory line on
#       stderr, emits nothing, and exits 0. The emitter appends nothing on any
#       non-zero exit, so no partial record reaches a sink.
#
# Seams (tests only; unset in production), following the loop's
# RESOLVE_LOOP_PAYLOAD_BIN convention:
#   STORY_TELEMETRY_EMITTER_BIN  the emitter (a PATH)
#   STORY_TELEMETRY_BUILDER_BIN  the payload builder (a PATH)
#
# Exit codes: 0 ok (and every never-fatal emit outcome) · 2 usage · 1 internal,
# from `args` (jq) and `start` (a clock it cannot read, a run file it cannot
# write). On a failed `start` the run has no start stamp and so no record, but
# its loops still take the sink flags — from `args`' output, since the run file
# that would have carried them was never written (see the skill's reference).

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local EMITTER="${STORY_TELEMETRY_EMITTER_BIN:-${self_dir}/../../../scripts/telemetry/emit-telemetry.zsh}"
local BUILDER="${STORY_TELEMETRY_BUILDER_BIN:-${self_dir}/build-story-telemetry-record.zsh}"

local invocation_help="usage: /development:resolve-issue <issue-number|url> [--telemetry-file PATH] [--telemetry-dir DIR] [--no-review]
  flags may appear in any position; sink precedence is --telemetry-file >
  --telemetry-dir (DIR/<repo-slug>.jsonl) > .claude/telemetry/telemetry.jsonl"

local usage="usage: story-telemetry.zsh args [WORD ...]
       story-telemetry.zsh start --run-file FILE [--telemetry-file PATH] [--telemetry-dir DIR] [--ts EPOCH]
       story-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR --issue N
                                [--repo-type T] [--loop-work-dir DIR ...] [--now EPOCH]"

# A sink path made absolute ONCE, against this call's cwd. A leading `~` is
# expanded first: a slash command's $ARGUMENTS reaches the shell unexpanded (and
# the skill single-quotes every word), so `--telemetry-dir ~/telemetry` would
# otherwise become a directory literally named `~` under the cwd — normally the
# repo — and every record would land there silently. Only `~` and `~/…` are
# expanded; `~user` forms are left as written.
_abs_path() {  # $1 = path; prints the absolute spelling
  local p="$1"
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="${HOME}${p#\~}"
  print -r -- "${p:a}"
}

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "story-telemetry: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "story-telemetry: $1 requires a non-empty value"; exit 2 }
}

# --- args -------------------------------------------------------------------

_cmd_args() {
  local ref="" tfile="" tdir="" seen_file=0 seen_dir=0 no_review=false
  _args_fail() {
    print -ru2 -- "story-telemetry: $1"
    print -ru2 -- "$invocation_help"
    exit 2
  }
  (( $# > 0 )) || _args_fail "no issue reference given"
  while (( $# > 0 )); do
    case "$1" in
    --telemetry-file|--telemetry-dir)
      (( $# >= 2 )) || _args_fail "$1 requires a value"
      [[ -n "$2" && "$2" != --* ]] || _args_fail "$1 requires a non-empty value"
      if [[ "$1" == --telemetry-file ]]; then
        (( ! seen_file )) || _args_fail "--telemetry-file given twice"
        seen_file=1; tfile="$2"
      else
        (( ! seen_dir )) || _args_fail "--telemetry-dir given twice"
        seen_dir=1; tdir="$2"
      fi
      shift 2 ;;
    # the skill's own review-loop switch (§3.5): parsed here so it never reads
    # as an unknown flag, and handed back for the conductor to act on
    --no-review) no_review=true; shift ;;
    -*) _args_fail "unknown flag: $1" ;;
    *)
      [[ -n "$1" ]] || _args_fail "an empty issue reference"
      [[ -z "$ref" ]] || _args_fail "more than one issue reference: $ref $1"
      ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || _args_fail "no issue reference given"
  # absolute once, here: a relative path would otherwise resolve against each
  # later caller's own cwd, and records of one run could split across sinks
  [[ -n "$tfile" ]] && tfile="$(_abs_path "$tfile")"
  [[ -n "$tdir" ]] && tdir="$(_abs_path "$tdir")"
  jq -nc --arg ref "$ref" --arg f "$tfile" --arg d "$tdir" --argjson nr "$no_review" \
    '{issue_ref:$ref,
      telemetry_file:(if $f == "" then null else $f end),
      telemetry_dir:(if $d == "" then null else $d end),
      no_review:$nr}' || {
    print -u2 -- "story-telemetry args: failed to print the parsed arguments"; exit 1 }
}

# --- start ------------------------------------------------------------------

# The emitter's own id format — <pipeline>-<epoch>-<4 hex rand>, the suffix drawn
# from urandom rather than derived from the stamp. This is a second copy of the
# emitter's _rand4, and it is kept deliberately: pre-minting is exactly the case
# the emitter's `--run-id` flag exists for, and the emitter has no mint-only
# mode. The FORMAT is what must not drift, and tests/story-telemetry.bats pins
# it against the regex the loop's own records are held to.
_rand4() {
  local h=""
  if [[ -r /dev/urandom ]]; then
    h=$(LC_ALL=C od -An -tx1 -N2 /dev/urandom 2>/dev/null | tr -d ' \n') || h=""
  fi
  [[ ${#h} -ge 4 ]] || h=$(printf '%04x' $(( RANDOM & 0xffff )))
  printf '%s' "${h:0:4}"
}

_cmd_start() {
  local run_file="" tfile="" tdir="" ts=""
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --telemetry-file) _need_val "$1" $# "${2:-}"; tfile="$2"; shift 2 ;;
    --telemetry-dir) _need_val "$1" $# "${2:-}"; tdir="$2"; shift 2 ;;
    --ts) _need_val "$1" $# "${2:-}"; ts="$2"; shift 2 ;;
    *) print -u2 -- "story-telemetry start: unknown argument: $1"; exit 2 ;;
    esac
  done
  [[ -n "$run_file" ]] || { print -u2 -- "story-telemetry start: --run-file is required"; exit 2 }
  if [[ -n "$ts" ]]; then
    [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "story-telemetry start: --ts must be a non-negative integer (got: $ts)"; exit 2 }
  else
    ts=$(date +%s) && [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "story-telemetry start: could not read the clock"; exit 1 }
  fi
  ts=$(( 10#$ts ))
  # The same JSON-`null` hazard the --repo-type guard in `emit` closes, at the
  # other end of the pipeline: these two values are ALWAYS read out of `args`'
  # JSON, and a `jq -r` of an absent sink prints the four-character string
  # `null`. Taken literally it would become <cwd>/null — a sink file inside the
  # repo — for this run AND every loop parented to it, with nothing exiting
  # non-zero. `args` itself is deliberately left alone: its words are the user's
  # literal invocation, where `null` could only be a real path.
  [[ "$tfile" != "null" ]] || tfile=""
  [[ "$tdir" != "null" ]] || tdir=""
  [[ -n "$tfile" ]] && tfile="$(_abs_path "$tfile")"
  [[ -n "$tdir" ]] && tdir="$(_abs_path "$tdir")"
  local run_id="resolve-issue-${ts}-$(_rand4)"
  local doc=""
  doc=$(jq -nc --arg id "$run_id" --argjson ts "$ts" --arg f "$tfile" --arg d "$tdir" '
    {run_id:$id, ts:$ts,
     telemetry_file:(if $f == "" then null else $f end),
     telemetry_dir:(if $d == "" then null else $d end),
     loop_args:(["--parent-run-id", $id]
                + (if $f == "" then [] else ["--telemetry-file", $f] end)
                + (if $d == "" then [] else ["--telemetry-dir", $d] end))}') || {
    print -u2 -- "story-telemetry start: failed to build the run file"; exit 1 }
  { print -r -- "$doc" > "$run_file" } 2>/dev/null || {
    print -u2 -- "story-telemetry start: cannot write the run file: $run_file"; exit 1 }
  print -r -- "$doc"
}

# --- emit -------------------------------------------------------------------

_cmd_emit() {
  local run_file="" state_file="" repo_dir="" issue="" repo_type="" now=""
  local -a loop_wds=()
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
    --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
    --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
    --repo-type) _need_val "$1" $# "${2:-}"; repo_type="$2"; shift 2 ;;
    --loop-work-dir) _need_val "$1" $# "${2:-}"; loop_wds+=("$2"); shift 2 ;;
    --now) _need_val "$1" $# "${2:-}"; now="$2"; shift 2 ;;
    *) print -u2 -- "story-telemetry emit: unknown argument: $1"; exit 2 ;;
    esac
  done
  local a
  for a in "run-file:$run_file" "state:$state_file" "repo-dir:$repo_dir" "issue:$issue"; do
    [[ -n "${a#*:}" ]] || {
      print -u2 -- "story-telemetry emit: --${a%%:*} is required"; exit 2 }
  done
  [[ "$issue" == <-> && ${#issue} -le 18 ]] || {
    print -u2 -- "story-telemetry emit: --issue must be a non-negative integer (got: $issue)"; exit 2 }
  [[ -z "$now" || ( "$now" == <-> && ${#now} -le 18 ) ]] || {
    print -u2 -- "story-telemetry emit: --now must be a non-negative integer (got: $now)"; exit 2 }

  # From here on nothing is fatal: the run has finished, and its telemetry is a
  # by-product that must never change what the run reports.
  # The scratch files are script-global so every exit path — the advisory
  # included — can remove them without relying on a function-scoped trap.
  typeset -g tmp_state="" tmp_payload=""
  _advise() {
    rm -f -- ${tmp_state:+"$tmp_state"} ${tmp_payload:+"$tmp_payload"} 2>/dev/null
    print -ru2 -- "story-telemetry: resolve-issue record NOT emitted — $1 (the run's result is unaffected)"
    exit 0
  }

  command -v jq >/dev/null 2>&1 || _advise "jq not found on PATH"
  [[ -f "$run_file" && -r "$run_file" ]] || _advise "no readable run file at $run_file (was 'start' run?)"
  local run_id="" ts="" tfile="" tdir="" emitted=""
  run_id=$(jq -r '.run_id // empty' "$run_file" 2>/dev/null) || run_id=""
  ts=$(jq -r '.ts // empty' "$run_file" 2>/dev/null) || ts=""
  tfile=$(jq -r '.telemetry_file // empty' "$run_file" 2>/dev/null) || tfile=""
  tdir=$(jq -r '.telemetry_dir // empty' "$run_file" 2>/dev/null) || tdir=""
  emitted=$(jq -r '.emitted // false' "$run_file" 2>/dev/null) || emitted=""
  [[ "$run_id" == resolve-issue-<->-[0-9a-f][0-9a-f][0-9a-f][0-9a-f] ]] || \
    _advise "the run file carries no well-formed run_id"
  [[ "$ts" == <-> && ${#ts} -le 18 ]] || _advise "the run file carries no start stamp"
  # one record per run: a repeat call (a re-entered ending, a compacted context)
  # would otherwise append a second record under the same run_id
  [[ "$emitted" != "true" ]] || _advise "run $run_id was already emitted"
  [[ -f "$state_file" && -r "$state_file" ]] || _advise "no readable state file at $state_file"
  [[ -x "$BUILDER" ]] || _advise "payload builder missing or not executable: $BUILDER"
  [[ -x "$EMITTER" ]] || _advise "emitter missing or not executable: $EMITTER"

  tmp_state=$(mktemp 2>/dev/null) || { tmp_state=""; _advise "could not create a scratch file" }
  tmp_payload=$(mktemp 2>/dev/null) || { tmp_payload=""; _advise "could not create a scratch file" }

  # the loops' ids — each ledger line is one terminal record the loop emitted.
  # A work-dir with no ledger is a loop that emitted nothing, which is fine; a
  # work-dir that does not exist at all is a wrong path, and saying so is the
  # only thing that separates "no loop records" from "the join is broken".
  local ids_json="[]" wd="" ledger=""
  for wd in "${loop_wds[@]}"; do
    [[ -d "$wd" ]] || {
      print -ru2 -- "story-telemetry: --loop-work-dir is not a directory: $wd — its loop ids are not listed"
      continue }
    ledger="$wd/.telemetry-run-ids"
    [[ -r "$ledger" ]] || continue
    ids_json=$(jq -c --argjson acc "$ids_json" -R -s \
      '$acc + (split("\n") | map(select(length > 0)))' "$ledger" 2>/dev/null) || \
      _advise "could not read the loop run-id ledger at $ledger"
  done
  jq -c --argjson ids "$ids_json" \
    '.review_loop_run_ids = ((.review_loop_run_ids // []) + $ids)' "$state_file" \
    > "$tmp_state" 2>/dev/null || _advise "the state file is not a JSON object"

  local outcome="" pr=""
  "$BUILDER" --state "$tmp_state" > "$tmp_payload" || _advise "the payload builder rejected the state"
  outcome=$("$BUILDER" --state "$tmp_state" --print-outcome) || \
    _advise "the payload builder could not narrow the outcome"
  # the builder accepts any integer-valued number, so normalise the spelling:
  # jq keeps a literal `413.0` as written, which the emitter's --pr refuses
  pr=$(jq -r '.pr // empty | if type == "number" then (floor | tostring) else . end' \
    "$tmp_state" 2>/dev/null) || pr=""

  [[ -n "$now" ]] || now=$(date +%s 2>/dev/null) || now=""
  [[ "$now" == <-> ]] || _advise "could not read the clock for wall_s"
  local wall_s=$(( 10#$now - 10#$ts ))
  # a backwards clock step must not cost the record: the emitter rejects a
  # negative wall_s outright (the review loop clamps for the same reason)
  (( wall_s >= 0 )) || wall_s=0

  local -a emit_args=(--pipeline resolve-issue --kind run --outcome "$outcome"
    --run-id "$run_id" --ts "$ts" --wall-s "$wall_s" --issue "$issue"
    --repo-dir "$repo_dir" --payload "$tmp_payload")
  [[ -n "$pr" ]] && emit_args+=(--pr "$pr")
  # `!= "null"` as well as non-empty, exactly as resolve-story-loop.zsh guards
  # the same emitter flag: the conductor reads repo_type out of JSON, and a
  # `jq -r` of an absent one prints the four-character string `null`, which
  # would land as repo_type: "null" and mis-bucket the run for good
  [[ -n "$repo_type" && "$repo_type" != "null" ]] && emit_args+=(--repo-type "$repo_type")
  [[ -n "$tfile" ]] && emit_args+=(--telemetry-file "$tfile")
  [[ -n "$tdir" ]] && emit_args+=(--telemetry-dir "$tdir")

  local rec="" rc=0
  rec=$("$EMITTER" "${emit_args[@]}") || rc=$?
  (( rc == 0 )) || _advise "the emitter exited $rc (its own diagnostic is above)"
  rm -f -- "$tmp_state" "$tmp_payload" 2>/dev/null
  # mark the run emitted — best-effort: the record has landed, and a failed
  # mark only loses the repeat guard, never the record
  local marked=""
  marked=$(jq -c '.emitted = true' "$run_file" 2>/dev/null) && [[ -n "$marked" ]] && \
    { { print -r -- "$marked" > "$run_file" } 2>/dev/null || true }
  print -r -- "$rec"
}

(( $# > 0 )) || { print -ru2 -- "$usage"; exit 2 }
local sub="$1"; shift
case "$sub" in
  args)  _cmd_args "$@" ;;
  start) _cmd_start "$@" ;;
  emit)  _cmd_emit "$@" ;;
  -h|--help) print -r -- "$usage" ;;
  *) print -u2 -- "story-telemetry: unknown subcommand: $sub"; print -ru2 -- "$usage"; exit 2 ;;
esac
