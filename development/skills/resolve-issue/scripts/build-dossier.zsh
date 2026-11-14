#!/usr/bin/env zsh
# build-dossier.zsh — turn a PR-OPENING review-loop status JSON (from
# resolve-story-loop.zsh, #562) into the PR "Review dossier" section: the durable
# audit record for why auto-merge happened (epic #557, issue #563).
#
# ONE terminal state opens a PR and so reaches this script: `CONVERGED` (exit 0).
# The residue terminal that once opened one with blockers still open is retired
# (#2580), so a loop that ran a round must have ended `CONVERGED` with
# an empty final changelist, and the guards below refuse anything else (#2599):
# the dossier never reports `open > 0` on a PR the loop opened.
#
# It emits, on stdout:
#   1. a human-readable "## Review dossier" markdown section — per-round blockers
#      found/fixed, dimensions reviewed, waived Low suggestions, reviewers, and
#      the final consolidator state. Each dimension also carries `open` in the
#      hidden block: the blockers still open in the final
#      changelist. The guard below refuses a non-zero count, so it is always 0;
#      it stays because the Approver backstops read it (#2586, #2587); and
#   2. a hidden JSON block  <!-- review-dossier: {…} -->  dimension-tagged with
#      the #449 enum, so the Approver re-ingests reviewer verdicts into its risk
#      register the same way maintenance re-ingests Approver findings today. An
#      empty (clean) dimension lets the Approver lower that lens's residual-risk
#      weight; the waived-Low list is context, not a finding.
#
# If the loop did not run (--no-review / no rounds), nothing is emitted (exit 0)
# so the PR body is exactly as it is today.
#
# Usage:  build-dossier.zsh --status FILE
# Exit codes: 0 ok (may be empty) · 2 usage · 1 bad input (not a regular
#             non-empty file, not exactly one JSON object, or a `--status`
#             naming a non-PR-opening or non-terminal status — see the guard
#             below). Every non-zero exit emits NOTHING on stdout.

emulate -L zsh
setopt nounset pipefail

local status_file=""
local -r USAGE="usage: build-dossier.zsh --status FILE"

# `--status --help` must not silently swallow the next FLAG as this one's value
# (the consolidate-findings precedent): a missing value is a usage error.
_need_val() {  # $1 = flag, $2 = remaining argc, $3 = candidate value
  [[ "$2" -ge 2 && "$3" != -* ]] || { print -r -u2 -- "build-dossier: $1 requires a value"; exit 2 }
  # the third arm of the cited precedent: an empty string is not flag-shaped, so
  # `--status "$VAR"` with VAR unset would otherwise fall through to the bare
  # usage line and hide that the caller demonstrably DID pass the flag.
  [[ -n "$3" ]] || { print -r -u2 -- "build-dossier: $1 requires a non-empty value"; exit 2 }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  -h|--help) print -r -- "$USAGE"; exit 0 ;;
  -*) print -r -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -r -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -r -u2 -- "$USAGE"; exit 2 }

# --- input validation ---------------------------------------------------------
# `-s` alone let a file holding the literal `null` through, whereupon `(.round_changelists // []) | length` is 0
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

local status_json=""
status_json=$(_read_status "$status_file" "--status") || exit $?

