#!/usr/bin/env zsh
# build-dossier.zsh — turn a PR-OPENING review-loop status JSON (from
# resolve-story-loop.zsh, #562) into the PR "Review dossier" section: the durable
# audit record for why auto-merge happened (epic #557, issue #563).
#
# TWO terminal states open a PR and so reach this script: `CONVERGED` (exit 0)
# and, since #1435, `CONVERGED_WITH_RESIDUE` (exit 14) — a run whose only
# remaining blockers were non-critical and confined to the previous round own
# fix pass, which opens the PR and files the remainder as follow-up issues. The
# status is rendered as-is rather than gated on, so the dossier states which of
# the two it was and a residue PR is auditable as exactly what it is: reviewed,
# green, and carrying named follow-ups.
#
# It emits, on stdout:
#   1. a human-readable "## Review dossier" markdown section — per-round blockers
#      found/fixed, dimensions reviewed, waived Low suggestions, reviewers, and
#      the final consolidator state. Each dimension also carries `open` (#1435):
#      the blockers still open in the BLOCKING phase's final changelist when the
#      PR was opened — deliberately NOT "at the terminal", since `$terminal` is a
#      bound name here meaning the PROMOTION status whenever the pair is passed,
#      and the count must not come from it (see the in-body comment). It is 0
#      everywhere but a residue run, whose dimensions read "N blocking found, K
#      still open" rather than claiming a fix that did not happen; and
#   2. a hidden JSON block  <!-- review-dossier: {…} -->  dimension-tagged with
#      the #449 enum, so the Approver re-ingests reviewer verdicts into its risk
#      register the same way maintenance re-ingests Approver findings today. An
#      empty (clean) dimension lets the Approver lower that lens's residual-risk
#      weight; the waived-Low list is context, not a finding.
#
# A suggestion-promotion phase (#994) is a SECOND, ordinary run of the same state
# machine, so it leaves a second status JSON. The Approver parses exactly ONE
# hidden block, so both phases are merged here into ONE section and ONE block
# (#1064): rounds summed, `status`/`final` describing the promotion phase (the
# run's terminal state), and a `promotion` object recording what the human picked
# versus what the phase actually raised.
#
# If the loop did not run (--no-review / no rounds in EITHER phase), nothing is
# emitted (exit 0) so the PR body is exactly as it is today.
#
# Usage:  build-dossier.zsh --status FILE [--promotion-status FILE --promoted FILE]
# Exit codes: 0 ok (may be empty) · 2 usage · 1 bad input (not a regular
#             non-empty file, not exactly one JSON object / array, or a
#             `--status` naming a non-PR-opening or non-terminal status — see
#             the guard below). Every non-zero exit emits NOTHING on stdout.

emulate -L zsh
setopt nounset pipefail

local status_file="" promotion_status_file="" promoted_file=""
local -r USAGE="usage: build-dossier.zsh --status FILE [--promotion-status FILE --promoted FILE]"

# `--status --promoted` must not silently swallow the next FLAG as this one's
# value (the consolidate-findings precedent): a missing value is a usage error.
_need_val() {  # $1 = flag, $2 = remaining argc, $3 = candidate value
  [[ "$2" -ge 2 && "$3" != -* ]] || { print -r -u2 -- "build-dossier: $1 requires a value"; exit 2 }
  # the third arm of the cited precedent: an empty string is not flag-shaped, so
  # `--promoted "$VAR"` with VAR unset would otherwise fall through to the
  # atomic-pair check and name a flag the caller demonstrably DID pass.
  [[ -n "$3" ]] || { print -r -u2 -- "build-dossier: $1 requires a non-empty value"; exit 2 }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  --promotion-status) _need_val "$1" $# "${2:-}"; promotion_status_file="$2"; shift 2 ;;
  --promoted) _need_val "$1" $# "${2:-}"; promoted_file="$2"; shift 2 ;;
  -h|--help) print -r -- "$USAGE"; exit 0 ;;
  -*) print -r -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -r -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -r -u2 -- "$USAGE"; exit 2 }

# --- the promotion flags are an ATOMIC PAIR ---------------------------------
# Each alone is meaningless: a promotion status with no selection cannot report
# what the human picked, and a selection with no promotion status has no phase
# to describe. Silently ignoring the lone flag would ship a dossier that looks
# complete while omitting the phase entirely — the exact failure #1064 exists to
# close — so it is a usage error, not a fallback.
if [[ -n "$promotion_status_file" && -z "$promoted_file" ]]; then
  print -r -u2 -- "build-dossier: --promotion-status requires --promoted (they are an atomic pair)"; exit 2
