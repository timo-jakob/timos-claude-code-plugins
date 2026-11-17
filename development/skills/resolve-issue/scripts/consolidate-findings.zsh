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
#   { round, summary{critical,high,low,blocking,conflicts,false_trips},
#     blocking[], suggestions[], conflicts[], non_converging, false_trips[],
#     escalation_reasons[] }  (each blocking[] item also carries false_trip:bool,
#     and class:"…" when --fix-touched was given — #1435. decided:"red"|"green"
#     rides on EVERY item, blocking[] AND suggestions[], when the round decided
#     the claim the merged item is titled from — #1584. A "green" record does NOT
#     imply the item is a suggestion: the group severity max and a
#     reviewer-written WARNING/CRITICAL whose decides: claim came back green (the
#     decided pass changes no severity on that malformed shape) each carry a
#     green-decided finding into blocking[]. Two keys are INTERNAL and never
#     part of this shape: `group_red`, the unrestricted group verdict, and
#     `_lane`, the group's lane test (the Low filter below), both minted in the
#     dedup map and stripped in the same projection that applies the Low filter —
#     if you see either in a changelist, that strip was moved or bypassed)
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
#   - Low filter (#3169, the rule ARCHITECTURE.md states for #3157): a
#     reviewer-emitted Low with neither a `decides:` nor a `follow-up:` line is
#     DISCARDED — it appears in neither `suggestions[]` nor `blocking[]`, and no
#     summary key counts it, so a plain suggestion costs nothing downstream. A
#     Low is KEPT, in `suggestions[]` and never blocking, when it is in a lane:
#       * any member of its dedup group has a description line that begins with
#         `decides:` or `follow-up:` (leading blanks allowed, matched at the
#         start of a line, never mid-line) — every member is read, because dedup
#         keeps only the longest description and can strip the line;
#       * or the item carries a `decided` record, or a red sits anywhere in its
#         dedup group (`group_red`) — an observed tool verdict is never deleted.
#     A risk-demoted item (`demoted: true`) is never discarded: the consolidator
#     writes that Low itself, on purpose. Only a SUGGESTION is discarded: a Low
#     whose severity is unrecognised (`Warning`, `HIGH`) is kept, because it may
#     be a blocker a reviewer misspelled. The filter runs AFTER dedup and the
#     risk demotion and BEFORE the conflict / non-convergence classification, so
#     a discarded Low cannot go on to seed a conflict pair or a carried-blocker
#     match. `summary.low` counts the kept Lows only.
#
#   - Residue class (#1435): with --fix-touched, every `blocking[]` item is
#     stamped with a `class` derived from ONE question — is the finding's file
#     an artifact the PREVIOUS round's fix pass touched?
#       * `new_defect`             — `.file` is NOT in the fix-touched set;
#       * `under_assertion`        — in the set, and `.dimension == "tests"`;
#       * `incomplete_propagation` — in the set, any other dimension.
#     It is DERIVED here, never emitted by a review agent, so the #558 findings
#     schema is untouched. The stamp is a direct per-item field — the same shape
#     `false_trip` (#983) already uses — so a consumer
#     detects an older, unstamped changelist with `[$blk[] | has("class")] | all`
#     rather than reading a missing stamp as a class. Without the flag NO item
#     carries `class` at all, which is what keeps a run that never passes it
#     byte-identical to before the field existed. The class is reporting only:
#     it feeds the loop's residue narration, the escalation histogram and the
#     telemetry `by_class` counts, and it never changes which items block.
#
#   - Decided tool verdicts (#1584): a read-only reviewer (`tools: Read, Grep,
#     Glob`) cannot run a linter, a suite, a validator or a version check, so a
#     finding whose claim IS one of those verdicts is capped at SUGGESTION and
#     names the command that settles it. The CONDUCTOR runs that command on the
#     minted tree before calling this script, and on a red rewrites `.severity`
#     to the severity the reviewer proposed. An optional per-finding `decided`
#     ("red" | "green") records which way it went, and is carried through to the
#     changelist item so the promotion is auditable there. It is a RECORD, not a
#     mechanism — nothing here reads it to RAISE a severity, so a `decided: "red"`
#     whose severity the conductor did NOT rewrite stays a suggestion, and a
#     `decided: "green"` never demotes anything. (Its one reader is the #1921 risk
#     demotion, which never LOWERS a `red` item.) Any other
#     value, or no field at all, adds no key — which is what keeps a run on
#     findings that never carry it byte-identical to before it existed. On dedup
#     the GROUP decides — but only among members sharing the representative's
#     normalized title, since the dedup key omits the title and a bare harvest
#     would stamp one claim's verdict onto a DIFFERENT claim at the same location.
#     Among those, red beats green beats absent, because `severity` is already the
#     group max and reading the field off the representative alone could pair a
#     promoted Warning with a "green" record. An EMPTY normalized title is not a
#     match key (every untitled finding normalizes to ""), so an untitled
#     representative contributes only its own record — the same refusal the
#     cross-round title arm makes.
#     `green` means NOT RED — the command ran clean, OR it could not be run at all
#     (uninstalled, malformed, or it would have written into the tree, which the
#     conductor settles the same way). Both leave the finding a logged suggestion,
#     which is the fail-closed direction; WHICH of the two it was lives in the
#     conductor's `<work-dir>/decided-<R>.log`, never here, so nothing downstream
#     may read `green` as "the tool passed".
#
#   - Risk demotion (#1921): with `corner_case_risk_threshold` ON (the #1920
#     variable, parsed by the shared risk-threshold-lib.zsh) and --risk FILE, the
#     conductor's assessment of the round's CRITICAL and WARNING findings is
#     applied. Every assessed item is stamped `risk_assessment: {p, p_why, impact,
#     impact_why, risk, risk_thousandths, threshold, threshold_thousandths}`, a
#     record beside `decided`. A WARNING item whose risk (p x impact, integer
#     thousandths) is BELOW the threshold is demoted to a suggestion — severity
#     SUGGESTION, priority Low, blocking false, `demoted: true` — so it is logged,
#     never fixed, and never counts toward convergence. It never disappears.
#     NEVER demoted, at any threshold or risk: a CRITICAL item, and an item a
#     tool decided red (`decided: "red"`, or a red anywhere in its dedup group). A dedup group is demoted only when
#     EVERY WARNING member has an assessment and the HIGHEST member risk is below
#     the threshold; the item carries that member's assessment. An unassessed
#     finding keeps its severity (a missing judgement never demotes anything).
#     Placed straight after dedup, before the Low filter, which never discards a
#     demoted item, and the conflict / non-convergence classification, so a
#     demoted item never reads as a surviving blocker.
#     `summary.risk_demoted` is present only when the demotion ran. With the
#     threshold OFF or IGNORED, --risk is accepted and the file is never read, and
#     no key above appears: the output is byte-identical to a run without it.
#
#   - Extension bar (#2577): --extension marks THIS round as an extension round
#     (the loop decides it from the grant ledger: `grants.jsonl` non-empty and
#     the round past the `original_max_rounds` its first line records). Unless `extension_risk_threshold` turns the bar off
#     (any spelling of zero), the demotion above runs against the EFFECTIVE bar,
#     max(corner_case_risk_threshold when on, extension_risk_threshold; default
#     0.10), even with the base threshold off, and every stamp records it
#     (`threshold`, `threshold_thousandths`) plus `bar: "extension"`, which is how
#     the progress block and the dossier mark a finding the extension bar
#     demoted. The exemptions are the demotion's own. An unparseable
#     extension_risk_threshold is announced on stderr and behaves as the
#     default. Without --extension, or with the bar off, nothing here differs.
#
# Usage:
#   consolidate-findings.zsh --findings FILE [--round N] [--prev FILE]
#                            [--fix-touched FILE] [--risk FILE] [--extension]
#     --findings  aggregate findings JSON for THIS round (required)
#     --round     round number (default 1)
#     --prev      previous round's changelist JSON (this script's own output);
#                 omitted on round 1
#     --fix-touched  the PREVIOUS round's fix-touched set (#1435) — repo-relative
#                 paths, one per line, as resolve-story-loop.zsh writes to
#                 `<work-dir>/fix-touched-<N-1>.txt`. Unlike every other file
#                 flag here an EMPTY file is accepted: "the fix pass touched
#                 nothing reviewable" is a real state (a fix confined to
#                 `.review/`), and it means every blocker is a `new_defect`.
#     --risk      the conductor's risk assessment for THIS round (#1921), in
#                 #1920's shape: a JSON array of {file, line, dimension, title,
#                 p, p_why, impact, impact_why}. Read only while the threshold
#                 is ON; a malformed file is then exit 2, naming the entry.
#     --extension this round is an extension round (#2577): demote against the
#                 effective extension bar described above.
#
# Exit codes: 0 ok · 2 usage error (including a malformed --risk while the
#             threshold is on, and any unknown option — the #994 overlay's
#             flag, retired by #3135, and the waived-suggestion carry's,
#             retired by #3169, among them) · 1 internal (unreadable /
#             invalid JSON)

