#!/usr/bin/env zsh
# maintenance-telemetry.zsh — the /development:maintenance run's own telemetry,
# as two deterministic steps the skill calls instead of improvising them (epic
# #741, child (c) — issue #1228). The judgement stays in the skill (what the
# run's facts were); everything mechanical — stamping the start, pre-minting the
# run_id, remembering it for a later --resume, and the never-fatal build + emit —
# lives here, where bats can reach it. It follows ARCHITECTURE.md's *Per-pipeline
# telemetry instrumentation* conventions, as resolve-issue's story-telemetry.zsh
# does.
#
#   maintenance-telemetry.zsh start --run-file FILE [--telemetry-file PATH]
#       [--telemetry-dir DIR] [--checkpoint-dir DIR] [--resume] [--ts EPOCH]
#       Stamp the run's start and PRE-MINT its run_id in the emitter's own
#       format, `maintenance-<ts>-<4 hex>`. Writes {run_id, ts, telemetry_file,
#       telemetry_dir, resumed_from_run_id} to FILE (a scratch path outside the
#       repo) and prints it; the sink paths are made absolute (a leading `~`
#       expanded first). With --checkpoint-dir (the store `checkpoint.zsh dir`
#       prints) the new run_id is also written to DIR/telemetry-run-id, so an
#       interrupted run can be named by the run that resumes it: with --resume,
#       the id found there BEFORE it is overwritten becomes
#       resumed_from_run_id (null when absent or malformed — "when recoverable").
#       Both checkpoint touches are best-effort: a failure warns and never stops
#       the run. Exit 1 only when the clock or the run file fails — the skill
#       then runs without a record.
#
#   maintenance-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR
#       [--stages FILE] [--v2-payload FILE ...] [--repo-type T] [--now EPOCH]
#       Build the payload (build-maintenance-telemetry-record.zsh), fold the
#       outcome, and emit ONE `kind: "run"` record through the shared emitter
#       with `--pipeline maintenance`, the pre-minted `--run-id`, `--ts` = the
#       start stamp, `--wall-s` = now − start, and the run's sink flags. The run
#       file's resumed_from_run_id overrides the state's, and each --v2-payload
#       (a constructed Phase 4 payload, as dispatched) replaces state.payloads —
#       so findings_by_tool is counted from exactly what was dispatched. Prints
#       the record and marks the run file `emitted: true`; a repeated `emit` is
#       refused with the advisory rather than appending a second record.
#       NEVER FATAL: any failure past argument parsing — a missing run file, a
#       run already emitted, a state the builder refuses, an emitter that is
#       absent, non-executable or exits non-zero — prints ONE advisory line on
#       stderr, emits nothing, and exits 0. The emitter appends nothing on a
#       non-zero exit, so no partial record reaches a sink.
#
# Seams (tests only; unset in production):
#   MAINTENANCE_TELEMETRY_EMITTER_BIN  the emitter (a PATH)
#   MAINTENANCE_TELEMETRY_BUILDER_BIN  the payload builder (a PATH)
#
# Exit codes: 0 ok (and every never-fatal emit outcome) · 2 usage · 1 internal
# (`start` only: a clock it cannot read, a run file it cannot write).

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local EMITTER="${MAINTENANCE_TELEMETRY_EMITTER_BIN:-${self_dir}/../../../scripts/telemetry/emit-telemetry.zsh}"
local BUILDER="${MAINTENANCE_TELEMETRY_BUILDER_BIN:-${self_dir}/build-maintenance-telemetry-record.zsh}"

local usage="usage: maintenance-telemetry.zsh start --run-file FILE [--telemetry-file PATH] [--telemetry-dir DIR]
                                       [--checkpoint-dir DIR] [--resume] [--ts EPOCH]
       maintenance-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR [--stages FILE]
                                      [--v2-payload FILE ...] [--repo-type T] [--now EPOCH]"

_abs_path() {  # $1 = path; prints the absolute spelling (a leading ~ expanded)
  local p="$1"
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="${HOME}${p#\~}"
  print -r -- "${p:a}"
}

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "maintenance-telemetry: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "maintenance-telemetry: $1 requires a non-empty value"; exit 2 }
}

