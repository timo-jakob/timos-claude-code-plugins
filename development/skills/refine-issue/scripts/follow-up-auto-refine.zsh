#!/usr/bin/env zsh
# follow-up-auto-refine.zsh — the decisions behind refine-issue's unattended
# follow-up mode (`--follow-up`, issue #2588, epic #2582).
#
# Why: the pipeline files some follow-ups itself — #2578's split children and the
# fix pass's parked findings — and each carries a follow-up-origin/v1 record
# (#2581) naming its source story and its slice. The source story was already
# refined well enough to build, so a follow-up can be refined from it without a
# human. This script holds every decision that mode makes; the skill relays and
# owns every GitHub write. A pure helper: it makes no GitHub calls.
#
# Inputs are files the skill writes from `gh`:
#   --comments FILE  a follow-up's comments: `gh issue view <N> --json comments`
#                    output, a bare array of comment objects, or an array of
#                    comment-body strings
#   --source FILE    the source issue: `gh issue view <S> --json
#                    number,title,body,comments`
#
# Modes:
#   origin --comments FILE
#       Print the follow-up's follow-up-origin/v1 record (one compact JSON line):
#       the first comment holding one. Exit 1 when no comment holds one.
#   eligible --comments FILE --source FILE
#       Print {"eligible": true|false, "reason": R, "source_issue": N|null}. R is
#       `eligible`, or the first refusal in this order:
#         no-origin-record   no comment holds a follow-up-origin/v1 record
#         already-attempted  a comment holds the refine-auto marker: one
#                            attempt per follow-up, so a re-run does nothing
#         second-generation  the source issue itself carries an origin record —
#                            a follow-up filed while resolving a follow-up stays
#                            needs-refinement for a human
#       Exit 0 eligible, 1 refused.
#   seed --comments FILE --source FILE
#       Print the refiner's seed:
#         {"origin": <the record>,
#          "source": {"number", "title", "prose", "story_spec"}}
#       prose is the source body between the story-spec prose sentinels (the
#       whole body when it has none); story_spec is read-story-spec.zsh's block,
#       or null. The seam or finding comes from the origin record alone.
#   decide --split FILE --turn FILE --round R [--max-rounds M]
#       Decide one round from split-refiner-questions.zsh's output (--split) and
#       the refiner's turn (--turn). Print {"decision": D, "park_type": P}, in
#       this order:
#         any `ask` question                       park needs-decision
#         questions == [], resolved_objections
#           non-empty and every entry resolved,
#           proposed_prose a non-blank string and
#           proposed_story_spec an object           accept
#         R >= M (default 3)                        park deferred
#         otherwise                                 continue (re-call the
#                                                   refiner with the auto answers)
#   note --seed FILE --answers FILE --threshold-milli M --decision D [--format md|json]
#       Render the refine-auto comment (md, the default) or the telemetry
#       `auto_refinement` object (json). --answers holds every answer taken
#       automatically across the rounds, as split-refiner-questions.zsh's `auto`
#       entries ([] when none). M is the threshold in thousandths, an integer in
#       0..1000 as split-refiner-questions.zsh takes it; the comment and the
#       json object show it as the number M/1000. D is
#       accept | ready | park-needs-decision | park-deferred; `ready` is Step 1's
#       already-READY shortcut, after zero rounds, when nothing is written back.
#       The accept score is the minimum confidence over the answers, null when
#       there were none.
#
# Exit codes: 0 success · 1 no record (origin) or refused (eligible) ·
#             2 invalid input or usage error

emulate -L zsh
setopt nounset pipefail

readonly MARKER="<!-- refine-auto: follow-up-origin/v1 -->"
readonly PROSE_START="<!-- story-spec:prose:start -->"
readonly PROSE_END="<!-- story-spec:prose:end -->"
readonly SELF_DIR="${0:A:h}"
readonly ORIGIN_TOOL="$SELF_DIR/../../resolve-issue/scripts/follow-up-origin.zsh"
readonly SPEC_TOOL="$SELF_DIR/../../resolve-issue/scripts/read-story-spec.zsh"

_die() { print -u2 -- "follow-up-auto-refine: $1"; exit "${2:-2}" }

