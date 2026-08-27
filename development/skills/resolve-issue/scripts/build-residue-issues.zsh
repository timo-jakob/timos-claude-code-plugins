#!/usr/bin/env zsh
# build-residue-issues.zsh — turn a CONVERGED_WITH_RESIDUE run's remaining
# blocking findings into a PLAN of follow-up issues to file (#1435).
#
# Why: a residue ending opens the PR with blockers still open, so the remainder
# has to land somewhere a human will meet it. This script BUILDS that plan and
# nothing else — deterministic, testable, and incapable of creating an issue.
# `resolve-issue/reference/residue.md` step 4 makes the `gh issue create` calls and attaches
# each result as a native sub-issue. That is the same build-vs-post split
# `build-escalation.zsh` already uses, for the same reason: the decision of what
# to file is worth a bats case, and the act of filing is not something a script
# should be able to do by accident.
#
# It DOES read from GitHub — twice, to answer the idempotency question below —
# but it never writes. A read that fails is not fatal (see FAIL-OPEN).
#
# Usage:
#   build-residue-issues.zsh --status FILE --changelist FILE --issue N
#                            [--epic N] [--dry-run]
#     --status      the loop status JSON (resolve-story-loop.zsh) — supplies the
#                   run context each body carries (status, rounds). It must be a
#                   `CONVERGED_WITH_RESIDUE` run, and specifically the BLOCKING
#                   phase's: residue is only filed for a run that OPENED its PR,
#                   and the terminal it replaces is an escalation that opened
#                   none. Anything else is exit 2, naming what it got
#     --changelist  the FINAL round changelist (consolidate-findings.zsh) — the
#                   authoritative list of residual blocking findings. Its
#                   `.round` must match the status JSON's `.rounds`; a mismatch
#                   is exit 2, naming both numbers, because an off-by-one would
#                   otherwise file issues for an earlier round's blockers —
#                   findings the fix pass already cleared, with titles new enough
#                   that the idempotency read filters none of them
#     --issue       the story issue number; the body links it, and it is the
#                   parent when there is no --epic
#     --epic        the story epic, when it has one — then IT is the parent
#     --dry-run     make NO GitHub call at all, and emit every candidate. The
#                   idempotency read is the script's only network use, so
#                   skipping it is exactly what "reports the plan and writes
#                   nothing" means here. The plan may therefore contain a
#                   candidate a live run would have suppressed — that is the
#                   point of the flag, and it says so on stderr.
#
# Output (stdout): a JSON array, one object per residual blocking finding:
#   { title, body, labels: ["review-residue","needs-refinement"], parent }
# `[]` is a legitimate, successful answer — it means every candidate is already
# filed (or the changelist has no blockers left).
#
# LABELS — both, always. `review-residue` is the pinned half of the idempotency
# key below. `needs-refinement` is load-bearing rather than decoration: linking
# residue as a native sub-issue makes the parent walk as an EPIC on its next
# `/development:resolve-issue` run, and E1b halts that walk on any child the
# readiness gate sends back — which an auto-generated finding title always is.
# The halt is the intended prompt (residue must be refined before it is built);
# the label is what makes the human meet a child already carrying the reason it
# stopped the walk, rather than a surprise.
#
# IDEMPOTENCY, on a pinned key: a candidate is ALREADY FILED when an issue
# carries the `review-residue` label AND its title equals the candidate title
# exactly. Both halves are required — a same-titled issue WITHOUT the label is
# somebody else's that happens to collide, and a labelled issue with a DIFFERENT
# title is a different residue. So an immediate second run is a no-op rather than
# a pile of duplicates.
#
# That key is looked up as the UNION of two reads: the parent's native
# sub-issues, and a repo-wide `review-residue` listing (bounded, `--state all`).
# The repo-wide half is not belt-and-braces — it covers the one state the
# parent-scoped read structurally cannot see. Filing is create-THEN-attach, two
# API calls, so a create that succeeds before a failed or interrupted attach
# leaves a real `review-residue` issue that is nobody's sub-issue; without the
# second read every re-run files it again, and each duplicate carries
# `needs-refinement`, halting the parent's epic walk twice on one finding.
#
# The union admits one deliberate over-suppression: a labelled issue under a
# DIFFERENT parent whose rendered title collides exactly. The title carries file,
# line and dimension, so a collision means the same finding in the same place —
# suppressing it is the better error than duplicating it, and the alternative
# (parent-scoped only) reopens the unattached hole above.
#
# Consumers that classify a candidate by matching it against the PARENT's
# sub-issues alone (`resolve-issue`'s `reference/residue.md` step 3) therefore see a
# builder-filtered candidate as unmatched. That is never a wrong `--changelist`
# — it means the key matched OUTSIDE the parent, which is either of the two
# producers above. `reference/residue.md` step 3 is NORMATIVE for telling them
# apart and for what to do; either way the answer is never to re-file.
#
# FAIL-OPEN: when BOTH idempotency reads fail (no `gh`, no network, no auth),
# the script warns LOUDLY on stderr and emits the full plan, exit 0. A parent
# that does not exist fails only the NARROW read and is announced separately —
# the plan is still filtered, against the repo-wide listing. The alternative — refusing — would block a PR whose code is
# already reviewed and green on a GitHub outage, and the cost of being wrong in
# this direction is a duplicate follow-up issue a human closes in a second.
#
# Seams (for tests / non-PATH installs):
#   GH_BIN  overrides the `gh` binary. Note the `repos/{owner}/{repo}` API path:
#           `gh` resolves those placeholders from the repository in the working
#           directory, which is why this script needs no --repo of its own.
#
# Exit codes: 0 ok (including an empty plan) · 2 usage · 1 internal (unreadable
#             or invalid --status / --changelist, missing jq)

