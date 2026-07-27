#!/usr/bin/env zsh
# rollup-telemetry.zsh — a thin, stream-generic `jq` rollup over `telemetry/v1`
# streams (epic #740, child (e) — issue #1007).
#
# Why this exists: a human wanting "how is this repo's pipeline doing?" should
# not need Grafana. This gives that in one command, with zero infrastructure,
# over any telemetry/v1 stream — the local sink, the (d) #1006 cross-repo
# directory, or a raw pipe — AND over the two pre-contract legacy files that
# predate the contract (review-loop.jsonl / refine-issue.jsonl), which it reads
# via a built-in v0->v1 adapter (no file migration is ever performed; see
# ARCHITECTURE.md, "The telemetry/v1 contract").
#
# Usage:
#   rollup-telemetry.zsh [FILE|DIR|-] [--repo OWNER/NAME] [--pipeline NAME] [--json] [-h|--help]
#
#   With no operand, reads the local default sink
#   (.claude/telemetry/telemetry.jsonl, relative to the current directory) —
#   silently treated as an empty stream if it does not exist yet (nothing has
#   ever emitted). An explicit FILE/DIR operand that is missing or unreadable is
#   a usage error instead: naming a path is a claim it exists.
#
#   FILE   a single JSONL stream.
#   DIR    every *.jsonl directly inside it (non-recursive, plain files only —
#          a directory or dangling symlink named `*.jsonl` is ignored) is read
#          and aggregated; anything else in the directory is ignored. This is
#          the (d) #1006 shared cross-repo layout.
#   -      stdin, so the rollup composes in a pipe.
#   --     end of options; EVERY remaining argument is positional, so a file
#          named `-shared.jsonl` can be given (a (d) shared-directory case) —
#          and flags may not follow it (a second operand is a usage error).
#
#   --repo OWNER/NAME   keep only records attributed to this repo, matched
#                       CASE-INSENSITIVELY (GitHub identities are
#                       case-insensitive but case-preserving, so the same repo
#                       can reach the sink as `Foo/Bar` from one remote and
#                       `foo/bar` from a caller-supplied --repo). A record
#                       with no `repo` (every legacy v0 record) is attributed to
#                       an `unknown` bucket; an unfiltered run counts it, this
#                       flag EXCLUDES it — and the report says so explicitly,
#                       naming how many were excluded (to stderr, in both text
#                       and --json mode — never a silent drop). `--repo unknown`
#                       is the one exception: it SELECTS the unknown bucket
#                       rather than excluding it, so nothing is reported
#                       excluded in that case.
#   --pipeline NAME     keep only this pipeline. Reports exactly one section for
#                       it even when it matches nothing (so "I looked, there's
#                       genuinely none" is distinguishable from a bug), UNLESS
#                       no RUN records remain once --repo has been applied —
#                       the stream held none at all, it held only records the
#                       rollup excludes (enrichments, off-enum kinds, non-v1
#                       schemas, malformed lines), or --repo emptied it — that
#                       is the "no records" case below, not a synthesized zero
#                       section. Emptiness is judged AFTER --repo and BEFORE
#                       this filter, so --repo excluding everything wins.
#   --json              emit a JSON array instead of the text report. See the
#                       shape note below.
#
# Reports, per pipeline: run count, outcome mix (success/parked/escalated/
# failed), mean rounds, mean wall_s, escalation rate. Any measure whose divisor
# is zero (nothing in the group carries that field, or the group itself is
# empty) is WITHHELD, never guessed: "-" in the text report, `null` (key still
# present) under --json. `mean wall_s` AND `mean rounds` are deliberately
# PER-RECORD means, not per-loop — consecutive records of one extended
# review-loop run (escalate -> grant more rounds -> resume) overlap in both
# span and rounds, and grouping them back into one loop is out of scope here
# (ARCHITECTURE.md has the per-loop recipes for that; averaging `rounds` over
# all of a pipeline's records, as this rollup does, is not the same number as
# any one loop's round count).
#
# --json shape: an array of per-pipeline objects, `unknown` included as just
# another entry — no cross-pipeline totals object anywhere:
#   [{"pipeline":"review-loop","run_count":2,
#     "outcome_mix":{"success":1,"parked":0,"escalated":1,"failed":0},
#     "mean_rounds":5,"mean_wall_s":4132,"escalation_rate":0.5}, ...]
#
# v0 (legacy) attribution rules — every pre-contract record carries no
# `schema`, no `pipeline` key:
#   pipeline: filename first (review-loop.jsonl -> review-loop,
#     refine-issue.jsonl -> refine-issue), else shape-sniff (a record with
#     `status` AND `findings_by_round` -> review-loop; a record with
#     `objections_raised` -> refine-issue), else `unknown`.
#   outcome: narrowed according to the ATTRIBUTED pipeline (mirroring the
#     (b)/(c) retrofits' own narrowing) — for `review-loop`, its `status`:
#     CONVERGED/SKIPPED -> success, every ESCALATE_*/BUDGET_EXHAUSTED ->
#     escalated, ERROR -> failed; for `refine-issue`, its `outcome`:
#     refined-ready -> success, parked -> parked; anything else (including an
#     `unknown`-pipeline record) -> failed, the same never-a-guess catch-all
#     the retrofits use.
#   repo: always `unknown` (no legacy record ever carried one).
#   `kind: "enrichment"` records are excluded from every count (v1 only; no
#   legacy record is ever an enrichment). A v1 record whose `schema` is present
#   but is NOT `"telemetry/v1"` (a future `telemetry/v2`+) is excluded entirely
#   rather than read through the v1 path — a version-tolerant read would report
#   numbers derived from a superseded envelope.
#
# A field's off-contract TYPE never crashes the rollup: a `kind` outside
# run/enrichment, an `outcome` outside the 4-value enum, a non-numeric
# `wall_s`/`rounds`, or a non-object `payload` is handled defensively rather
# than raising a jq type error that would abort the whole run over one bad
# record. The three policies differ deliberately: an off-enum `kind` is
# EXCLUDED (treated as not-a-run — including an explicit `null`/`false`, since
# only an ABSENT key defaults to `run`), an off-enum `outcome` is COERCED to
# `failed` and kept, and a bad numeric is WITHHELD as null.
#
# Exit codes (the shared taxonomy emit-telemetry.zsh / validate-telemetry.zsh
# use):
#   0  success — including an empty stream, a stream a filter emptied out, and
#      a stream whose malformed lines were skipped (with a warning each, to
#      stderr; the exit stays 0 either way)
#   2  usage — unknown flag, a value flag with no value, more than one
#      positional operand, an explicit FILE/DIR operand (including an empty
#      string) that is missing or unreadable
#   3  internal — jq missing, a scratch-file failure, a source that existed and
#      was nameable but could not actually be read (as opposed to a
#      line-level malformation, which warns and stays exit 0), or a failure in
#      the aggregation pass

