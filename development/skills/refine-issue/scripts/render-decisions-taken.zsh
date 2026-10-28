#!/usr/bin/env zsh
# render-decisions-taken.zsh — render the `## Decisions taken` section for the
# implementation questions refine-issue answered instead of asking (#2900).
#
# The record's shape is ARCHITECTURE.md, *Decision rights — question taxonomy
# and the Decisions-taken record* (#2899): one entry per decision, carrying the
# question, the choice, the evidence it rests on and how to overrule it. The
# entries come from one split-refiner-questions.zsh output: every `auto` entry
# whose `kind` is `implementation`. An auto-accepted `intent` or `gap` answer
# stays in the *Answers taken automatically* list, so it is never rendered here.
#
# The conductor adds what this prints to the draft's prose. The section is
# append-only: when the prose already has one, the entries below the heading go
# at its end, and an earlier run's entries are never removed (SKILL.md, Step 2).
#
# Usage:  render-decisions-taken.zsh --split <file>
#         (<file> holds one split-refiner-questions.zsh output)
# Output: the section in Markdown on stdout, or nothing when the split took no
#         implementation answer.
# Exit:   0 rendered (or nothing to render); 2 usage error, or a --split file
#         that is not one JSON object with an `auto` array.

emulate -L zsh
setopt no_unset

usage() { print -r -u2 -- "usage: render-decisions-taken.zsh --split <file>" }

local split=""
while (( $# > 0 )); do
  case "$1" in
    --split) (( $# >= 2 )) || { usage; exit 2 }; split="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$split" && -f "$split" && -r "$split" ]] || {
  print -r -u2 -- "render-decisions-taken: --split file missing or unreadable: '$split'"; exit 2 }
jq -e -s 'length == 1 and (.[0] | type == "object") and ((.[0].auto // null) | type == "array")' \
  "$split" >/dev/null 2>&1 || {
  print -r -u2 -- "render-decisions-taken: --split is not one JSON object with an auto array: $split"; exit 2 }

jq -r '
  # NB: no apostrophes in this program — it is single-quoted.
  def line: tostring | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  [.auto[] | select(.kind == "implementation")] as $d
  | if ($d | length) == 0 then empty
    else "## Decisions taken", "",
      ($d[] | "- **question:** \(.question | line)",
              "  **choice:** \(.answer | line)",
              "  **evidence:** \(.rationale | line)",
              "  **how to overrule:** \(.overrule // "edit this entry and the story text that rests on it in the issue body." | line)")
    end
' "$split"
