#!/usr/bin/env zsh
# consolidate-findings.zsh — turn a review round's aggregate findings into ONE
# prioritised changelist for the autonomous review loop (epic #557, issue #561).
#
# Why: five reviewers giving unmediated feedback to the implementor produces
# conflicting advice and thrash. This is the single consolidation step between
# the panel and the implementor. It is a DETERMINISTIC engine (jq) so the
# severity mapping, dedup, blocking classification and non-convergence detection
# are reliable and testable — the `review-consolidator` agent wraps it and adds
# the semantic judgment (subtle dedup / genuine conflict) the heuristic can't.
#
# Input: the round's aggregate findings JSON (issue #558 schema — a flat array
# of finding objects). Output on stdout: one changelist JSON:
#   { round, summary{critical,high,low,blocking,conflicts,false_trips,
#                     adjudicated_dropped},
#     blocking[], suggestions[], conflicts[], non_converging, false_trips[],
#     escalation_reasons[] }  (each blocking[] item also carries false_trip:bool,
#     and promoted:true when the overlay raised it — #995)
#
# Rules (per #561):
#   - Severity map: CRITICAL->Critical, WARNING->High, SUGGESTION->Low.
#     Blocking = Critical + High. Low is logged in `suggestions`, never blocks.
#   - Dedup: findings sharing file+line+dimension merge into one item — keep the
#     most detailed description, union the reviewers (agreement = how many), and
#     carry the highest severity seen.
#   - Conflict: co-located findings (same file+line) whose dimensions pull in
#     opposite directions (performance vs code_quality) become a `conflicts`
#     item — surfaced, not silently ordered; a surviving conflict is an
#     escalation reason.
#   - Promotion overlay (#994): with --promote, a human-selected set of waived
#     Low findings is raised SUGGESTION->WARNING *after* dedup and *before* the
#     conflict / non-convergence classification, so a promoted item lands in
#     `blocking` and flows through everything downstream exactly like a
#     reviewer-raised Warning. Matching REUSES the #983 rules rather than exact
#     key equality: candidates are GATHERED on [file, dimension] + line
#     proximity, and the VERDICT is title-identity — exact normalized title, a
#     shared significant token, or a tokenless side promotes; FULLY DISJOINT
#     titles do not. Exact-line equality would silently un-promote an item the
#     moment its own fix shifted the line, which is the one thing a promoted
#     item must survive. A raised item is STAMPED promoted:true (#995) so every
#     surface downstream can tell the human's pick from a reviewer-raised
#     Warning; only Low items are eligible, so a reviewer-raised blocker a key
#     matches is never stamped. Without --promote (or with an empty array) the
#     output is byte-identical to a run without the flag — nothing is stamped.
#   - Non-convergence (#606 + #983): candidates for "this blocked last round too"
#     are GATHERED on [file, dimension] + line proximity (within LINEWIN lines; a
#     missing line on either side is a wildcard). The VERDICT on a candidate is
#     title-IDENTITY (#983): an exact normalized-title match => genuine survivor
#     (non_converging:true, escalates); a non-exact match sharing a significant
#     token — or where either side yields no significant tokens (untitled, or a
#     title of only <4-char words) => AMBIGUOUS (non_converging:true, still
#     escalates — a reword must not defeat the match, #606); a non-exact match
#     whose titles BOTH yield tokens and share NONE => a false trip (false_trip:true,
#     non_converging:false) that does NOT escalate — the loop auto-continues,
#     because it is a genuinely different finding that only landed in the window
#     after a fix shifted lines (#983, the #976 21-minute false escalation). Only
#     non_converging (verified/ambiguous) sets the top-level flag + escalation
#     reason; false_trips are counted in the summary and surfaced for the loop to
#     record.
#
#   - Adjudicated re-raises (#1434): with --adjudicated, a Low finding that
#     re-states a suggestion an EARLIER round already surfaced and waived is
#     dropped instead of being logged again. Three guards, ALL required —
#     narrow on purpose, because the cost of over-dropping is a real defect
#     silently deleted, while the cost of under-dropping is one more logged
#     suggestion that never blocked anything:
#       1. the #983 matcher, reused — gather on [file, dimension] + line
#          proximity (LINEWIN, a null line a wildcard), verdict on the
#          `normtitle` EXACT arm ONLY. Never the shared-token or tokenless arms:
#          those exist to fail TOWARD the human on a possible survivor, and the
#          same leniency here would delete findings on a single shared word;
#       2. the incoming finding is itself Low — a re-raise at WARNING or
#          CRITICAL is never suppressed, whatever an earlier round waived;
#       3. the entry is still valid, which the LOOP enforces by removing every
#          adjudication whose file the last fix pass touched before calling this.
#     The drop runs AFTER the #994 promotion overlay and BEFORE the conflict /
#     non-convergence classification, so a human-promoted item (now WARNING) is
#     structurally ineligible by guard 2 rather than by a special case.
#     `summary.adjudicated_dropped` is ALWAYS present (0 without the flag), so a
#     consumer never has to tell "no drops" from "an older changelist".
#
# Usage:
#   consolidate-findings.zsh --findings FILE [--round N] [--prev FILE]
#                            [--promote FILE] [--adjudicated FILE]
#     --findings  aggregate findings JSON for THIS round (required)
#     --round     round number (default 1)
#     --prev      previous round's changelist JSON (this script's own output);
#                 omitted on round 1
#     --promote   JSON array of identity keys {file, line, dimension, title}
#                 (#994) — the human-selected waived suggestions to raise to
#                 blocking for this round. Omitted outside a promotion sub-loop.
#     --adjudicated  JSON array of the same identity keys (#1434) — the Low
#                 findings prior rounds already surfaced and waived. MAY be
#                 empty (`[]`): an early round legitimately has nothing waived
#                 yet, unlike --promote, where an empty selection is contracted
#                 to skip the sub-loop entirely.
#
# Exit codes: 0 ok · 2 usage error · 1 internal (unreadable / invalid JSON)