fi
if [[ -n "$promoted_file" && -z "$promotion_status_file" ]]; then
  print -r -u2 -- "build-dossier: --promoted requires --promotion-status (they are an atomic pair)"; exit 2
fi

# --- input validation, one shape for every status input ----------------------
# Parity with the promotion inputs (#1064): `-s` alone let a file holding the
# literal `null` through, whereupon `(.round_changelists // []) | length` is 0
# and the script exited 0 having emitted NOTHING — the PR silently lost its
# dossier with no diagnostic anywhere. `-s` is also true for a directory, which
# would fail inside jq and be relabelled as a content problem. Require a regular
# non-empty file holding exactly ONE JSON OBJECT.
# NB: the local is `file`, never `path` — in zsh `path` is the array form of
# PATH, so `local path="$1"` silently replaces the command search path with a
# filename and every external command in this function stops resolving.
_read_status() {  # $1 = file, $2 = flag label; echoes the compact JSON
  local file="$1" label="$2" json
  [[ -f "$file" && -s "$file" ]] || {
    print -r -u2 -- "build-dossier: $label must be a non-empty regular file: $file"; exit 1 }
  json=$(jq -c 'if type == "object" then . else error("status input is not a JSON object") end' -- "$file") || {
    print -r -u2 -- "build-dossier: $label unreadable, or not a JSON object: $file"; exit 1 }
  # jq runs the filter once per TOP-LEVEL value, so a file holding two
  # concatenated objects (a scratch file re-written with >> instead of >) passes
  # twice and captures two lines; --argjson would then reject it far from here.
  [[ "$json" != *$'\n'* ]] || {
    print -r -u2 -- "build-dossier: $label must hold exactly ONE JSON object: $file"; exit 1 }
  # belt and braces: a jq that somehow exits 0 with no output must not reach
  # --argjson either (the same failure arrived at by a different road)
  [[ -n "$json" ]] || {
    print -r -u2 -- "build-dossier: $label yielded no JSON value: $file"; exit 1 }
  print -r -- "$json"
}

local status_json="" promotion_status_json="null" promoted_json="[]"
status_json=$(_read_status "$status_file" "--status") || exit $?

# --- --status must be a PR-OPENING terminal ---------------------------------
# The header says only two states reach this script; until #1435 that was merely
# assumed, and an escalation status handed over by mistake rendered a slightly-off
# round count. It cannot stay assumed now: an escalation's `final_changelist`
# carries blockers by construction, so `open > 0` fires and the residue paragraph
# below asserts — in the one document that exists to BE the audit record — that a
# PR was opened, that the blockers were non-critical and fix-touched, and that
# each was filed as a follow-up. Three claims nothing established.
#
# Refusing up front closes the whole class rather than one sentence, and it is
# the same guard build-residue-issues.zsh applies to the same operand for the
# same reason. Exit 1, not 2: this operand's other content failures are 1, and a
# status file that exists and parses but describes the wrong run is an input
# problem rather than a malformed command line.
#
# Stated as a DENY-list of the endings that open no PR, not an allow-list of the
# two that do. `SKIPPED` (the `--no-review` fast path) and a zero-round status
# both legitimately reach this script and correctly emit nothing, so an
# allow-list would turn two working no-ops into hard failures — and it would
# have to be revisited for every future terminal, whereas "an escalation never
# opens a PR" is the invariant that actually motivates the guard.
#
# `AWAITING_FIX` is in the list and is the one that matters most in practice: it
# is not an ending at all, and it is the status the loop writes MOST often —
# every intermediate step-mode round overwrites `--status-file` with it, where an
# escalation is written at most once per run. Its `final_changelist.blocking` is
# non-empty by construction (that is what "awaiting a fix" means), so a stale one
# renders the residue paragraph and contradicts itself inside one section
# ("exited **AWAITING_FIX**" above "the loop ended **CONVERGED_WITH_RESIDUE**").
_refuse_non_pr_terminal() {  # $1 = compact status JSON, $2 = flag label
  local st=""
  st=$(print -r -- "$1" | jq -r '.status // empty' 2>/dev/null) || st=""
  case "$st" in
    ESCALATE_*|BUDGET_EXHAUSTED|ERROR|STALE_FINDINGS|AWAITING_FIX)
      print -r -u2 -- "build-dossier: $2 is a non-PR-opening or non-terminal status (${st}) — no escalation opens a PR and AWAITING_FIX is not an ending, so a dossier built from one would attest in the audit record to a merge that never happened. Pass the status of the run that opened this PR."
      exit 1 ;;
  esac
}
_refuse_non_pr_terminal "$status_json" "--status"