emulate -L zsh
setopt nounset pipefail

trap '' PIPE

local operand="" operand_seen="" repo_filter="" pipeline_filter="" json_mode=""
local usage="usage: rollup-telemetry.zsh [FILE|DIR|-] [--repo OWNER/NAME] [--pipeline NAME] [--json] [-h|--help]

With no operand, reads the local default sink .claude/telemetry/telemetry.jsonl
(silently empty if it does not exist yet). DIR reads every *.jsonl directly
inside it. - reads stdin. -- ends option parsing."

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || {
    print -ru2 -- "rollup-telemetry: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -ru2 -- "rollup-telemetry: $1 requires a value (got the flag $3)"; exit 2 }
}
_need_nonempty() {  # $1 = flag, $2 = value
  [[ -n "$2" ]] || {
    print -ru2 -- "rollup-telemetry: $1 requires a non-empty value"; exit 2 }
}
_take_operand() {  # $1 = candidate operand
  [[ -z "$operand_seen" ]] || {
    print -ru2 -- "rollup-telemetry: only one input may be given (got extra: $1)
$usage"; exit 2 }
  operand="$1"; operand_seen=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; repo_filter="$2"; shift 2 ;;
  --pipeline) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; pipeline_filter="$2"; shift 2 ;;
  --json) json_mode=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  --) # end of options — every remaining argument is positional
    shift
    while [[ $# -gt 0 ]]; do
      _take_operand "$1"; shift
    done
    ;;
  -) # stdin, spelled explicitly — still only ONE input
    _take_operand "-"; shift ;;
  -*) print -ru2 -- "rollup-telemetry: unknown flag: $1"; exit 2 ;;
  *)
    _take_operand "$1"; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  print -ru2 -- "rollup-telemetry: jq not found on PATH"; exit 3 }

