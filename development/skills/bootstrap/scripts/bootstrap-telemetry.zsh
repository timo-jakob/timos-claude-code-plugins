#!/usr/bin/env zsh
# bootstrap-telemetry.zsh — the /development:bootstrap run's own telemetry, as
# two deterministic steps the skill calls instead of improvising them (epic
# #741, child (d) — issue #1229). The judgement stays in the skill (what the
# run's facts were); everything mechanical — stamping the start, pre-minting the
# run_id, reading the host, siting the record in the TARGET repo, and the
# never-fatal build + emit — lives here, where bats can reach it. It follows
# ARCHITECTURE.md's *Per-pipeline telemetry instrumentation* conventions, as
# resolve-issue's story-telemetry.zsh and maintenance-telemetry.zsh do.
#
#   bootstrap-telemetry.zsh start --run-file FILE [--telemetry-file PATH]
#       [--telemetry-dir DIR] [--ts EPOCH]
#       Stamp the run's start (the wall_s origin) and PRE-MINT its run_id in the
#       emitter's own format, `bootstrap-<ts>-<4 hex>`. Also reads the host —
#       `os` from `uname -s` (Darwin → macos, Linux → linux, anything else
#       lower-cased) and `homebrew` from whether `brew` is on PATH — so the
#       record can say why Step 4.5 could not run. Writes {run_id, ts,
#       telemetry_file, telemetry_dir, host} to FILE (a scratch path outside the
#       target repo) and prints it; the sink paths are made absolute (a leading
#       `~` expanded first). Exit 1 only when the clock or the run file fails —
#       the skill then runs without a record, and nothing else changes.
#
#   bootstrap-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR
#       [--now EPOCH]
#       Build the payload (build-bootstrap-telemetry-record.zsh), fold the
#       outcome, and emit ONE `kind: "run"` record through the shared emitter
#       with `--pipeline bootstrap`, the pre-minted `--run-id`, `--ts` = the
#       start stamp, `--wall-s` = now − start, the state's `pr` and the run's
#       sink flags. The run file's host replaces the state's.
#       SITING: DIR is resolved to the target's MAIN checkout — `dirname` of the
#       absolute `git rev-parse --git-common-dir` — so a run from a linked
#       worktree (which Step 4g deletes) still lands in the target's own sink,
#       and the envelope `repo` is derived from the target, never from the
#       directory this script was called from. A DIR that is not its own
#       checkout's root (a State A folder, even one nested in another repo) is
#       used as it is, and its basename is passed as the emitter's `--repo`.
#       Prints the record and marks the run file `emitted: true`; a repeated
#       `emit` is refused with the advisory rather than appending a second one.
#       NEVER FATAL: any failure past argument parsing — a missing run file, a
#       run already emitted, a state the builder refuses, an emitter that is
#       absent, non-executable or exits non-zero — prints ONE advisory line on
#       stderr, emits nothing, and exits 0. The emitter appends nothing on a
#       non-zero exit, so no partial record reaches a sink.
#
# Seams (tests only; unset in production):
#   BOOTSTRAP_TELEMETRY_EMITTER_BIN  the emitter (a PATH)
#   BOOTSTRAP_TELEMETRY_BUILDER_BIN  the payload builder (a PATH)
#
# Exit codes: 0 ok (and every never-fatal emit outcome) · 2 usage · 1 internal
# (`start` only: a clock it cannot read, a run file it cannot write).

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local EMITTER="${BOOTSTRAP_TELEMETRY_EMITTER_BIN:-${self_dir}/../../../scripts/telemetry/emit-telemetry.zsh}"
local BUILDER="${BOOTSTRAP_TELEMETRY_BUILDER_BIN:-${self_dir}/build-bootstrap-telemetry-record.zsh}"

local usage="usage: bootstrap-telemetry.zsh start --run-file FILE [--telemetry-file PATH] [--telemetry-dir DIR] [--ts EPOCH]
       bootstrap-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR [--now EPOCH]"

_abs_path() {  # $1 = path; prints the absolute spelling (a leading ~ expanded)
  local p="$1"
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="${HOME}${p#\~}"
  print -r -- "${p:a}"
}

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "bootstrap-telemetry: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "bootstrap-telemetry: $1 requires a non-empty value"; exit 2 }
}