emulate -L zsh
setopt nounset pipefail

local usage="usage: consolidate-findings.zsh --findings FILE [--round N] [--prev FILE] [--fix-touched FILE] [--risk FILE] [--extension]"

# A value flag with no value, or one whose value is the NEXT FLAG, is a caller
# mistake that this script used to turn into the wrong failure. Under `nounset`
# a dangling `--findings` aborted on the bare `$2` with zsh's raw "2: parameter
# not set" and exit 1 — which this script's taxonomy reserves for *internal*
# errors, so a usage mistake was indistinguishable from unreadable input. And
# the unquoted `--prev $VAR` idiom with VAR unset collapses so the next flag
# becomes the value: `--prev --fix-touched` would swallow `--fix-touched`,
# silently consolidating with no fix-touched set. resolve-story-loop.zsh has
# guarded exactly this way since #971; a half-applied rule is the inconsistency
# the next caller trips on, so it covers EVERY value flag here too (#994).
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || {
    print -u2 -- "consolidate-findings: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "consolidate-findings: $1 requires a value (got the flag $3)"; exit 2 }
  # An EXPLICIT empty value is the same mistake wearing a third hat — the
  # realistic `--flag "$VAR"` with VAR unset — and left alone it reads
  # downstream as "flag omitted", exit 0: `--fix-touched ""` would silently
  # drop the whole fix-touched set and stamp no blocker with its class.
  [[ -n "$3" ]] || {
    print -u2 -- "consolidate-findings: $1 requires a non-empty value"; exit 2 }
}

