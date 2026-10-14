#!/usr/bin/env zsh
# build-approver-telemetry-record.zsh — build the approve `payload` for ONE
# `telemetry/v1` record: one posted Approver review (epic #741, child (f) —
# issue #1231).
#
# A PAYLOAD builder, per ARCHITECTURE.md's *Per-pipeline telemetry
# instrumentation* conventions: it emits no envelope key (the envelope is
# emit-telemetry.zsh's), and it owns the outcome behind --print-outcome, so the
# mapping is tested code. It is PURE: one review JSON and its parsed hidden
# block in, the payload out — no clock, no git, no network.
# collect-approver-telemetry.zsh is its caller, and the only thing that talks
# to GitHub.
#
# Inputs:
#   --review FILE   the review object, as `GET /repos/{o}/{r}/pulls/{n}/reviews`
#                   returns it — read: id (the review id), state, commit_id.
#   --block FILE    the JSON object of the review body's hidden
#                   `<!-- claude-approver:findings … -->` block — read:
#                   approver_version, language, dimensions, verdict,
#                   confidence, type_detected, findings.
#
# Payload (exactly these keys, in this order):
#   verdict             the block's verdict: APPROVE | REQUEST_CHANGES | COMMENT
#   confidence          the block's confidence, verbatim: HIGH | MEDIUM | LOW
#   risk_register_size  the count of block findings with category "risk"
#   dimensions          the block's dimensions — the lenses walked, in walk order
#   pr_type             the block's type_detected
#   language            the block's language (go | java | python | swift |
#                       claude-plugin | …)
#   review_id           the review's id — the collector's idempotency key
#   head_sha            the review's commit_id
#   approver_version    the block's approver_version
#
# REFUSED (exit 1, nothing on stdout):
#   - a verdict that disagrees with the review's GitHub state: APPROVE needs
#     APPROVED, REQUEST_CHANGES needs CHANGES_REQUESTED, COMMENT needs
#     COMMENTED. A DISMISSED review's state no longer says what was posted, so
#     any verdict stands against it; any other state (PENDING, …) was never
#     posted and is refused;
#   - a review whose id is not a positive integer or whose commit_id is not a
#     hex commit SHA;
#   - a block whose verdict or confidence is outside its enum, whose findings is
#     not an array of objects, whose dimensions is not a non-empty array, or
#     whose approver_version, language, type_detected or a dimension is not a
#     short lowercase identifier. A token-shaped value (a gh*_ / github_pat_
#     prefix, or anything outside those identifier shapes) is refused, so no
#     credential can ride a block into a sink.
#
# Outcome (--print-outcome): `success` for every verdict — the record describes
# the review event, never the PR's fate, and a REQUEST_CHANGES review is a
# successful review. The refusals above apply to --print-outcome too.
#
# Usage:
#   build-approver-telemetry-record.zsh --review FILE --block FILE [--print-outcome]
#
# Exit codes: 0 ok · 2 usage (an unknown/dangling flag, a positional, a missing
# --review or --block, an operand that is a directory, missing or unreadable) ·
# 1 refused or internal (a rule above broken, an input that is not one JSON
# object, jq missing).

emulate -L zsh
setopt nounset pipefail

local P=build-approver-telemetry-record
local usage="usage: build-approver-telemetry-record.zsh --review FILE --block FILE [--print-outcome]
  --review         the GitHub review JSON of one posted Approver review
  --block          the JSON object of its hidden claude-approver:findings block
  --print-outcome  print the envelope outcome instead of the payload"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -ru2 -- "$P: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || { print -ru2 -- "$P: $1 requires a non-empty value"; exit 2 }
}

local review_file="" block_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --review) _need_val "$1" $# "${2:-}"; review_file="$2"; shift 2 ;;
  --block) _need_val "$1" $# "${2:-}"; block_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -ru2 -- "$P: unknown flag: $1"; exit 2 ;;
  *) print -ru2 -- "$P: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$review_file" ]] || { print -ru2 -- "$P: --review is required"; print -ru2 -- "$usage"; exit 2 }