# --- --status must be a CONVERGED run with nothing left open (#2599) --------
# An ALLOW-list: when the loop ran at least one round, its status must
# be `CONVERGED`, the only ending that opens a PR (#2580). Anything else — an
# escalation, `BUDGET_EXHAUSTED`, a non-ending such as `AWAITING_FIX` (the status
# the loop writes most often, once per step-mode round), the retired
# `CONVERGED_WITH_RESIDUE`, or a status the loop has never written — describes a
# run that opened no PR, and a dossier built from it would attest in the audit
# record to a merge that never happened. Exit 1, not 2: the operand exists and
# parses but describes the wrong run, an input problem rather than a malformed
# command line.
#
# The no-op shapes stay no-ops because they ran no round: `SKIPPED` (the
# `--no-review` fast path), a zero-round status, and a status-less zero-round
# file all reach the round count below and emit nothing.
#
# Then the backstop the epic needs: `open` is counted from the status's
# final changelist whatever the status, and a count above 0 is refused, so no
# dossier this script emits reports `open > 0` (#2586 and #2587 read it).
_refuse_non_converged() {  # $1 = compact status JSON, $2 = flag label
  local st="" ran="" open=""
  st=$(print -r -- "$1" | jq -r '.status // ""' 2>/dev/null) || st=""
  ran=$(print -r -- "$1" | jq -r '((.round_changelists // []) | length)' 2>/dev/null) || ran=""
  # an uncountable round_changelists is the round count's to refuse, below
  [[ "$ran" == <-> ]] || return 0
  if (( ran > 0 )) && [[ "$st" != CONVERGED ]]; then
    print -r -u2 -- "build-dossier: $2 ran ${ran} round(s) but did not end CONVERGED (${st:-no status}) — CONVERGED is the only review-loop ending that opens a PR, so a dossier built from this status would attest in the audit record to a merge that never happened. Pass the status of the run that opened this PR."
    exit 1
  fi
  open=$(print -r -- "$1" | jq -r '((.final_changelist.blocking // []) | length)' 2>/dev/null) || open=""
  [[ "$open" == <-> ]] || {
    print -r -u2 -- "build-dossier: $2 has an unreadable final_changelist.blocking — cannot count open blockers"; exit 1 }
  if (( open > 0 )); then
    print -r -u2 -- "build-dossier: $2 still carries ${open} open blocker(s) in its final changelist (open > 0) — the review loop never opens a PR with blockers left, so this dossier would report unreviewed work as reviewed. Re-run the loop to CONVERGED."
    exit 1
  fi
}
_refuse_non_converged "$status_json" "--status"

