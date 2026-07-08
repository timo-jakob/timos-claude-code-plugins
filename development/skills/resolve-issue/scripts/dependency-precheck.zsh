#!/usr/bin/env zsh
# dependency-precheck.zsh — the single-issue dependency gate (epic #583,
# issue #585).
#
# Why: `resolve-issue` on an issue with an open dependency must not silently
# implement against a missing prerequisite. This precheck runs at the very
# start of the single-issue flow — before the readiness gate, before any
# branch exists — and turns the shared reader's graph (#584) into one typed
# decision plus a ready-to-post argumentation comment. Like the readiness
# gate, it is a pure judgment: it performs NO GitHub writes — the skill posts
# the comment and applies the `blocked` label.
#
# Usage:
#   dependency-precheck.zsh --repo OWNER/NAME --issue N [--max-depth D]
#
# Emits one decision JSON object on stdout:
#   {
#     "issue": N,
#     "decision": "PROCEED" | "REJECT_BLOCKED" | "REJECT_CYCLE",
#     "open_blockers": [numbers],   # passed through from the reader
#     "blockers": [...],            # every blocker reached, classified (#584)
#     "cycles": [[a,b,a], ...],
#     "comment_md": "..." | null    # the argumentation to post on rejection
#   }
#
# Decision rules (cycle wins — a cycle can never be satisfied, so listing its
# members as "resolve these first" would be a lie):
#   cycles non-empty        -> REJECT_CYCLE
#   open_blockers non-empty -> REJECT_BLOCKED
#   otherwise               -> PROCEED
#
# Seams (for tests / non-PATH installs):
#   DEPS_BIN  overrides the read-dependencies.zsh reader (must emit the #584
#             result JSON on stdout).
#
# Exit codes (typed, mirroring the review loop's 10+ escalation range):
#   0   PROCEED — no open blockers, continue the flow exactly as today
#   10  REJECT_BLOCKED — open blockers exist; do not branch or implement
#   11  REJECT_CYCLE — the blocked-by graph contains a cycle; refuse, don't loop
#   2   usage error
#   1   internal error (the reader failed)

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local deps_bin="${DEPS_BIN:-${self_dir}/read-dependencies.zsh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" issue="" max_depth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --max-depth) max_depth="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: dependency-precheck.zsh --repo OWNER/NAME --issue N [--max-depth D]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ -n "$issue" ]] || die_usage "--issue N is required"

local deps
deps=$("$deps_bin" --repo "$repo" --issue "$issue" ${max_depth:+--max-depth} ${max_depth:+$max_depth}) || {
  print -u2 -- "dependency-precheck: read-dependencies failed for issue #$issue"; exit 1
}

local decision
if (( $(print -r -- "$deps" | jq '.cycles | length') > 0 )); then
  decision="REJECT_CYCLE"
elif (( $(print -r -- "$deps" | jq '.open_blockers | length') > 0 )); then
  decision="REJECT_BLOCKED"
else
  decision="PROCEED"
fi

# The argumentation the skill posts verbatim on rejection. A trailing
# machine-findable marker mirrors build-escalation.zsh's idiom.
_comment_md() {
  case "$decision" in
  REJECT_BLOCKED)
    print -r -- "$deps" | jq -r --arg n "$issue" '
      "## ⛔ Dependency precheck — blocked\n\n" +
      "`/development:resolve-issue` was invoked on #\($n), but its GitHub-native blocked-by graph (#583) has **open blockers**. Implementing #\($n) now would build against missing prerequisites, so no branch was created and nothing was implemented.\n\n" +
      "Open blockers (transitive, via native `blockedBy`):\n\n" +
      ([.blockers[] | select(.open) |
        "- #\(.number) — open \(if .kind == "epic" then "**epic**" else "issue" end), depth \(.depth)"]
       | join("\n")) + "\n" +
      (if .truncated then "\n> ⚠️ Traversal stopped at the depth cap — the list above may be incomplete.\n" else "" end) +
      "\nResolve the blockers first — e.g. `/development:resolve-issue \(.open_blockers[0])` — then re-run `/development:resolve-issue \($n)`.\n\n" +
      "<!-- dependency-precheck: REJECT_BLOCKED -->"'
    ;;
  REJECT_CYCLE)
    print -r -- "$deps" | jq -r --arg n "$issue" '
      "## ⛔ Dependency precheck — dependency cycle\n\n" +
      "The GitHub-native blocked-by graph of #\($n) contains a cycle — no order of work can ever satisfy it, so `resolve-issue` refuses rather than looping:\n\n" +
      ([.cycles[] | "- " + (map("#\(.)") | join(" → "))] | join("\n")) + "\n" +
      "\nRemove whichever blocked-by relationship points the wrong way, then re-run `/development:resolve-issue \($n)`.\n\n" +
      "<!-- dependency-precheck: REJECT_CYCLE -->"'
    ;;
  esac
}

local comment=""
[[ "$decision" != "PROCEED" ]] && { comment=$(_comment_md) || exit 1 }

print -r -- "$deps" | jq -c --arg decision "$decision" --arg comment "$comment" \
  '{ issue, decision: $decision, open_blockers, blockers, cycles,
     comment_md: (if $decision == "PROCEED" then null else $comment end) }'

case "$decision" in
  PROCEED) exit 0 ;;
  REJECT_BLOCKED) exit 10 ;;
  REJECT_CYCLE) exit 11 ;;
esac