local findings="" round=1 prev="" fix_touched="" risk_file="" extension=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --findings) _need_val "$1" $# "${2:-}"; findings="$2"; shift 2 ;;
  --round) _need_val "$1" $# "${2:-}"; round="$2"; shift 2 ;;
  --prev) _need_val "$1" $# "${2:-}"; prev="$2"; shift 2 ;;
  # the PATH must still be non-empty (`--fix-touched ""` is the same unset-VAR
  # slip _need_val exists for, and would silently drop the whole stamp); it is
  # the file's CONTENTS that may legitimately be empty — see below
  --fix-touched) _need_val "$1" $# "${2:-}"; fix_touched="$2"; shift 2 ;;
  --risk) _need_val "$1" $# "${2:-}"; risk_file="$2"; shift 2 ;;
  --extension) extension=1; shift ;;
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

# The fix-touched set (#1435): repo-relative paths, one per line. `has_touched`
# is what gates the stamp, NOT the array's emptiness — the two are different
# facts, and conflating them would make "no class" ambiguous between "nobody
# asked" and "the fix touched nothing". An EMPTY set means "the fix
# pass touched nothing reviewable", so every blocker is a `new_defect`; an
# ABSENT flag means "nobody asked", so no item is stamped at all.
local fix_touched_json='[]' has_touched='false'
if [[ -n "$fix_touched" ]]; then
  # `-f`, deliberately not `-s`: a zero-byte file is a legitimate empty set (the
  # `.review/`-only fix pass), so the usual non-empty guard would refuse the very
  # state the flag has to represent. `-f` still excludes a DIRECTORY, which would
  # otherwise reach jq as "Is a directory" and be relabelled a content problem;
  # `-r` catches the unreadable file the same guard would have caught.
  [[ -f "$fix_touched" ]] || {
    print -u2 -- "consolidate-findings: --fix-touched must be a regular file: $fix_touched"; exit 1 }
  [[ -r "$fix_touched" ]] || {
    print -u2 -- "consolidate-findings: --fix-touched file is not readable: $fix_touched"; exit 1 }
  # Normalised on the way IN, with the same `^\./` strip the findings side
  # applies (`normfile`), so a `./a.zsh` on one side and `a.zsh` on the other can
  # never disagree about membership — the drift that this repo has already paid
  # for once between two line rules (#994). Blank lines are
  # dropped (an empty path matches nothing and would only widen the set with
  # noise); `unique` makes membership a set test rather than a list scan.
  fix_touched_json=$(jq -R -s 'split("\n") | map(sub("^\\./"; "")) | map(select(length > 0)) | unique' \
    -- "$fix_touched") || {
    print -u2 -- "consolidate-findings: could not read the --fix-touched set: $fix_touched"; exit 1 }
  [[ -n "$fix_touched_json" ]] || {
    print -u2 -- "consolidate-findings: --fix-touched file yielded no JSON value: $fix_touched"; exit 1 }
  has_touched='true'