emulate -L zsh
setopt nounset pipefail

local gh_bin="${GH_BIN:-gh}"
local usage="usage: build-residue-issues.zsh --status FILE --changelist FILE --issue N [--epic N] [--dry-run]"

# A value flag with no value, one whose value is the NEXT FLAG, or an explicitly
# empty one are all caller mistakes that would otherwise surface as something
# else entirely: under `nounset` a dangling `--issue` aborts on the bare `$2`
# with zsh's raw parameter error and exit 1, which this taxonomy reserves for
# internal failures. Every sibling script in this directory guards the same way.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-residue-issues: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "build-residue-issues: $1 requires a value (got the flag $3)"; exit 2 }
  [[ -n "$3" ]] || { print -u2 -- "build-residue-issues: $1 requires a non-empty value"; exit 2 }
}

local status_file="" changelist="" issue="" epic="" dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  --changelist) _need_val "$1" $# "${2:-}"; changelist="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
  --epic) _need_val "$1" $# "${2:-}"; epic="$2"; shift 2 ;;
  --dry-run) dry_run=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" && -n "$changelist" && -n "$issue" ]] || { print -u2 -- "$usage"; exit 2 }

# Both numbers reach jq as RAW JSON via --argjson and GitHub as a URL path
# segment, so validate the shape here rather than letting a junk value fail
# inside jq (where the `||` branch would blame a file) or become a bogus API
# path. The width cap mirrors every sibling: JSON forbids leading zeros, hence
# the 10# normalisation.
_need_issue_number() {  # $1 = flag, $2 = value
  # POSITIVE: GitHub issue numbers start at 1, so `0` is never legitimate — and
  # `<->` matches it. Left through, it becomes `parent: 0`, an
  # `issues/0/sub_issues` request whose 404 lands on the fail-open path, and a
  # body reading "story #0", after which the skill would attach residue to an
  # issue that does not exist.
  [[ "$2" == <-> && ${#2} -le 18 ]] && (( 10#$2 >= 1 )) || {
    print -u2 -- "build-residue-issues: $1 must be a positive issue number (got: $2)"; exit 2 }
}
_need_issue_number --issue "$issue"; issue=$(( 10#$issue ))
if [[ -n "$epic" ]]; then _need_issue_number --epic "$epic"; epic=$(( 10#$epic )); fi

# Without this the `||` branches below would report "invalid JSON" for an absent
# jq — a wrong diagnosis of an environment problem, and the one this directory
# has already had to fix once.
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-residue-issues: jq not found on PATH"; exit 1 }

# A DIRECTORY has non-zero size, so `-s` alone would let it through to jq as
# "Is a directory" and get relabelled a content problem; a NON-EXISTENT path is
# a caller mistake (exit 2), while a file that exists and is unreadable or
# malformed is an input failure (exit 1). Same operand policy as
# build-telemetry-record.zsh.
_need_json_object() {  # $1 = flag, $2 = path
  [[ ! -d "$2" ]] || { print -u2 -- "build-residue-issues: $1 is a directory: $2"; exit 2 }
  [[ -e "$2" ]] || { print -u2 -- "build-residue-issues: $1 file does not exist: $2"; exit 2 }
  [[ -r "$2" ]] || { print -u2 -- "build-residue-issues: $1 file not readable: $2"; exit 1 }
  [[ -s "$2" ]] || { print -u2 -- "build-residue-issues: $1 file is empty: $2"; exit 1 }
  # exactly ONE object: a whitespace-only file makes jq emit nothing and exit 0,
  # and a concatenated multi-document file would silently build two plans
  jq -e -s 'length == 1 and (.[0] | type == "object")' "$2" >/dev/null 2>&1 || {
    print -u2 -- "build-residue-issues: $1 is not exactly one JSON object: $2"; exit 1 }
}
_need_json_object --status "$status_file"
_need_json_object --changelist "$changelist"

# The status must be the RESIDUE ending, and this is the first guard because it
# is the likeliest caller mistake here: residue replaces exactly
# `ESCALATE_NO_CONVERGENCE` and `BUDGET_EXHAUSTED`, whose branches sit beside the
# residue branch in `reference/residue.md`, and the model hand-picks which status file to
# pass. An escalation status paired with its own final-round changelist is
# self-consistent — it satisfies the round cross-check below — so nothing else
# would catch it, and the plan would go on to file `review-residue` follow-ups,
# parented into the epic, for a run that ESCALATED and opened no PR. That is
# precisely the "issues on the board for work that never shipped" outcome the
# skill's own ordering rule exists to prevent, and until now the only guard
# against it was prose. It also stops the body's `// "CONVERGED_WITH_RESIDUE"`
# fallback being load-bearing.
local st_status=""
st_status=$(jq -r '.status // empty' -- "$status_file" 2>/dev/null) || st_status=""
[[ "$st_status" == "CONVERGED_WITH_RESIDUE" ]] || {
  print -u2 -- "build-residue-issues: --status must be a CONVERGED_WITH_RESIDUE run (got: ${st_status:-<none>}) — residue is only filed for a run that OPENED its PR, and an escalation opens none, so filing its blockers would leave issues on the board for work that never shipped"
  exit 2 }

# The two operands are two sources for ONE fact, so their agreement is checked
# rather than assumed. The status JSON already inlines the run's final changelist
# (`resolve-story-loop.zsh` sets `final_changelist` every round), so
# `--changelist` can only ever ADD a disagreement — and `reference/residue.md`
# step 1 asks a model to compute `changelist-<final round>.json` by hand. An off-by-one, or a leftover
# file in a re-used work-dir, passes every guard above (it is one JSON object)
# and produces a plan built from an EARLIER round's blockers: GitHub issues filed
# for findings the fix pass already cleared, each body narrating the real round
# count. Nothing downstream can catch it — the titles are new, so the idempotency
# read filters none of them.
#
# Exit 2, not 1: naming the wrong file is a caller mistake, and the diagnostic
# has to print BOTH numbers or it does not tell the caller which way to move.
# A changelist with no `.round` at all is not refused — an older or hand-built
# fixture legitimately lacks it, and refusing would be a new failure mode for a
# file that is otherwise fine.
local cl_round="" st_rounds=""
cl_round=$(jq -r '.round // empty' -- "$changelist" 2>/dev/null) || cl_round=""
st_rounds=$(jq -r '.rounds // empty' -- "$status_file" 2>/dev/null) || st_rounds=""
if [[ -n "$cl_round" && -n "$st_rounds" && "$cl_round" != "$st_rounds" ]]; then
  print -u2 -- "build-residue-issues: --changelist is round $cl_round but --status reports the run ended at round $st_rounds — that plan would file issues for an earlier round's blockers. Pass <work-dir>/changelist-${st_rounds}.json."
  exit 2
fi

# The parent: the epic when the story has one, else the story itself. Residue
# belongs to the work it came out of, and an epic that exists is the closer
# match for "the thing whose next walk must stop and refine this".
local parent="${epic:-$issue}"

# --- the candidate plan ------------------------------------------------------
# Titles are the IDENTITY this script is idempotent on, so they are built from
# the finding fields that do not move between two runs of the same round and
# nothing else. Reviewer-produced text is neutralised (newlines and backticks
# out, length capped) for the same reason every sibling renderer does it: a
# finding title is untrusted input, and here it becomes both a GitHub issue
# title and part of an equality test.
local plan=""
plan=$(jq -c --argjson issue "$issue" --argjson parent "$parent" \
  --slurpfile st "$status_file" '
  # NB: no apostrophes in this program — it is single-quoted.
  def safe: (. // "") | tostring | gsub("[\r\n`]"; " ") | gsub(" +"; " ")
            | sub("^ +"; "") | sub(" +$"; "");
  def linepart: if (.line | type) == "number" then ":\(.line)" else "" end;
  ($st[0] // {}) as $s
  | [ (.blocking // [])[]
      | . as $f
      | ((.title | safe)[0:120]) as $t
      | ((.file // "") | safe) as $fl
      | ((.dimension // "") | safe) as $dim
      | ((.class // "unclassified") | safe) as $cls
      | ((.priority // "High") | safe) as $sev
      # The ASSEMBLED title is capped, not just its title component: `$fl` (a
      # reviewer-reported path) and `$dim` are unbounded, and a deep plugin path
      # plus a long dimension clears the 256-character GitHub issue-title limit
      # on its own. Over the limit `gh issue create` 422s, and a caller who
      # recovers by shortening the title creates an issue that the key lookup on
      # the next run cannot match — so the re-run duplicates it.
      #
      # But the cap must never eat the TAIL. `\($fl)\(linepart) [\($dim)]` is
      # what makes two findings at different places distinguishable, and a naive
      # `[0:250]` truncates from the right — dimension first, then line, then the
      # path — so two findings differing ONLY in dimension (two reviewers on one
      # spot through different lenses: the ordinary case) would render the same
      # string. So the tail is built first and the reviewer text is capped
      # against whatever budget is left, with a floor so the title never becomes
      # only a path.
      # (NB: no apostrophes in this block — the jq program is single-quoted.)
      # The tail COMPONENTS are bounded first, so the floor below can never be
      # reached and the final slice can never fire. Without that, a tail over ~206
      # characters (`$fl` is an unbounded reviewer-reported path, `$dim` unbounded
      # too) makes the floor outrank the budget, and the closing `[0:250]`
      # truncates from the right again — eating dimension, then line, then path.
      # The consequence is no longer a silent intra-plan drop (`dedupe_key` is the
      # raw identity now), but the pinned IDEMPOTENCY key is the rendered title:
      # two entries with identical titles mean a partially-failed first run has
      # BOTH filtered out as already-filed on the re-run, and the residual blocker
      # is never filed at all.
      # bound copies for the TITLE only — the body still renders the full path
      # and dimension, since it has no length contract to keep
      | (($fl)[0:120]) as $flt
      | (($dim)[0:40]) as $dimt
      | ("\($flt)\($f | linepart) [\($dimt)]") as $tail
      | ((230 - ($tail | length)) as $budget
         | "review residue: \($t[0:(if $budget < 24 then 24 else $budget end)]) — \($tail)") as $ttl0
      # belt and braces only: with the tail bounded above this is a no-op
      | ($ttl0[0:250]) as $ttl
      | { title: $ttl,
          body: ( "Left open by the review loop when it ended `\($s.status // "CONVERGED_WITH_RESIDUE")`"
                  + " after \($s.rounds // 0) round(s) on story #\($issue).\n\n"
                  + "| field | value |\n| --- | --- |\n"
                  + "| file | `\($fl)` |\n"
                  + "| line | \(if (.line | type) == "number" then "\(.line)" else "_(none recorded)_" end) |\n"
                  + "| dimension | \($dim) |\n"
                  + "| severity | \($sev) |\n"
                  + "| class | `\($cls)` |\n\n"
                  + "**Finding**\n\n\($t)\n\n"
                  + (if ((.description | safe) | length) > 0
                     then "**Detail**\n\n\((.description | safe)[0:1500])\n\n" else "" end)
                  + (if ((.suggested_fix | safe) | length) > 0
                     then "**Suggested fix**\n\n\((.suggested_fix | safe)[0:1500])\n\n" else "" end)
                  + "---\n\n"
                  + "Filed automatically by the review loop residue path (#1435): the last two"
                  + " rounds were zero-CRITICAL and the declaring round read the whole story diff,"
                  + " which every remaining blocker is confined to, so"
                  + " story #\($issue) opened its PR and the remainder was filed here instead of"
                  + " spending another round.\n\n"
                  + "It carries `needs-refinement` on purpose — it is a finding, not a story, and it"
                  + " must be refined before anything is built from it." ),
          labels: ["review-residue", "needs-refinement"],
          # the dedupe identity, carried on the entry and stripped again below.
          # Deliberately NOT the rendered title: that string is capped twice, so
          # two genuinely different findings can render identically, and a
          # title-keyed dedupe would then drop one SILENTLY — a residual blocker
          # never filed, in the one mechanism whose whole point is that the
          # remainder lands somewhere a human meets it. The raw four-field
          # identity cannot collide unless the findings really are the same
          # defect at the same place.
          dedupe_key: ([(.file // ""), (.line // null), (.dimension // ""), (.title // "")] | tojson),
          parent: $parent } ]
  # One entry per DISTINCT identity — and a plan that filed two copies of one
  # defect would defeat the idempotency promise on its very first run, before any
  # second run could.
  #
  # Deliberately NOT `unique_by`, which SORTS: the changelist arrives
  # Critical-first (the consolidator ranked it), and re-alphabetising the plan
  # would file the follow-ups in an order that has nothing to do with how bad
  # they are. Keep the first occurrence, in place.
  | reduce .[] as $e ({seen: [], out: []};
      if (.seen | index($e.dedupe_key)) != null then .
      else { seen: (.seen + [$e.dedupe_key]), out: (.out + [$e]) } end)
  | [ .out[] | del(.dedupe_key) ]' -- "$changelist") || {
  print -u2 -- "build-residue-issues: could not build the plan from $changelist"; exit 1 }

# --- idempotency: drop what the parent already carries ----------------------
if (( dry_run )); then
  print -u2 -- "build-residue-issues: --dry-run — no GitHub call made, so the plan below is NOT filtered against issues already filed (neither #${parent}'s sub-issues nor the repo-wide review-residue listing)"
  print -r -- "$plan"
  exit 0
fi

# `[]` short-circuits: there is nothing an existing-issue list could remove, so
# the read would spend a round-trip to filter an empty plan.
if [[ "$plan" == "[]" ]]; then
  print -r -- "$plan"
  exit 0
fi

local existing="" existing_raw="" repo_wide="" repo_wide_raw=""
# Each read's outcome, tracked EXPLICITLY. Inferring it from the merged value
# cannot work: `[]` is a perfectly valid answer from either read and a non-empty
# string, so "did the narrow read succeed" and "is the merged value non-empty"
# are different questions — and conflating them silenced the one diagnostic that
# named a nonexistent parent.
local sub_ok=0 repo_ok=0
# `repos/{owner}/{repo}` — resolved by `gh` from the working directory, which is
# what keeps this script free of a --repo flag. stderr is kept out of the
# capture but NOT silenced: a 404 on the parent, an auth failure and a network
# error are three different things to act on, and the warning below only says
# the read failed.
if existing_raw=$("$gh_bin" api --paginate "repos/{owner}/{repo}/issues/${parent}/sub_issues" \
  --jq '[.[] | {title: (.title // ""), labels: [((.labels // [])[] | if type == "object" then (.name // "") else tostring end)]}]'); then
  # `jq -cs add` merges the per-page arrays --paginate emits, exactly as
  # backfill-sub-issues.zsh does. An empty body (a parent with no sub-issues)
  # yields `[]` rather than a parse failure.
  if existing=$(print -r -- "$existing_raw" | jq -cs 'add // []' 2>/dev/null); then
    sub_ok=1
  else
    existing=""
  fi
fi

# ...and the SAME key across the whole repo, unioned in. The sub-issue list
# alone leaves a hole exactly where the filing is least atomic:
# `reference/residue.md` step 4 creates each entry and THEN attaches it, two API
# calls, so a create that succeeds
# before a failed (or interrupted) attach leaves a real `review-residue` issue
# this parent-scoped read cannot see. The re-run files it again — and the
# duplicate carries `needs-refinement`, so once attached it halts the parent's
# epic walk twice on one finding. The pinned key is *label + exact title*, which
# a repo-wide search answers just as well, so the narrow query was the hole
# rather than the key.
#
# Best-effort and unioned, never a replacement: on failure the sub-issue answer
# still stands, and the fail-open warning below still covers the case where
# BOTH reads FAILED.
if repo_wide_raw=$("$gh_bin" issue list --label review-residue --state all --limit 200 \
  --json title,labels); then
  repo_wide=$(print -r -- "$repo_wide_raw" \
    | jq -cs 'add // [] | [.[] | {title: (.title // ""), labels: [((.labels // [])[] | if type == "object" then (.name // "") else tostring end)]}]' 2>/dev/null) && repo_ok=1 || repo_wide=""
  # Merge into a TEMP and commit only on success. `existing=$(cmd) || :` would
  # still perform the assignment when `cmd` fails, clobbering a perfectly good
  # sub-issue answer with the empty output of the failed merge — turning a
  # best-effort widening into a silent loss of the narrow read.
  local merged=""
  if [[ -n "$repo_wide" && -n "$existing" ]]; then
    if merged=$(jq -cn --argjson a "$existing" --argjson b "$repo_wide" '$a + $b' 2>/dev/null); then
      existing="$merged"
    else
      print -u2 -- "build-residue-issues: could not merge the repo-wide review-residue read with #${parent}'s sub-issues — the plan is filtered against the sub-issues ALONE, so an already-filed-but-unattached residue issue may be duplicated"
    fi
  elif [[ -n "$repo_wide" ]]; then
    existing="$repo_wide"
  fi
fi

# Say so when the widening did not land. The only warning below fires when BOTH
# reads yielded nothing, so a failed repo-wide read on an otherwise healthy run
# was completely silent — reopening the create-succeeded/attach-failed duplicate
# hole this read was added to close, with nothing in the run log to notice. Same
# policy as the sub-issue read above: a rate limit, an auth failure and a stale
# `gh` are three different things to act on.
# Gated on the sub-issue answer EXISTING, because the second clause is a claim
# about what the filter did. With no `gh` at all — the documented fail-open state
# — BOTH reads fail, and an unconditional message would assert the narrow filter
# applied three lines before the fail-open branch says nothing was filtered at
# all: two contradictory claims about one plan, in the run log of the operator
# whose job is to judge whether the follow-ups are duplicates.
# FOUR combinations, and three of them are worth saying out loud. Silence was
# only ever right for "both reads worked" — inferring the rest from the merged
# string left a failed NARROW read completely undiagnosed whenever the repo-wide
# one succeeded, which is exactly how a wrong `--epic` (404 on the parent, listing
# fine) stopped being reported while the plan still carried that parent for the
# skill to attach to.
if (( sub_ok && ! repo_ok )); then
  print -u2 -- "build-residue-issues: the repo-wide review-residue read failed or returned nothing usable — the plan is filtered only against #${parent}'s sub-issues, so a residue issue created by an earlier run whose attach failed may be duplicated"
elif (( ! sub_ok && repo_ok )); then
  print -u2 -- "build-residue-issues: could not read the sub-issues of #${parent} (a parent that does not exist, or auth/network) — the plan is filtered only against the repo-wide review-residue listing, which is capped, so verify --issue/--epic before attaching anything"
fi

if (( ! sub_ok && ! repo_ok )); then
  # FAIL-OPEN, loudly. Silence here would let a duplicate wave through looking
  # exactly like a first run, and refusing would block a green PR on a GitHub
  # outage — so say it, and let the caller see it in the run log.
  print -u2 -- "build-residue-issues: could not read EITHER idempotency source (#${parent}'s sub-issues, or the repo-wide review-residue listing) — the plan below is NOT filtered for issues already filed, so a re-run may duplicate them"
  print -r -- "$plan"
  exit 0
fi

# BOTH halves of the pinned key, in one pass: the label AND an exact title
# match. `index` is given a STRING here (a membership lookup); handed an array
# it would be a subsequence search, which is the trap this directory documents.
print -r -- "$plan" | jq -c --argjson existing "$existing" '
  ( [ $existing[] | select((.labels // []) | index("review-residue")) | .title ] ) as $filed
  | [ .[] | . as $c | select(($filed | index($c.title)) == null) ]' || {
  print -u2 -- "build-residue-issues: could not filter the plan against the already-filed review-residue issues (#${parent}'s sub-issues unioned with the repo-wide listing)"; exit 1
}