emulate -L zsh
setopt nounset pipefail

local usage="usage: consolidate-findings.zsh --findings FILE [--round N] [--prev FILE] [--promote FILE] [--adjudicated FILE]"

# A value flag with no value, or one whose value is the NEXT FLAG, is a caller
# mistake that this script used to turn into the wrong failure. Under `nounset`
# a dangling `--findings` aborted on the bare `$2` with zsh's raw "2: parameter
# not set" and exit 1 — which this script's taxonomy reserves for *internal*
# errors, so a usage mistake was indistinguishable from unreadable input. And
# the unquoted `--prev $VAR` idiom with VAR unset collapses so the next flag
# becomes the value: `--prev --promote` would swallow `--promote`, silently
# consolidating with no overlay. resolve-story-loop.zsh has guarded exactly
# this way since #971; a half-applied rule is the inconsistency the next caller
# trips on, so it covers EVERY value flag here too (#994).
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || {
    print -u2 -- "consolidate-findings: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "consolidate-findings: $1 requires a value (got the flag $3)"; exit 2 }
  # An EXPLICIT empty value is the same mistake wearing a third hat — the
  # realistic `--flag "$VAR"` with VAR unset — and left alone it reads
  # downstream as "flag omitted", exit 0: `--promote ""` would silently drop
  # the whole promoted set and converge the sub-loop having promoted nothing.
  [[ -n "$3" ]] || {
    print -u2 -- "consolidate-findings: $1 requires a non-empty value"; exit 2 }
}

local findings="" round=1 prev="" promote="" adjudicated=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --findings) _need_val "$1" $# "${2:-}"; findings="$2"; shift 2 ;;
  --round) _need_val "$1" $# "${2:-}"; round="$2"; shift 2 ;;
  --prev) _need_val "$1" $# "${2:-}"; prev="$2"; shift 2 ;;
  --promote) _need_val "$1" $# "${2:-}"; promote="$2"; shift 2 ;;
  --adjudicated) _need_val "$1" $# "${2:-}"; adjudicated="$2"; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$findings" ]] || { print -u2 -- "$usage"; exit 2 }