fi

# The risk demotion (#1921). The threshold is parsed by the SAME parser the
# loop uses for its up-front --risk check, so a value can never demote here and
# be read differently there. `riskon` is the one gate the program reads: it is true only when the
# threshold is ON *and* an assessment was supplied. Every other combination —
# threshold off, ignored, or on with no --risk (hook mode supplies none) — leaves
# `risk_json` empty and the program on exactly its pre-#1921 path, which is the
# byte-identity guarantee. --risk is accepted and left UNREAD while the threshold
# is off or ignored, so a caller can pass it every round without first reading
# the environment itself.
source "${0:A:h}/risk-threshold-lib.zsh" || {
  print -u2 -- "consolidate-findings: could not load risk-threshold-lib.zsh"; exit 1 }
local thr_raw="" thr_state="off" thr_milli=0 risk_json='[]' riskon='false'
risk_threshold_parse
# The extension bar (#2577): in an extension round whose bar is not turned off,
# the threshold the program reads becomes the effective one, and `extbar` marks
# every stamp. Any other round leaves thr_* exactly as parsed above. `bar:
# "extension"` marks the KIND of round the stamp was made in, not which side of
# max(base, extension) won: the effective `threshold` beside it carries that.
local ext_raw="" ext_state="off" ext_milli=0 eff_raw="" eff_milli=0 extbar='false'
if (( extension )); then
  risk_extension_parse
  [[ "$ext_state" != "ignored" ]] || print -r -u2 -- "consolidate-findings: extension_risk_threshold='${ext_raw}' is not a decimal in [0, 1] with at most three decimals — IGNORED, so the default ${RISK_EXTENSION_DEFAULT_RAW} applies (e.g. 0.15, not 15)"
  risk_extension_effective
  if (( eff_milli > 0 )); then
    [[ "$thr_state" != "ignored" || -z "$risk_file" ]] || print -r -u2 -- "consolidate-findings: corner_case_risk_threshold='${thr_raw}' is not a decimal in [0, 1] with at most three decimals — IGNORED, so only the extension bar applies this round (e.g. 0.05, not 5 or 30)"
    thr_raw="$eff_raw" thr_state="on" thr_milli=$eff_milli extbar='true'
  fi
