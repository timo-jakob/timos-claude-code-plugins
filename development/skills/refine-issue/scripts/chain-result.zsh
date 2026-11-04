#!/usr/bin/env zsh
# chain-result.zsh — the chained refinement mode's two documents (#2939):
# the step handoff it reads, and the one outcome document it returns.
#
# A chained refinement is refine-issue run as a step of a
# /development:resolve-issue run (`--chained-from <root> --handoff <file>`). It
# never asks the human itself: its caller relays the questions and re-dispatches
# it. Both documents cross that boundary, so both are validated here and never
# judged by eye.
#
# read-handoff --file <path>
#   Validate a step-handoff/v1 object (ARCHITECTURE.md, *Step handoff contract*)
#   and print it, compacted, on stdout. Required fields:
#     schema       "step-handoff/v1"
#     issue        integer >= 1, the issue the step works on
#     chained_from integer >= 1, the root issue of the run
#     origin       "human" | "pipeline"
#     scratch_dir  an absolute path (a string starting with "/")
#     answers      an array of {issue, question, answer}: issue an integer
#                  >= 1, question and answer non-blank strings. A question is
#                  a pending ask entry's question text, verbatim.
#   Keys this reader does not read are ignored, so other step kinds may add
#   fields. A missing, unreadable or malformed file is exit 2 with one reason on
#   stderr, and the chained run then returns stopped with the reason
#   "unreadable step handoff".
#
# emit --issue <N> --outcome <outcome> [outcome flags]
#   Print the chained run's one outcome document:
#     {"schema":"chain-result/v1","issue":N,"outcome":"<outcome>", …}
#   The outcome is one of four, each a step verdict value by the same name:
#     ready              --risk <low|normal|elevated> [--answers <file>]
#                        adds risk and auto_accepted, the run's auto-accepted
#                        answers: <file> holds a JSON array of
#                        {question, answer, confidence, weakest}; [] without it
#     split              --children <file>
#                        adds children: <file> holds file-split-children.zsh's
#                        non-empty `filed` array of {number, title}
#     questions-pending  --split <split.json> --turn <turn.json>
#                        --resume <abs path> --round <R>
#                        adds questions, resume and round. questions is the
#                        split file's non-empty `ask` array, each entry
#                        split-refiner-questions.zsh's ask entry unchanged
#                        (question, kind, recommended_answer, confidence,
#                        weakest, rationale, reason), plus proposed_doc_change
#                        on a gap whose turn question carries one
#     stopped            --reason <text>
#                        adds reason, a non-blank string
#   Any other outcome, a flag that belongs to another outcome, a missing flag
#   or malformed input is exit 2, and nothing is printed on stdout.
#
# Exit: 0 printed; 2 usage error or malformed input (named on stderr);
#       1 jq missing from PATH.

emulate -L zsh
setopt no_unset pipe_fail

usage() {
  print -r -u2 -- "usage: chain-result.zsh read-handoff --file <path>"
  print -r -u2 -- "       chain-result.zsh emit --issue <N> --outcome <ready|split|questions-pending|stopped> [outcome flags]"
}
die() { print -r -u2 -- "chain-result: $1"; exit 2 }

(( $+commands[jq] )) || { print -r -u2 -- "chain-result: jq is not on PATH"; exit 1 }
(( $# >= 1 )) || { usage; exit 2 }

local sub="$1"; shift
local -A opt
local -a allowed
case "$sub" in
  read-handoff) allowed=(--file) ;;
  emit) allowed=(--issue --outcome --risk --answers --children --split --turn --resume --round --reason) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