# --- ...and its final round's tree was proved by the WHOLE suite (#2926) ------
# Every round's gate may select now; only the whole suite on the final tree may
# open a PR. The loop runs it before a selected-only round converges, and its
# green run becomes that round's history[].gate, so a CONVERGED status whose last
# round's gate still reads "scope":"selected" was never proved and is refused.
# A status with no history, or a final round with no gate record (every stack
# that is not run-gate.zsh), carries no selected claim and passes.
_refuse_selected_final_gate() {  # $1 = compact status JSON, $2 = flag label
  local st="" scope=""
  st=$(print -r -- "$1" | jq -r '.status // ""' 2>/dev/null) || st=""
  [[ "$st" == CONVERGED ]] || return 0
  scope=$(print -r -- "$1" | jq -r '((.history // []) | if type == "array" then (last // {}) else {} end
                                     | (.gate? // {}) | if type == "object" then (.scope // "") else "" end)' \
          2>/dev/null) || scope=""
  if [[ "$scope" == selected ]]; then
    print -r -u2 -- "build-dossier: $2 ended CONVERGED, but its final round's gate only SELECTED tests — a PR opens only on a whole-suite green on the final tree (#2926). Re-run the loop: it runs the whole suite before a selected-only round converges."
    exit 1
  fi
}
_refuse_selected_final_gate "$status_json" "--status"

# --- nothing to render when the loop ran no round ------------------------------
local nrounds=""
nrounds=$(jq -n --argjson s "$status_json" '($s.round_changelists // []) | length') || {
  print -r -u2 -- "build-dossier: could not count rounds"; exit 1 }
[[ "$nrounds" -gt 0 ]] || exit 0

# --- the machine-readable dossier object (dimension-tagged, #449 enum) -------
#
# THE RISK-DEMOTED SET (#1921). Findings the loop demoted below
# corner_case_risk_threshold are Low items stamped `demoted: true`, so without a
# rule they would read as ordinary waived suggestions — hiding that each one
# cleared a reviewer blocking bar and was set aside by a risk judgement. ONE
# harvest, prepended to both programs below so the hidden block and the rendered
# table can never list different findings. It walks EVERY item — blocking and
# suggestions — of every round in order and follows each finding the way the
# consolidator follows one across rounds: same file, dimension and normalised
# title, with the line within LINEWIN (10) lines of the record it continues (a
# null line on either side is a wildcard). So a fix pass that moves a finding a
# few lines still continues its record, while two same-titled findings further
# apart stay two records. Each record carries the finding as it was LATEST seen
# (`priority`, `demoted`) and whether any occurrence was demoted (`anydemoted`).
# The demoted set is the records whose latest occurrence is still demoted — so a
# finding a later round kept blocking is not listed as "not fixed". `seq` orders
# the records and is dropped from the hidden block. With nothing demoted no
# record has `anydemoted`, which keeps a run with the threshold off
# byte-identical. (No apostrophes: the definition is single-quoted.)
local demoted_def='
  def dem_lk: [(.file // ""), (.dimension // ""),
               ((.title // "") | tostring | ascii_downcase | gsub("\\s+"; " ")
                 | sub("^ +"; "") | sub(" +$"; ""))];
  # 10 is consolidate-findings.zsh LINEWIN (its gather window; the verdict here
  # is an exact normalised title), and the 11 in dem_find is LINEWIN + 1 —
  # change all three together
  def dem_near($a; $b):
    if (($a | type) == "number") and (($b | type) == "number")
    then ((($a) - ($b)) | (if . < 0 then -. else . end) <= 10) else true end;
  # the index of the record an item continues — the nearest same-key record in
  # the window — or null
  # only a record from an EARLIER round is continued: two findings of one round
  # are two findings, however close
  def dem_find($recs; $it; $pass):
    ($it | dem_lk) as $k
    | [ $recs | to_entries[]
        | select(.value.lk == $k and .value.pass != $pass and dem_near(.value.line; $it.line))
        | { i: .key, d: (if ((.value.line | type) == "number") and (($it.line | type) == "number")
                         then ((.value.line - $it.line) | if . < 0 then -. else . end) else 11 end) } ]
    | sort_by(.d) | (.[0].i // null);
  def dem_records($s):
    [ ($s.round_changelists // [])
      | to_entries[] | .key as $pass | .value | .round as $rn
      | ((.blocking // []), (.suggestions // []))[]
      | { item: ., round: $rn, pass: $pass } ]
    | to_entries
    | reduce .[] as $e ([];
        ($e.value.item) as $it
        | dem_find(.; $it; $e.value.pass) as $i
        | { lk: ($it | dem_lk), file: $it.file, line: $it.line, dimension: $it.dimension,
            title: $it.title, round: $e.value.round, pass: $e.value.pass, seq: $e.key,
            ids: ((if $i == null then [] else .[$i].ids end)
                  + [[$it.file, $it.line, $it.dimension, $it.title] | tojson]),
            priority: ($it.priority // "Low"), demoted: ($it.demoted == true),
            anydemoted: (($it.demoted == true) or ($i != null and (.[$i].anydemoted // false))),
            p: $it.risk_assessment.p, impact: $it.risk_assessment.impact,
            risk_thousandths: $it.risk_assessment.risk_thousandths,
            p_why: $it.risk_assessment.p_why, impact_why: $it.risk_assessment.impact_why,
            threshold: $it.risk_assessment.threshold,
            bar: $it.risk_assessment.bar } as $r
        | if $i == null then . + [$r] else .[$i] = $r end);
  def demoted_set($s): [ dem_records($s)[] | select(.demoted) ];
'
local dossier=""
dossier=$(jq -cn --argjson s "$status_json" "$demoted_def"'
  ["bugs","security","performance","code_quality","tests"] as $core
  | (($s.round_changelists // [])) as $brounds
  # (No apostrophes in these jq comments: the program is a single-quoted shell
  # string, so one would close it and hand the rest to the shell as code.)
  | [ $brounds[] | (.blocking[]?, .suggestions[]?) ] as $allf
  | ( [ $allf[] | {file, line, dimension, title,
                   priority: (.priority // "Low"),
                   reviewers: (.reviewers // [])} ]
      | unique_by([.file, .line, .dimension, .title]) ) as $u
  | dem_records($s) as $recs
  | demoted_set($s) as $demmap
  # A finding that was demoted in ANY round (#1921) is counted ONCE, with the
  # priority and line of its LATEST occurrence, in both directions:
  # blocking-then-demoted counts as a suggestion and stays in waived_low, and
  # demoted-then-kept-blocking counts as "blocking found & fixed". So $uv is
  # built from the RECORDS, not from the deduped entries: every record that was
  # ever demoted contributes exactly one entry, carrying its latest identity
  # (file, line, dimension, title) and priority, and a deduped entry survives
  # only when no such record absorbed its exact identity (`ids`). A record never
  # demoted whose every identity was absorbed that way contributes its own
  # entry too, so no finding is lost to a shared identity. A finding never
  # demoted is left exactly as before, so with nothing demoted $uv is $u.
  | [ $recs[] | select(.anydemoted) ] as $drecs
  | [ $drecs[].ids[] ] as $claimed
  | ( [ $u[] | ([.file, .line, .dimension, .title] | tojson) as $id
        | select(any($claimed[]; . == $id) | not) ]
      + [ $recs[] | select(.anydemoted
                           or (all(.ids[]; . as $i | any($claimed[]; . == $i)) and ($claimed | length) > 0))
          | { file, line, dimension, title, priority, reviewers: [] } ] ) as $uv
  | (($core + ($uv | map(.dimension))) | unique) as $dims
  # Blockers still OPEN, per dimension, from the final changelist. The guard
  # above refuses a non-zero count, so every emitted dossier carries `open: 0`;
  # the key stays because the Approver backstops read it (#2586, #2587), and
  # counting it here unconditionally keeps the hidden block honest even if that
  # guard is ever bypassed.
  | ($s.final_changelist.blocking // []) as $openblk
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
      status: $s.status,
      rounds: ($s.rounds // ($brounds | length)),
      repo_type: $s.repo_type,
      dimensions: $dimmap,
      # a risk-demoted finding (#1921) STAYS in this machine-readable list, which
      # the Approver folds into its risk register: removing it would take a
      # finding that cleared a blocking bar out of that register. Only the
      # rendered waived list below leaves it out, since the human reads it in
      # its own table; `risk_demoted` names which of these were demoted.
      waived_low: [ $uv[] | select(.priority=="Low") | {file, line, dimension, title} ],
      reviewers: ([ $u[] | .reviewers[]? ] | unique),
      final: ($s.final_changelist.summary // {})
    }
  # present only when non-empty (#1921), so a dossier with no demotion keeps
  # exactly its previous shape for every reader of the hidden block
  # an extension-bar demotion (#2577) also names the bar and the effective
  # threshold it was judged against; any other entry keeps its #1921 shape
  | if ($demmap | length) == 0 then . else . + { risk_demoted: [ $demmap[]
        | {file, line, dimension, title, round, p, impact, risk_thousandths}
          + (if .bar == "extension" then {bar, threshold} else {} end) ] } end') || {
  print -r -u2 -- "build-dossier: could not build dossier"; exit 1 }

# --- human-readable section --------------------------------------------------
# BUFFERED, then printed once (#1064). Streaming this block straight to stdout
# meant a jq failure part-way through shipped a TRUNCATED dossier at exit 0 — a
# PR body carrying half a section and no hidden block, with nothing to signal it.
local section=""
section=$(jq -rn --argjson s "$status_json" --argjson d "$dossier" "$demoted_def"'
  # untrusted reviewer and conductor text in a table cell (#1921): newlines and
  # backticks stripped, pipes escaped — the same neutralisation the residue
  # builder applies to its dropped-finding rows
  def safe: (. // "") | tostring | gsub("[\r\n`]"; " ") | gsub(" +"; " ")
            | sub("^ +"; "") | sub(" +$"; "");
  def cell: safe | gsub("\\|"; "\\|");
  def linepart: if (.line | type) == "number" then ":\(.line)" else "" end;
  def roundline($r): "- Round \($r.round): \($r.summary.blocking) blocking"
    + (if ($r.summary.conflicts // 0) > 0 then ", \($r.summary.conflicts) conflict(s)" else "" end)
    + ", \($r.summary.low) suggestion(s) logged";
  [ "## Review dossier",
    "",
    ("The local review loop ran **\($d.rounds) round(s)** and exited **\($d.status)** "
     + "before this PR was opened — CI is only spent on code the reviewer panel already converged on."),
    ""
  ]
  + [ "**Per round**", "" ]
  + [ ($s.round_changelists[]? | roundline(.)) ]
  + [ "", "**Dimensions reviewed** (#449 lenses)", "" ]
  + [ ($d.dimensions | to_entries[] |
        if .value.clean then "- `\(.key)` — ✓ clean (reviewed, no findings)"
        else "- `\(.key)` — \(.value.blocking) blocking found & fixed, \(.value.suggestions) suggestion(s)" end) ]
  + [ "" ]
  # RISK-DEMOTED (#1921), above the waived list and never folded into it.
  + ( [ demoted_set($s)[] ] as $dem
      | if ($dem | length) == 0 then [] else
          # the heading names the base threshold from a base-bar record; when
          # every record is an extension-bar demotion (#2577) it names that bar
          # instead, and each extension row is marked in its risk cell
          [ ([ $dem[] | select(.bar != "extension") ] as $base
             | (if ($base | length) > 0
                then "**Demoted by the risk threshold (`corner_case_risk_threshold` = `\($base | max_by(.seq) | .threshold | cell)`):** "
                else "**Demoted by the extension bar (effective threshold = `\($dem | max_by(.seq) | .threshold | cell)`):** " end)
             + "these findings cleared a reviewer'"'"'s blocking bar, but each one'"'"'s risk (probability × impact) "
             + "is below the threshold, so the loop logged them as suggestions and did not fix them. "
             + "Promote any of them if you disagree with its assessment."),
            "",
            "| finding | round | p | impact | risk | why |",
            "|---|---|---|---|---|---|" ]
          + [ $dem[] | "| `\((.title | cell)[0:120])` — `\(((.file // "") | cell)[0:120])\(linepart)`"
                       + " | \(.round) | \(.p) | \(.impact) | \(.risk_thousandths / 1000)"
                       + (if .bar == "extension" then " (extension bar, threshold \(.threshold | cell))" else "" end)
                       + " | \(.p_why | cell); \(.impact_why | cell) |" ]
          + [ "" ] end )
  # the rendered waived list leaves out what the demoted table above already
  # lists (#1921); waived_low carries each demoted finding under the latest
  # identity of its record, so that identity is the match. With nothing demoted the
  # filter keeps everything
  + ( demoted_set($s) as $dm
      | [ $dm[] | [.file, .line, .dimension, .title] | tojson ] as $dmids
      | [ $d.waived_low[] | ([.file, .line, .dimension, .title] | tojson) as $id
          | select(any($dmids[]; . == $id) | not) ] as $wl
      | if ($wl | length) > 0 then
          [ "**Waived suggestions** (Low — logged, never blocking)", "" ]
          + [ ($wl[] | "- `\(.file):\(.line)` [\(.dimension)] \(.title)") ]
          + [ "" ]
        else [] end )
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