# A dangling value flag must not reach `shift 2` (zsh refuses the shift and the
# loop spins); follow-up-origin.zsh guards its parser the same way.
_need_val() {   # $1 = flag, $2 = remaining argc, $3 = the candidate value
  (( $2 >= 2 )) || _die "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _die "$1 requires a value"
}

_readable() {   # $1 = flag, $2 = path
  [[ -n "$2" ]] || _die "$1 is required"
  [[ -f "$2" && -r "$2" ]] || _die "cannot read $1 $2"
}

command -v jq >/dev/null 2>&1 || _die "jq is required"

# The comment bodies in FILE, as one JSON array of strings.
_bodies() {   # $1 = comments file
  jq -c 'if type == "object" then (.comments // error("no comments key")) else . end
    | if type != "array" then error("not an array") else . end
    | map(if type == "string" then . elif type == "object" then (.body // "") else error("bad entry") end)' \
    -- "$1" 2>/dev/null || _die "--comments $1 is not a comment list (gh issue view --json comments)"
}

# The first origin record among the bodies of comments file $1; returns 1 when
# none holds one. A body whose marker is followed by an invalid record is not a
# record: follow-up-origin.zsh parse exits 2 on it, and it is skipped.
_origin_in() {   # $1 = comments file
  local bodies n i rec
  bodies="$(_bodies "$1")" || return 2
  n="$(jq 'length' <<< "$bodies")"
  for (( i = 0; i < n; i++ )); do
    if rec="$(jq -r --argjson i "$i" '.[$i]' <<< "$bodies" | zsh "$ORIGIN_TOOL" parse 2>/dev/null)"; then
      print -r -- "$rec"
      return 0
    fi
  done
  return 1
}

# 0 when some body in comments file $1 holds the refine-auto marker line.
_attempted() {   # $1 = comments file
  local bodies
  bodies="$(_bodies "$1")" || return 2
  jq -e --arg m "$MARKER" 'any(.[]; split("\n") | any(.[]; sub("\r$"; "") == $m))' <<< "$bodies" >/dev/null
}

# Validate the source file and print it compact.
_source_json() {   # $1 = source file
  jq -ce 'select(type == "object" and (.number | type == "number") and (.number >= 1)
                 and (.title | type == "string") and (.body | type == "string"))' \
    -- "$1" 2>/dev/null || _die "--source $1 must be an issue object with number, title and body"
}

(( $# >= 1 )) || _die "usage: follow-up-auto-refine.zsh origin|eligible|seed|decide|note ..."
local mode="$1"; shift

case "$mode" in
  origin)
    local comments=""
    while (( $# )); do
      case "$1" in
        --comments) _need_val "$1" $# "${2:-}"; comments="$2"; shift 2 ;;
        *) _die "origin: unknown argument: $1" ;;
      esac
    done
    _readable --comments "$comments"
    local rec rc=0
    rec="$(_origin_in "$comments")" || rc=$?
    case $rc in
      0) print -r -- "$rec" ;;
      1) print -u2 -- "follow-up-auto-refine: no follow-up-origin/v1 record in the comments"; exit 1 ;;
      *) exit 2 ;;
    esac
    ;;

  eligible|seed)
    local comments="" source=""
    while (( $# )); do
      case "$1" in
        --comments) _need_val "$1" $# "${2:-}"; comments="$2"; shift 2 ;;
        --source)   _need_val "$1" $# "${2:-}"; source="$2"; shift 2 ;;
        *) _die "$mode: unknown argument: $1" ;;
      esac
    done
    _readable --comments "$comments"
    _readable --source "$source"
    local src rec rc=0
    src="$(_source_json "$source")"
    rec="$(_origin_in "$comments")" || rc=$?
    (( rc <= 1 )) || exit 2
    if [[ "$mode" == eligible ]]; then
      local reason="eligible" src_issue="null"
      if (( rc == 1 )); then
        reason="no-origin-record"
      else
        src_issue="$(jq -r '.source.issue' <<< "$rec")"
        [[ "$(jq -r '.number' <<< "$src")" == "$src_issue" ]] \
          || _die "eligible: --source is issue #$(jq -r '.number' <<< "$src"), but the origin record names #$src_issue"
        if _attempted "$comments"; then
          reason="already-attempted"
        else
          local srcc; srcc="$(mktemp "${TMPDIR:-/tmp}/fuar-src.XXXXXX")" || _die "eligible: cannot create a temp file"
          jq -c '.comments // []' <<< "$src" > "$srcc"
          if _origin_in "$srcc" >/dev/null; then reason="second-generation"; fi
          rm -f -- "$srcc"
        fi
      fi
      jq -cn --arg r "$reason" --argjson s "$src_issue" '{eligible: ($r == "eligible"), reason: $r, source_issue: $s}'
      [[ "$reason" == eligible ]] && exit 0 || exit 1
    fi
    # seed
    (( rc == 0 )) || _die "seed: no follow-up-origin/v1 record in the comments"
    [[ "$(jq -r '.number' <<< "$src")" == "$(jq -r '.source.issue' <<< "$rec")" ]] \
      || _die "seed: --source is not the issue the origin record names"
    local body prose spec="null" spec_rc=0
    body="$(jq -r '.body' <<< "$src")"
    prose="$(print -r -- "$body" | awk -v s="$PROSE_START" -v e="$PROSE_END" '
      { sub(/\r$/, "") }
      $0 == s { on = 1; seen = 1; next }
      $0 == e { on = 0; next }
      on { print }
      END { if (!seen) exit 3 }')" || prose="$body"
    spec="$(print -r -- "$body" | zsh "$SPEC_TOOL" 2>/dev/null)" || spec_rc=$?
    case $spec_rc in
      0) ;;
      1) spec="null" ;;
      *) _die "seed: read-story-spec.zsh failed on the source body (exit $spec_rc)" ;;
    esac
    jq -cn --argjson origin "$rec" --argjson src "$src" --arg prose "$prose" --argjson spec "$spec" \
      '{origin: $origin, source: {number: $src.number, title: $src.title, prose: $prose, story_spec: $spec}}'
    ;;

  decide)
    local split="" turn="" round="" max=3
    while (( $# )); do
      case "$1" in
        --split)      _need_val "$1" $# "${2:-}"; split="$2"; shift 2 ;;
        --turn)       _need_val "$1" $# "${2:-}"; turn="$2"; shift 2 ;;
        --round)      _need_val "$1" $# "${2:-}"; round="$2"; shift 2 ;;
        --max-rounds) _need_val "$1" $# "${2:-}"; max="$2"; shift 2 ;;
        *) _die "decide: unknown argument: $1" ;;
      esac
    done
    _readable --split "$split"
    _readable --turn "$turn"
    [[ "$round" == <1-> ]] || _die "decide: --round must be a positive integer (got '$round')"
    [[ "$max" == <1-> ]] || _die "decide: --max-rounds must be a positive integer (got '$max')"
    jq -e 'type == "object" and (.ask | type == "array") and (.auto | type == "array")' -- "$split" >/dev/null 2>&1 \
      || _die "decide: --split is not split-refiner-questions.zsh output ({auto, ask})"
    jq -e 'type == "object" and (.questions | type == "array") and (.resolved_objections | type == "array")' \
      -- "$turn" >/dev/null 2>&1 || _die "decide: --turn has no questions and resolved_objections arrays"
    jq -cn --slurpfile sp "$split" --slurpfile t "$turn" --argjson r "$round" --argjson m "$max" '
      ($sp[0]) as $s | ($t[0]) as $u
      | if ($s.ask | length) > 0 then {decision: "park", park_type: "needs-decision"}
        elif ($u.questions | length) == 0 and ($u.resolved_objections | length) > 0
             and all($u.resolved_objections[]; .resolved == true)
             and ($u.proposed_prose | if type == "string" then (gsub("\\s"; "") | length) > 0 else false end)
             and ($u.proposed_story_spec | type == "object")
          then {decision: "accept", park_type: null}
        elif $r >= $m then {decision: "park", park_type: "deferred"}
        else {decision: "continue", park_type: null} end'
    ;;

  note)
    local seed="" answers="" thr="" decision="" format="md"
    while (( $# )); do
      case "$1" in
        --seed)      _need_val "$1" $# "${2:-}"; seed="$2"; shift 2 ;;
        --answers)   _need_val "$1" $# "${2:-}"; answers="$2"; shift 2 ;;
        --threshold-milli) _need_val "$1" $# "${2:-}"; thr="$2"; shift 2 ;;
        --decision)  _need_val "$1" $# "${2:-}"; decision="$2"; shift 2 ;;
        --format)    _need_val "$1" $# "${2:-}"; format="$2"; shift 2 ;;
        *) _die "note: unknown argument: $1" ;;
      esac
    done
    _readable --seed "$seed"
    _readable --answers "$answers"
    [[ "$thr" =~ '^[0-9]{1,4}$' ]] && (( 10#$thr <= 1000 )) \
      || _die "note: --threshold-milli must be an integer in 0..1000 (got '$thr')"
    case "$decision" in
      accept|ready|park-needs-decision|park-deferred) ;;
      *) _die "note: --decision must be accept, ready, park-needs-decision or park-deferred (got '$decision')" ;;
    esac
    case "$format" in md|json) ;; *) _die "note: --format must be md or json (got '$format')" ;; esac
    jq -e '.origin.kind | IN("split-child", "parked-finding")' -- "$seed" >/dev/null 2>&1 \
      || _die "note: --seed is not a seed (follow-up-auto-refine.zsh seed output)"
    jq -e 'type == "array" and all(.[]; type == "object" and (.question | type == "string")
             and (.answer | type == "string") and ((.confidence | tonumber?) != null))' \
      -- "$answers" >/dev/null 2>&1 \
      || _die "note: --answers must be an array of {question, answer, confidence} (split-refiner-questions.zsh auto entries)"
    local summary
    summary="$(jq -cn --slurpfile sd "$seed" --slurpfile a "$answers" --argjson thr "$(( 10#$thr ))" --arg d "$decision" '
      ($sd[0]) as $s | ($a[0] | map(.confidence | tonumber)) as $c
      | {seed_kind: $s.origin.kind, source_issue: $s.source.number, threshold: ($thr / 1000),
         confidences: $c, accept_score: (if ($c | length) == 0 then null else ($c | min) end),
         decision: $d}')" || _die "note: could not build the summary"
    if [[ "$format" == json ]]; then
      print -r -- "$summary"
      exit 0
    fi
    jq -rn --slurpfile sd "$seed" --slurpfile a "$answers" --argjson sum "$summary" --arg m "$MARKER" '
      ($sd[0]) as $s
      | def esc: gsub("\n"; " ") | gsub("\\|"; "\\|");
        def outcome: {"accept": "accepted: the draft was written back and re-gated",
                      "ready": "already READY: the label was cleared and nothing was written back",
                      "park-needs-decision": "parked (needs-decision): a question needs a human",
                      "park-deferred": "parked (deferred): no convergence within the round cap"}[$sum.decision];
      [ $m,
        "**Refined unattended from #\($s.source.number)** (`/development:refine-issue --follow-up`). Outcome: \(outcome).",
        "",
        "- Source: #\($s.source.number), story-spec `prose_sha256` \(($s.source.story_spec.provenance.prose_sha256 // null) | if . == null then "none (no story-spec block)" else "`\(.)`" end)",
        (if $s.origin.kind == "split-child"
         then "- Seam: child \($s.origin.seam.child) of \($s.origin.seam.of), assigned criteria:",
              ($s.origin.seam.criteria[] | "  - \(.)")
         else "- Finding: `\($s.origin.finding.file)`:\($s.origin.finding.line // "-") (\($s.origin.finding.dimension), round \($s.origin.finding.round)): \($s.origin.finding.title)" end),
        "- Threshold: \($sum.threshold); accept score: \($sum.accept_score // "none (no question was answered automatically)")",
        "",
        (if ($a[0] | length) == 0 then "No answer was taken automatically."
         else "| Answer taken automatically | Confidence |", "|---|---|",
              ($a[0][] | "| \(.question | esc) → \(.answer | esc) | \(.confidence) |") end),
        "",
        "```json",
        ($sum | tojson),
        "```"
      ] | .[]'
    ;;

  *) _die "unknown mode '$mode' (origin | eligible | seed | decide | note)" ;;
esac