[[ -n "$block_file" ]] || { print -ru2 -- "$P: --block is required"; print -ru2 -- "$usage"; exit 2 }

_check_operand() {  # $1 = flag, $2 = path
  [[ ! -d "$2" ]] || { print -ru2 -- "$P: $1 is a directory: $2"; exit 2 }
  [[ -e "$2" ]] || { print -ru2 -- "$P: $1 file does not exist: $2"; exit 2 }
  [[ -r "$2" ]] || { print -ru2 -- "$P: $1 file not readable: $2"; exit 2 }
}
_check_operand --review "$review_file"
_check_operand --block "$block_file"

command -v jq >/dev/null 2>&1 || { print -ru2 -- "$P: jq not found on PATH"; exit 1 }

local review="" block="" f="" name=""
for f name in "$review_file" --review "$block_file" --block; do
  jq -e -s 'length == 1 and (.[0] | type == "object")' < "$f" >/dev/null 2>&1 \
    || { print -ru2 -- "$P: $name must be a single JSON object"; exit 1 }
done
review="$(jq -c . < "$review_file")" || { print -ru2 -- "$P: failed to read --review"; exit 1 }
block="$(jq -c . < "$block_file")" || { print -ru2 -- "$P: failed to read --block"; exit 1 }

# --- the rules, then the payload ----------------------------------------------

local res=""
res="$(jq -c -n --argjson r "$review" --argjson b "$block" '
  def ident: type == "string" and test("^[a-z][a-z0-9_-]{0,31}$")
             and (test("^(gh[a-z]|github_pat)_") | not);
  def state_of: {APPROVE: "APPROVED", REQUEST_CHANGES: "CHANGES_REQUESTED", COMMENT: "COMMENTED"}[.];
  [ (select(($r.id | type == "number" and . == floor and . >= 1) | not)
        | "review id must be a positive integer"),
    (select(($r.commit_id | type == "string" and test("^[0-9a-f]{7,40}$")) | not)
        | "review commit_id must be a hex commit SHA"),
    (select(($b.verdict | IN("APPROVE", "REQUEST_CHANGES", "COMMENT")) | not)
        | "block verdict must be APPROVE, REQUEST_CHANGES or COMMENT"),
    (select(($b.confidence | IN("HIGH", "MEDIUM", "LOW")) | not)
        | "block confidence must be HIGH, MEDIUM or LOW"),
    (select(($b.findings | type == "array" and all(.[]; type == "object")) | not)
        | "block findings must be an array of objects"),
    (select(($b.dimensions | type == "array" and length > 0 and all(.[]; ident)) | not)
        | "block dimensions must be a non-empty array of lowercase identifiers"),
    (select(($b.approver_version | ident) | not)
        | "block approver_version must be a lowercase identifier"),
    (select(($b.language | ident) | not) | "block language must be a lowercase identifier"),
    (select(($b.type_detected | ident) | not) | "block type_detected must be a lowercase identifier"),
    (select(($b.verdict | IN("APPROVE", "REQUEST_CHANGES", "COMMENT"))
            and $r.state != "DISMISSED" and $r.state != ($b.verdict | state_of))
        | "block verdict \($b.verdict) disagrees with the review state \($r.state | tostring)")
  ] as $errs
  | if ($errs | length) > 0 then {errors: $errs} else
      {payload: {verdict: $b.verdict, confidence: $b.confidence,
                 risk_register_size: ([$b.findings[] | select(.category == "risk")] | length),
                 dimensions: $b.dimensions, pr_type: $b.type_detected, language: $b.language,
                 review_id: $r.id, head_sha: $r.commit_id, approver_version: $b.approver_version},
       outcome: "success"}
    end
')" || { print -ru2 -- "$P: failed to evaluate the review"; exit 1 }

if [[ "$(print -r -- "$res" | jq -r 'has("errors")')" == "true" ]]; then
  print -r -- "$res" | jq -r --arg p "$P" '.errors[] | "\($p): review refused — \(.)"' >&2
  exit 1
fi

if (( print_outcome )); then
  print -r -- "$res" | jq -r '.outcome'
else
  print -r -- "$res" | jq -c '.payload'
fi