# The promotion operand's narrower cousin: NON-ENDINGS only. See the call site
# below for why the escalating endings deliberately stay renderable here.
_refuse_non_ending_promotion() {  # $1 = compact promotion status JSON
  local st=""
  st=$(print -r -- "$1" | jq -r '.status // empty' 2>/dev/null) || st=""
  case "$st" in
    AWAITING_FIX|STALE_FINDINGS|ERROR)
      print -r -u2 -- "build-dossier: --promotion-status is not an ending (${st}) — the dossier would report the run exited a status the loop never terminates on, and on a residue PR that line sits directly above 'the loop ended CONVERGED_WITH_RESIDUE'. Pass the promotion phase's terminal status."
      exit 1 ;;
  esac
}

if [[ -n "$promotion_status_file" ]]; then
  promotion_status_json=$(_read_status "$promotion_status_file" "--promotion-status") || exit $?
  # Guarded NARROWLY, and the narrowness is the point. #1064 contracts this
  # operand as renderable in a non-`CONVERGED` **ending** — the section says "and
  # the phase exited **X**" precisely so a promotion phase that did not clear its
  # picks is reported rather than hidden — so the escalating endings must stay
  # through. Nothing in #1064 contracts a NON-ending, and one of those is the
  # real hazard: `$terminal` is this operand whenever the pair is passed, so its
  # status is what the opening sentence and the hidden block report. A stale
  # `AWAITING_FIX` — the value the sub-loop overwrites its status file with every
  # intermediate round, i.e. the most-written value here — would render "exited
  # **AWAITING_FIX**" above "the loop ended **CONVERGED_WITH_RESIDUE**": the same
  # self-contradiction the `--status` guard exists for, relocated to the sibling
  # operand.
  _refuse_non_ending_promotion "$promotion_status_json"
  # the SELECTION file, same element-shape discipline as consolidate-findings'
  # --promote: `["a title"]` or `[113]` pass a bare `type == "array"` test and
  # then abort deep inside the main jq, blaming the wrong input.
  [[ -f "$promoted_file" && -s "$promoted_file" ]] || {
    print -r -u2 -- "build-dossier: --promoted must be a non-empty regular file: $promoted_file"; exit 1 }
  # Same discipline as the LOOP's own --promote validator, `length > 0`
  # included: selecting nothing is contracted to skip the sub-loop entirely, so
  # an empty array means no phase ran and the pair should not have been passed.
  # (The consolidator ENGINE is the lenient one — it tolerates `[]` as a
  # provably no-op overlay; the loop refuses it at exit 2, this at exit 1.)
  # Emitting `selected: 0` would assert in the durable audit record that a phase
  # happened which by contract cannot have.
  promoted_json=$(jq -c 'if (type == "array") and (length > 0)
                            and (all(.[]; type == "object"
                                  and (.file | type == "string" and length > 0)
                                  and (.dimension | type == "string" and length > 0)
                                  and (.title | type == "string")))
                         then . else error("promoted input is not an array of identity-key objects") end' \
    -- "$promoted_file") || {
    print -r -u2 -- "build-dossier: --promoted file unreadable, or not a NON-EMPTY JSON array of objects with non-empty file and dimension and a string title: $promoted_file"; exit 1 }
  [[ "$promoted_json" != *$'\n'* ]] || {
    print -r -u2 -- "build-dossier: --promoted file must hold exactly ONE JSON array: $promoted_file"; exit 1 }
  [[ -n "$promoted_json" ]] || {
    print -r -u2 -- "build-dossier: --promoted file yielded no JSON value: $promoted_file"; exit 1 }
fi

# --- nothing to render when NEITHER phase ran --------------------------------
# Summed across phases (#1064): gating on the blocking phase alone discarded a
# real promotion phase's record whenever the blocking phase had zero rounds.
local nrounds=""
nrounds=$(jq -n --argjson s "$status_json" --argjson p "$promotion_status_json" \
  '(($s.round_changelists // []) | length) + ((($p // {}).round_changelists // []) | length)') || {
  print -r -u2 -- "build-dossier: could not count rounds"; exit 1 }