fi
if [[ -n "$risk_file" ]]; then
  if [[ "$thr_state" == "ignored" ]]; then
    print -r -u2 -- "consolidate-findings: corner_case_risk_threshold='${thr_raw}' is not a decimal in [0, 1] with at most three decimals — IGNORED, so no finding is demoted (e.g. 0.05, not 5 or 30)"
  elif [[ "$thr_state" == "on" ]]; then
    risk_validate_file "consolidate-findings" "$risk_file" || exit 2
    risk_json=$(jq -c '.' -- "$risk_file") || {
      print -u2 -- "consolidate-findings: could not read --risk: $risk_file"; exit 1 }
    riskon='true'
  fi
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
# One line-recovery rule for every line this program compares: a digit-only
# STRING line is recovered losslessly, anything else becomes null. The findings
# side and the --risk side (#1921) both use it, so a "line": "113" on one side
# can never miss a 113 on the other — two hand-inlined copies is how two sides
# drifted apart before #994.
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
# RISK STAMP + DEMOTION (#1921) — applied to one item carrying the internal
# `_risk` (see the dedup block), which it always deletes. The stamp is a RECORD
# beside `decided`; the demotion is the only place a severity is ever LOWERED in
# this program, so its exemptions are spelled out here rather than inherited:
# CRITICAL never (severity must be WARNING), and an observed tool red never
# (`decided` on the item, or `group_red` anywhere in its group). `$k.all` keeps a group
# with an unassessed blocking member blocking. The comparison is strict: a risk
# EQUAL to the threshold stays blocking. A blocker that keeps a stamp BELOW its
# own threshold was therefore kept by an exemption — which is how the residue
# builder recognises it without a second key.
# NB: no apostrophes in this block — the jq program is single-quoted.
def riskstamp:
  if has("_risk") then
    ._risk as $k | $k.top as $e
    | del(._risk)
    | . + { risk_assessment: ({ p: $e.p, p_why: $e.p_why, impact: $e.impact,
              impact_why: $e.impact_why, risk: ($e.r / 1000),
              risk_thousandths: $e.r, threshold: $thr_raw,
              threshold_thousandths: $thr_milli }
              + (if $extbar then { bar: "extension" } else {} end)) }
    | if (.severity == "WARNING") and $k.all and ($e.r < $thr_milli)
         and (.decided != "red") and (.group_red != true)
      then . + { severity: "SUGGESTION", priority: prio("SUGGESTION"),
                 blocking: blocks("SUGGESTION"), demoted: true }
      else . end
  else . end;
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
    # shared with the --risk side via `normline`.
    line: (.line | normline),
    title: (.title // ""),
    description: ((.description // "") | tostring),
    suggested_fix: (.suggested_fix // ""),
    reviewer: (.reviewer // "")
  }
  # DECIDED (#1584) — a read-only reviewer cannot run a linter/suite/validator, so
  # a finding whose claim IS one of those verdicts arrives as a SUGGESTION naming
  # the command that settles it. The CONDUCTOR runs that command before calling
  # this script and, on a red, rewrites `.severity` to the reviewer proposed one.
  # `decided` records WHICH way that went so the promotion is visible in the
  # changelist — it is a record, never the mechanism: nothing here reads it to
  # raise a severity or make an item block (the #1921 risk demotion reads it
  # only to never lower a red). Carried through as a
  # direct per-item field, the same shape `false_trip` (#983) and `class` (#1435)
  # already use.
  #
  # Strictly additive and defaulted: only the two contracted values survive, and a
  # finding without the field (or with anything else in it — a reviewer-crafted
  # string must never reach a renderer) gets NO key at all. That is what keeps a
  # run on findings that never carry it byte-identical to before the field existed.
  + ( if (.decided == "red") or (.decided == "green")
      then { decided: .decided } else {} end ) ]

# dedup by file+line+dimension
| ( group_by([.file, (.line|tostring), .dimension]) | map(
      (sort_by(.description | length) | last) as $rep
    | ([ .[].severity ] | max_by(sevrank(.))) as $sev
    # The group verdict, not the representative one (#1584). `severity` is already
    # the MAX over the group, so reading `decided` off $rep alone could pair a
    # promoted WARNING with a missing (or "green") record whenever the longest
    # description happened to belong to the undecided member — a changelist that
    # contradicts itself. `red` wins over `green`, which wins over absent; when no
    # member carries the field, no key is added.
    #
    # SAME-CLAIM ONLY. The dedup key is [file, line, dimension] — the TITLE is not
    # in it, deliberately (two reviewers wording one defect differently must still
    # merge). So a bare group harvest would carry a `decided` across two genuinely
    # DIFFERENT claims at one location: a tool-decided SUGGESTION->WARNING beside a
    # reviewer-raised CRITICAL emits one CRITICAL item, titled from the CRITICAL,
    # stamped `decided: "red"` — telling every downstream reader that a
    # reviewer-raised blocker was tool-decided. Harvesting same-claim only removes
    # that MISATTRIBUTION; the merged item still carries no record of the
    # co-located promotion, which is dedup own loss (the key omits the title) and
    # not this rule to fix. NB: no apostrophes in this block — the jq program is
    # single-quoted, and one closes it, which zsh then reports as a parse error
    # on a later pipe rather than anywhere near the quote.
    # Harvesting only from group members that share the representative
    # normalized title keeps the stamp attached to the claim it was decided about;
    # a reworded duplicate of the same claim still matches, which is the same
    # leniency `normtitle` buys everywhere else in this script.
    #
    # AN EMPTY normalized title is NOT a match key. `title` defaults to "" on the
    # way in, so `normtitle` of every untitled finding is "" and a bare title
    # comparison is TRUE for every pair of untitled members — reinstating the
    # cross-claim stamp on exactly that input class. The two other title-keyed
    # site here refuses an empty normtitle for the same reason (the cross-round
    # exact arm), so this one does too:
    # when the representative is untitled, fall back to object identity, which
    # still keeps the representative own record and nothing else.
    | ([ .[] | select(if ($rep.title | normtitle) == "" then (. == $rep)
                      else (.title | normtitle) == ($rep.title | normtitle) end)
             | .decided // empty ]) as $dec
    # The UNRESTRICTED group verdict (#1584), read by the risk demotion and the
    # Low filter. The stamp above is deliberately same-claim, but neither reader
    # may be: a red-decided Low that is NOT the representative and carries a
    # different title loses its record at the harvest, so a filter reading only
    # the emitted `.decided` would discard the merged item — deleting an observed
    # tool verdict with no trace at all. Carried as an internal key and deleted in
    # the SAME projection that applies the Low filter (see the strip comment
    # below), so it never reaches the output.
    | ([ .[] | .decided // empty ]) as $anydec
    # The LANE test (#3169), read by the Low filter. A member is in a lane when a
    # line of its description begins with `decides:` or `follow-up:` (leading
    # blanks allowed). EVERY member is read, not only the representative: dedup
    # keeps the longest description, which may well be the member without the
    # line. Internal (`_lane`), stripped beside `group_red`.
    | ([ .[] | .description | select(test("(^|\n)[ \t]*(decides|follow-up):")) ]
       | length > 0) as $lane
    # RISK (#1921) — the group view of the conductor assessment, gathered HERE
    # because the members are only visible inside the dedup group. Only the
    # blocking members count: the conductor assesses CRITICAL and WARNING
    # findings, and a Low member neither blocks nor was assessed. `top` is the
    # member with the HIGHEST risk — the conservative pick, since a group is
    # demoted only when even its riskiest member is below the threshold — and
    # `all` says whether every blocking member was assessed, because one
    # unassessed member keeps the whole item blocking. Identity is matched on the
    # normalized file and line the members carry, against the entry normalized
    # the same way, so a `./` or a digit-string line cannot defeat the match.
    # Internal (`_risk`), consumed and deleted by riskstamp below; null when the
    # demotion is off, so no key is added and the output is unchanged.
    | ( if $riskon then
          ( [ .[] | select(blocks(.severity)) | . as $m
              | ( [ $risk[] | select(((.file // "") | normfile) == $m.file
                                     and (.line | normline) == $m.line
                                     and ((.dimension // "") | tostring) == $m.dimension
                                     and (.title // "") == $m.title) ] | first ) ] ) as $bm
          | ( [ $bm[] | select(. != null)
                | . + { r: ((.p * 100 | round) * (.impact * 10 | round)) } ] ) as $as
          | if ($as | length) > 0
            then { top: ($as | max_by(.r)), all: ([ $bm[] | . != null ] | all) }
            else null end
        else null end ) as $rk
    | $rep + {
        severity: $sev,
        priority: prio($sev),
        blocking: blocks($sev),
        reviewers: ([ .[].reviewer ] | map(select(. != "")) | unique),
        agreement: ([ .[].reviewer ] | map(select(. != "")) | unique | length)
      }
    | ( if ($dec | index("red")) != null then . + { decided: "red" }
        elif ($dec | index("green")) != null then . + { decided: "green" }
        else . end )
    | ( if ($anydec | index("red")) != null then . + { group_red: true }
        else . end )
    | ( if $lane then . + { _lane: true } else . end )
    | ( if $rk != null then . + { _risk: $rk } else . end )
    | del(.reviewer)
  ) ) as $items

# RISK DEMOTION (#1921) — applied HERE, straight after dedup. It stays before
# the Low filter, which never discards a demoted item (see there). `group_red`
# is still present here for the tool-red exemption; it is stripped in the Low
# filter projection below. With the demotion off no item carries `_risk`, so
# this map is the identity and the output is unchanged.
| ( $items | map(riskstamp) ) as $items

# LOW FILTER (#3169) — a reviewer-emitted Low with neither a `decides:` nor a
# `follow-up:` line is discarded here. Placed HERE deliberately: after the risk
# demotion, so a `demoted: true` item can be exempted, and before conflicts /
# non-convergence, so a discarded item cannot go on to seed a conflict pair or a
# carried-blocker match, which would resurrect through a side door what the
# filter just removed.
#
# NB: no apostrophes in this block — the jq program is single-quoted.
# An item is KEPT when its severity is not SUGGESTION (so a Low from an
# unrecognised severity, maybe a misspelled blocker, stays visible as before),
# when the risk demotion wrote it (`demoted`), when its group is in a lane
# (`_lane`), or when it carries a tool verdict: a `decided` record, or a red anywhere in its group (`group_red`). The
# last two are tested apart from the lane on purpose. Dedup keeps the `decided`
# stamp of one claim only, and the decided pass may record a red on a `decides:` finding
# without changing its severity, so the red-at-Low item is an observed verdict
# that must never vanish, even if a malformed member lost its line.
#
# `group_red` and `_lane` are internal and are stripped IN THE SAME projection
# that applies the filter, not in a separate step below it. The invariant "these
# keys never reach a consumer" would otherwise be enforced only by the POSITION
# of a lone `del`, and the natural next extension of this block would be written
# above it and emit them. `del` of an absent key is a no-op that preserves key
# order.
| ( [ $items[]
      | select((.severity != "SUGGESTION") or (.demoted == true) or (._lane == true)
               or (.decided != null) or (.group_red == true))
      | del(.group_red, ._lane) ] ) as $items

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
# RESIDUE CLASS (#1435) — stamped here, on the assembled blocking list, so every
# downstream reader of `blocking[]` (and of `false_trips[]`, which is a subset of
# it) sees the same field. Deliberately AFTER the ordering above and after the
# non-convergence verdict: the class answers "where did this finding come from",
# never "does it block", so it must not sit anywhere it could perturb either.
#
# Gated on $has_touched, not on the set being non-empty: an absent flag leaves
# every item WITHOUT the key, which is precisely what lets a consumer tell an
# unstamped (older, or flagless) changelist from a genuine all-`new_defect`
# round. NB: no apostrophes in this block — the jq program is single-quoted.
# The item is bound FIRST for the membership test: inside `$fixtouched | index(g)`
# the input to `g` is $fixtouched (the ARRAY), so a bare `.file` there would index
# an array with an array and answer the wrong question entirely: `index` on an
# ARRAY argument is a subsequence search in jq, not a membership test. `index` on
# a STRING argument is the membership lookup we want; `$it.file` is already `normfile`d, and the set was
# normalised the same way on the way in, so the two sides cannot disagree.
| ( if $has_touched
    then [ $blocking[] | . as $it
           | $it + { class: (if (($fixtouched | index($it.file)) == null) then "new_defect"
                             elif ($it.dimension == "tests") then "under_assertion"
                             else "incomplete_propagation" end) } ]
    else $blocking end ) as $blocking
| ( [ $blocking[] | select(.non_converging) ] | length > 0 ) as $nonconv
# verified false trips (#983): blockers proximity GATHERED as non-convergence
# candidates but identity-cleared (disjoint titles) as genuinely different — they
# are stamped non_converging:false from the start (never set $nonconv), and are
# surfaced so progress/telemetry can record the auto-continue.
| ( [ $blocking[] | select(.false_trip == true) ] ) as $ftrips

| {
    round: $round,
    # parenthesised: an object value must be a single term, and the risk key
    # (#1921) is appended with `+`, only when the demotion ran
    summary: ({
      critical: ($crit | length),
      high: ($high | length),
      low: ($low | length),
      blocking: ($blocking | length),
      conflicts: ($conflicts | length),
      false_trips: ($ftrips | length)
    } + ( if $riskon then { risk_demoted: ([ $items[] | select(.demoted == true) ] | length) }
          else {} end )),
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

jq -c --argjson round "$round" --argjson prev "$prev_json" \
  --argjson fixtouched "$fix_touched_json" --argjson has_touched "$has_touched" \
  --argjson riskon "$riskon" --argjson risk "$risk_json" \
  --arg thr_raw "$thr_raw" --argjson thr_milli "$thr_milli" --argjson extbar "$extbar" \
  "$PROG" -- "$findings" || {
  print -u2 -- "consolidate-findings: invalid findings JSON: $findings"; exit 1
}

# An assessment entry that matched no CRITICAL or WARNING finding is a mistyped
# identity, and its finding therefore kept its severity — the safe direction, but
# the conductor meant to judge it and should know why nothing changed. Stderr
# only: the changelist above is already written, and this never changes it.
if [[ "$riskon" == "true" ]]; then
  local n_unmatched=""
  n_unmatched=$(jq -r --argjson risk "$risk_json" '
    def normfile: ((. // "") | tostring | sub("^\\./";""));
    def normline: if (. | type) == "number" then .
      elif ((. | type) == "string") and (test("^[0-9]+$")) then tonumber else null end;
    [ .[] | select(.severity == "CRITICAL" or .severity == "WARNING")
      | [(.file | normfile), (.line | normline), ((.dimension // "") | tostring), (.title // "")] ] as $ids
    | [ $risk[] | [((.file // "") | normfile), (.line | normline), ((.dimension // "") | tostring), (.title // "")]
        | select(. as $k | $ids | any(. == $k) | not) ] | length' -- "$findings" 2>/dev/null) || n_unmatched=""
  [[ -z "$n_unmatched" || "$n_unmatched" == 0 ]] || print -r -u2 -- "consolidate-findings: ${n_unmatched} --risk entr(y/ies) matched no CRITICAL or WARNING finding this round (identity is file + line + dimension + title, exactly) — those findings were not assessed and keep their severity"
fi
