#!/usr/bin/env zsh
# build-parked-comment.zsh — render a typed "refinement parked" comment for
# /development:refine-issue (#578, epic #573).
#
# Not every refinement session converges to READY in one sitting. When a
# human-present session can't converge, refine-issue's Step 2 loop takes a
# **typed parked exit** (mirroring resolve-issue's typed escalation, #564) that
# captures the state so a LATER run resumes instead of restarting. This renders
# that comment: a human-readable section plus the machine-findable resume
# contract — a `<!-- refine-parked: <TYPE> -->` marker and a hidden
# `<!-- refine-parked-state: {…} -->` JSON block that `read-parked-state.zsh`
# reads back on the next run.
#
# Three park types (chosen 2026-07-11):
#   needs-decision     — an absent stakeholder / upstream decision blocks a
#                        testable spec; the state names the decision + its owner.
#   split-recommended  — the story is really an epic; the state lists candidate
#                        children.
#   deferred           — the human pauses without converging; the conversation
#                        so far is preserved.
#
# Input is one JSON state object (via --state <file> or stdin):
#   { "type": "needs-decision"|"split-recommended"|"deferred",
#     "open_questions": ["…", …],                 # required, non-empty
#     "decision": "…", "owner": "…",              # needs-decision
#     "candidate_children": ["…", …],             # split-recommended
#     "conversation": [ {"role":"…","text":"…"} ] # preserved (deferred esp.)
#   }
#
# It prints the full comment markdown to stdout. It performs NO GitHub writes —
# the skill posts it (as the human, like every refine-issue side effect).
#
# Exit codes: 0 ok · 2 usage error · 3 runtime error (bad/missing state, no jq).
#
# Usage:
#   build-parked-comment.zsh --issue <N> --state <state.json>
#   … | build-parked-comment.zsh --issue <N>            # state on stdin

emulate -L zsh
set -euo pipefail

local issue="" state_file=""
while (( $# > 0 )); do
  case "$1" in
    --issue)
      (( $# >= 2 )) || { print -u2 "build-parked-comment.zsh: --issue needs a value"; exit 2; }
      issue="$2"; shift 2 ;;
    --state)
      (( $# >= 2 )) || { print -u2 "build-parked-comment.zsh: --state needs a value"; exit 2; }
      state_file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: build-parked-comment.zsh --issue <N> [--state <state.json>]  (else stdin)"
      exit 0 ;;
    *) print -u2 "build-parked-comment.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$issue" ]] || { print -u2 "build-parked-comment.zsh: --issue is required"; exit 2; }
[[ "$issue" == <-> ]] || { print -u2 "build-parked-comment.zsh: --issue must be a number, got: $issue"; exit 2; }
[[ -z "$state_file" || -f "$state_file" ]] || { print -u2 "build-parked-comment.zsh: state file not found: $state_file"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "build-parked-comment.zsh: jq not found on PATH"; exit 3; }

local state
if [[ -n "$state_file" ]]; then state="$(<"$state_file")"; else state="$(cat)"; fi
print -r -- "$state" | jq -e . >/dev/null 2>&1 || { print -u2 "build-parked-comment.zsh: --state is not valid JSON"; exit 3; }

local type
type="$(print -r -- "$state" | jq -r '.type // empty')"
case "$type" in
  needs-decision|split-recommended|deferred) ;;
  "") print -u2 "build-parked-comment.zsh: state.type is required"; exit 3 ;;
  *)  print -u2 "build-parked-comment.zsh: unknown park type: $type"; exit 3 ;;
esac

# open_questions must be a non-empty ARRAY (the resume contract). Check the type
# explicitly — a JSON string would pass a bare `length > 0` (length counts
# characters) and then crash mid-render on `.open_questions[]`.
print -r -- "$state" | jq -e '(.open_questions|type)=="array" and (.open_questions|length)>0' >/dev/null \
  || { print -u2 "build-parked-comment.zsh: state.open_questions must be a non-empty array"; exit 3; }

# Type-specific required fields.
case "$type" in
  needs-decision)
    print -r -- "$state" | jq -e '(.decision // "") != "" and (.owner // "") != ""' >/dev/null \
      || { print -u2 "build-parked-comment.zsh: needs-decision requires state.decision and state.owner"; exit 3; } ;;
  split-recommended)
    print -r -- "$state" | jq -e '(.candidate_children|type)=="array" and (.candidate_children|length)>0' >/dev/null \
      || { print -u2 "build-parked-comment.zsh: split-recommended requires a non-empty state.candidate_children array"; exit 3; } ;;
esac

# The single-line rendered fields must not carry a newline or a fake resume
# marker — either would forge a `refine-parked-state` line in the human section
# that the resume reader could pick up. (The hidden state is jq-escaped and safe;
# these are the only values rendered as raw markdown lines.)
print -r -- "$state" | jq -e '
  [ (.open_questions // [])[], (.candidate_children // [])[], (.decision // ""), (.owner // "") ]
  | all( (type=="string") and ((contains("\n") or contains("refine-parked")) | not) )' >/dev/null \
  || { print -u2 "build-parked-comment.zsh: rendered fields (open_questions/candidate_children/decision/owner) must be single-line strings and must not contain 'refine-parked'"; exit 3; }

# --- render -------------------------------------------------------------------
local label
case "$type" in
  needs-decision)    label="needs a decision" ;;
  split-recommended) label="should be split into an epic" ;;
  deferred)          label="deferred" ;;
esac

print -r -- "## ⏸️ Refinement parked — $label"
print -r --
print -r -- "This \`/development:refine-issue\` session on #$issue could not converge to \`READY\` and was **parked** (\`$type\`). The story keeps its \`needs-refinement\` label and **no \`story-spec\` block was written** (the prose isn't finalized). Re-run \`/development:refine-issue $issue\` to resume — the next run reads this comment and continues with the context below."
print -r --

case "$type" in
  needs-decision)
    print -r -- "### Blocking decision"
    print -r --
    print -r -- "- **Decision:** $(print -r -- "$state" | jq -r '.decision')"
    print -r -- "- **Owner:** $(print -r -- "$state" | jq -r '.owner')"
    print -r -- ;;
  split-recommended)
    print -r -- "### Recommended decomposition"
    print -r --
    print -r -- "This story is really an epic. Candidate children:"
    print -r --
    print -r -- "$state" | jq -r '.candidate_children[] | "- \(.)"'
    print -r -- ;;
  deferred)
    print -r -- "### Paused"
    print -r --
    print -r -- "The refinement was paused without converging; the conversation so far is preserved in the resume state below."
    print -r -- ;;
esac

print -r -- "### Open questions"
print -r --
print -r -- "$state" | jq -r '.open_questions[] | "- \(.)"'
print -r --

# Machine-findable resume contract: the typed marker + hidden state JSON. The
# next run's Step 0 greps these; keep them on their own lines, JSON compact.
print -r -- "<!-- refine-parked: $type -->"
print -r -- "<!-- refine-parked-state: $(print -r -- "$state" | jq -c '.') -->"
