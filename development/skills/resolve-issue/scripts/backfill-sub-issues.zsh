#!/usr/bin/env zsh
# backfill-sub-issues.zsh — one-time migration of an epic's markdown task-list
# children into GitHub-native sub-issues (#802).
#
# Why: #802 makes native sub-issues the authoritative epic→child source (the
# contract read-sub-issues.zsh reads). Existing epics declared their children
# only as markdown task-list lines — switching readers without backfilling
# would make every such epic enumerate ZERO native children and look
# never-decomposed (the migration hazard: #798's failure mode, en masse). This
# script converts the markdown declaration into the native relationship, one
# epic at a time. The markdown list itself is left untouched — it remains the
# human-readable view, it just stops being authoritative.
#
# Idempotent: children already attached natively are skipped, so an immediate
# second run is a no-op. Dry-run-able: --dry-run reports the plan and writes
# nothing.
#
# Usage:
#   backfill-sub-issues.zsh --repo OWNER/NAME --epic N [--dry-run]
#
# Parsing rule: this script owns the MIGRATION rule — which refs get attached
# as native sub-issues (the rule resolve-issue's E1 and
# list-refinement-children.zsh enumerated by before #802 made native
# sub-issues authoritative — both now read only the shared reader). The rule:
# checklist bullets (`- [ ]` / `- [x]`, `*`/`+` too), the first issue ref per
# line that ENDS on a word boundary (so `#0055aa` or `#3rd-party` never
# manufacture a child out of their leading digits), lines inside ``` or ~~~
# fences ignored (the fence state tracks the
# opener — see the invariant note below). A `this-repo#N` ref (compared
# case-insensitively — GitHub slugs are) counts as `#N`; a genuinely
# CROSS-repo ref is NOT migrated (this script attaches by same-repo issue
# number; cross-repo parenting is out of scope) — it is skipped and reported
# in "skipped_cross_repo".
#
# NOT the only consumer of a task-list rule (#1260): read-dependencies.zsh
# owns the CLASSIFICATION rule (is this issue an epic at all?), which is
# deliberately STRICTER on ref POSITION — a checkbox line counts only when its
# content STARTS with the ref, so an acceptance criterion that merely cites an
# issue is not a child. This script stays looser on purpose: first ref ANYWHERE
# on the line, so whoever vets the `--dry-run` plan — model or human;
# resolve-issue's E1 requires the vet on autonomous runs too — SEES a context
# ref it would otherwise migrate blind. The trailing word boundary, though, is
# SHARED with the classifier **for ASCII** (Oniguruma's \b there, this ASCII
# test here). A ref glued to a NON-ASCII word character is the one place the
# BOUNDARY RULE ITSELF diverges — safely, since the classifier is the stricter
# side. It is one of the deliberate one-sided strictnesses ARCHITECTURE.md
# records per shape; this parser is also looser on ref POSITION, above.
#
# The two rules are NOT interchangeable, but they must satisfy a two-sided
# invariant, and this parser owns one side of each:
#   (a) it must resolve a ref from every line the classifier calls a child —
#       attaching it, or reporting it in `skipped_cross_repo` /
#       `skipped_self_ref`, never dropping
#       it silently — else an epic is detected that migrates nothing. Hence the
#       identical bullet/blank classes — spelled `[ \t]` on both sides, never
#       `[[:blank:]]` (see the note above the awk pass) — and the trailing
#       word boundary after the ref, identical for ASCII (above); hence
#       also no bare-issue-URL and no ordered-list (`1. [ ]`) support HERE,
#       which is why the classifier omits both too. The two refs resolved and
#       then deliberately not attached — a cross-repo ref and a self-reference
#       to the epic — are why E1 must halt on an EMPTY plan instead of reading
#       exit 0 as success.
#   (b) it must ignore every line the classifier ignores as fenced — else it
#       migrates a quoted ref and misparents it (one parent only). Hence both
#       skip ``` and ~~~, and both track the fence OPENER (character + run
#       length) instead of toggling a flag.
# Widening a shape in either direction means changing both scripts in one
# change, with a test on each side.
#
# Emits one JSON object on stdout:
#   {
#     "epic": N, "dry_run": bool,
#     "markdown_children": [numbers],   # parsed from the body, body order —
#                                       # EXCLUDING every ref reported in
#                                       # skipped_cross_repo / skipped_self_ref
#                                       # (so E1's reverse vet must read all
#                                       # four arrays, never this one alone)
#     "already_present": [numbers],     # markdown children ALREADY attached
#                                       # natively IN THIS REPO before this run.
#                                       # Two carve-outs: a native child with no
#                                       # markdown line is not listed
#                                       # (read-sub-issues.zsh is the
#                                       # full-native-list reader); and a native
#                                       # child attached from ANOTHER repository
#                                       # is not counted present — a bare number
#                                       # is meaningless outside its own repo —
#                                       # and is noted on stderr instead
#     "added": [numbers],               # attached by this run ([] on dry-run)
#     "would_add": [numbers],           # dry-run only: the plan
#     "skipped_cross_repo": ["owner/repo#N", ...],
#     "skipped_self_ref": [numbers],   # the epic's own number, cited on a
#                                      # checkbox line: an issue cannot parent
#                                      # itself, so it is reported, not dropped
#                                      # (E1's reverse vet reads this array)
#     "failed": [{"number": M, "error": "..."}]
#   }
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary.
#
# Exit codes:
#   0  success — including the no-op (nothing to add) and dry-run
#   2  usage error
#   1  internal error (missing jq/awk, epic body parse failure, epic fetch or
#      sub-issue list failed)
#   5  partial — some children could not be attached (see "failed")

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"