# --- resolve the source list: an array of (label, readable-path) pairs -------
# label drives v0 filename-first attribution; "-" (stdin) and the default
# sink's own basename ("telemetry.jsonl") never match the two canonical legacy
# filenames, so they fall straight through to shape-sniff, which is the correct
# behaviour for a stream mixing several pipelines (the default sink, and any
# (d) shared file).

typeset -a src_labels src_paths

# Branch on whether an operand was GIVEN (operand_seen), never on whether its
# VALUE is empty: an explicit `rollup-telemetry.zsh ""` (e.g. a wrapper script
# forwarding an unset variable) names a path, even an empty one, and the
# documented contract is that naming a path is a claim it exists — it must
# fall through to the same existence check every other explicit operand does,
# never silently read the default sink instead.
if [[ -z "$operand_seen" ]]; then
  local default_sink=".claude/telemetry/telemetry.jsonl"
  if [[ -e "$default_sink" ]]; then
    src_labels=("${default_sink:t}"); src_paths=("$default_sink")
  fi
  # else: leave both arrays empty — an empty stream, not a usage error; naming
  # no path at all is not a claim that one exists.
elif [[ "$operand" == "-" ]]; then
  src_labels=("-"); src_paths=("-")
elif [[ -d "$operand" ]]; then
  # The operand itself must be usably readable — distinct from a source WITHIN
  # it later turning out unreadable, which is a per-source read failure
  # (exit 3, below), not a usage error about the named operand.
  [[ -r "$operand" && -x "$operand" ]] || {
    print -ru2 -- "rollup-telemetry: not readable: $operand"; exit 2 }
  typeset -a dirfiles
  # (N-.): nullglob (no error on zero matches) + resolve symlinks + plain
  # files only — a directory or dangling symlink named `*.jsonl` is ignored
  # exactly like any other non-stream entry, never fed to jq as a source.
  dirfiles=("$operand"/*.jsonl(N-.))
  local f
  for f in "${dirfiles[@]}"; do
    src_labels+=("${f:t}"); src_paths+=("$f")
  done
else
  [[ -e "$operand" ]] || {
    print -ru2 -- "rollup-telemetry: no such file or directory: $operand"; exit 2 }
  [[ -r "$operand" ]] || {
    print -ru2 -- "rollup-telemetry: not readable: $operand"; exit 2 }
  src_labels=("${operand:t}"); src_paths=("$operand")
fi

# --- per-source extraction: malformed/non-object lines warn to stderr and are
# skipped; everything else is tagged with its source label and collected ------

local records_tmp extract_tmp
records_tmp=$(mktemp) || {
  print -ru2 -- "rollup-telemetry: failed to create a scratch file"; exit 3 }
extract_tmp=$(mktemp) || {
  rm -f -- "$records_tmp"
  print -ru2 -- "rollup-telemetry: failed to create a scratch file"; exit 3 }
trap 'rm -f -- "$records_tmp" "$extract_tmp"' EXIT

# `-R -r -n`: raw lines in, raw text out, run once so `inputs` sees every line
# (mirrors validate-telemetry.zsh's own extraction idiom, including the
# `[$line | fromjson?]` trick that turns "no parse" into an observable
# zero-length array instead of vanishing the line from the report).
# The extraction jq attaches the origin label ITSELF (--arg src), emitting the
# already-wrapped {_src, rec} object the aggregation pass consumes. Doing it
# here rather than in a per-record `jq --argjson` in the read loop below is
# what keeps this O(sources) instead of O(records) in process spawns, and it
# keeps record JSON out of argv entirely — an unbounded v0 findings_by_round
# blob passed via --argjson could otherwise hit ARG_MAX and surface as a
# misattributed "failed to read a stream".
local extract_prog='
  def is_blank: length == 0 or (test("^\\s*$"));
  [inputs] as $lines
  | ( $lines
      | to_entries[]
      | select(.value | is_blank | not)
      | (.key + 1) as $n
      | .value as $line
      | ([$line | fromjson?]) as $parsed
      | if ($parsed | length) == 0 then
          "W\t\($n)"
        elif ($parsed[0] | type) != "object" then
          "W\t\($n)"
        else
          "R\t" + ({_src: $src, rec: $parsed[0]} | tojson)
        end
    )'

local i label srcpath tag rest
local read_err=""
for (( i = 1; i <= ${#src_paths[@]}; i++ )); do
  label="${src_labels[$i]}"
  srcpath="${src_paths[$i]}"
  # A plain redirection (never a process substitution) so `$?` right after is
  # genuinely this jq invocation's own exit status — a process substitution's
  # status is NOT observable by the command consuming it, which previously let
  # every producer-side failure (a dying jq, an unreadable file discovered only
  # at read time) vanish as an empty read and a false "no records" at exit 0.
  if [[ "$srcpath" == "-" ]]; then
    jq -R -r -n --arg src "$label" "$extract_prog" > "$extract_tmp"
  else
    jq -R -r -n --arg src "$label" "$extract_prog" < "$srcpath" > "$extract_tmp"
  fi
  if [[ $? -ne 0 ]]; then
    read_err=1
    continue
  fi
  while IFS=$'\t' read -r tag rest; do
    if [[ "$tag" == "W" ]]; then
      print -ru2 -- "rollup-telemetry: ${label}: line ${rest}: skipping malformed or non-object line"
    elif [[ "$tag" == "R" ]]; then
      # Already wrapped as {_src, rec} by the extraction jq — append verbatim.
      # A distinct diagnostic: this is a scratch-file WRITE failure, not a
      # failure to read the source, and a shared "failed to read a stream"
      # would point an operator at the wrong stage.
      print -r -- "$rest" >> "$records_tmp" || {
        print -ru2 -- "rollup-telemetry: failed to stage a record from ${label}"
        read_err=1
      }
    fi
  done < "$extract_tmp"
done

[[ -z "$read_err" ]] || {
  print -ru2 -- "rollup-telemetry: failed to read a stream"; exit 3 }

# --- one jq pass: normalize (v0 adapter + v1 passthrough), filter, group -----

local agg_prog='
  def as_outcome($v):
    if ($v | type) == "string" and (["success","parked","escalated","failed"] | index($v) != null)
    then $v else "failed" end;
  def as_num($v): if ($v | type) == "number" then $v else null end;
  def as_bucket($v):
    if ($v | type) == "string" and (($v | length) > 0) then $v else "unknown" end;

  def narrow_reviewloop($status):
    if ($status | type) != "string" then "failed"
    elif ($status == "CONVERGED" or $status == "SKIPPED") then "success"
    elif ($status == "ERROR") then "failed"
    elif ($status == "BUDGET_EXHAUSTED" or ($status | test("^ESCALATE_"))) then "escalated"
    else "failed" end;
  def narrow_refine($outcome):
    if ($outcome | type) != "string" then "failed"
    elif $outcome == "refined-ready" then "success"
    elif $outcome == "parked" then "parked"
    else "failed" end;

  # Records declaring a schema other than "telemetry/v1" (a future v2+) are
  # excluded entirely rather than read through this v1-shaped path — a
  # version-tolerant read would silently report numbers derived from a
  # superseded envelope. Only the ABSENCE of a schema key means legacy v0.
  def normalize:
    (.rec) as $r | (._src) as $src
    | if ($r.schema? == "telemetry/v1") then
        ( ($r.payload? // {}) as $p
          # has("kind"), never the // default: the jq alternative operator
          # treats an explicit false (and null) as absent, so an off-enum
          # kind:false would be COERCED to "run" and counted — the opposite of
          # the documented policy, under which any kind outside run/enrichment
          # is excluded. Only a genuinely ABSENT key defaults to "run".
          # (No apostrophes in this jq program: it lives inside a
          # single-quoted shell string, so one would terminate it.)
          | { kind: (if ($r | has("kind")) then $r.kind else "run" end),
              pipeline: as_bucket($r.pipeline // ""),
              repo: as_bucket($r.repo // ""),
              outcome: as_outcome($r.outcome // ""),
              wall_s: as_num($r.wall_s),
              rounds: (if ($p | type) == "object" then as_num($p.rounds) else null end) } )
      elif ($r | has("schema")) then
        null
      else
        ( if ($src == "review-loop.jsonl") then "review-loop"
          elif ($src == "refine-issue.jsonl") then "refine-issue"
          elif ($r | has("status")) and ($r | has("findings_by_round")) then "review-loop"
          elif ($r | has("objections_raised")) then "refine-issue"
          else "unknown" end
        ) as $pl
        | { kind: "run",
            pipeline: $pl,
            repo: "unknown",
            outcome: (
              if $pl == "review-loop" then narrow_reviewloop($r.status)
              elif $pl == "refine-issue" then narrow_refine($r.outcome)
              else "failed" end),
            wall_s: as_num($r.wall_s),
            rounds: as_num($r.rounds) }
        end;

  def mix_of($arr):
    {success:0, parked:0, escalated:0, failed:0}
    * (reduce $arr[] as $x ({}; .[$x.outcome] = ((.[$x.outcome] // 0) + 1)));

  def mean_of($arr; $field):
    ([$arr[] | .[$field] | select(. != null)]) as $vals
    | if ($vals | length) == 0 then null else (($vals | add) / ($vals | length)) end;

  def group($name; $arr):
    ($arr | length) as $n
    | { pipeline: $name,
        run_count: $n,
        outcome_mix: mix_of($arr),
        mean_rounds: mean_of($arr; "rounds"),
        mean_wall_s: mean_of($arr; "wall_s"),
        escalation_rate: (if $n == 0 then null else (mix_of($arr).escalated / $n) end) };

  ($repo_filter | ascii_downcase) as $repo_filter_ci
  | [ .[] | normalize ] as $normalized
  | [ $normalized[] | select(. != null) ] as $all
  | [ $all[] | select(.kind == "run") ] as $runs
  | ([ $runs[] | select(.repo == "unknown") ] | length) as $unknown_repo_count
  # GitHub identities are case-insensitive but case-preserving (the same repo
  # can reach the sink as "Foo/Bar" from one remote and "foo/bar" from a
  # caller-supplied --repo), so the filter folds case on both sides — matching
  # the consumer rule ARCHITECTURE.md already states for grouping by `repo`.
  | ( if ($repo_filter | length) > 0
      then [ $runs[] | select((.repo | ascii_downcase) == $repo_filter_ci) ]
      else $runs end
    ) as $after_repo
  | ( if ($pipeline_filter | length) > 0
      then [ $after_repo[] | select(.pipeline == $pipeline_filter) ]
      else $after_repo end
    ) as $selected
  | { empty: (($after_repo | length) == 0),
      # --repo unknown SELECTS the unknown bucket rather than excluding it —
      # reporting it as both counted and excluded would be self-contradictory.
      excluded_unknown: (if ($repo_filter | length) > 0 and $repo_filter_ci != "unknown"
                          then $unknown_repo_count else 0 end),
      groups: (
        if ($after_repo | length) == 0 then []
        elif ($pipeline_filter | length) > 0 then [ group($pipeline_filter; $selected) ]
        else ( $after_repo | group_by(.pipeline) | map(group(.[0].pipeline; .)) )
        end) }'

local agg
agg=$(jq -c -s --arg repo_filter "$repo_filter" --arg pipeline_filter "$pipeline_filter" \
  "$agg_prog" "$records_tmp") || {
  print -ru2 -- "rollup-telemetry: failed to aggregate records"; exit 3 }

# --- render -------------------------------------------------------------------

local is_empty excluded_unknown
is_empty=$(print -r -- "$agg" | jq -r '.empty')
excluded_unknown=$(print -r -- "$agg" | jq -r '.excluded_unknown')

# The exclusion note always goes to STDERR — in both text and --json mode —
# so a --json consumer's stdout stays a pure array while "never a silent
# drop" still holds; a combined (non-`--separate-stderr`) capture still sees
# it inline, same as before.
if [[ "$excluded_unknown" != "0" ]]; then
  print -ru2 -- "note: excluded ${excluded_unknown} record(s) attributed to an unknown repo (--repo ${repo_filter} was given)"
fi

if [[ -n "$json_mode" ]]; then
  print -r -- "$agg" | jq -c '.groups'
  exit 0
fi

if [[ "$is_empty" == "true" ]]; then
  print -r -- "no records"
  exit 0
fi

print -r -- "$agg" | jq -r '
  def show($v): if $v == null then "-" else ($v | tostring) end;
  .groups[]
  | "Pipeline: \(.pipeline)",
    "  runs: \(.run_count)",
    "  outcome mix: success=\(.outcome_mix.success) parked=\(.outcome_mix.parked) escalated=\(.outcome_mix.escalated) failed=\(.outcome_mix.failed)",
    "  mean rounds: \(show(.mean_rounds))",
    "  mean wall_s: \(show(.mean_wall_s))",
    "  escalation rate: \(show(.escalation_rate))",
    ""'

exit 0