# The emitter's own id suffix — 4 hex from urandom (story-telemetry.zsh keeps
# the same deliberate copy; the FORMAT is what must not drift).
_rand4() {
  local h=""
  if [[ -r /dev/urandom ]]; then
    h=$(LC_ALL=C od -An -tx1 -N2 /dev/urandom 2>/dev/null | tr -d ' \n') || h=""
  fi
  [[ ${#h} -ge 4 ]] || h=$(printf '%04x' $(( RANDOM & 0xffff )))
  printf '%s' "${h:0:4}"
}

local RUN_ID_PAT='maintenance-<->-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'

# --- start ------------------------------------------------------------------

_cmd_start() {
  local run_file="" tfile="" tdir="" ckdir="" resume=0 ts=""
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --telemetry-file) _need_val "$1" $# "${2:-}"; tfile="$2"; shift 2 ;;
    --telemetry-dir) _need_val "$1" $# "${2:-}"; tdir="$2"; shift 2 ;;
    --checkpoint-dir) _need_val "$1" $# "${2:-}"; ckdir="$2"; shift 2 ;;
    --resume) resume=1; shift ;;
    --ts) _need_val "$1" $# "${2:-}"; ts="$2"; shift 2 ;;
    *) print -u2 -- "maintenance-telemetry start: unknown argument: $1"; exit 2 ;;
    esac
  done
  [[ -n "$run_file" ]] || { print -u2 -- "maintenance-telemetry start: --run-file is required"; exit 2 }
  if [[ -n "$ts" ]]; then
    [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "maintenance-telemetry start: --ts must be a non-negative integer (got: $ts)"; exit 2 }
  else
    ts=$(date +%s) && [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "maintenance-telemetry start: could not read the clock"; exit 1 }
  fi
  ts=$(( 10#$ts ))
  [[ -n "$tfile" ]] && tfile="$(_abs_path "$tfile")"
  [[ -n "$tdir" ]] && tdir="$(_abs_path "$tdir")"
  local run_id="maintenance-${ts}-$(_rand4)"

  # The interrupted run's id, read BEFORE this run overwrites it. Anything not
  # shaped like a maintenance run_id is "not recoverable", never guessed at.
  local prev=""
  if (( resume )) && [[ -n "$ckdir" && -r "$ckdir/telemetry-run-id" ]]; then
    prev="$(<"$ckdir/telemetry-run-id")" 2>/dev/null || prev=""
    prev="${prev%%$'\n'*}"
    [[ "$prev" == ${~RUN_ID_PAT} ]] || prev=""
  fi
  if [[ -n "$ckdir" ]]; then
    { print -r -- "$run_id" > "$ckdir/telemetry-run-id" } 2>/dev/null || \
      print -u2 -- "maintenance-telemetry start: could not record the run_id in $ckdir (a later --resume will not name this run)"
  fi

  local doc=""
  doc=$(jq -nc --arg id "$run_id" --argjson ts "$ts" --arg f "$tfile" --arg d "$tdir" --arg p "$prev" '
    {run_id:$id, ts:$ts,
     telemetry_file:(if $f == "" then null else $f end),
     telemetry_dir:(if $d == "" then null else $d end),
     resumed_from_run_id:(if $p == "" then null else $p end)}') || {
    print -u2 -- "maintenance-telemetry start: failed to build the run file"; exit 1 }
  { print -r -- "$doc" > "$run_file" } 2>/dev/null || {
    print -u2 -- "maintenance-telemetry start: cannot write the run file: $run_file"; exit 1 }
  print -r -- "$doc"
}

# --- emit -------------------------------------------------------------------

_cmd_emit() {
  local run_file="" state_file="" stages_file="" repo_dir="" repo_type="" now=""
  local -a v2_files=()
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
    --stages) _need_val "$1" $# "${2:-}"; stages_file="$2"; shift 2 ;;
    --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
    --repo-type) _need_val "$1" $# "${2:-}"; repo_type="$2"; shift 2 ;;
    --v2-payload) _need_val "$1" $# "${2:-}"; v2_files+=("$2"); shift 2 ;;
    --now) _need_val "$1" $# "${2:-}"; now="$2"; shift 2 ;;
    *) print -u2 -- "maintenance-telemetry emit: unknown argument: $1"; exit 2 ;;
    esac
  done
  local a
  for a in "run-file:$run_file" "state:$state_file" "repo-dir:$repo_dir"; do
    [[ -n "${a#*:}" ]] || {
      print -u2 -- "maintenance-telemetry emit: --${a%%:*} is required"; exit 2 }
  done
  [[ -z "$now" || ( "$now" == <-> && ${#now} -le 18 ) ]] || {
    print -u2 -- "maintenance-telemetry emit: --now must be a non-negative integer (got: $now)"; exit 2 }

  # From here on nothing is fatal: the run has finished, and its telemetry is a
  # by-product that must never change what the run reports.
  typeset -g tmp_state="" tmp_payload=""
  _advise() {
    rm -f -- ${tmp_state:+"$tmp_state"} ${tmp_payload:+"$tmp_payload"} 2>/dev/null
    print -ru2 -- "maintenance-telemetry: maintenance record NOT emitted — $1 (the run's result is unaffected)"
    exit 0
  }

  command -v jq >/dev/null 2>&1 || _advise "jq not found on PATH"
  [[ -f "$run_file" && -r "$run_file" ]] || _advise "no readable run file at $run_file (was 'start' run?)"
  local run_id="" ts="" tfile="" tdir="" emitted="" prev=""
  run_id=$(jq -r '.run_id // empty' "$run_file" 2>/dev/null) || run_id=""
  ts=$(jq -r '.ts // empty' "$run_file" 2>/dev/null) || ts=""
  tfile=$(jq -r '.telemetry_file // empty' "$run_file" 2>/dev/null) || tfile=""
  tdir=$(jq -r '.telemetry_dir // empty' "$run_file" 2>/dev/null) || tdir=""
  emitted=$(jq -r '.emitted // false' "$run_file" 2>/dev/null) || emitted=""
  prev=$(jq -c '.resumed_from_run_id // null' "$run_file" 2>/dev/null) || prev="null"
  [[ "$run_id" == ${~RUN_ID_PAT} ]] || _advise "the run file carries no well-formed run_id"
  [[ "$ts" == <-> && ${#ts} -le 18 ]] || _advise "the run file carries no start stamp"
  [[ "$emitted" != "true" ]] || _advise "run $run_id was already emitted"
  [[ -f "$state_file" && -r "$state_file" ]] || _advise "no readable state file at $state_file"
  [[ -z "$stages_file" || ( -f "$stages_file" && -r "$stages_file" ) ]] || \
    _advise "no readable stages file at $stages_file"
  [[ -x "$BUILDER" ]] || _advise "payload builder missing or not executable: $BUILDER"
  [[ -x "$EMITTER" ]] || _advise "emitter missing or not executable: $EMITTER"

  tmp_state=$(mktemp 2>/dev/null) || { tmp_state=""; _advise "could not create a scratch file" }
  tmp_payload=$(mktemp 2>/dev/null) || { tmp_payload=""; _advise "could not create a scratch file" }

  # The dispatched payloads, as dispatched: each must be one JSON object. Only
  # its findings_by_tool reaches the state, so a 10 KB release-notes body costs
  # nothing past this read.
  local payloads="[]" f="" one=""
  for f in "${v2_files[@]}"; do
    one=$(jq -e -s -c 'if length == 1 and (.[0] | type == "object")
                        then {findings_by_tool: (.[0].findings_by_tool // {})} else error end' \
      "$f" 2>/dev/null) || _advise "the v2 payload $f is not one readable JSON object"
    payloads=$(jq -nc --argjson acc "$payloads" --argjson one "$one" '$acc + [$one]') || \
      _advise "could not collect the v2 payloads"
  done
  local -a merge=(--argjson prev "$prev")
  local prog='.resumed_from_run_id = $prev'
  if (( ${#v2_files} )); then
    merge+=(--argjson payloads "$payloads"); prog+=' | .payloads = $payloads'
  fi
  jq -c "${merge[@]}" "if type == \"object\" then $prog else error end" "$state_file" \
    > "$tmp_state" 2>/dev/null || _advise "the state file is not a JSON object"

  local -a bargs=(--state "$tmp_state")
  [[ -n "$stages_file" ]] && bargs+=(--stages "$stages_file")
  local outcome=""
  "$BUILDER" "${bargs[@]}" > "$tmp_payload" || _advise "the payload builder refused the state"
  outcome=$("$BUILDER" "${bargs[@]}" --print-outcome) || _advise "the payload builder could not fold the outcome"

  [[ -n "$now" ]] || now=$(date +%s 2>/dev/null) || now=""
  [[ "$now" == <-> ]] || _advise "could not read the clock for wall_s"
  local wall_s=$(( 10#$now - 10#$ts ))
  (( wall_s >= 0 )) || wall_s=0   # a backwards clock step must not cost the record

  local -a emit_args=(--pipeline maintenance --kind run --outcome "$outcome"
    --run-id "$run_id" --ts "$ts" --wall-s "$wall_s"
    --repo-dir "$repo_dir" --payload "$tmp_payload")
  [[ -n "$repo_type" && "$repo_type" != "null" ]] && emit_args+=(--repo-type "$repo_type")
  [[ -n "$tfile" ]] && emit_args+=(--telemetry-file "$tfile")
  [[ -n "$tdir" ]] && emit_args+=(--telemetry-dir "$tdir")

  local rec="" rc=0
  rec=$("$EMITTER" "${emit_args[@]}") || rc=$?
  (( rc == 0 )) || _advise "the emitter exited $rc (its own diagnostic is above)"
  rm -f -- "$tmp_state" "$tmp_payload" 2>/dev/null
  # best-effort: the record has landed; a failed mark only loses the repeat guard
  local marked=""
  marked=$(jq -c '.emitted = true' "$run_file" 2>/dev/null) && [[ -n "$marked" ]] && \
    { { print -r -- "$marked" > "$run_file" } 2>/dev/null || true }
  print -r -- "$rec"
}

(( $# > 0 )) || { print -ru2 -- "$usage"; exit 2 }
local sub="$1"; shift
case "$sub" in
  start) _cmd_start "$@" ;;
  emit)  _cmd_emit "$@" ;;
  -h|--help) print -r -- "$usage" ;;
  *) print -u2 -- "maintenance-telemetry: unknown subcommand: $sub"; print -ru2 -- "$usage"; exit 2 ;;
esac
