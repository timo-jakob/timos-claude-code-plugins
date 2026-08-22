#!/usr/bin/env zsh
# build-telemetry-record.zsh — build the review-loop `payload` for ONE
# `telemetry/v1` record from the loop's status JSON (from resolve-story-loop.zsh,
# #562; epic #557, issue #566 — retrofitted onto the shared contract by epic
# #740's child (b), issue #1004).
#
# It is a PAYLOAD builder, not a record builder. The envelope — `schema`, `kind`,
# `run_id`, `parent_run_id`, `ts`, `repo`, `repo_type`, `pipeline`, `issue`,
# `pr`, `outcome`, `wall_s`, `tokens` — belongs to
# `development/scripts/telemetry/emit-telemetry.zsh`, which owns it for EVERY
# pipeline so no skill hand-rolls one. This script contributes only the
# review-loop's own detail, which the emitter embeds unmodified as `payload`;
# `resolve-story-loop.zsh` pipes the two together and owns the sink.
#
# The payload is deterministic given the status JSON, so it is built and tested
# separately from the loop that emits it. The `wall_s`/`ts`/`issue` this script
# used to carry are envelope fields now, supplied by the loop to the emitter —
# hence no `--ts`/`--issue`/`--wall-s` flags here.
#
# Usage:
#   build-telemetry-record.zsh --status FILE
#
# Exit codes: 0 ok · 2 usage (bad/absent/unreadable --status operand) ·
#             1 internal — the status JSON could not be turned into a payload.
#             Stated as a CLASS, not a closed list: it covers an empty status
#             file, a missing jq, input that is not exactly one JSON object,
#             and a structurally-wrong-but-valid object the jq program itself
#             cannot evaluate (e.g. a numeric `.status`).

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-telemetry-record.zsh --status FILE"

# A value flag with no value is a caller mistake, not an omission: under
# `nounset` a bare `$2` would abort with a raw zsh parameter error and exit 1,
# reading downstream as "invalid status JSON" — name the actual mistake.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "build-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local status_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -u2 -- "$usage"; exit 2 }
# A directory has non-zero size, so it would sail past the -s check below and
# surface as jq's "Is a directory" relabelled "invalid status JSON". Name it for
# what it is — the same operand policy the sibling emitter applies to --payload.
[[ ! -d "$status_file" ]] || {
  print -u2 -- "build-telemetry-record: --status is a directory: $status_file"; exit 2 }
# A path that does not exist (or cannot be read) is a CALLER mistake — exit 2,
# the same class the sibling emitter gives a bad --payload operand. Only a file
# that exists and is empty is the internal case (exit 1: the loop produced
# nothing), so a path typo stays distinguishable from a broken status JSON.
[[ -e "$status_file" ]] || {
  print -u2 -- "build-telemetry-record: --status file does not exist: $status_file"; exit 2 }
[[ -r "$status_file" ]] || {
  print -u2 -- "build-telemetry-record: --status file not readable: $status_file"; exit 2 }
[[ -s "$status_file" ]] || { print -u2 -- "build-telemetry-record: status file is empty: $status_file"; exit 1 }

# Without this, an absent jq makes the `||` branch below report "invalid status
# JSON" — a wrong diagnosis of an environment problem. The sibling emitter
# guards the same way (it exits 3; this script's documented taxonomy has no 3,
# so the internal class here is 1).
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-telemetry-record: jq not found on PATH"; exit 1 }

# `-s` only proves the file is non-empty, which two malformed inputs satisfy
# while still producing a bogus exit 0: a WHITESPACE-ONLY file (jq -c emits
# nothing and exits 0, so an EMPTY payload would be handed to the emitter) and a
# CONCATENATED multi-document file (jq runs the program per document, emitting
# several payload lines where the contract allows exactly one). The first is
# reachable from the loop itself — if its own `jq -nc` ever failed, the status
# tmpfile would hold a lone newline. Require exactly one JSON object up front.
jq -e -s 'length == 1 and (.[0] | type == "object")' "$status_file" >/dev/null 2>&1 || {
  print -u2 -- "build-telemetry-record: invalid status JSON (expected exactly one JSON object): $status_file"; exit 1 }