while (( $# > 0 )); do
  (( ${allowed[(Ie)$1]} )) || { print -r -u2 -- "chain-result: unknown argument for $sub: $1"; usage; exit 2 }
  (( $# >= 2 )) && [[ -n "$2" ]] || die "$1 needs a value"
  [[ -z "${opt[$1]:-}" ]] || die "$1 given twice"
  opt[$1]="$2"; shift 2
done

# A file operand: present, readable, exactly one JSON document.
readjson() {  # <flag> -> prints the compacted document
  local f="${opt[$1]:-}"
  [[ -n "$f" ]] || die "$1 is required"
  [[ -f "$f" && -r "$f" ]] || die "$1 file missing or unreadable: $f"
  jq -c -s 'if length == 1 then .[0] else error("not one JSON document") end' "$f" 2>/dev/null \
    || die "$1 is not exactly one JSON document: $f"
}

local defs='def nonblank: type == "string" and (gsub("\\s"; "") | length) > 0;
            def posint: type == "number" and . >= 1 and . == floor;'

if [[ "$sub" == read-handoff ]]; then
  local doc reason
  doc="$(readjson --file)" || exit 2
  reason="$(jq -r "$defs"'
    if type != "object" then "the handoff is not a JSON object"
    elif .schema != "step-handoff/v1" then "schema is not step-handoff/v1"
    elif (.issue // null | posint | not) then "issue is not an integer >= 1"
    elif (.chained_from // null | posint | not) then "chained_from is not an integer >= 1"
    elif (.origin // null | IN("human", "pipeline") | not) then "origin is not human or pipeline"
    elif (.scratch_dir // null | nonblank and startswith("/") | not) then "scratch_dir is not an absolute path"
    elif (.answers // null | type != "array") then "answers is not an array"
    else ([.answers | to_entries[]
           | select((.value | type) != "object"
                    or (.value.issue // null | posint | not)
                    or (.value.question // null | nonblank | not)
                    or (.value.answer // null | nonblank | not))
           | "answers[\(.key)] needs issue, question and answer"] | first // "")
    end' <<< "$doc")" || die "could not read the handoff"
  [[ -z "$reason" ]] || die "unreadable step handoff: $reason"
  print -r -- "$doc"
  exit 0
fi

# --- emit ---------------------------------------------------------------------
local issue="${opt[--issue]:-}" outcome="${opt[--outcome]:-}"
[[ "$issue" =~ '^[1-9][0-9]*$' ]] || die "--issue must be an integer >= 1, got '$issue'"
local -A owns=(
  ready             "--risk --answers"
  split             "--children"
  questions-pending "--split --turn --resume --round"
  stopped           "--reason"
)
[[ -n "${owns[$outcome]:-}" ]] || die "--outcome must be ready, split, questions-pending or stopped, got '$outcome'"
local f
for f in --risk --answers --children --split --turn --resume --round --reason; do
  [[ -z "${opt[$f]:-}" ]] || (( ${${=owns[$outcome]}[(Ie)$f]} )) || die "$f does not belong to outcome $outcome"
done

local base
base="$(jq -cn --argjson n "$issue" --arg o "$outcome" '{schema: "chain-result/v1", issue: $n, outcome: $o}')"

case "$outcome" in
  ready)
    [[ "${opt[--risk]:-}" == (low|normal|elevated) ]] || die "--risk must be low, normal or elevated"
    local answers='[]'
    if [[ -n "${opt[--answers]:-}" ]]; then answers="$(readjson --answers)" || exit 2; fi
    jq -e "$defs"'type == "array" and all(.[]; type == "object" and (.question // null | nonblank)
          and (.answer // null | nonblank) and ((.weakest // null) | type == "array"))' \
      <<< "$answers" >/dev/null || die "--answers must be an array of {question, answer, confidence, weakest}"
    jq -c --arg r "${opt[--risk]}" --argjson a "$answers" '. + {risk: $r, auto_accepted: $a}' <<< "$base"
    ;;
  split)
    local children; children="$(readjson --children)" || exit 2
    jq -e "$defs"'type == "array" and length > 0
          and all(.[]; type == "object" and (.number // null | posint) and (.title // null | nonblank))' \
      <<< "$children" >/dev/null || die "--children must be a non-empty array of {number, title}"
    jq -c --argjson c "$children" '. + {children: $c}' <<< "$base"
    ;;
  questions-pending)
    local split turn
    split="$(readjson --split)" || exit 2
    turn="$(readjson --turn)" || exit 2
    [[ "${opt[--resume]:-}" == /* ]] || die "--resume must be an absolute path"
    [[ "${opt[--round]:-}" =~ '^[1-9][0-9]*$' ]] || die "--round must be an integer >= 1"
    jq -e "$defs"'type == "object" and (.ask | type == "array") and (.ask | length > 0)
          and all(.ask[]; type == "object" and (.question // null | nonblank)
                  and (.kind // null | IN("intent", "gap", "implementation")) and has("reason"))' \
      <<< "$split" >/dev/null || die "--split must be a split-refiner-questions.zsh object with a non-empty ask set"
    jq -e 'type == "object" and (.questions | type == "array")' <<< "$turn" >/dev/null \
      || die "--turn must be one issue-refiner turn with a questions array"
    jq -c --argjson s "$split" --argjson t "$turn" --arg r "${opt[--resume]}" --argjson n "${opt[--round]}" '
      ([$t.questions[] | objects | select((.proposed_doc_change // null) | type == "object")
        | {key: .question, value: .proposed_doc_change}] | from_entries) as $docs
      | . + {questions: [$s.ask[] | if .kind == "gap" and ($docs[.question] != null)
                                    then . + {proposed_doc_change: $docs[.question]} else . end],
             resume: $r, round: $n}' <<< "$base"
    ;;
  stopped)
    jq -en "$defs"'$ARGS.named.r | nonblank' --arg r "${opt[--reason]:-}" >/dev/null || die "--reason must be a non-blank string"
    jq -c --arg r "${opt[--reason]}" '. + {reason: $r}' <<< "$base"
    ;;
esac
