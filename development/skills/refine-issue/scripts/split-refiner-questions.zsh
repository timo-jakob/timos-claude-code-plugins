#!/usr/bin/env zsh
# split-refiner-questions.zsh — split one issue-refiner turn's `questions` into
# the ones the conductor may answer itself (auto) and the ones the human must
# answer (ask), against the auto-accept threshold.
#
# Why a script: the decision is arithmetic over the refiner's own scores, and a
# conductor doing it by eye would drift — the one thing auto-accept must never do
# is take an answer the threshold does not admit. The refiner scores; this script
# decides.
#
# A question entry is either a plain string (the pre-auto-accept shape — always
# asked) or an object:
#   { "question": "…",
#     "recommended_answer": "…" | null,
#     "criteria": { "repo_consistency": s, "best_practice": s, "evidence": s,
#                   "uniqueness": s, "reversibility": s } | null,
#     "rationale": "…" }
# with each score s a number in [0, 1] with at most two decimals.
#
# CONFIDENCE is the MINIMUM of the five scores — the weakest criterion caps the
# answer — computed here, never taken from the refiner. It is compared in integer
# thousandths, so no float rounding moves an answer across the threshold. An
# answer is AUTO when it has a non-blank recommended_answer, all five scores are
# well-formed, the rationale is non-blank, and confidence >= threshold. Every
# other entry is ASK, with a `reason`: below-threshold | no-recommendation |
# malformed. A malformed entry is asked, never an error: the refiner's output is
# not the caller's mistake, and failing safe means asking the human.
#
# Usage:  split-refiner-questions.zsh --threshold-milli <0..1000> --turn <file>
#         (<file> holds the refiner's whole JSON turn)
# Output: one JSON object on stdout:
#   { "threshold": "0.900",
#     "auto": [ { question, answer, confidence, weakest, rationale } ],
#     "ask":  [ { question, recommended_answer, confidence, weakest, rationale, reason } ] }
#   confidence is a "0.00"-style string, or null when unscored; weakest lists
#   the criteria scored at the minimum ([] when unscored).
# Exit:   0 split; 2 usage error, or a turn that is not a JSON object whose
#         `questions` is an array.

emulate -L zsh
setopt no_unset

usage() { print -r -u2 -- "usage: split-refiner-questions.zsh --threshold-milli <0..1000> --turn <file>" }

local thr="" turn=""
while (( $# > 0 )); do
  case "$1" in
    --threshold-milli) (( $# >= 2 )) || { usage; exit 2 }; thr="$2"; shift 2 ;;
    --turn)            (( $# >= 2 )) || { usage; exit 2 }; turn="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$thr" =~ '^[0-9]{1,4}$' ]] && (( 10#$thr <= 1000 )) || {
  print -r -u2 -- "split-refiner-questions: --threshold-milli must be an integer in 0..1000, got '$thr'"; exit 2 }
[[ -n "$turn" && -f "$turn" && -r "$turn" ]] || {
  print -r -u2 -- "split-refiner-questions: --turn file missing or unreadable: '$turn'"; exit 2 }
jq -e -s 'length == 1 and (.[0] | type == "object") and ((.[0].questions // null) | type == "array")' \
  "$turn" >/dev/null 2>&1 || {
  print -r -u2 -- "split-refiner-questions: --turn is not one JSON object with a questions array: $turn"; exit 2 }

jq --argjson thr "$(( 10#$thr ))" '
  # NB: no apostrophes in this program — it is single-quoted.
  def names: ["repo_consistency", "best_practice", "evidence", "uniqueness", "reversibility"];
  def nonblank: type == "string" and (gsub("\\s"; "") | length) > 0;
  # a score in hundredths, or null when it is not a number in [0,1] with at most
  # two decimals (checked by rounding a scaled value, never by float equality)
  def hundredths: if type == "number" and . >= 0 and . <= 1
                     and (((. * 100) | round) - (. * 100) | fabs) < 0.000001
                  then (. * 100 | round) else null end;
  def fmt2($h): ($h | tostring) as $s
                | if $h == 100 then "1.00"
                  elif $h < 10 then "0.0\($s)" else "0.\($s)" end;
  def fmt3($m): if $m == 1000 then "1.000"
                else ($m | tostring) as $s
                  | "0." + ("000"[0:(3 - ($s | length))]) + $s end;
  def scored:
    (.criteria // null) as $c
    | if ($c | type) != "object" then null
      else [names[] as $n | {name: $n, h: ($c[$n] | hundredths)}]
        | if any(.[]; .h == null) then null else . end
      end;
  def classify:
    if type == "string" then
      {question: ., recommended_answer: null, confidence: null, weakest: [],
       rationale: null, reason: "no-recommendation", auto: false}
    elif type != "object" or ((.question // null) | nonblank | not) then
      {question: (tostring), recommended_answer: null, confidence: null,
       weakest: [], rationale: null, reason: "malformed", auto: false}
    else
      . as $q | scored as $s
      | ($s // [] | map(.h) | min) as $min
      | {question: $q.question,
         recommended_answer: (if ($q.recommended_answer // null) | nonblank
                              then $q.recommended_answer else null end),
         confidence: (if $s == null then null else fmt2($min) end),
         weakest: (if $s == null then [] else [$s[] | select(.h == $min) | .name] end),
         rationale: (if ($q.rationale // null) | nonblank then $q.rationale else null end)}
      | if .recommended_answer == null then . + {reason: "no-recommendation", auto: false}
        elif $s == null or .rationale == null then . + {reason: "malformed", auto: false}
        elif ($min * 10) >= $thr then . + {auto: true}
        else . + {reason: "below-threshold", auto: false} end
    end;
  [.questions[] | classify] as $all
  | {threshold: fmt3($thr),
     auto: [$all[] | select(.auto)
            | {question, answer: .recommended_answer, confidence, weakest, rationale}],
     ask:  [$all[] | select(.auto | not) | del(.auto)]}
' "$turn"