die_usage() { print -u2 -- "$1"; exit 2 }

local repo="" epic="" dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) (( $# >= 2 )) || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --epic) (( $# >= 2 )) || die_usage "--epic needs a value"; epic="$2"; shift 2 ;;
  --dry-run) dry_run=true; shift ;;
  -h|--help)
    print -r -- "usage: backfill-sub-issues.zsh --repo OWNER/NAME --epic N [--dry-run]"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || die_usage "--repo OWNER/NAME is required"
# the full slug charset, not merely "contains a slash": $repo is spliced raw
# into four REST paths, one of which WRITES, so a value carrying extra path
# segments or a query would aim the POST somewhere the caller never named.
# Spelled with parameter expansion rather than `##` globs, which would need
# EXTENDED_GLOB that `emulate -L zsh` does not set.
# Neither half may be empty, `.` or `..`: the dot segments are legal under the
# charset test, but they normalise away and would aim the request at a path the
# caller never named. Reject exactly those two — NOT "must start alphanumeric",
# which would also refuse `OWNER/.github`, a real repo that carries issues.
local repo_owner="${repo%%/*}" repo_name="${repo#*/}"
[[ "$repo" == */* && "$repo_name" != */* \
   && -n "$repo_owner" && -n "$repo_name" \
   && "$repo_owner" != "." && "$repo_owner" != ".." \
   && "$repo_name" != "." && "$repo_name" != ".." \
   && -z "${repo_owner//[A-Za-z0-9_.-]/}" && -z "${repo_name//[A-Za-z0-9_.-]/}" ]] \
  || die_usage "--repo must be OWNER/NAME, got: $repo"
[[ -n "$epic" ]] || die_usage "--epic N is required"
# at least 1, mirroring read-dependencies.zsh's --issue guard: GitHub issue
# numbers start there, so 0 cannot name an epic. Without the bound the fetch
# 404s and the run dies exit 1 as "failed to fetch epic #0" — a malformed
# argument reported as a runtime failure.
{ [[ "$epic" == <-> ]] && (( epic >= 1 )) } \
  || die_usage "--epic must be a positive number, got: $epic"
# normalise a zero-padded value (007 -> 7) the same way child refs are: JSON
# forbids leading zeros, and `--argjson epic` would otherwise reject it only at
# the final emit — on the live path, AFTER every child has been POSTed
epic=$(( epic ))
command -v jq >/dev/null 2>&1 || { print -u2 -- "backfill-sub-issues: jq not found on PATH"; exit 1 }
command -v awk >/dev/null 2>&1 || { print -u2 -- "backfill-sub-issues: awk not found on PATH"; exit 1 }

# The epic body — the markdown declaration being migrated.
local body
body=$("$gh_bin" api "repos/$repo/issues/$epic" --jq .body 2>/dev/null) || {
  print -u2 -- "backfill-sub-issues: failed to fetch epic #$epic from $repo"; exit 1
}