# The emitter's own id suffix — 4 hex from urandom (story-telemetry.zsh and
# maintenance-telemetry.zsh keep the same deliberate copy; the FORMAT is what
# must not drift).
_rand4() {
  local h=""
  if [[ -r /dev/urandom ]]; then
    h=$(LC_ALL=C od -An -tx1 -N2 /dev/urandom 2>/dev/null | tr -d ' \n') || h=""
  fi
  [[ ${#h} -ge 4 ]] || h=$(printf '%04x' $(( RANDOM & 0xffff )))
  printf '%s' "${h:0:4}"
}

local RUN_ID_PAT='bootstrap-<->-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'

# --- start ------------------------------------------------------------------

_cmd_start() {
  local run_file="" tfile="" tdir="" ts=""
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --telemetry-file) _need_val "$1" $# "${2:-}"; tfile="$2"; shift 2 ;;
    --telemetry-dir) _need_val "$1" $# "${2:-}"; tdir="$2"; shift 2 ;;
    --ts) _need_val "$1" $# "${2:-}"; ts="$2"; shift 2 ;;
    *) print -u2 -- "bootstrap-telemetry start: unknown argument: $1"; exit 2 ;;
    esac
  done
  [[ -n "$run_file" ]] || { print -u2 -- "bootstrap-telemetry start: --run-file is required"; exit 2 }
  if [[ -n "$ts" ]]; then
    [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "bootstrap-telemetry start: --ts must be a non-negative integer (got: $ts)"; exit 2 }
  else
    ts=$(date +%s) && [[ "$ts" == <-> && ${#ts} -le 18 ]] || {
      print -u2 -- "bootstrap-telemetry start: could not read the clock"; exit 1 }
  fi
  ts=$(( 10#$ts ))
  [[ -n "$tfile" ]] && tfile="$(_abs_path "$tfile")"
  [[ -n "$tdir" ]] && tdir="$(_abs_path "$tdir")"
  local run_id="bootstrap-${ts}-$(_rand4)"

  # The host, read once here so the record says why Step 4.5 could not run.
  local os="" brew=false
  os=$(uname -s 2>/dev/null) || os=""
  case "$os" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    "") os=unknown ;;
    *) os="${(L)os}" ;;
  esac
  command -v brew >/dev/null 2>&1 && brew=true

  local doc=""
  doc=$(jq -nc --arg id "$run_id" --argjson ts "$ts" --arg f "$tfile" --arg d "$tdir" \
          --arg os "$os" --argjson brew "$brew" '
    {run_id:$id, ts:$ts,
     telemetry_file:(if $f == "" then null else $f end),
     telemetry_dir:(if $d == "" then null else $d end),
     host:{os:$os, homebrew:$brew}}') || {
    print -u2 -- "bootstrap-telemetry start: failed to build the run file"; exit 1 }
  { print -r -- "$doc" > "$run_file" } 2>/dev/null || {
    print -u2 -- "bootstrap-telemetry start: cannot write the run file: $run_file"; exit 1 }
  print -r -- "$doc"
}

# --- emit -------------------------------------------------------------------

_cmd_emit() {
  local run_file="" state_file="" repo_dir="" now=""
  while (( $# > 0 )); do
    case "$1" in
    --run-file) _need_val "$1" $# "${2:-}"; run_file="$2"; shift 2 ;;
    --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
    --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
    --now) _need_val "$1" $# "${2:-}"; now="$2"; shift 2 ;;
    *) print -u2 -- "bootstrap-telemetry emit: unknown argument: $1"; exit 2 ;;
    esac
  done
  local a
  for a in "run-file:$run_file" "state:$state_file" "repo-dir:$repo_dir"; do
    [[ -n "${a#*:}" ]] || {
      print -u2 -- "bootstrap-telemetry emit: --${a%%:*} is required"; exit 2 }
  done
  [[ -z "$now" || ( "$now" == <-> && ${#now} -le 18 ) ]] || {
    print -u2 -- "bootstrap-telemetry emit: --now must be a non-negative integer (got: $now)"; exit 2 }

  # From here on nothing is fatal: the run has finished, and its telemetry is a
  # by-product that must never change what the run reports.
  typeset -g tmp_state="" tmp_payload=""
  _advise() {
    rm -f -- ${tmp_state:+"$tmp_state"} ${tmp_payload:+"$tmp_payload"} 2>/dev/null
    print -ru2 -- "bootstrap-telemetry: bootstrap record NOT emitted — $1 (the run's result is unaffected)"
    exit 0
  }

  command -v jq >/dev/null 2>&1 || _advise "jq not found on PATH"
  [[ -f "$run_file" && -r "$run_file" ]] || _advise "no readable run file at $run_file (was 'start' run?)"
  local run_id="" ts="" tfile="" tdir="" emitted="" host="null"
  run_id=$(jq -r '.run_id // empty' "$run_file" 2>/dev/null) || run_id=""
  ts=$(jq -r '.ts // empty' "$run_file" 2>/dev/null) || ts=""
  tfile=$(jq -r '.telemetry_file // empty' "$run_file" 2>/dev/null) || tfile=""
  tdir=$(jq -r '.telemetry_dir // empty' "$run_file" 2>/dev/null) || tdir=""
  emitted=$(jq -r '.emitted // false' "$run_file" 2>/dev/null) || emitted=""
  host=$(jq -c '.host // null' "$run_file" 2>/dev/null) || host="null"
  [[ "$run_id" == ${~RUN_ID_PAT} ]] || _advise "the run file carries no well-formed run_id"
  [[ "$ts" == <-> && ${#ts} -le 18 ]] || _advise "the run file carries no start stamp"
  [[ "$emitted" != "true" ]] || _advise "run $run_id was already emitted"
  [[ -f "$state_file" && -r "$state_file" ]] || _advise "no readable state file at $state_file"
  [[ -d "$repo_dir" ]] || _advise "--repo-dir is not a directory: $repo_dir"
  [[ -x "$BUILDER" ]] || _advise "payload builder missing or not executable: $BUILDER"
  [[ -x "$EMITTER" ]] || _advise "emitter missing or not executable: $EMITTER"

  # Site the record in the target's MAIN checkout: a linked worktree's common
  # dir is the main checkout's .git, so its dirname is the checkout every
  # worktree of the target shares. Only DIR's own work-tree root is resolved —
  # git searches upward, so a folder nested in another repo would otherwise
  # borrow that repo, and a submodule's common dir sits in .git/modules.
  # The envelope `repo` follows the same rule: a site that is its own root
  # yields its own `origin` (the emitter's host-based rule, read at that root,
  # which has nothing above it to borrow); any other site is handed its
  # basename as `--repo`, so the emitter never searches upward for one.
  local site="${repo_dir:a}" common="" top="" own_root=0
  top=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  common=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  [[ -n "$top" && "${top:A}" == "${repo_dir:A}" && "$common" == /*/.git ]] && { site="${common:h}"; own_root=1 }

  tmp_state=$(mktemp 2>/dev/null) || { tmp_state=""; _advise "could not create a scratch file" }
  tmp_payload=$(mktemp 2>/dev/null) || { tmp_payload=""; _advise "could not create a scratch file" }

  local prog='if type == "object" then . else error end'
  [[ "$host" != "null" ]] && prog+=' | .host = $host'
  jq -c --argjson host "$host" "$prog" "$state_file" > "$tmp_state" 2>/dev/null || \
    _advise "the state file is not a JSON object"
  local pr=""
  pr=$(jq -r 'if (.pr | type) == "number" then .pr else empty end' "$tmp_state" 2>/dev/null) || pr=""

  local outcome=""
  "$BUILDER" --state "$tmp_state" > "$tmp_payload" || _advise "the payload builder refused the state"
  outcome=$("$BUILDER" --state "$tmp_state" --print-outcome) || \
    _advise "the payload builder could not fold the outcome"

  [[ -n "$now" ]] || now=$(date +%s 2>/dev/null) || now=""
  [[ "$now" == <-> ]] || _advise "could not read the clock for wall_s"
  local wall_s=$(( 10#$now - 10#$ts ))
  (( wall_s >= 0 )) || wall_s=0   # a backwards clock step must not cost the record

  local -a emit_args=(--pipeline bootstrap --kind run --outcome "$outcome"
    --run-id "$run_id" --ts "$ts" --wall-s "$wall_s"
    --repo-dir "$site" --payload "$tmp_payload")
  (( own_root )) || emit_args+=(--repo "${site:t}")
  [[ -n "$pr" ]] && emit_args+=(--pr "$pr")
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
  *) print -u2 -- "bootstrap-telemetry: unknown subcommand: $sub"; print -ru2 -- "$usage"; exit 2 ;;
esac