jq -c '
  . as $s
  | [ $s.round_changelists[]? ] as $rounds
  # distinct findings across all rounds, keyed by identity
  | ( [ $rounds[] | (.blocking[]?, .suggestions[]?)
        | {file, line, dimension, title, priority:(.priority // "Low")} ]
      | unique_by([.file, .line, .dimension, .title]) ) as $seen
  | ( [ ($s.final_changelist.blocking // [])[]
        | "\(.file)|\(.line)|\(.dimension)|\(.title)" ] | unique ) as $final_keys
  | {
      # PAYLOAD ONLY — no envelope keys. `ts`, `issue`, `wall_s` and `tokens`
      # belong to the emitter, and `repo_type` is an envelope field the loop
      # hands it as --repo-type; duplicating any of them here would give a
      # consumer two places to read one fact.
      # (No apostrophes in this block: the jq program is single-quoted.)
      status: $s.status,
      escalation: (if ($s.status | test("^ESCALATE_")) or $s.status=="BUDGET_EXHAUSTED"
                   then $s.status else null end),
      rounds: ($s.rounds // 0),
      max_rounds: ($s.max_rounds // 0),
      # promotion sub-loop marker (#995). A promotion pass is a SECOND full
      # invocation for one story, so counting its record alongside the phase-1
      # one inflates the per-record convergence rate and adds a second
      # (repo, issue, ts) group to the first-pass rate. The documented metrics
      # exclude it with select(.payload.promotion_phase != true); an older
      # status JSON with no such key reads false, i.e. a phase-1 record.
      promotion_phase: ($s.promotion_phase // false),
      # per-round severity counts use the USER-FACING vocabulary (#969):
      # Critical / Warning / Suggestion — the same words the human reads in
      # progress.md and the escalation — so on-screen and on-disk agree
      # (internally Warning == priority High, Suggestion == the Low bucket).
      # The stamped/carried/new/fixed derivation is one of THREE copies kept
      # in lockstep with render-progress-block.zsh and build-escalation.zsh;
      # change all three together. build-dossier.zsh is NOT one of them — it
      # shares only the per-item `promoted` expression (see below).
      # The #1435 `class` histogram below is a FOURTH member of that same
      # three-way lockstep (progress block, escalation histogram, this): one
      # derivation, three renderings, moved together or not at all.
      findings_by_round: [ range(0; ($rounds | length)) as $i | $rounds[$i] as $r
        | ($r.blocking // []) as $blk
        | ((($blk | length) == 0) or ([ $blk[] | has("non_converging") ] | all)) as $stamped
        | (if $stamped then ([ $blk[] | select(.non_converging == true) ] | length) else null end) as $carried
        | (if $stamped then ($blk | map(select(.non_converging == true)
              | {file, dimension, mp: (.matched_prior // {line, title})})
            | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
           else null end) as $carried_priors
        | {
        round: $r.round,
        by_severity: {
          Critical:   ([ $blk[] | select(.priority=="Critical") ] | length),
          Warning:    ([ $blk[] | select(.priority=="High") ] | length),
          Suggestion: (($r.suggestions // []) | length)
        },
        # human-promoted blockers this round (#995): a SUBSET of
        # by_severity.Warning (the overlay raises a Low to WARNING), never a
        # fourth severity to add to it. Same per-item expression as the four
        # sibling copies — progress block, escalation table, and the two
        # build-dossier reads: raised-set + round suffix (#1064); no stamp
        # gate, so an unstamped changelist counts 0.
        promoted: ([ $blk[] | select(.promoted == true) ] | length),
        by_dimension: ( reduce ($blk + ($r.suggestions // []))[] as $f
                          ({}; .[($f.dimension // "")] = ((.[($f.dimension // "")] // 0) + 1)) ),
        # residue class histogram (#1435): where the blockers of this round came
        # from — new_defect (a file the previous fix pass never touched),
        # incomplete_propagation (in a touched file), under_assertion (in a
        # touched TEST file). It is what makes "would another round help?"
        # answerable from the record rather than by reading the diff.
        # (NB: no apostrophes in this block — the jq program is single-quoted.)
        #
        # null, NOT zeros, on a changelist whose blocking[] is not fully stamped
        # — a pre-#1435 round, or one the loop had no fix-touched set for. Zeros
        # would assert "no new defects here" about a round nobody classified.
        # Detected exactly as the sibling fields are, so an empty blocking array
        # reads as stamped (all three counts are determinately 0 with no
        # per-item stamps to consult).
        by_class: (if ([ $blk[] | has("class") ] | all)
                   then { new_defect:             ([ $blk[] | select(.class == "new_defect") ] | length),
                          incomplete_propagation: ([ $blk[] | select(.class == "incomplete_propagation") ] | length),
                          under_assertion:        ([ $blk[] | select(.class == "under_assertion") ] | length) }
                   else null end),
        # new/carried need the #913 per-item stamp; fixed_from_prev is derived
        # against the previous round from DISTINCT matched priors (null on
        # round 1 / stamp-less rounds — an honest gap, never a confident
        # wrong number)
        new:     (if $carried != null then (($blk | length) - $carried) else null end),
        carried: $carried,
        fixed_from_prev: (if ($i > 0) and ($carried_priors != null)
                          then (((($rounds[$i-1].blocking // []) | length) - $carried_priors)
                                | if . < 0 then 0 else . end)
                          else null end),
        # verified false trips (#983): proximity matches identity cleared as
        # genuinely different — auto-continued, never escalated. Recorded per
        # round so convergence analytics can separate a false-trip continuation
        # from a genuine carry. null (not 0) on a pre-#983 changelist that could
        # not compute the count — the honest-gap convention the sibling fields use.
        false_trips: (if (($r.summary // {}) | has("false_trips")) then $r.summary.false_trips else null end)
      } ],
      # per-loop convergence assessment (#969): the machine-readable form of
      # the read the grant prompt shows the human
      convergence_assessment: (
        if ($rounds | length) == 0 then null else
          ( [ $rounds[] | ((.blocking // []) | length) ] ) as $series
          | ($rounds[-1].blocking // []) as $lastblk
          | ((($lastblk | length) == 0) or ([ $lastblk[] | has("non_converging") ] | all)) as $stamped
          | (if $stamped then ([ $lastblk[] | select(.non_converging == true) ] | length) else null end) as $carried
          | (if $stamped then ($lastblk | map(select(.non_converging == true)
                | {file, dimension, mp: (.matched_prior // {line, title})})
            | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
             else null end) as $carried_priors
          | {
              blocking_by_round: $series,
              trend: (if ($series | length) < 2 then null
                      elif $series[-1] < $series[-2] then "improving"
                      elif $series[-1] == $series[-2] then "flat"
                      else "regressing" end),
              blockers_moving: (if (($series | length) < 2) or ($carried_priors == null) then null
                                else (((($rounds[-2].blocking // []) | length) - $carried_priors) > 0) end),
              carried_final: $carried,
              possible_false_trips: (if $stamped
                then ([ $lastblk[] | select((.non_converging == true) and (.possible_false_trip == true)) ] | length)
                else null end)
            }
        end),
      fixed:  ( [ $seen[]
                  | select(.priority=="Critical" or .priority=="High")
                  | ("\(.file)|\(.line)|\(.dimension)|\(.title)") as $k
                  | select( ($final_keys | index($k)) == null ) ]
                | length ),
      waived: ($seen | map(select(.priority=="Low")) | length)
    }' "$status_file" || { print -u2 -- "build-telemetry-record: invalid status JSON"; exit 1 }