# Its task-list child refs, in body order — the fence-aware awk pass (this
# script's MIGRATION rule; see the header — read-dependencies.zsh owns the
# stricter classification rule), keeping the optional `owner/repo` prefix of
# each line's FIRST ref so cross-repo refs can be told apart below.
#
# The fence pass tracks the OPENER (character + run length) rather than
# toggling a flag, and the checkbox guard allows any run of blanks after the
# bullet — both so this parser skips every line the classifier skips AS FENCED
# (invariant (b)) and resolves a ref from every line the classifier calls a
# child (invariant (a)). It stays deliberately LOOSER everywhere else — an
# acceptance criterion that merely cites an issue is skipped by the classifier
# and still parsed here, which is the whole point of surfacing it in the
# dry-run. Do NOT "fix" this pass to start-anchor its ref match; see the header.
# A bare toggle would let the ``` inside a ````-fenced example close the outer
# block, and quoted `- [ ] #N` lines would then be migrated as real children —
# a misparent, and GitHub allows one parent only.
#
# The blank classes are spelled `[ \t]`, NOT `[[:blank:]]`: jq's Oniguruma
# reads a POSIX class as Unicode-aware (NBSP, U+2000-U+200A, U+3000 all count)
# while awk's is ASCII, so the same spelling would denote DIFFERENT sets and
# the two parsers would disagree on any body pasted from a rendered page.
local -a refs awk_out
awk_out=("${(@f)$(print -r -- "$body" | awk '
  { sub(/\r$/, "") }          # CRLF bodies: normalise once, so no rule needs \r
  /^[ \t]*(```|~~~)/ {
    line = $0
    sub(/^[ \t]*/, "", line)
    ch = substr(line, 1, 1)
    n = 0
    while (substr(line, n + 1, 1) == ch) n++
    rest = substr(line, n + 1)
    if (fence_ch == "") { fence_ch = ch; fence_len = n }
    else if (ch == fence_ch && n >= fence_len && rest ~ /^[ \t]*$/) fence_ch = ""
    next
  }
  fence_ch != "" { next }
  /^[ \t]*[-*+][ \t]+\[[ xX]\]/ {
    # first ref anywhere on the line — but with the classifier trailing word
    # boundary, so a hex colour or an anchor (`#0055aa`, `#3rd-party`) never
    # manufactures a child number out of its leading digits
    # test the REMAINDER anchored at the ref end, never a single extracted
    # byte: `substr(…, 1)` on a multibyte character yields half a character,
    # and matching that aborts awk ("towc: multibyte conversion failure"),
    # which would fail the whole migration on an ordinary body like
    # `- [ ] #687<curly-apostrophe>s seam` or `- [ ] #687<em-dash>the child`
    rest = $0
    while (match(rest, /([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#[0-9]+/)) {
      ref = substr(rest, RSTART, RLENGTH)
      if (substr(rest, RSTART + RLENGTH) !~ /^[0-9A-Za-z_]/) { print ref; break }
      rest = substr(rest, RSTART + RLENGTH)
    }
  }')}") || {
  # without this check a failed parse (no awk, or a program it rejects) yields
  # an empty plan at exit 0 — indistinguishable from a genuine no-op epic
  print -u2 -- "backfill-sub-issues: failed to parse the epic body (awk)"; exit 1
}
refs=("${awk_out[@]}")
refs=(${refs:#})   # drop the empty element a childless body yields

# Same-repo refs (`#N`, `this-repo#N`) become candidate children; genuinely
# cross-repo refs are unmigratable and only reported. A self-reference (a
# tracker line like "#N stays open until …") is never a child — an issue
# cannot be its own sub-issue.
local -a md_children skipped_cross skipped_self
local ref n
for ref in "${refs[@]}"; do
  if [[ "$ref" == "#"<-> ]]; then
    n="${ref#\#}"
  # compare the owner/repo prefix and the number SEPARATELY (GitHub slugs are
  # case-insensitive, hence the (L)). The older `== "${(L)repo}#"<->` form was
  # also literal in its quoted part — zsh matches quoted RHS text literally —
  # but it mixed a quoted literal and an unquoted pattern in one comparison,
  # which reads as pattern-matching the repo and invites exactly that edit. An
  # UNQUOTED `$repo` on the right IS a pattern, and would let `--repo o/r*`
  # swallow a genuinely cross-repo `o/rother#55` — a misparent, and what
  # skipped_cross_repo exists to prevent.
  elif [[ "${ref%\#*}" != "$ref" && "${(L)${ref%\#*}}" == "${(L)repo}" \
          && "${ref##*\#}" == <-> ]]; then
    n="${ref##*\#}"
  else
    skipped_cross+=("$ref")
    continue
  fi
  n=$(( n ))   # normalize zero-padded refs (#007 → 7); JSON forbids leading zeros
  # self-ref: an issue cannot parent itself. REPORTED, not silently dropped —
  # E1's reverse vet requires every child-shaped line to appear in one of the
  # output arrays, and a tracker line (`- [ ] #746 stays open until …`) IS a
  # child line by the #1260 rule, so an unreported drop would halt a healthy epic
  # recorded at most once: every entry here is by construction $epic, so a
  # second tracker line would only repeat a constant in a document a model
  # must reason over line by line
  (( n == epic )) && { (( ${#skipped_self} == 0 )) && skipped_self+=("$n"); continue }
  md_children+=("$n")
done

# The native sub-issues already attached, restricted to THIS repo.
# A sub-issue may live in another repository (read-sub-issues.zsh documents the
# same hazard for its own reader and keys its children by `repo`). The markdown
# children we compare against were all resolved as same-repo (`#N` or
# `this-repo#N`), so keying `present` by a bare foreign number would collide:
# an epic holding native OWNER/B#42 and declaring `- [ ] #42` (meaning
# OWNER/A#42) would report the real child `already_present` and never attach
# it — and E1's reverse vet would read the ref as accounted for, so the epic
# ships looking migrated while permanently missing a child. Filter on the
# repository each child actually belongs to; `repository_url` ends in the slug.
# An ABSENT slug counts as same-repo: we cannot prove it foreign, and dropping
# it would re-POST an attached child, breaking the idempotency promised above.
local existing_all existing_json existing_foreign
existing_all=$("$gh_bin" api --paginate "repos/$repo/issues/$epic/sub_issues" \
  --jq '[.[] | {number, slug: ((.repository_url // "")
                 # take the LAST two path segments, never a greedy prefix strip:
                 # for owner `repos` the URL is .../repos/repos/name and a
                 # greedy ^.*/repos/ leaves "name", which reads as foreign and
                 # re-POSTs an attached child on every run. An unrecognised
                 # shape falls back to "" = same-repo, the fail-safe direction.
                 | if test("/repos/[^/]+/[^/]+$")
                   then (split("/") | .[-2:] | join("/")) else "" end)}]' \
  2>/dev/null | jq -cs 'add // []') || {
  print -u2 -- "backfill-sub-issues: failed to list sub-issues of epic #$epic"; exit 1
}
existing_json=$(print -r -- "$existing_all" | jq -c --arg repo "$repo" \
  '[.[] | select(.slug == "" or (.slug | ascii_downcase) == ($repo | ascii_downcase))
   | .number]') || {
  print -u2 -- "backfill-sub-issues: failed to parse the sub-issue list of epic #$epic"; exit 1
}
# Never hide the exclusion: a same-numbered native child elsewhere is exactly
# what would otherwise look like an unexplained re-attach to whoever vets this.
existing_foreign=$(print -r -- "$existing_all" | jq -r --arg repo "$repo" \
  '[.[] | select(.slug != "" and (.slug | ascii_downcase) != ($repo | ascii_downcase))
   | "\(.slug)#\(.number)"] | join(", ")') || existing_foreign=""
[[ -n "$existing_foreign" ]] && print -u2 -- \
  "backfill-sub-issues: note — cross-repo sub-issues already attached, not counted as present: $existing_foreign"

typeset -A present
# NB: `n` was declared with the ref parse above — re-declaring `local` at
# script (non-function) scope in zsh echoes the parameter, polluting stdout.
# checked: an unchecked parse failing would leave `present` empty and re-POST
# every already-attached child — the opposite of the idempotency promised above
local existing_nums
existing_nums=$(print -r -- "$existing_json" | jq -r '.[]') || {
  print -u2 -- "backfill-sub-issues: failed to parse the sub-issue list of epic #$epic"; exit 1
}
for n in ${(f)existing_nums}; do
  [[ -n "$n" ]] && present[$n]=1
done

# Partition: already attached vs to attach (dedup'd, body order).
typeset -A seen
local -a already to_add
for n in "${md_children[@]}"; do
  [[ -n "${seen[$n]:-}" ]] && continue
  seen[$n]=1
  if [[ -n "${present[$n]:-}" ]]; then already+=("$n"); else to_add+=("$n"); fi
done

_json_num_array() {
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}
_json_str_array() {  # newline-join → jq split, so no hand-escaping needed
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "${(pj:\n:)@}" | jq -Rcs 'split("\n")'
}

if [[ "$dry_run" == true ]]; then
  jq -nc \
    --argjson epic "$epic" \
    --argjson md "$(_json_num_array "${md_children[@]}")" \
    --argjson already "$(_json_num_array "${already[@]}")" \
    --argjson would "$(_json_num_array "${to_add[@]}")" \
    --argjson skipped "$(_json_str_array "${skipped_cross[@]}")" \
    --argjson selfrefs "$(_json_num_array "${skipped_self[@]}")" \
    '{ epic: $epic, dry_run: true, markdown_children: $md,
       already_present: $already, added: [], would_add: $would,
       skipped_cross_repo: $skipped, skipped_self_ref: $selfrefs, failed: [] }' || {
    # exit 0 with an empty plan would tell the vetter "nothing to migrate" —
    # the one answer the dry-run exists to distinguish from a broken run
    print -u2 -- "backfill-sub-issues: failed to emit the dry-run plan"; exit 1
  }
  exit 0
fi

# Attach each missing child: resolve its database id, then POST it as a
# sub-issue. A single child's failure (e.g. it already has a different
# parent — GitHub allows one parent only) is recorded and does not abort the
# rest of the run.
local -a added failed_recs id_lines
local child_id child_out err rec
# both record builders are CHECKED: an empty element would corrupt `failed`,
# the final emitter would then die, and the run would report exit 1 instead of
# the documented 5 (partial) — after real POSTs had already landed
_record_failure() {  # $1 = child number, $2 = reason
  # the reason is arbitrary gh stderr, so strip anything jq --arg would reject
  # (it requires valid UTF-8) and NEVER let a diagnostic field abort the run:
  # the POSTs have already landed, and aborting would lose the `added` list
  local msg=${2//[^[:print:][:space:]]/?}
  # the last fallback needs NO jq: $1 is already a bare integer, so this can
  # never fail — which is what makes the "never abort" rule above true, rather
  # than merely intended (an abort here would lose the `added` accounting)
  rec=$(jq -nc --argjson n "$1" --arg e "$msg" '{number: $n, error: $e}') \
    || rec="{\"number\": $1, \"error\": \"unprintable error from gh\"}"
  failed_recs+=("$rec")
}
for n in "${to_add[@]}"; do
  # capture gh's reason here too, as the POST branch does: a 404, a 403 and a
  # 502 must not collapse into one opaque string the operator cannot act on.
  # No temp file: a fixed /tmp path would break on a read-only /tmp (aborting
  # the substitution before gh even runs, so every child would be reported as
  # a bogus lookup failure) and is a symlink target under a guessable name.
  if ! child_out=$("$gh_bin" api "repos/$repo/issues/$n" --jq .id 2>&1); then
    _record_failure "$n" "${child_out:-failed to resolve issue id}"
    continue
  fi
  # 2>&1 folds stderr in, and a gh notice (SSO hint, deprecation) can land
  # either side of the payload — so PICK the numeric line rather than assuming
  # the capture is only the id, or a healthy child would be reported failed
  # count rather than take-the-first: an AMBIGUOUS capture (more than one bare
  # numeric line) is the only failure mode with a destructive outcome — POSTing
  # a guessed sub_issue_id misparents an issue — so fail closed into the same
  # per-child recorded failure instead of picking one
  id_lines=( ${(M)${(f)child_out}:#<->} )
  if (( ${#id_lines} != 1 )); then
    _record_failure "$n" "unexpected id response: $child_out"
    continue
  fi
  child_id=$id_lines[1]
  if err=$("$gh_bin" api -X POST "repos/$repo/issues/$epic/sub_issues" \
             -F sub_issue_id="$child_id" 2>&1 >/dev/null); then
    added+=("$n")
  else
    _record_failure "$n" "${err:-POST failed}"
  fi
done

_json_array() {
  (( $# == 0 )) && { print -rn -- '[]'; return }
  print -rn -- "[${(j:,:)@}]"
}

jq -nc \
  --argjson epic "$epic" \
  --argjson md "$(_json_num_array "${md_children[@]}")" \
  --argjson already "$(_json_num_array "${already[@]}")" \
  --argjson added "$(_json_num_array "${added[@]}")" \
  --argjson skipped "$(_json_str_array "${skipped_cross[@]}")" \
  --argjson selfrefs "$(_json_num_array "${skipped_self[@]}")" \
  --argjson failed "$(_json_array "${failed_recs[@]}")" \
  '{ epic: $epic, dry_run: false, markdown_children: $md,
     already_present: $already, added: $added, would_add: [],
     skipped_cross_repo: $skipped, skipped_self_ref: $selfrefs,
     failed: $failed }' || {
  # the POSTs have already landed, so a silent exit 0 with no document would
  # tell E1 "clean run, nothing to account for" about a run that DID write
  print -u2 -- "backfill-sub-issues: failed to emit the result document"; exit 1
}

(( ${#failed_recs} > 0 )) && exit 5
exit 0
