#!/usr/bin/env zsh
# read-dependencies.zsh — the shared reader for GitHub-native issue
# dependencies (epic #583, issue #584).
#
# Why: `resolve-issue` enforces dependencies only when they are DECLARED as
# GitHub-native `blockedBy` relationships — the single, machine-readable source
# of truth (a dependency living only in prose is a readiness-gate failure, not
# an input to this reader). Every consumer of dependency data — the readiness
# gate, the single-issue precheck (#585), the epic-as-dependency recursion
# (#587) — reads through this one helper so the traversal, classification, and
# cycle semantics can never drift between them.
#
# Usage:
#   read-dependencies.zsh --repo OWNER/NAME --issue N [--max-depth D]
#
# Emits one JSON object on stdout:
#   {
#     "issue": N,
#     "blocked": true|false,        # any OPEN blocker, directly or transitively
#                                   # — SAME-repo or cross-repo (fail-closed:
#                                   #   a foreign blocker cannot be traversed,
#                                   #   but an open one still blocks)
#     "open_blockers": [numbers],   # the open SAME-repo ones, dedup'd,
#                                   # discovery order. Cross-repo blockers are
#                                   # never here — a bare number is meaningless
#                                   # outside its repo; see foreign_blockers
#     "blockers": [                 # every distinct SAME-repo blocker reached
#       { "number": M, "state": "OPEN"|"CLOSED", "open": bool,
#         "kind": "epic"|"issue",   # epic := native sub-issues (#802), `epic`
#                                   #         label, tracked issues, or a
#                                   #         child task list (`- [ ] #N`, see
#                                   #         the parsing rule below)
#         "depth": 1.. }            # 1 = direct blocker of the named issue
#     ],
#     "foreign_blockers": [         # blockers in ANOTHER repository, dedup'd
#       { "ref": "owner/name#M",    # by slug-qualified ref (two repos may both
#         "open": bool }            # have a #7), never traversed and never
#     ],                            # re-resolved against --repo
#     "cycles": [[a,b,a], ...],     # each cycle as the path that closed it
#     "truncated": bool             # true when the cap stopped traversal at a
#                                   # node that still had UNREAD edges. A leaf
#                                   # reached at the cap leaves nothing unread
#                                   # and reports false — the cap being hit is
#                                   # not by itself evidence of an incomplete
#                                   # answer, and claiming otherwise tells the
#                                   # operator a complete list is a floor
#   }
#
# Child task list (the un-backfilled-epic signal, #1260): a checkbox line
# declares a CHILD only when its content STARTS with an issue reference —
# `- [ ] #N` or `- [x] owner/repo#N` — which is GitHub's own
# task-list-to-sub-issue shape and how every real epic here writes its children
# (`- [ ] #687 — description`). A checkbox that merely MENTIONS an issue
# somewhere in its text is an acceptance criterion, not a child declaration:
# matching those made a well-specified single story (cross-referenced,
# checkbox-shaped criteria) classify as an epic, and the better the story the
# more likely it misfired. Lines inside ``` or ~~~ fences are ignored, so an
# issue that QUOTES an epic task list is not itself read as an epic.
#
# TWO RULES, TWO OWNERS — do not conflate them (#1260). This one is the
# CLASSIFICATION rule (is this issue an epic at all?) and is start-anchored.
# backfill-sub-issues.zsh owns the MIGRATION rule (which refs get attached as
# native sub-issues) and is deliberately LOOSER on ref POSITION — it takes the
# first ref ANYWHERE on a checkbox line, so a context ref is put in front of
# whoever vets its `--dry-run` plan (resolve-issue's E1) instead of being
# dropped silently. They are not "the same rule"; what they must satisfy is a
# two-sided invariant, and both directions have already bitten:
#   (a) every line THIS rule calls a child, backfill must also resolve a ref
#       from — attaching it, or reporting it in `skipped_cross_repo` /
#       `skipped_self_ref` — never
#       dropping it silently, because an epic detected here that then migrates
#       nothing leaves E1 with a vacuously-satisfied gate. So the bare-URL
#       shape (`- [ ] https://github.com/o/r/issues/N`) is NOT matched here
#       (backfill's parser needs a `#N`; the pre-#1260 rule missed it too), an
#       ordered-list checkbox (`1. [ ] #N`) is not matched here (backfill
#       accepts only `[-*+]` bullets), and the blank classes around the bullet
#       are kept identical in both — spelled `[ \t]`, never `[[:blank:]]`:
#       Oniguruma reads the POSIX class as Unicode-aware and awk reads it as
#       ASCII, so the same spelling would denote DIFFERENT sets.
#       Two refs backfill resolves and then deliberately does NOT attach — a
#       genuinely cross-repo ref and a self-reference to the epic — so a body
#       made only of those is an epic here with an empty migration plan. That
#       is why E1 must halt on an empty plan rather than treat exit 0 as done.
#   (b) every line THIS rule ignores as fenced, backfill must ignore too —
#       otherwise it migrates a quoted ref and misparents it (GitHub allows one
#       parent only). So both skip ``` and ~~~ fences, and both track the
#       opener rather than toggling a flag.
# The trailing word boundary is SHARED **for ASCII**: Oniguruma's \b here,
# awk's ASCII `[0-9A-Za-z_]` test there — change it on one side only and (a)
# breaks. For a NON-ASCII word character glued to the ref (`- [ ] #687ä`) the
# two differ, because Oniguruma's word class is Unicode-aware: this rule
# refuses the line, the migrator still resolves `#687`. That is the stricter
# direction, so (a) holds — a deliberate one-sided strictness, listed below.
# Divergences that violate NEITHER direction are fine and deliberate:
# this rule additionally requires a blank after the checkbox, it does not
# match a decorated ref (`- [ ] **#687**`, `- [ ] [#687](url)`), and it refuses
# a ref glued to a NON-ASCII word character (above) — all strictly stricter,
# so (a) still holds.
# Known and OUT of scope for #1260: neither parser understands an INDENTED
# code block (4+ spaces), the other standard way to quote an epic body, so a
# quoted child list in that form is still read as real by both. Closing it
# needs list-context tracking in both parsers; it is not a two-sided-invariant
# violation, since both agree.
# Widening a shape in either direction means changing BOTH scripts, in one
# change, with a test on each side.
#
# Traversal: depth-first over `blockedBy`, transitively. A CLOSED blocker is
# recorded but NOT recursed into — a met prerequisite's own history cannot
# block anything (so a cycle running through a closed issue is inert and goes
# unreported by design). Cycles among open issues are returned explicitly, and
# each issue is fetched exactly once.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary (must accept `api graphql` and print the
#           raw GraphQL response JSON).
#
# Exit codes:
#   0  success — result JSON on stdout
#   2  usage error
#   1  internal error (gh / GraphQL / jq failed, or the issue doesn't exist)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" issue="" max_depth=20
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --issue) (( $# >= 2 )) || die_usage "--issue needs a value"; issue="$2"; shift 2 ;;
  --max-depth) (( $# >= 2 )) || die_usage "--max-depth needs a value"; max_depth="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: read-dependencies.zsh --repo OWNER/NAME --issue N [--max-depth D]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
[[ -n "$issue" ]] || die_usage "--issue N is required"
# the same guard backfill-sub-issues.zsh applies, so the mirrored pair cannot
# drift: without it `--repo owner/name/extra` splits into name="name/extra",
# GraphQL returns null, and a malformed ARGUMENT surfaces as "issue #N not
# found" — a usage error reported as a missing issue
# Neither half may be empty, `.` or `..` (they normalise away). NOT "must start
# alphanumeric": that would refuse `OWNER/.github`, a real repo carrying issues.
local repo_owner="${repo%%/*}" repo_name="${repo#*/}"
[[ "$repo" == */* && "$repo_name" != */* \
   && -n "$repo_owner" && -n "$repo_name" \
   && "$repo_owner" != "." && "$repo_owner" != ".." \
   && "$repo_name" != "." && "$repo_name" != ".." \
   && -z "${repo_owner//[A-Za-z0-9_.-]/}" && -z "${repo_name//[A-Za-z0-9_.-]/}" ]] \
  || die_usage "--repo must be OWNER/NAME, got: $repo"
# at least 1: GitHub issue numbers start there, so 0 cannot name one. Without
# the lower bound the query returns a null issue and the run dies exit 1 with
# "issue #0 not found" — a malformed ARGUMENT reported as a missing issue, the
# same miscategorisation the --repo guard above exists to stop, and one that
# dependency-precheck relays as "the reader failed" (retry) rather than "fix
# the call". Mirrored on --epic in backfill-sub-issues.zsh.
{ [[ "$issue" == <-> ]] && (( issue >= 1 )) } \
  || die_usage "--issue must be a positive number, got: $issue"
issue=$(( issue ))   # 007 -> 7: `--argjson issue` would reject a padded value
                     # only at the final emit, after the whole traversal ran
# at least 1, mirrored in dependency-precheck.zsh so the pair cannot drift:
# a cap of 0 reads no edge at all, so an issue that HAS dependencies comes
# back with an empty blocker set (truncated, hence rejected) and one that has
# none is "cleared" without a single edge being read. Neither is a cap.
{ [[ "$max_depth" == <-> ]] && (( max_depth >= 1 )) } \
  || die_usage "--max-depth must be a positive number, got: $max_depth"
# after argument validation, so `--help` and usage errors keep their own exit
# codes: without this guard every jq call below fails and each issue is
# misreported as "not found" — an unusable toolchain indistinguishable from a
# deleted issue
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "read-dependencies: jq not found on PATH"; exit 1
}
local owner="${repo%%/*}" name="${repo#*/}"

# One GraphQL round-trip per issue, memoized. Each node is normalized to
#   {number, state, epic, blocked_by:[numbers]}
# so the traversal below never touches raw GraphQL shapes.
typeset -A node_cache   # number -> normalized node JSON

_fetch_node() {
  local n="$1" raw
  [[ -n "${node_cache[$n]:-}" ]] && return 0
  raw=$("$gh_bin" api graphql \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          number state body trackedIssuesCount
          subIssuesSummary{total}
          labels(first:100){nodes{name}}
          blockedBy(first:100){nodes{number state repository{nameWithOwner}}}
        }
      }
    }' \
    -f owner="$owner" -f name="$name" -F number="$n" 2>/dev/null) || {
    print -u2 -- "read-dependencies: gh api graphql failed for issue #$n"; return 1
  }
  local node
  node=$(print -r -- "$raw" | jq -ce --arg repo "$repo" '
    # one checkbox line: a child declaration iff its content STARTS with an
    # issue ref (see the header rule) — never a criterion that merely cites one
    def is_child_decl:
      test("^[ \t]*[-*+][ \t]+\\[[ xX]\\][ \t]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+\\b");
    # the body, fence-aware: does it declare at least one child? The fence
    # state carries the OPENER (character + run length), not a bare flag: a
    # fence closes only on a run of the SAME character at least as long, with
    # nothing but blanks after it. A bare toggle would let the ``` inside a
    # ````-fenced markdown example close the outer block — and every quoted
    # `- [ ] #N` after it would read as a real child, which is the #1260 false
    # positive all over again on exactly the issues that discuss task lists.
    def has_child_task_list:
      ((. // "") | split("\n") | map(sub("\r$"; ""))
       | reduce .[] as $line ({fence: null, found: false};
           # THREE or more, as CommonMark and the awk opener both require: a
           # run of one would open a fence on any line that merely STARTS with
           # an inline code span, swallowing the Children list below it
           (($line | capture("^[ \t]*(?<run>```+|~~~+)(?<rest>.*)$")) // {run: "", rest: ""}) as $f
           | if ($f.run | length) > 0 then
               if .fence == null then .fence = {ch: $f.run[0:1], len: ($f.run | length)}
               elif ($f.run[0:1] == .fence.ch) and (($f.run | length) >= .fence.len)
                    and ($f.rest | test("^[ \t]*$")) then .fence = null
               else . end
             elif .fence != null then .
             elif ($line | is_child_decl) then .found = true
             else . end)
       | .found);
    .data.repository.issue
    | { number, state,
        epic: ((.subIssuesSummary.total > 0)
               or ([.labels.nodes[].name] | index("epic") != null)
               or (.trackedIssuesCount > 0)
               or (.body | has_child_task_list)),
        # A blockedBy edge may point at ANOTHER repository (read-sub-issues.zsh
        # documents the same hazard for sub-issues). _fetch_node is hard-bound
        # to --repo, so re-resolving a foreign number here would look up a
        # DIFFERENT issue that happens to share the number: a closed same-repo
        # #7 would make a genuinely-blocked issue report blocked:false, and an
        # open one would graft a whole foreign sub-tree onto the walk. Split
        # them: traverse same-repo numbers, and carry foreign ones through as
        # slugs so nothing is hidden and none is ever re-resolved. An ABSENT
        # slug counts as same-repo — we cannot prove it foreign, and dropping
        # it from the traversal would under-report the blocker set.
        blocked_by: [.blockedBy.nodes[]
                     | select((.repository.nameWithOwner // "") == ""
                              or ((.repository.nameWithOwner | ascii_downcase)
                                  == ($repo | ascii_downcase))) | .number],
        foreign_blocked_by: [.blockedBy.nodes[]
                     | select((.repository.nameWithOwner // "") != ""
                              and ((.repository.nameWithOwner | ascii_downcase)
                                   != ($repo | ascii_downcase)))
                     | {ref: "\(.repository.nameWithOwner)#\(.number)",
                        open: (.state == "OPEN")}] }') || {
    # jq's own stderr is deliberately NOT discarded: this exit-1 path covers
    # both a genuinely absent issue and a jq/program failure, and without the
    # message an operator cannot tell a deleted issue from a broken filter
    print -u2 -- "read-dependencies: issue #$n not found in $repo (or unparseable response)"
    return 1
  }
  node_cache[$n]="$node"
}

typeset -A recorded     # blocker number -> 1 (recorded once, at its MIN depth)
typeset -A rec_at       # blocker number -> its index in blocker_recs
typeset -A depth_of     # blocker number -> the depth currently recorded for it
typeset -A on_path      # number -> 1 (the current DFS stack, for cycles)
typeset -a chain        # the current DFS chain, root first (NB: not `path` — special in zsh)
typeset -a blocker_recs # one compact JSON object per distinct blocker
typeset -a cycle_recs   # one compact JSON array per detected cycle
typeset -A foreign_seen # "owner/name#N" -> 1 (dedup across the whole walk)
typeset -a foreign_recs # one compact JSON object per distinct cross-repo blocker
typeset -A expanded     # number -> 1 once this node's edges have been READ
typeset -A deferred     # number -> 1 while its edges are still unread
local truncated=false

_walk() {  # $1 = issue number whose blockers to expand; depth = ${#chain}
  # NB: every local is declared HERE, once. Re-running `local x` on a
  # parameter that already exists in this scope makes zsh DISPLAY it
  # (`x='…'`) — inside the loop below that would print straight onto the
  # result stdout and corrupt the JSON for any issue with 2+ blockers.
  local n="$1" b node state kind depth rec cyc idx f fref foreign_raw pending capped_raw
  # At the cap, DEFER this node rather than deciding truncation on the spot.
  # Two things must not count as unread: a LEAF (already fetched, so nothing is
  # left), and a node whose edges this walk has ALREADY read via another path —
  # the recursion below is unconditional for an OPEN blocker, so a node reached
  # a second time can land at the cap with its whole subtree enumerated.
  # Deciding here would report a floor for a walk that is exact, and
  # dependency-precheck would render "the list above may be incomplete" onto
  # the issue. The flag is derived once, after the walk, from what is STILL
  # deferred — a node deferred deep and later expanded shallow clears itself.
  if (( ${#chain} >= max_depth )); then
    # A cycle can close HERE, on an edge back onto the current chain — and this
    # is the only path it closes on, because the recursion that would find it
    # is what the cap stops. Record those before any early return: losing one
    # turns REJECT_CYCLE into REJECT_BLOCKED and posts a "resolve the deepest
    # blocker first" instruction that the cycle makes unsatisfiable. The edges
    # are already cached, so this costs no fetch.
    capped_raw=$(print -r -- "${node_cache[$n]}" | jq -r '.blocked_by[]') || {
      print -u2 -- "read-dependencies: failed to read the blockers of issue #$n"; return 1
    }
    for b in ${(f)capped_raw}; do
      [[ -n "$b" ]] || continue
      # a SELF-edge closes here too, and an on_path test alone cannot see it:
      # at the cap this node is deliberately not yet pushed onto the chain.
      # The non-cap path reports this shape, so skipping it would make the two
      # recorders disagree about a contracted shape.
      if [[ "$b" == "$n" ]]; then
        cyc=$(print -r -- "$n,$b" | jq -Rc 'split(",") | map(tonumber)') || {
          print -u2 -- "read-dependencies: failed to record the cycle closing on issue #$b"; return 1
        }
        cycle_recs+=("$cyc")
        continue
      fi
      [[ -n "${on_path[$b]:-}" ]] || continue
      idx=${chain[(i)$b]}
      cyc=$(print -r -- "${(j:,:)chain[$idx,-1]},$n,$b" \
        | jq -Rc 'split(",") | map(tonumber)') || {
        print -u2 -- "read-dependencies: failed to record the cycle closing on issue #$b"; return 1
      }
      cycle_recs+=("$cyc")
    done
    [[ -n "${expanded[$n]:-}" ]] && return 0
    pending=$(print -r -- "${node_cache[$n]}" \
      | jq -r '(.blocked_by | length) + (.foreign_blocked_by | length)') || {
      print -u2 -- "read-dependencies: failed to read the edge count of issue #$n"; return 1
    }
    # never branch arithmetically on an unvalidated substitution: zsh reads an
    # empty value as 0, which would silently mean "nothing unread" — the
    # fail-OPEN direction, and the one wrong answer this flag can give
    [[ "$pending" == <-> ]] || {
      print -u2 -- "read-dependencies: non-numeric edge count for issue #$n"; return 1
    }
    (( pending > 0 )) && deferred[$n]=1
    return 0
  fi
  expanded[$n]=1
  unset "deferred[$n]"
  on_path[$n]=1
  chain+=("$n")
  # checked: unchecked, a jq failure here yields an EMPTY blocker list, the
  # loop never runs, and the issue is reported `blocked: false` at exit 0 —
  # the same silent-success mode the gh path deliberately refuses
  local blocked_by_raw
  blocked_by_raw=$(print -r -- "${node_cache[$n]}" | jq -r '.blocked_by[]') || {
    print -u2 -- "read-dependencies: failed to read the blockers of issue #$n"; return 1
  }
  local -a blockers=( ${(f)blocked_by_raw} )
  # Foreign blockers cannot be traversed (a different repository needs a
  # different query), but an OPEN one still blocks. Record them so `blocked`
  # can stay fail-closed: a gate that cannot verify must never report ready.
  foreign_raw=$(print -r -- "${node_cache[$n]}" | jq -c '.foreign_blocked_by[]') || {
    print -u2 -- "read-dependencies: failed to read the cross-repo blockers of issue #$n"; return 1
  }
  for f in ${(f)foreign_raw}; do
    [[ -n "$f" ]] || continue
    fref=$(print -r -- "$f" | jq -r '.ref') || {
      print -u2 -- "read-dependencies: failed to read a cross-repo blocker ref of issue #$n"; return 1
    }
    [[ -n "${foreign_seen[$fref]:-}" ]] && continue
    foreign_seen[$fref]=1
    foreign_recs+=("$f")
  done
  for b in "${blockers[@]}"; do
    [[ -n "$b" ]] || continue
    if [[ -n "${on_path[$b]:-}" ]]; then
      # the chain closed on itself: report the loop from b's first occurrence
      idx=${chain[(i)$b]}
      # checked: an empty element would corrupt the cycles array, and a cycle
      # is what dependency-precheck escalates as REJECT_CYCLE — losing one
      # silently would let an unsatisfiable graph read as merely blocked
      cyc=$(print -r -- "${(j:,:)chain[$idx,-1]},$b" | jq -Rc 'split(",") | map(tonumber)') || {
        print -u2 -- "read-dependencies: failed to record the cycle closing on issue #$b"; return 1
      }
      cycle_recs+=("$cyc")
      continue
    fi
    _fetch_node "$b" || return 1
    node="${node_cache[$b]}"
    # checked for the same reason: an empty $state is not OPEN, so the sub-tree
    # below this blocker would be silently pruned and the set under-reported
    state=$(print -r -- "$node" | jq -r '.state') || {
      print -u2 -- "read-dependencies: failed to read the state of issue #$b"; return 1
    }
    [[ -n "$state" ]] || {
      print -u2 -- "read-dependencies: empty state for issue #$b"; return 1
    }
    # depth is the MINIMUM over all paths, not the first one DFS happens to
    # take: with R blocked by [A, B] and A blocked by B, B is reached at depth
    # 2 before the top-level pass reaches it at depth 1 — and `depth: 1` is
    # documented as "direct blocker", a claim that reaches the human verbatim
    # in the `comment_md` dependency-precheck renders and the SKILL posts
    depth=${#chain}
    if [[ -z "${recorded[$b]:-}" || depth -lt ${depth_of[$b]} ]]; then
      rec=$(print -r -- "$node" | jq -c --argjson depth "$depth" \
        '{number, state, open: (.state == "OPEN"), kind: (if .epic then "epic" else "issue" end), depth: $depth}') || {
        print -u2 -- "read-dependencies: failed to build the blocker record for issue #$b"; return 1
      }
      if [[ -z "${recorded[$b]:-}" ]]; then
        recorded[$b]=1
        blocker_recs+=("$rec")
        rec_at[$b]=${#blocker_recs}
      else
        blocker_recs[${rec_at[$b]}]="$rec"   # same slot: discovery order holds
      fi
      depth_of[$b]=$depth
    fi
    # a CLOSED blocker is a met prerequisite — its own blockers can't block us
    [[ "$state" == "OPEN" ]] && { _walk "$b" || return 1 }
  done
  chain[-1]=()
  unset "on_path[$n]"
}

_fetch_node "$issue" || exit 1
_walk "$issue" || exit 1
# derive the flag ONCE, from what is still deferred at the end: a node deferred
# at the cap and later expanded from a shallower path has cleared itself, so
# only genuinely-unread edges remain
(( ${#deferred} > 0 )) && truncated=true

_json_array() {  # join pre-validated compact-JSON elements into one array
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}

jq -nc \
  --argjson issue "$issue" \
  --argjson blockers "$(_json_array "${blocker_recs[@]}")" \
  --argjson cycles "$(_json_array "${cycle_recs[@]}")" \
  --argjson foreign "$(_json_array "${foreign_recs[@]}")" \
  --argjson truncated "$truncated" \
  '{ issue: $issue,
     # an OPEN cross-repo blocker blocks too — it simply cannot be traversed,
     # so it never reaches $blockers. Counting it keeps the gate fail-closed:
     # reporting ready on an unverifiable blocker is the one wrong answer.
     blocked: (([$blockers[] | select(.open)] | length > 0)
               or ([$foreign[] | select(.open)] | length > 0)),
     open_blockers: [$blockers[] | select(.open) | .number],
     blockers: $blockers,
     foreign_blockers: $foreign,
     cycles: $cycles,
     truncated: $truncated }' || {
  # unchecked, jq's own exit 2 on a bad --argjson would surface as THIS
  # script's documented exit 2 = "usage error", with nothing on stderr
  print -u2 -- "read-dependencies: failed to emit the result document for issue #$issue"; exit 1
}