# --round is interpolated as RAW JSON via --argjson, so a junk value does not
# fail here — it fails inside the final jq, whose `||` branch blames the
# FINDINGS file and exits 1 (internal). That is the very confusion _need_val was
# ported to end, so validate the one flag whose value becomes JSON. `<->` admits
# leading zeros, which JSON forbids, hence the 10# normalisation.
[[ "$round" == <-> ]] && [[ ${#round} -le 18 ]] || {
  print -u2 -- "consolidate-findings: --round must be a non-negative integer (got: $round)"; exit 2 }
round=$(( 10#$round ))
[[ -s "$findings" ]] || { print -u2 -- "consolidate-findings: findings file missing or empty: $findings"; exit 1 }

local prev_json='null'
if [[ -n "$prev" ]]; then
  [[ -s "$prev" ]] || { print -u2 -- "consolidate-findings: --prev file missing or empty: $prev"; exit 1 }
  prev_json=$(<"$prev")
fi

# The promoted set defaults to [] so the overlay is a provable no-op when the
# flag is absent — the byte-identity guarantee the story rests on (#994). A
# non-array (an object, a bare string, a truncated write) is refused rather
# than iterated: `$promote[]` over a non-array would abort jq mid-program and
# blank the changelist, turning a caller mistake into a silent empty round.
local promote_json='[]'
if [[ -n "$promote" ]]; then
  # The `-s` guard comes FIRST, exactly as --findings and --prev do. jq exits 0
  # with EMPTY output on an empty file, so without it the capture lands empty,
  # survives to `--argjson promote ""`, and blows up in the final jq — which
  # this script would then report as "invalid findings JSON", pointing the
  # caller at the wrong file entirely.
  # -s alone is TRUE for a directory, so `--promote <a dir>` would pass here and
  # fail inside jq with "Is a directory", which the || below would relabel as a
  # content problem — pointing the caller at the file's CONTENTS when the problem
  # is that it is not a file at all.
  [[ -f "$promote" && -s "$promote" ]] || {
    print -u2 -- "consolidate-findings: --promote must be a non-empty regular file: $promote"; exit 1 }
  # The ELEMENT shape is checked, not just the container. `["a title"]` or `[113]`
  # — the shapes a hand-written or model-written selection most plausibly takes —
  # pass a bare `type == "array"` test, then abort the MAIN jq at `.file` on a
  # string ("Cannot index string with ..."), landing in the final `||` branch
  # that blames the findings file. Worse, that abort is input-dependent: the
  # overlay only evaluates $promote[] for Low items, so the same bad file passes
  # silently on a round with no suggestions and explodes on the next one.
  # jq's stderr is KEPT, not discarded: the promote file is written by a model
  # from a multiSelect, so a syntax slip is the expected failure and jq's
  # "parse error ... at line N, column M" is the one diagnostic that locates it.
  # The script's own message says WHICH input is at fault; jq's says WHERE.
  # the identity keys are required, not just object-ness: `[{}]` or a mis-keyed
  # object would compare against empty strings, match nothing, and turn a
  # caller mistake into a silent no-op round
  # `has()` is true for a key whose value is null or "", and both are meaningless
  # for `file`/`dimension`: they are compared for EQUALITY, so an empty one
  # matches only a finding whose own field was missing. Require real values there.
  # `title` is deliberately allowed to be an empty STRING — a genuinely untitled
  # finding must stay promotable, and the tokenless-title path is safe now that
  # the overlay raises at most one item per key. It must still be a string, so a
  # `null` cannot reach the title rules.
  promote_json=$(jq -c 'if (type == "array")
                           and (all(.[]; type == "object"
                                 and (.file | type == "string" and length > 0)
                                 and (.dimension | type == "string" and length > 0)
                                 and (.title | type == "string")))
                        then . else error("promote input is not an array of identity-key objects") end' \
    -- "$promote") || {
    print -u2 -- "consolidate-findings: --promote file unreadable, or not a JSON array of objects with non-empty file and dimension and a string title: $promote"; exit 1 }
  # jq runs the filter once per TOP-LEVEL value, so a file holding two
  # concatenated arrays (a scratch file re-written with >> instead of >) passes
  # the filter twice and captures two lines. --argjson then rejects it, again in
  # the final jq and again blaming the findings file. `jq -c` emits exactly one
  # line per value, so a newline in the capture is a reliable discriminator.
  [[ "$promote_json" != *$'\n'* ]] || {
    print -u2 -- "consolidate-findings: --promote file must hold exactly ONE JSON array: $promote"; exit 1 }
  # belt and braces: a jq that somehow exits 0 with no output must not reach
  # --argjson either (the failure mode above, arrived at by a different road)
  [[ -n "$promote_json" ]] || {
    print -u2 -- "consolidate-findings: --promote file yielded no JSON value: $promote"; exit 1 }
fi

# The adjudicated list (#1434) defaults to [] so the drop rule is a provable
# no-op without the flag — the same byte-identity discipline --promote follows,
# and the reason `adjudicated_dropped` is the ONLY output difference a run
# without the flag sees. Every refusal below mirrors --promote's, for the same
# reasons (an unchecked bad file aborts the MAIN jq and gets relabelled "invalid
# findings JSON", sending the caller to the wrong input) — with ONE deliberate
# divergence: an EMPTY array is accepted here. Rounds 1-2 of a real run routinely
# have nothing waived yet, so refusing `[]` would make the loop choose between
# omitting the flag on some rounds and failing on others.
local adjudicated_json='[]'
if [[ -n "$adjudicated" ]]; then
  # `-s` alone is true for a directory, which would fail inside jq with "Is a
  # directory" and be relabelled a content problem
  [[ -f "$adjudicated" && -s "$adjudicated" ]] || {
    print -u2 -- "consolidate-findings: --adjudicated must be a non-empty regular file: $adjudicated"; exit 1 }
  # element shape, not just container: `["a title"]` would pass a bare
  # `type == "array"` test and then abort the main jq at `.file` on a string.
  # `file`/`dimension` are compared for EQUALITY so an empty one is meaningless;
  # `title` must be a string but may be empty (the exact arm below refuses to
  # match on an empty normalized title anyway, so such an entry is inert rather
  # than a file-wide suppressor); `line` is the one optional member.
  adjudicated_json=$(jq -c 'if (type == "array")
                              and (all(.[]; type == "object"
                                    and (.file | type == "string" and length > 0)
                                    and (.dimension | type == "string" and length > 0)
                                    and (.title | type == "string")))
                           then . else error("adjudicated input is not an array of identity-key objects") end' \
    -- "$adjudicated") || {
    print -u2 -- "consolidate-findings: --adjudicated file unreadable, or not a JSON array of objects with non-empty file and dimension and a string title: $adjudicated"; exit 1 }
  # a file holding two concatenated arrays (>> instead of >) makes jq emit two
  # lines, which --argjson would reject inside the MAIN jq and blame on findings
  [[ "$adjudicated_json" != *$'\n'* ]] || {
    print -u2 -- "consolidate-findings: --adjudicated file must hold exactly ONE JSON array: $adjudicated"; exit 1 }
  [[ -n "$adjudicated_json" ]] || {
    print -u2 -- "consolidate-findings: --adjudicated file yielded no JSON value: $adjudicated"; exit 1 }
fi

local -r PROG='
def sevrank(s): if s=="CRITICAL" then 3 elif s=="WARNING" then 2 elif s=="SUGGESTION" then 1 else 0 end;
def prio(s): if s=="CRITICAL" then "Critical" elif s=="WARNING" then "High" else "Low" end;
def blocks(s): (s=="CRITICAL" or s=="WARNING");
def normfile: ((. // "") | tostring | sub("^\\./";""));
# title normalization for the #983 identity verdict (an exact normtitle match =>
# a verified survivor) and the possible_false_trip flag (#969): lenient enough
# that pure case/whitespace re-wording is not read as a different finding;
# tostring keeps a malformed non-string title from aborting the whole round
def normtitle: ((. // "") | tostring | ascii_downcase | gsub("\\s+"; " ")
  | sub("^ +"; "") | sub(" +$"; ""));
# Identity verdict tokens (#983): the significant words of a title — lowercase
# alphanumeric runs of length >= 4 (a cheap stopword filter), de-duplicated.
# The cross-round matcher still GATHERS candidates by [file, dimension] + line
# proximity (#606), but the VERDICT on a carried blocker is now identity-based:
#   * an exact normalized-title match among the candidates => a genuine survivor
#     (escalates, as before);
#   * no exact title, but the current title shares ANY significant token with a
#     candidate (or either title is too short to yield tokens) => AMBIGUOUS — it
#     may be a reworded survivor, so it still escalates (fail-toward-the-human);
#   * no exact title AND fully DISJOINT significant tokens => a verified false
#     trip: a genuinely different finding that merely landed in the proximity
#     window after a fix shifted lines. It does NOT escalate — the loop
#     auto-continues and records it (#983). Disjoint titles are the only signal
#     strong enough to auto-continue; a single shared domain word ("coverage",
#     "counter") is deliberately treated as ambiguous, not clear.
def sigtokens: ((. // "") | tostring | ascii_downcase | [ scan("[a-z0-9]+") ]
  | map(select(length >= 4)) | unique);
def shares_token($a; $b): (($a | length) > 0) and (($b | length) > 0)
  and ([ $a[] | select(. as $x | $b | index($x)) ] | length) > 0;
# Candidate GATHER predicate (#606): same file + dimension, with the line close
# enough that a small edit-drift between rounds still matches (a null line on
# either side is a wildcard). The title plays no role in GATHERING — a reviewer
# re-wording the same finding must not stop it being a candidate. The title then
# decides the VERDICT on the gathered set (#983, see the classification block
# below): exact => verified survivor, shared token => ambiguous, disjoint => false
# trip.
def LINEWIN: 10;
# One line-recovery rule for BOTH sides of the proximity test. The findings side
# already recovered a digit-only STRING line losslessly; without the same rule on
# the promote side a key carrying "line": "113" is a non-number, which line_near
# treats as a WILDCARD — silently widening "near line 113" to "anywhere in this
# file+dimension" and over-promoting every title-compatible Low in the file.
def normline: if (. | type) == "number" then .
  elif ((. | type) == "string") and (test("^[0-9]+$")) then tonumber
  else null end;
# A missing or non-numeric line on either side is a wildcard (match) — never a
# type error from subtracting a stray string line.
def line_near($a;$b):
  if (($a | type) == "number") and (($b | type) == "number")
  then ((($a) - ($b)) | (if . < 0 then -. else . end) <= LINEWIN)
  else true end;
# nearest candidate by line distance to $c — stable sort, so wildcard or
# line-less candidates rank last (LINEWIN + 1) and ties keep prior
# blocking-array order; used by BOTH matched_prior branches so co-windowed
# priors always attribute to their own successors (#969)
def nearest($c): sort_by(
  if ((.line | type) == "number") and (($c.line | type) == "number")
  then (((.line) - ($c.line)) | if . < 0 then -. else . end)
  else LINEWIN + 1 end) | .[0];

# previous round blockers projected to [file, dimension, line, title] (empty on
# round 1). The title is load-bearing (#983): it decides the identity verdict
# (exact => verified survivor, token overlap => ambiguous, disjoint => false
# trip) and is part of the one-to-one claim key — not a display-only label.
( ($prev // {}) | (.blocking // [])
  | map({ file: (.file | normfile), dimension: ((.dimension // "") | tostring),
          line: .line, title: (.title // "") }) ) as $prevblk

# normalize this round
| [ .[] | {
    severity: (.severity // "SUGGESTION"),
    dimension: ((.dimension // "") | tostring),
    file: (.file | normfile),
    # number-or-null only: a digit-only string line is recovered losslessly
    # (a plausible model-output malformation), anything else becomes null —
    # already a wildcard for line_near — so no downstream renderer can ever
    # interpolate a reviewer-crafted string line into markdown (#969). ONE rule,
    # shared with the promote-key side via `normline`: two hand-inlined copies is
    # exactly how the two sides drifted apart before #994.
    line: (.line | normline),
    title: (.title // ""),
    description: ((.description // "") | tostring),
    suggested_fix: (.suggested_fix // ""),
    reviewer: (.reviewer // "")
  } ]

# dedup by file+line+dimension
| ( group_by([.file, (.line|tostring), .dimension]) | map(
      (sort_by(.description | length) | last) as $rep
    | ([ .[].severity ] | max_by(sevrank(.))) as $sev
    | $rep + {
        severity: $sev,
        priority: prio($sev),
        blocking: blocks($sev),
        reviewers: ([ .[].reviewer ] | map(select(. != "")) | unique),
        agreement: ([ .[].reviewer ] | map(select(. != "")) | unique | length)
      }
    | del(.reviewer)
  ) ) as $items

# PROMOTION OVERLAY (#994) — human-selected waived suggestions raised to blocking.
# Placed here deliberately: AFTER dedup (so one promoted key cannot bump the same
# finding twice, and the key matches the consolidated title the human was shown)
# and BEFORE conflicts / non-convergence (so a promoted item participates in every
# downstream classification exactly like a reviewer-raised Warning — including
# escalating if it survives two rounds).
#
# Matching REUSES the #983 rules, not exact key equality: GATHER on
# [file, dimension] + line proximity, then decide by title identity — exact
# normalized title, a shared significant token, or a tokenless side promotes;
# FULLY DISJOINT titles do not. That is what lets a promoted item survive its own
# fix shifting the line, which exact `[file,line,dimension,title]` equality could
# not: the first edit above it would silently drop it back to Low and the sub-loop
# would "converge" without doing the work the human asked for.
#
# Only Low items are eligible — an item already blocking needs no raise, and
# re-stamping it would let a promoted key perturb a reviewer-raised finding.
#
# ONE-TO-ONE, like the cross-round matcher below: each promote key raises AT MOST
# ONE item — its nearest eligible candidate — and claims it, so a second key
# cannot take the same item and, crucially, ONE key cannot fan out across several
# neighbouring Lows. The verdict is deliberately lenient (a shared token, or a
# tokenless side, matches), so an unbounded map would let a single selection
# raise every title-compatible Low in the window: blocking work the human never
# picked, any of which can escalate the run at round 2. With an empty $promote
# the reduce returns its seed, hence byte-identical output.
| ( $promote
    | reduce .[] as $k ({ its: $items, claimed: [] };
        .its as $cur | .claimed as $cl
        # gather the candidates for this key: still-Low, not already claimed by an
        # earlier key, same file + dimension, line within the window
        | ( [ $cur | to_entries[]
              | select(.value.priority == "Low")
              # bind the index first: `$cl | index(.key)` would evaluate .key
              # against $cl (an array), not against the entry
              | select(.key as $i | ($cl | index($i)) == null)
              | select((($k.file // "") | normfile) == .value.file
                       and (($k.dimension // "") | tostring) == .value.dimension
                       and line_near(($k.line | normline); .value.line)) ] ) as $g
        | ( [ $g[] | select((($k.title // "") | normtitle) != ""
                 and (($k.title // "") | normtitle) == (.value.title | normtitle)) ] ) as $exact
        | (($k.title // "") | sigtokens) as $kt
        # verdict, same three arms as the cross-round matcher: exact title, a
        # tokenless side, or a shared significant token; disjoint titles never
        | ( if ($exact | length) > 0 then $exact
            elif ($kt | length) == 0 then $g
            else [ $g[] | select(((.value.title | sigtokens) | length) == 0
                     or shares_token($kt; (.value.title | sigtokens))) ] end ) as $elig
        | if ($elig | length) == 0 then .
          else ( $elig | sort_by(
                   if ((.value.line | type) == "number")
                      and ((($k.line | normline) | type) == "number")
                   then (((.value.line) - ($k.line | normline)) | if . < 0 then -. else . end)
                   else LINEWIN + 1 end) | .[0] ) as $best
            | { its: ($cur | .[$best.key] |= (. + { severity: "WARNING",
                        priority: prio("WARNING"), blocking: blocks("WARNING"),
                        # the LABEL (#995): a promoted item is otherwise
                        # indistinguishable from a reviewer-raised Warning
                        # everywhere it is read afterwards. A direct per-item
                        # flag with NO stamp gate (the #983 false_trip
                        # precedent), so an absent flag simply counts 0.
                        promoted: true })),
                claimed: ($cl + [$best.key]) }
          end)
    | .its ) as $items

# ADJUDICATED RE-RAISE DROP (#1434) — a Low that an earlier round already
# surfaced and the human already let go. Placed HERE deliberately: after the
# promotion overlay (so a human-promoted item is WARNING by now and fails guard 2
# structurally — no special case, and no ordering hazard if the overlay changes)
# and before conflicts / non-convergence (so a dropped item cannot go on to seed
# a conflict pair or a carried-blocker match, which would resurrect through a
# side door what the drop just removed).
#
# NB: no apostrophes in this block — the jq program is single-quoted.
# The verdict uses the EXACT arm of the #983 matcher only. Its other two arms — a shared
# significant token, and a tokenless side — exist to fail TOWARD the human when a
# blocker MIGHT be a reworded survivor. Suppression is the opposite direction:
# here a false match deletes a genuine new finding, so only an exact normalized
# title counts, and an entry with an EMPTY normalized title matches nothing at
# all rather than silencing every untitled finding in its file+dimension.
#
# Selection is by POSITION, the same idiom the promote overlay uses for its
# claimed set: an identity-key rebuild would have to re-derive a key that dedup
# already made unique, and `index` on an ARRAY argument is a subsequence search
# in jq, not a membership test — a trap this file must not set for its next
# editor. Positions also leave `$items` itself untouched, which is what keeps a
# run without the flag byte-identical apart from the new count.
| ( [ $items | to_entries[]
      | select(.value.priority == "Low")
      | .value as $it
      | select([ $adjudicated[]
                 | select((($it.title | normtitle) != "")
                     and (((.title // "") | normtitle) == ($it.title | normtitle))
                     and (((.file // "") | normfile) == $it.file)
                     and (((.dimension // "") | tostring) == $it.dimension)
                     and line_near((.line | normline); $it.line)) ] | length > 0)
      | .key ] ) as $adj_idx
| ( $adj_idx | length ) as $adj_dropped
| ( [ $items | to_entries[]
      | select(.key as $i | ($adj_idx | index($i)) == null)
      | .value ] ) as $items

# conflicts: co-located, opposite-direction dimensions (performance vs code_quality)
| ( $items | group_by([.file, (.line|tostring)]) | map(
      select( (length >= 2)
        and ( [ .[].dimension ] as $d
              | ($d | index("performance")) and ($d | index("code_quality")) ) )
      | { file: .[0].file, line: .[0].line,
          between: ["performance","code_quality"],
          items: [ .[] | select(.dimension=="performance" or .dimension=="code_quality")
                   | {dimension, title, priority} ],
          detail: "co-located recommendations pull in opposite directions (performance vs code_quality)" }
  ) ) as $conflicts

# classify carried blockers by cross-round IDENTITY (#983). Candidates are still
# GATHERED on [file, dimension] + line proximity (#606) — a null line on either
# side is a wildcard — but the VERDICT is title-identity, not proximity: an exact
# normalized-title match => genuine survivor (non_converging, escalates); a
# non-exact match that shares a significant token, or a tokenless side => AMBIGUOUS
# (non_converging, escalates — fail-toward-the-human, it may be a reworded
# survivor); a non-exact match with FULLY DISJOINT titles => a false trip that
# does NOT escalate (false_trip:true, non_converging:false — the loop
# auto-continues, #983). Each records matched_prior (its line + title) so a human
# can see what the window hit (#913). possible_false_trip (#969) is "no exact
# title match" on EVERY matched item — including the clear/false_trip branch (true
# there too) — so a surface that wants only the ESCALATING set must read it in
# conjunction with non_converging (as the progress/escalation/telemetry surfaces
# do). Attribution among the escalating set is ONE-TO-ONE: each such item, in
# deduped [file, line, dimension] group order (NOT the Critical-first output
# order), claims the NEAREST still-unclaimed candidate from the pool its verdict
# allows — the exact-title set when verified; ALL matches when the current title yields no
# tokens; otherwise only the token-sharing / tokenless-candidate subset (never a
# disjoint-titled prior) — falling back to the nearest claimed one only when every
# pool candidate is taken, else two carried blockers claim the same prior and the
# distinct-priors fixed count collapses. A false trip is a NEW blocker, not a
# carried one, so it claims nothing. NB: keep this jq program free of
# apostrophes; it lives in a zsh single-quoted string.
| ( $items | reduce .[] as $cur ({out: [], claimed: []};
    ( [ $prevblk[] | select(
          .file == $cur.file and .dimension == $cur.dimension and line_near(.line; $cur.line)) ] ) as $m
    | if ($cur.blocking and ($m | length) > 0)
      then ([ $m[] | select(((.title | normtitle) != "")
               and ((.title | normtitle) == ($cur.title | normtitle))) ]) as $exact
         | ($cur.title | sigtokens) as $ct
         | (if ($exact | length) > 0 then "verified"
            elif ($ct | length) == 0 then "ambiguous"
            elif ([ $m[] | select(((.title | sigtokens | length) == 0)
                     or shares_token($ct; (.title | sigtokens))) ] | length) > 0 then "ambiguous"
            else "clear" end) as $verdict
         | if $verdict == "clear"
           then { out: (.out + [ $cur + {
                    non_converging: false, false_trip: true,
                    matched_prior: ($m | nearest($cur) | {line, title}),
                    possible_false_trip: true } ]),
                  claimed: .claimed }
           else (if $verdict == "verified" then $exact
                 elif ($ct | length) == 0 then $m
                 else [ $m[] | select(((.title | sigtokens | length) == 0)
                          or shares_token($ct; (.title | sigtokens))) ] end) as $cands
              | (.claimed) as $cl
              | ([ $cands[] | [.file, .dimension, .line, .title] as $k
                   | select((any($cl[]; . == $k)) | not) ]) as $free
              | ((if ($free | length) > 0 then $free else $cands end) | nearest($cur)) as $mp
              | { out: (.out + [ $cur + {
                      non_converging: true, false_trip: false,
                      matched_prior: ($mp | {line, title}),
                      possible_false_trip: (($exact | length) == 0) } ]),
                  claimed: (.claimed + [[ $mp.file, $mp.dimension, $mp.line, $mp.title ]]) }
           end
      else { out: (.out + [ $cur + { non_converging: false, false_trip: false } ]), claimed: .claimed }
      end)
    | .out ) as $items

| ( [ $items[] | select(.priority=="Critical") ] ) as $crit
| ( [ $items[] | select(.priority=="High") ] ) as $high
| ( [ $items[] | select(.priority=="Low") ] ) as $low
| ( ($crit + $high) | sort_by(if .priority=="Critical" then 0 else 1 end) ) as $blocking
| ( [ $blocking[] | select(.non_converging) ] | length > 0 ) as $nonconv
# verified false trips (#983): blockers proximity GATHERED as non-convergence
# candidates but identity-cleared (disjoint titles) as genuinely different — they
# are stamped non_converging:false from the start (never set $nonconv), and are
# surfaced so progress/telemetry can record the auto-continue.
| ( [ $blocking[] | select(.false_trip == true) ] ) as $ftrips

| {
    round: $round,
    summary: {
      critical: ($crit | length),
      high: ($high | length),
      low: ($low | length),
      blocking: ($blocking | length),
      conflicts: ($conflicts | length),
      false_trips: ($ftrips | length),
      # ALWAYS present (#1434) — 0 without --adjudicated. A consumer must never
      # have to tell "this round dropped nothing" from "this changelist predates
      # the key", which is the same argument promotion_phase carries in the
      # status JSON.
      adjudicated_dropped: $adj_dropped
    },
    blocking: $blocking,
    suggestions: $low,
    conflicts: $conflicts,
    non_converging: $nonconv,
    false_trips: $ftrips,
    escalation_reasons: (
      ( if ($conflicts | length) > 0 then ["unresolved_conflict"] else [] end )
      + ( if $nonconv then ["non_converging_blocker"] else [] end )
    )
  }
'

jq -c --argjson round "$round" --argjson prev "$prev_json" --argjson promote "$promote_json" \
  --argjson adjudicated "$adjudicated_json" \
  "$PROG" -- "$findings" || {
  print -u2 -- "consolidate-findings: invalid findings JSON: $findings"; exit 1
}
