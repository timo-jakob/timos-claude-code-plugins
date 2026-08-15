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
#     "open_blockers": [numbers],   # passed through from the reader (same-repo)
#     "foreign_blockers": [ {ref, open} ],  # cross-repo, never traversed —
#                                   # an OPEN one still rejects (fail-closed)
#     "blockers": [...],            # every blocker reached, classified (#584)
#     "cycles": [[a,b,a], ...],
#     "truncated": bool,            # the cap left edges UNREAD, so the arrays
#                                   # above are a FLOOR, not complete. A leaf
#                                   # reached at the cap leaves nothing unread
#                                   # and reports false — see the reader header
#     "reader_blocked": bool,       # the reader's own verdict, so a consumer
#                                   # facing an EMPTY blocker set can tell which
#                                   # unnameable cause rejected it
#     "comment_md": "..." | null    # the argumentation to post on rejection
#   }
#
# Decision rules (cycle wins — a cycle can never be satisfied, so listing its
# members as "resolve these first" would be a lie). Every predicate is ONE
# checked jq call: a gate whose decision can fall through to PROCEED when its
# own tooling fails is worse than no gate.
#   cycles non-empty        -> REJECT_CYCLE
#   open_blockers non-empty -> REJECT_BLOCKED
#   an OPEN foreign_blocker -> REJECT_BLOCKED (cannot be traversed, still blocks)
#   truncated, EMPTY finding set -> REJECT_BLOCKED (the walk never looked, so
#                              the empty arrays are not evidence of no blockers;
#                              names no blocker and is NOT remediable — there is
#                              no rung to run, so the skill reports and stops)
#     NB the stock reader cannot currently produce this shape: it only trips
#     the cap while expanding an OPEN blocker, which is therefore already
#     recorded — so `open_blockers` is non-empty and the rule above fires
#     first. It is a deliberate fail-closed default for a non-conforming or
#     future reader (a DEPS_BIN double is how it is exercised), NOT dead code.
#   the reader reports blocked -> REJECT_BLOCKED (a reason none of the four
#                              counts above names. The shared reader exists so
#                              this judgment cannot drift between consumers, so
#                              consume its verdict rather than only re-deriving
#                              it: a NEW reader reason rejects by default
#                              instead of silently proceeding. Also
#                              unnameable, so also not remediable.)
#   otherwise               -> PROCEED
#
# Seams (for tests / non-PATH installs):
#   DEPS_BIN  overrides the read-dependencies.zsh reader (must emit the #584
#             result JSON on stdout).
#
# Exit codes (typed, mirroring the review loop's 10+ escalation range):
#   0   PROCEED — the graph was fully walked and no open blocker was found
#   10  REJECT_BLOCKED — an open blocker exists; or the walk was truncated and
#       enumerated nothing; or the reader reported `blocked` for a reason this
#       gate cannot name. Do not branch or implement
#   11  REJECT_CYCLE — the blocked-by graph contains a cycle; refuse, don't loop
#   2   usage error — including the reader's own, re-raised rather than
#       laundered into 1 (which would tell the caller to retry, not to fix)
#   1   internal error (jq missing, the reader failed, or a document that could
#       not be read or emitted). Every exit-1 path prints NOTHING on stdout, so
#       a caller must treat any code outside 0/10/11 as "not a pass".

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local deps_bin="${DEPS_BIN:-${self_dir}/read-dependencies.zsh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" issue="" max_depth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  # the arity guard every sibling script in this directory carries: without it
  # a dangling `--repo` reads an unset $2 under `nounset`, and zsh aborts with
  # a raw "2: parameter not set" at exit 1 — the code this script's own header
  # documents as "the reader failed". A malformed invocation would be reported
  # as a broken dependency reader.
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --issue) (( $# >= 2 )) || die_usage "--issue needs a value"; issue="$2"; shift 2 ;;
  # an EMPTY value would be dropped by the conditional expansion below and
  # silently fall back to the reader's default, discarding a cap the caller
  # explicitly asked for; every other malformed value already reaches the
  # reader and returns exit 2, so emptiness is the one inconsistent hole
  --max-depth) (( $# >= 2 )) || die_usage "--max-depth needs a value"
    # at least 1: a cap of 0 reads no edge at all: an issue that HAS
    # dependencies comes back with an empty blocker set (truncated, hence
    # rejected), and one that has none is "cleared" without a single edge
    # being read. Neither is a cap — both are a usage error.
    { [[ "$2" == <-> ]] && (( $2 >= 1 )) } \
      || die_usage "--max-depth must be a positive number, got: $2"
    max_depth="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: dependency-precheck.zsh --repo OWNER/NAME --issue N [--max-depth D]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ -n "$issue" ]] || die_usage "--issue N is required"

# after argument validation, so `--help` and usage errors keep their own exit
# codes: every decision predicate below is a jq call, and without jq they would
# all produce empty output — which reads as "no findings" and PROCEEDs.
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "dependency-precheck: jq not found on PATH"; exit 1
}

local deps rc=0
deps=$("$deps_bin" --repo "$repo" --issue "$issue" ${max_depth:+--max-depth} ${max_depth:+$max_depth}) || rc=$?
if (( rc != 0 )); then
  print -u2 -- "dependency-precheck: read-dependencies failed for issue #$issue"
  # re-raise the reader's USAGE code rather than laundering it into 1: exit 1
  # is documented here as "the reader failed", so collapsing a malformed
  # argument into it tells the caller to retry when it must fix the call
  (( rc == 2 )) && exit 2
  exit 1
fi

# Compute all five counts in ONE checked call. Never branch on a bare command
# substitution inside (( )): if jq produced nothing the expression becomes
# `(( > 0 ))`, zsh reports a bad math expression, the compound returns non-zero
# and control falls through — ending at PROCEED. A gate that fails OPEN is the
# one wrong answer it can give.
# ASSERT the shape here, do not default it away: `.cycles | length` on a
# MISSING key is 0, not an error, so a well-formed document that is not the
# reader's contract (a renamed field, a bare `null`, a DEPS_BIN double) would
# read as "no findings" and PROCEED. Checking only the call's status and the
# field count cannot see that.
local counts
counts=$(print -r -- "$deps" | jq -er '
  # assert the WHOLE contract, especially the three fields whose `//` default
  # is the PERMISSIVE value — foreign_blockers, truncated, blocked. Guarding
  # only the arrays leaves the fail-closed fields defaulting to "ready", which
  # is the exact hole this assertion exists to close. The stock reader always
  # emits all seven, so asserting all seven cannot reject a valid document.
  . as $doc
  | if (type != "object")
       or (["issue","blocked","open_blockers","blockers",
            "foreign_blockers","cycles","truncated"]
           | any(. as $k | ($doc | has($k)) | not))
    then error("reader document is missing required keys") else . end
  # a key present with a null value passes has(). For the arrays null|length is
  # 0; for the BOOLEANS null is falsy under `if`, so a null `blocked` or
  # `truncated` reads as "not blocked" and "walk complete" — the two claims this
  # gate must never assume. Dropping the `//` does not help there (null is falsy
  # either way); only a type assertion closes it.
  | if ((.cycles | type) != "array") or ((.open_blockers | type) != "array")
       or ((.blockers | type) != "array") or ((.foreign_blockers | type) != "array")
       or ((.truncated | type) != "boolean") or ((.blocked | type) != "boolean")
       or ((.issue | type) != "number")
    then error("reader document has wrong field types") else . end
  # ...and one level DOWN, on the per-element `open` booleans. Every consumer
  # below reads them through `select(.open)`, which silently DROPS an element
  # whose `open` is missing or null — the permissive direction again. A
  # foreign blocker lacking it would make all five counts zero and the gate
  # PROCEED on an unverifiable cross-repo prerequisite.
  | if ([.foreign_blockers[]
         | select(((.open | type) != "boolean") or ((.ref | type) != "string"))]
        | length) > 0
       or ([.blockers[]
            | select(((.open | type) != "boolean") or ((.number | type) != "number")
                     or ((.depth | type) != "number")
                     # the comment renders epic-vs-issue from this and posts it
                     # verbatim; a wrong or absent kind mislabels an epic as an
                     # ordinary issue, which is what tells the human whether to
                     # decompose or implement
                     or ((.kind != "epic") and (.kind != "issue")))]
           | length) > 0
       # .cycles is the third structured array and the only one that drives the
       # exit-11 decision. Unchecked, a non-array element aborts the renderer
       # AFTER the decision was made, turning a correctly-classified cycle into
       # exit 1 "the reader failed" and losing the typed escalation.
       or ([.cycles[]
            | select((type != "array") or ((map(type) | any(. != "number"))))]
           | length) > 0
    then error("reader document has wrong field types") else . end
  # the decision reads .open_blockers while the comment renders from .blockers;
  # for the stock reader they are derived from one another, but this gate now
  # accepts a substituted reader, and a divergence would reject correctly while
  # posting "No blocker could be enumerated" over a document that names them
  | if ((.open_blockers | sort) != ([.blockers[] | select(.open) | .number] | sort))
    then error("reader document disagrees with itself about the open blockers")
    else . end
  | [(.cycles | length),
     (.open_blockers | length),
     ([.foreign_blockers[] | select(.open)] | length),
     (if .truncated then 1 else 0 end),
     # the reader publishes its own fail-closed verdict; consume it rather than
     # only re-deriving it, so a future reason IT has for `blocked: true`
     # rejects here by default instead of silently PROCEEDing
     (if .blocked then 1 else 0 end)] | @tsv') || {
  print -u2 -- "dependency-precheck: unreadable reader document for issue #$issue"; exit 1
}
local -a n_counts=( ${(s: :)${counts//$'\t'/ }} )
(( ${#n_counts} == 5 )) || {
  print -u2 -- "dependency-precheck: unreadable reader document for issue #$issue"; exit 1
}

local decision
if (( n_counts[1] > 0 )); then
  decision="REJECT_CYCLE"
elif (( n_counts[2] > 0 )); then
  decision="REJECT_BLOCKED"
elif (( n_counts[3] > 0 )); then
  # an OPEN cross-repo blocker blocks too. The reader cannot traverse it (a
  # different repository needs a different query), so it never reaches
  # open_blockers — keying only on that would PROCEED on an issue the reader
  # itself reported `blocked: true`, which is the one wrong answer a gate can
  # give. Same rejection, and the comment names the refs rather than numbers.
  decision="REJECT_BLOCKED"
elif (( n_counts[4] > 0 )); then
  # the walk was cut short by the depth cap, so the EMPTY finding set above is
  # not evidence of no blockers — it is evidence of not having looked. Same
  # fail-closed rule as a foreign blocker: unverifiable is never ready.
  decision="REJECT_BLOCKED"
elif (( n_counts[5] > 0 )); then
  # the reader says blocked for a reason none of the four counts above names.
  # Reject rather than PROCEED: the shared reader exists so this judgment
  # cannot drift between consumers, and defaulting to "ready" on a reason we do
  # not yet understand is the drift it was built to prevent.
  decision="REJECT_BLOCKED"
else
  decision="PROCEED"
fi

# The argumentation the skill posts verbatim on rejection. A trailing
# machine-findable marker mirrors build-escalation.zsh's idiom.
_comment_md() {
  case "$decision" in
  REJECT_BLOCKED)
    print -r -- "$deps" | jq -r '
      # bind ONCE, over the whole expression: an `as` binding inside a
      # parenthesised group goes out of scope at its closing paren
      ([.blockers[] | select(.open) |
        "- #\(.number) — open \(if .kind == "epic" then "**epic**" else "issue" end), depth \(.depth)"] +
       [.foreign_blockers[] | select(.open) |
        "- \(.ref) — open, in **another repository** (not traversed)"]) as $lines |
      "## ⛔ Dependency precheck — blocked\n\n" +
      "`/development:resolve-issue` was invoked on #\(.issue), but its GitHub-native blocked-by graph (#583) has **open blockers**. Implementing #\(.issue) now would build against missing prerequisites, so no branch was created and nothing was implemented.\n\n" +
      # an unnameable rejection has no findings to list — saying "open blockers"
      # over an empty list would read as a rendering bug, not a verdict. The two
      # unnameable causes need DIFFERENT wording: blaming the depth cap when it
      # never fired sends the human to raise --max-depth for a rejection that
      # would not clear, and the same document says `truncated: false`.
      (if ($lines | length) > 0
       then "Open blockers (transitive, via native `blockedBy`):\n\n" + ($lines | join("\n")) + "\n"
       elif .truncated
       then "**No blocker could be enumerated**: the traversal was cut short by the depth cap, so this is a refusal to guess, not a list of prerequisites.\n"
       else "**No blocker could be enumerated**: the dependency reader reported this issue blocked for a reason this gate cannot name, so it refuses rather than guessing.\n" end) +
      # only when there IS a list above: on the depth-cap-only rejection the
      # previous sentence has just said nothing could be enumerated, and this
      # posts verbatim to a GitHub issue, where the pair reads as a render bug
      (if (.truncated and (($lines | length) > 0)) then "\n> ⚠️ Traversal stopped at the depth cap — the list above may be incomplete.\n" else "" end) +
      (if ([.foreign_blockers[] | select(.open)] | length) > 0 then
         "\n> ℹ️ A cross-repo blocker is reported but never walked — this reader is bound to one repository, so its own blockers are not enumerated here. Resolve it in its own repo.\n" else "" end) +
      "\nResolve the blockers first" +
      # the DEEPEST open blocker, not open_blockers[0]. That array is in DFS
      # discovery order, so element 0 is a direct blocker, which this same gate
      # would immediately reject if it is itself blocked. The skill rule is
      # deepest-first; suggesting the shallowest costs a wasted round on a
      # comment posted verbatim to the issue.
      (([.blockers[] | select(.open)] | max_by(.depth) // null) as $deepest |
       if $deepest != null then " — e.g. `/development:resolve-issue \($deepest.number)` (deepest first)" else "" end) +
      " — then re-run `/development:resolve-issue \(.issue)`.\n\n" +
      "<!-- dependency-precheck: REJECT_BLOCKED -->"'
    ;;
  REJECT_CYCLE)
    print -r -- "$deps" | jq -r '
      "## ⛔ Dependency precheck — dependency cycle\n\n" +
      "The GitHub-native blocked-by graph of #\(.issue) contains a cycle — no order of work can ever satisfy it, so `resolve-issue` refuses rather than looping:\n\n" +
      ([.cycles[] | "- " + (map("#\(.)") | join(" → "))] | join("\n")) + "\n" +
      "\nRemove whichever blocked-by relationship points the wrong way, then re-run `/development:resolve-issue \(.issue)`.\n\n" +
      "<!-- dependency-precheck: REJECT_CYCLE -->"'
    ;;
  esac
}

local comment=""
[[ "$decision" != "PROCEED" ]] && { comment=$(_comment_md) || exit 1 }

print -r -- "$deps" | jq -c --arg decision "$decision" --arg comment "$comment" \
  '{ issue, decision: $decision, open_blockers, blockers,
     # no `//` defaults: the shape assertion above already guarantees these,
     # and `false // true` is `true`, so a defaulted boolean would invert on a
     # value that IS present and false — flipping every ordinary rejection into
     # one the skill reports as an unverifiable graph
     foreign_blockers, cycles,
     truncated,
     # the verdict the reader itself published, projected so a consumer facing
     # an EMPTY blocker set can tell WHICH unnameable cause rejected it rather
     # than guessing — or, worse, reading the empty arrays as a malfunction.
     # NB: no apostrophes in this program, they would close the shell quote.
     reader_blocked: .blocked,
     comment_md: (if $decision == "PROCEED" then null else $comment end) }' || {
  # unchecked, a failed emit would still fall through to the exit code below:
  # the caller would read exit 0 with NOTHING on stdout — "cleared by the gate"
  # for a run that never rendered a decision
  print -u2 -- "dependency-precheck: failed to emit the decision document for issue #$issue"; exit 1
}

case "$decision" in
  PROCEED) exit 0 ;;
  REJECT_BLOCKED) exit 10 ;;
  REJECT_CYCLE) exit 11 ;;
esac