[[ "$nrounds" -gt 0 ]] || exit 0

# --- the machine-readable dossier object (dimension-tagged, #449 enum) -------
#
# THE PROMOTED-ITEM EXCLUSION (#1064). An item the human promoted and the
# sub-loop fixed must not still read as "logged and deliberately not acted on".
# The set to drop is taken from the ENGINE'S OWN VERDICT — the `promoted: true`
# stamp the overlay writes on each item it raised (#995) — never from re-running
# the match here, so the dossier and the overlay can never disagree about what
# was promoted.
#
# Identity for the drop is [file, dimension, normalized title] — LINE-INSENSITIVE
# (the promotion phase re-reports an item at its current line, which has drifted
# from the line the blocking phase recorded) but requiring an EXACT normalized
# title. That is deliberately STRICTER than the overlay's own verdict, which also
# promotes on a shared significant token: an item whose title the panel REWORDED
# between phases is fixed but stays listed as waived. The asymmetry is chosen for
# its failure direction — the strict rule can only ever leave a fixed item listed
# (conservative, visible, and contradicted by the promotion counts right above
# it), whereas token-matching here could DROP a genuinely waived neighbour that
# merely shares a word, hiding real un-actioned work. The overlay can afford
# leniency because it is line-windowed and one-to-one; the dossier reconstructs
# neither bound.
local dossier=""
dossier=$(jq -cn --argjson s "$status_json" --argjson p "$promotion_status_json" \
              --argjson sel "$promoted_json" '
  def normtitle: ((. // "") | tostring | ascii_downcase | gsub("\\s+"; " ")
    | sub("^ +"; "") | sub(" +$"; ""));
  # a STRING key, not an array: jq index() on an array argument searches for a
  # SUBSEQUENCE, so an array-valued identity would match by accident.
  def identkey: [(.file // ""), (.dimension // ""), (.title | normtitle)] | tojson;
  # the overlay title-verdict helpers, copied verbatim from consolidate-findings
  # so the dossier attributes a raise to the same key the engine did
  def sigtokens: ((. // "") | tostring | ascii_downcase | [ scan("[a-z0-9]+") ]
    | map(select(length >= 4)) | unique);
  def shares_token($a; $b): (($a | length) > 0) and (($b | length) > 0)
    and ([ $a[] | select(. as $x | $b | index($x)) ] | length) > 0;
  ["bugs","security","performance","code_quality","tests"] as $core
  | (($s.round_changelists // [])) as $brounds
  | ((($p // {}).round_changelists // [])) as $prounds
  # PROMOTION FIRST in the concatenation. This ordering decides exactly ONE case:
  # an item both phases report at the SAME [file, line, dimension, title], where
  # unique_by keeps the first of the group and the raised (blocking) view from
  # the promotion phase therefore wins over the waived (Low) view. It does NOT
  # handle the drifted-line case — there the two views land in different groups
  # and never merge; the line-insensitive exclusion below is what resolves that.
  # (No apostrophes in these jq comments: the program is a single-quoted shell
  # string, so one would close it and hand the rest to the shell as code.)
  | [ ($prounds[], $brounds[]) | (.blocking[]?, .suggestions[]?) ] as $allf
  # the raised set: every identity the overlay actually stamped, deduped (a
  # promoted item that survives two rounds is stamped in each)
  # Same per-item expression as the four sibling copies (progress block,
  # escalation table, telemetry payload, and the round-suffix read below) —
  # change all five together (#995/#1064). THIS read is the one whose failure is
  # silent: move the stamp and the waived-list exclusion simply stops firing, so
  # a promoted-and-fixed item reappears as a waived suggestion.
  | ([ $prounds[] | .blocking[]? | select(.promoted == true) | identkey ] | unique) as $raised
  | (reduce $raised[] as $k ({}; . + { ($k): true })) as $raisedset
  | ( [ $allf[] | {file, line, dimension, title,
                   priority: (.priority // "Low"),
                   reviewers: (.reviewers // [])} ]
      | unique_by([.file, .line, .dimension, .title]) ) as $u
  # ONE exclusion, applied ONCE, upstream of BOTH the dimension counts and the
  # waived list — so the rendered and machine-readable halves cannot disagree.
  # Only Lows are dropped: the raised item itself must keep counting as blocking.
  | [ $u[] | select((.priority == "Low") and ($raisedset[identkey] == true) | not) ] as $uv0
  # CROSS-PHASE Low dedupe, by the same line-insensitive identity. unique_by
  # above keys on the LINE, so an unpromoted waived Low that the promotion panel
  # re-reports at a drifted line survives as two entries — listed twice in the
  # waived list and counted twice in its dimension. Deduped here via a reduce
  # rather than a second unique_by so the surviving ORDER is untouched: a plain
  # unique_by would re-sort the waived list, changing the single-phase output
  # that is otherwise byte-identical to before this merge existed.
  # Gated on a promotion phase being present. The same drifted-line collision is
  # reachable WITHIN one phase (a Low re-reported by a later round after a fix
  # shifted it), where the pre-#1064 script listed both — so running this
  # unconditionally would change single-phase output, which must stay
  # byte-identical to before this merge existed. Cross-phase merging is the only
  # duplication #1064 introduces, so it is the only one it removes.
  | ( if $p == null then $uv0
      else ( reduce $uv0[] as $x ({ seen: {}, out: [] };
               ($x | identkey) as $k
               | if ($x.priority == "Low") and (.seen[$k] == true) then .
                 else { seen: (if $x.priority == "Low" then (.seen + { ($k): true }) else .seen end),
                        out: (.out + [$x]) } end) | .out ) end ) as $uv
  | (($core + ($uv | map(.dimension))) | unique) as $dims
  | (if $p == null then $s else $p end) as $terminal
  # Blockers still OPEN, per dimension (#1435). Until residue existed this was
  # zero by construction — the only PR-opening terminal was CONVERGED, whose
  # final changelist has none — so the rendered line could say "found & fixed"
  # unconditionally. A CONVERGED_WITH_RESIDUE run opens its PR with blockers
  # still open and files them as follow-ups, and a dossier that called those
  # fixed would be a confidently wrong number in the one document that exists to
  # be the audit record.
  #
  # Read from the BLOCKING phase, and specifically NOT from `$terminal`.
  # `$terminal` is the PROMOTION status whenever the pair is passed — and §3.5
  # routes a residue run through the promotion offer before the residue branch,
  # so that is the normal path, not a corner. Keyed on `$terminal` the promotion
  # phase (which converges clean) would supply the counts, every dimension would
  # read 0, and the body would pair a Summary naming the residue ending with a
  # dossier asserting the same blockers were fixed.
  #
  # `$s` is the exactly-right source, not a narrowing: residue is single-phase
  # (#1435 — the loop never declares it in a promotion sub-loop), so the blocking
  # phase is the ONLY one whose leftover blockers can be "still open" on a PR,
  # and the only one the residue branch files from. Summing `$p` in as well would
  # let a promotion phase that is renderable-but-not-clean (#1064 keeps that
  # shape) inflate a count the very next lines describe as filed. On every
  # non-residue run the array is empty anyway, so CONVERGED output is unchanged.
  #
  # Gated on the residue status as well, so the MACHINE-READABLE `open` carries
  # the same predicate as the prose that describes it. The two rendered arms are
  # `$isresidue`-gated; leaving the JSON count on the raw array would let the
  # hidden block report `open: N` while the line beside it says "found & fixed" —
  # and the Approver reads the JSON half. No status the loop writes reaches that
  # state today, but the guard above is deliberately a DENY-list, so a terminal
  # added later passes by default: this makes `open` 0 off the residue path by
  # construction rather than by luck.
  | (if $s.status == "CONVERGED_WITH_RESIDUE"
     then ($s.final_changelist.blocking // []) else [] end) as $openblk
  | ( reduce $openblk[] as $b ({};
        ((($b.dimension // "") | tostring)) as $bd
        | . + { ($bd): ((.[$bd] // 0) + 1) }) ) as $openmap
  | ( reduce $dims[] as $d ({};
        . + { ($d): {
          blocking: ([ $uv[] | select(.dimension==$d and (.priority=="Critical" or .priority=="High")) ] | length),
          suggestions: ([ $uv[] | select(.dimension==$d and .priority=="Low") ] | length),
          open: ($openmap[$d] // 0),
          clean: ([ $uv[] | select(.dimension==$d) ] | length == 0)
        }}) ) as $dimmap
  | {
      status: $terminal.status,
      rounds: ((($s.rounds // ($brounds | length))) + (if $p == null then 0 else ($p.rounds // ($prounds | length)) end)),
      repo_type: ($s.repo_type // ($p // {}).repo_type),
      dimensions: $dimmap,
      waived_low: [ $uv[] | select(.priority=="Low") | {file, line, dimension, title} ],
      # Reviewers come from the widest set, because BOTH the exclusion and the
      # cross-phase dedupe drop whole findings — and a dropped copy may name a
      # reviewer the surviving one does not (each round consolidates only its
      # own reporters). Such a reviewer did review this change and must not
      # vanish from the audit record. $allf is pre-dedupe and pre-exclusion; the
      # $p == null arm keeps single-phase output byte-identical.
      reviewers: ([ (if $p == null then $u else $allf end)[] | .reviewers[]? ] | unique),
      final: ($terminal.final_changelist.summary // {})
    }
  | if $p == null then . else . + { promotion: {
      rounds: ($p.rounds // ($prounds | length)),
      status: $p.status,
      selected: ($sel | length),
      # How many of the human KEYS the engine raised — never how many distinct
      # findings it stamped. Across rounds one key can be re-matched to a
      # succession of different findings as the text it names moves (the overlay
      # is one-to-one per ROUND, not per phase), so counting stamped identities
      # can exceed `selected` and render the nonsense "selected 1, of which 2
      # were raised". Bounded by construction: a key counts once, when some
      # stamped identity shares its file and dimension. Deliberately ignoring the
      # title here — the overlay raises on a shared token or a tokenless side, so
      # the raised title legitimately differs from the key it came from.
      promoted: ([ $sel[]
                   | (.file // "") as $kf | (.dimension // "") as $kd
                   | ((.title // "") | normtitle) as $kt
                   | ((.title // "") | sigtokens) as $ktok
                   | select([ $raised[] | fromjson
                              | select(.[0] == $kf and .[1] == $kd
                                  and (.[2] == $kt
                                       or ($ktok | length) == 0
                                       or ((.[2] | sigtokens) | length) == 0
                                       or shares_token($ktok; (.[2] | sigtokens)))) ]
                            | length > 0) ]
                 | length)
    } } end') || { print -r -u2 -- "build-dossier: could not build dossier"; exit 1 }

# --- human-readable section --------------------------------------------------
# BUFFERED, then printed once (#1064). Streaming this block straight to stdout
# meant a jq failure part-way through shipped a TRUNCATED dossier at exit 0 — a
# PR body carrying half a section and no hidden block, with nothing to signal it.
local section=""
section=$(jq -rn --argjson s "$status_json" --argjson p "$promotion_status_json" \
                 --argjson d "$dossier" '
  # the second of the two build-dossier stamp reads — same per-item expression
  # as the four sibling copies; change all five together (#995/#1064)
  def roundline($r; $label): "- \($label)\($r.round): \($r.summary.blocking) blocking"
    + (if (([ $r.blocking[]? | select(.promoted == true) ] | length) > 0)
       then " (\([ $r.blocking[]? | select(.promoted == true) ] | length) promoted)" else "" end)
    + (if ($r.summary.conflicts // 0) > 0 then ", \($r.summary.conflicts) conflict(s)" else "" end)
    + ", \($r.summary.low) suggestion(s) logged";
  # the residue predicate, bound ONCE so the paragraph and the per-dimension arm
  # can never key on different things (#1435). It is the BLOCKING phase status:
  # residue is single-phase by construction, so that is exactly the condition
  # under which "still open" blockers exist and were filed.
  ($s.status == "CONVERGED_WITH_RESIDUE") as $isresidue
  | [ "## Review dossier",
    "",
    ("The local review loop ran **\($d.rounds) round(s)** and exited **\($d.status)** "
     + "before this PR was opened — CI is only spent on code the reviewer panel already converged on."),
    ""
  ]
  # RESIDUE (#1435). `status` reports the TERMINAL phase by the #1064 rule, so on
  # a residue run that also ran a promotion phase it reads `CONVERGED` and the
  # residue ending would otherwise be invisible here — while the per-dimension
  # lines below say "still open". Name it, so the section cannot contradict
  # itself.
  #
  # Gated on the STATUS, not on the open count. The paragraph asserts a terminal
  # and a filing, and neither is derivable from a count: any status whose final
  # changelist still carries blockers makes a count-gate fire, so a stale one
  # would have the audit record assert a terminal that never happened. The
  # single-phase rule (#1435: residue is never declared in a promotion sub-loop)
  # makes the status of the blocking phase the exactly-correct predicate, so the
  # count survives only as the NUMBER the sentence reports.
  # (NB: no apostrophes in this block — the jq program is single-quoted.)
  + (if $isresidue then
      [ ("**This PR carries residue** (#1435): the loop ended "
         + "**CONVERGED_WITH_RESIDUE** with "
         + "**\($d.dimensions | to_entries | map(.value.open // 0) | add // 0)** blocking finding(s) still open. "
         + "Every one was non-critical and confined to the previous round own fix pass, and each was filed "
         + "as a labelled follow-up issue — they were NOT fixed here. The per-dimension lines below say which."),
        "" ]
     else [] end)
  + (if $p == null then [] else
      [ ("A **suggestion-promotion phase** (#994) ran after convergence: the human selected "
         + "**\($d.promotion.selected)** waived suggestion(s), of which **\($d.promotion.promoted)** "
         + "were raised to blocking over \($d.promotion.rounds) round(s)"
         # only a CONVERGED promotion phase actually cleared them; saying
         # "cleared" next to an exited-BUDGET_EXHAUSTED line contradicts itself
         + (if $d.promotion.status == "CONVERGED" then " and cleared."
            else " and the phase exited **\($d.promotion.status)**." end)
         + " Promoted-and-fixed items are excluded from the waived list below."),
        "" ] end)
  + [ "**Per round**", "" ]
  + [ ($s.round_changelists[]? | roundline(.; "Round ")) ]
  + (if $p == null then [] else [ ($p.round_changelists[]? | roundline(.; "Promotion round ")) ] end)
  + [ "", "**Dimensions reviewed** (#449 lenses)", "" ]
  + [ ($d.dimensions | to_entries[] |
        if .value.clean then "- `\(.key)` — ✓ clean (reviewed, no findings)"
        # "found & fixed" is only true when NOTHING is still open in this
        # dimension at the terminal. A residue run (#1435) opens its PR with
        # blockers outstanding, so it says how many and where they went instead
        # of claiming a fix that did not happen. `open` is 0 on every other
        # terminal, so this arm is unreachable off the residue path and the
        # CONVERGED rendering is byte-identical.
        # "filed" is unconditional because residue is single-phase by
        # construction (the loop never declares it in a promotion sub-loop,
        # #1435), so every open blocker on a residue run came from the blocking
        # phase — the one the residue branch files from. That reasoning is about
        # the STATUS, so the arm tests the status: gated on the count alone it
        # would make the same claim for any run whose final changelist still
        # carries blockers, which is the comment being true and the code not
        # implementing it.
        elif ($isresidue and ((.value.open // 0) > 0)) then
          "- `\(.key)` — \(.value.blocking) blocking found, \(.value.open) still open (filed as follow-up issue(s)), \(.value.suggestions) suggestion(s)"
        else "- `\(.key)` — \(.value.blocking) blocking found & fixed, \(.value.suggestions) suggestion(s)" end) ]
  + [ "" ]
  + (if ($d.waived_low | length) > 0 then
       [ "**Waived suggestions** (Low — logged, never blocking)", "" ]
       + [ ($d.waived_low[] | "- `\(.file):\(.line)` [\(.dimension)] \(.title)") ]
       + [ "" ]
     else [] end)
  + [ ("**Reviewers:** " + ($d.reviewers | if length==0 then "—" else join(", ") end)),
      "",
      "_Machine-readable dossier below is consumed by the Approver'"'"'s risk register._",
      "" ]
  | .[]') || { print -r -u2 -- "build-dossier: could not render dossier section"; exit 1 }

# The dossier is embedded verbatim inside an HTML comment, and jq compact output
# does not escape `>` — so a reviewer title or path containing `-->` (mermaid
# arrows, heredoc markers) would CLOSE the comment early, spilling JSON into the
# visible PR body and handing the Approver a truncated payload. In compact JSON a
# `>` can only occur inside a string literal, so escaping every one to its \u003e
# form is semantically identical after parsing and cannot appear as a terminator.
dossier="${dossier//>/\\u003e}"

print -r -- "$section"
# the blank line the section array ends with is eaten by $(...) trailing-newline
# stripping, so re-emit it: the hidden block has always been separated from the
# prose by one blank line, and open-pr appends this verbatim into the PR body.
print -r --
print -r -- "<!-- review-dossier: ${dossier} -->"
