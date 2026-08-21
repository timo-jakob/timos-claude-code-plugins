#!/usr/bin/env zsh
# review-dispatch.zsh — the review-panel invocation contract for the autonomous
# review loop (epic #557, issue #560).
#
# Why: the review loop's orchestrator (#562) must invoke the right language
# review panel WITHOUT knowing language specifics — mirroring the
# /development:maintenance dispatch contract, where adding a language needs zero
# orchestrator edits. This helper is the seam that maps a repo to its panel and
# scopes review to the STORY'S DIFF, so:
#   - repo-type detection reuses the maintenance detection logic (detect-stack.sh),
#   - the panel is invoked on the changed files (+ their blast radius), never the
#     whole repo — pre-existing findings in untouched code belong to
#     /development:maintenance, not the loop; without diff-scoping round 2
#     re-litigates legacy code and the loop never converges,
#   - an unsupported/ambiguous repo type is a TYPED error the orchestrator
#     surfaces as an escalation instead of crashing.
#
# Round 1 reviews the whole story diff; every round after it is an ITERATION on
# the previous one (#1434), not an independent repeat. `--prior-tree` names the
# working-tree identity the PREVIOUS round's reviewers saw (git-tree-id.zsh), so
# an intermediate round's scope is exactly what that round's fix pass changed —
# and `--final` marks the run's CLOSING FULL SWEEP, the one round after round 1
# that is scoped to the whole story diff again, so a defect only visible in the
# interaction between rounds can never ride out unseen. The loop owns WHEN a
# closing sweep happens (that rule moves with each human grant); this script owns
# only the one descriptor value that decides the scope.
#
# Subcommands:
#   plan --repo PATH [--base REF] [--round N] [--findings-path PATH]
#        [--final] [--prior-tree TREE_ID] [--fix-verification PATH]
#        [--adjudicated PATH]
#       Emit the dispatch descriptor JSON on stdout:
#         { repo_type, review_skill, round, base, findings_path, changed_files[],
#           scope_mode, scope_empty, prior_tree, delta_files,
#           fix_verification_path, adjudicated_path }
#       scope_mode is "full" when `round <= 1 || --final`, else "delta" — `<= 1`
#       because `--round` is contracted as any NON-NEGATIVE integer, and there is
#       no round 0 to iterate on.
#       changed_files keeps its meaning as THE REVIEW SCOPE: the full diff
#       against --base on a full round, and exactly delta_files on a delta one.
#       delta_files is everything differing from --prior-tree — computed whenever
#       the flag is given, INCLUDING on a full round, because the loop needs it to
#       invalidate adjudications whose file the last fix pass touched.
#       scope_empty is `changed_files == []`; it is always present, and it exists
#       for CALLERS — the driving session plans its own panel and must know a
#       delta came back empty BEFORE it spawns reviewers. The loop deliberately
#       does NOT read it: it judges emptiness on the scope file it has already
#       written, after the .review/ + work-dir filtering, which is a strict
#       superset (a repo-internal --work-dir puts the loop's own state inside
#       every delta, so this field would say non-empty while the panel is handed
#       nothing). Round 1's existing "a scope that is ONLY artifacts yields empty
#       changed_files, not an error" behaviour stands either way.
#       --fix-verification / --adjudicated are echoed through as
#       fix_verification_path / adjudicated_path (null when absent) — this script
#       never reads either file; the loop writes them and the reviewers consume
#       them. `--max-rounds` is deliberately NOT a flag here: finality is the
#       loop's rule, and duplicating the ceiling would mean two places to change.
#       repo_type ∈ {swift, python, java, go, claude-plugin, kubernetes};
#       review_skill is the
#       review skill the orchestrator invokes (development-<repo_type>:review),
#       passing changed_files as the review scope. claude-plugin (#809) and
#       kubernetes (#1153) are FALLBACK repo_types: selected only when no
#       supported language matched and detect-stack reports is_claude_plugin /
#       is_kubernetes — a language always wins, and neither fallback
#       participates in the ambiguity tiebreak. They are ORDERED, claude-plugin
#       first: both markers fire on a plugin repo that ALSO carries Kubernetes
#       content, and plugin prose is what such a repo is actually made of.
#       kubernetes additionally requires NO detected language at all (not merely
#       no supported one), so a JS/TS service shipping a Helm chart keeps the
#       typed escalation instead of being reviewed by the manifest panel.
#       The panel writes its aggregate findings JSON (issue #558 schema) to
#       findings_path. On an unsupported or ambiguous repo type, print a typed
#       error object and exit 3 (see Exit codes).
#
#   scope-findings --repo PATH [--base REF] --findings FILE
#       Read the panel's aggregate findings array (FILE) and print only the
#       findings whose `file` is inside the story's diff — dropping anything in
#       untouched code. Missing/empty FILE prints []. This enforces the
#       "findings outside the story's diff do not appear" contract downstream of
#       whatever the panel reported.
#
# Seams (for tests / non-PATH installs):
#   DETECT_STACK_BIN  overrides the detect-stack.sh binary (must emit the same
#                     JSON, at least the `.languages` array; `.is_claude_plugin`
#                     and `.is_kubernetes` are read with a false default when
#                     absent).
#   GIT_BIN           overrides the `git` binary. It is also handed to
#                     git-tree-id.zsh (as its own GIT_TREE_ID_BIN seam) when the
#                     delta is computed, so ONE override covers every git call.
#
# Exit codes:
#   0  success — descriptor (plan) or filtered array (scope-findings) on stdout
#   2  usage error — an unknown flag or subcommand, a value-taking flag with no
#      value, a `--round` that is not a non-negative integer, or a `--round > 1`
#      carrying neither `--final` nor `--prior-tree` (there is no silent fallback
#      to the full diff: a round that cannot say what it is iterating on has no
#      scope). Every one of these is checked at PARSE time, so the message names
#      the flag rather than surfacing later as a zsh nounset abort or a jq
#      --argjson parse error.
#   3  typed escalation — unsupported or ambiguous repo type; a JSON error object
#      { error, ... } is printed on stdout for the orchestrator to relay
#   1  internal error — detect-stack / git / jq failed, a `--prior-tree` that
#      does not resolve to a tree-ish in the repo, or `--repo` names
#      something unusable (absent, not a directory, not readable/traversable).
#      Note the split from 2: a MISSING `--repo` is a usage error (2), a `--repo`
#      that is present but unusable is this one, because the invocation was
#      well-formed and the environment is what failed.

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local detect_bin="${DETECT_STACK_BIN:-${self_dir}/../../bootstrap/scripts/detect-stack.sh}"
local git_bin="${GIT_BIN:-git}"
# The delta is computed against the SAME working-tree identity the loop persists
# per round (#981/#1434), so the two must be one implementation — hence the
# sibling script rather than a second inlined `write-tree` here.
local tree_id_bin="${self_dir}/git-tree-id.zsh"

die_usage() { print -u2 -- "$1"; exit 2 }

# A value-taking flag must be followed by its value. Called as
# `need_value <subcommand> "$@"` from inside the parse loop, so $2 is the flag
# and $3 its value — present only when the caller supplied one. Without this,
# `setopt nounset` turns a trailing `--round` into a raw abort (exit 1) instead
# of the exit-2 usage path the header documents.
# Three shapes, not one — the contract both sibling scripts (`_need_val` in
# resolve-story-loop.zsh and consolidate-findings.zsh) have carried for a while,
# and which this one was missing. #1434 routed three new value flags through
# here, and the gap bites hardest on them:
#   * a FLAG-SHAPED value, the realistic unquoted `--prior-tree $VAR` with VAR
#     unset, assigns the NEXT flag as the value. `--prior-tree --final` then
#     swallows `--final`, so the round is planned as a delta and
#     `_verify_prior_tree` fails with "does not resolve to a tree: --final" —
#     exit 1 (internal error) with a confidently wrong cause, where a malformed
#     invocation is contracted as exit 2;
#   * an EXPLICITLY EMPTY value reads downstream as "flag omitted" at exit 0:
#     `--fix-verification ""` / `--adjudicated ""` emit a null path, so the
#     round's panel silently gets no carry and no waived list.
need_value() {
  (( $# >= 3 )) || die_usage "$1: $2 requires a value"
  [[ "$3" != --* ]] || die_usage "$1: $2 requires a value (got the flag $3)"
  [[ -n "$3" ]] || die_usage "$1: $2 requires a non-empty value"
}

# --- repo-relative changed files = the story's diff -------------------------
# Everything that differs from the base ref (committed + staged + unstaged for
# tracked files) plus new untracked files — the story's blast radius as seen in
# the worktree. base defaults to origin/main. The loop's OWN outputs — the
# per-round findings under .review/ and the telemetry JSONL (#566) — must never
# enter the scope (#909): on a repeat/resumed run they are untracked files in
# the repo, and without this exclusion the panel would be directed to review
# prior rounds' findings as story code. The exclusion covers the DEFAULT
# artifact locations only (a caller-overridden --findings-path elsewhere in the
# repo is not followed), and it applies to tracked changes under these prefixes
# too — runtime JSONL is never review scope. sed (not grep -v) so an
# all-artifact scope yields empty output with exit 0 under pipefail, not a
# pipeline failure.
#
# The normalisation + exclusion half is factored out because the DELTA scope
# (#1434) must go through the very same rules: one file-listing path, so a
# `.review/` artifact excluded from a full round can never sneak into a delta
# round, and a `./`-prefixed spelling can never make the two disagree.
_normalise_paths() {
  sed -E 's#^\./##' | sort -u \
    | sed -e '/^$/d' -e '\#^\.review/#d' -e '\#^\.claude/telemetry/#d'
}

_changed_files() {
  local repo="$1" base="$2"
  # A failed diff or ls-files must FAIL the scope computation (#910) — the old
  # 2>/dev/null swallow let an unresolvable base degrade to an empty/garbage
  # scope on which the loop happily CONVERGED. Base resolvability is validated
  # up front by _verify_base, so a failure here is a genuine git error.
  {
    "$git_bin" -C "$repo" diff --name-only "$base" -- || return 1
    "$git_bin" -C "$repo" ls-files --others --exclude-standard || return 1
  } | _normalise_paths
}

# --- the delta since the previous round's tree (#1434) ----------------------
# Everything differing between --prior-tree and the CURRENT working tree. Both
# sides are `git add -A` trees (git-tree-id.zsh), so tracked edits, deletions and
# untracked additions are compared by one uniform rule — where `git diff <tree>`
# would see only what the index knows and mis-report a file that was untracked at
# the prior identity. Prior-tree resolvability is validated up front by
# _verify_prior_tree, so a failure here is a genuine git/identity error and must
# FAIL the scope rather than degrade to an empty delta (the #910 rule: an empty
# scope the loop would happily converge on is the worst possible fallback).
_delta_files() {
  local repo="$1" prior="$2" cur=""
  [[ -x "$tree_id_bin" ]] || {
    print -u2 -- "review-dispatch: cannot compute the delta — $tree_id_bin is missing or not executable"
    return 1
  }
  cur=$(GIT_TREE_ID_BIN="$git_bin" "$tree_id_bin" "$repo") || {
    print -u2 -- "review-dispatch: could not compute the current working-tree identity for $repo"
    return 1
  }
  [[ -n "$cur" ]] || {
    print -u2 -- "review-dispatch: the current working-tree identity for $repo came back empty"
    return 1
  }
  # same normalisation + #909 exclusions as the full scope — `pipefail` is set,
  # so a failing diff-tree still fails the function rather than yielding an
  # empty delta
  "$git_bin" -C "$repo" diff-tree -r --name-only "$prior" "$cur" | _normalise_paths
}

# --- base ref must resolve before it scopes anything (#910) -----------------
# An unresolvable --base (a typo, an unfetched remote, a worktree before its
# first fetch) must be a fast, named failure — not a silently empty scope that
# lets the loop exit CONVERGED on code no panel ever saw.
_verify_base() {
  local repo="$1" base="$2"
  # name the actual culprit: a non-repo path must not read as a bad ref
  "$git_bin" -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --repo is not a git repository: $repo"
    return 1
  }
  "$git_bin" -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --base does not resolve to a commit in $repo: $base"
    return 1
  }
}

# --- prior tree must resolve before it scopes anything (#1434) --------------
# Exactly _verify_base's argument, one round later: an unresolvable --prior-tree
# (a truncated id, a tree gc'd out of a foreign object DB, a work-dir carried to
# another clone) must be a fast, NAMED failure. Degrading to the full diff would
# silently turn every intermediate round back into an independent repeat, and
# degrading to an empty delta would let the loop converge on code no panel saw.
# `^{tree}` deliberately, not `^{commit}`: the identity the loop persists is a
# tree, and a commit-ish is accepted only because it peels to one.
_verify_prior_tree() {
  local repo="$1" prior="$2"
  "$git_bin" -C "$repo" rev-parse --verify --quiet "${prior}^{tree}" >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --prior-tree does not resolve to a tree in $repo: $prior"
    return 1
  }
}

# --- full detection JSON via the reused detection logic ---------------------
_detect_json() {
  local repo="$1" out rc err_file
  # RELAY detect-stack's stderr rather than dropping it (#1177). Since detect-
  # stack grew an error contract, its non-zero exit carries its whole meaning
  # there ("the kubernetes marker search did not complete (find exit N, grep
  # exit M)"). Swallowing it leaves the operator with a bare "detect-stack
  # failed" and no way to tell a permissions problem from a missing binary — and
  # that named message is the deliverable the hardening exists to produce.
  # A temp FILE, not `2>&1` around the assignment: `out=$( … )` inside a command
  # substitution runs in a subshell, so the captured JSON would be discarded
  # with it. `cd --`, because `[[ -d ]]` passes for a path starting with `-`
  # that `cd` would read as an option and blame on the wrong culprit.
  # DEGRADE, never fail, when the buffer cannot be made: it exists only to
  # forward a diagnostic and is not needed on the success path, so an unwritable
  # TMPDIR must not fail a repo this could otherwise plan.
  err_file=$(mktemp) || {
    print -u2 -- "review-dispatch: no temp file — detect-stack's stderr will not be relayed"
    err_file=""
  }
  if [[ -n "$err_file" ]]; then
    out=$( cd -- "$repo" && "$detect_bin" 2>"$err_file" ); rc=$?
  else
    out=$( cd -- "$repo" && "$detect_bin" ); rc=$?
  fi
  if (( rc != 0 )); then
    print -u2 -- "review-dispatch: detect-stack failed for $repo (exit $rc)"
    [[ -n "$err_file" && -s "$err_file" ]] && print -u2 -r -- "$(<"$err_file")"
    [[ -z "$err_file" ]] || rm -f "$err_file"
    return 1
  fi
  [[ -z "$err_file" ]] || rm -f "$err_file"
  # jq's own parse error is RELAYED, not suppressed — same argument as above: it
  # names WHERE the document went wrong, which the message below cannot.
  print -r -- "$out" | jq -c . || {
    print -u2 -- "review-dispatch: could not parse detect-stack output"; return 1
  }
}

# --- .maintenance.yml primary (dependency-free, mirrors maintenance SKILL) --
_primary() {
  local repo="$1"
  grep -E '^[[:space:]]*primary:' "$repo/.maintenance.yml" 2>/dev/null | head -1 \
    | sed -E 's/^[[:space:]]*primary:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^["'\'']//; s/["'\'']$//'
}

cmd_plan() {
  local repo="" base="origin/main" round=1 findings_path=""
  # `prior_tree_given` tracks PRESENCE, separately from the value. The blank
  # check below cannot be written against the value alone: `--prior-tree ""` —
  # the realistic `--prior-tree "$(<tree-1.txt)"` with the file absent — is
  # indistinguishable from "flag omitted" once assigned, and would be waved
  # through, which is precisely the shape the check exists to catch.
  local final=0 prior_tree="" prior_tree_given=0 fix_verification="" adjudicated=""
  while [[ $# -gt 0 ]]; do
    # `need_value` BEFORE the assignment (#1177): this script runs under
    # `setopt nounset`, so a value-taking flag in last position made `"$2"` a raw
    # parameter-not-set abort — exit 1 with a zsh diagnostic, where the header
    # contract documents exit 2 and a usage message for a malformed invocation.
    # A caller distinguishing "you called me wrong" (2) from "something broke"
    # (1) was told the wrong one, and the message named zsh's internals instead
    # of the missing flag.
    case "$1" in
    --repo) need_value "plan" "$@"; repo="$2"; shift 2 ;;
    --base) need_value "plan" "$@"; base="$2"; shift 2 ;;
    # …and validate the ROUND at parse time. It reaches jq as `--argjson round`,
    # where a non-numeric value is a jq parse error — an exit 5 from jq
    # surfacing as an unexplained failure at the very END of a successful plan,
    # long after the typo that caused it.
    --round) need_value "plan" "$@"
             # WIDTH too, not just the character class — the sibling value
             # flags all carry the cap (`--issue`, `--max-rounds`,
             # consolidate's own `--round`). zsh arithmetic is 64-bit, so a
             # 20-digit value WRAPS to a negative round in the normalisation
             # below: `scope_mode` is then forced "full" by the `round <= 1`
             # test — a caller asking for a delta silently gets the whole
             # story diff — and the default sink becomes
             # `findings-round--7766279631452241920.json`.
             [[ "$2" == <-> ]] && [[ ${#2} -le 18 ]] || \
               die_usage "plan: --round must be a non-negative integer of at most 18 digits: $2"
             # NORMALISE, don't just accept: `007` is a non-negative integer and
             # passes the pattern, but it is not valid JSON, so `--argjson round
             # 007` below would fail with jq's exit 5 at the very end of an
             # otherwise successful plan — the late failure this parse-time check
             # exists to prevent, and a status outside the documented set.
             # `emulate -L zsh` leaves OCTAL_ZEROES off, so $(( 007 )) is 7 — it
             # also keeps findings-round-007.json from becoming a second,
             # colliding artifact path for round 7.
             round=$(( $2 )); shift 2 ;;
    --findings-path) need_value "plan" "$@"; findings_path="$2"; shift 2 ;;
    # --final is a BOOLEAN — the loop's "this is the closing full sweep" signal.
    # No value, so it never goes through need_value.
    --final) final=1; shift ;;
    --prior-tree) need_value "plan" "$@"; prior_tree="$2"; prior_tree_given=1; shift 2 ;;
    # Echoed through, never read here: the loop writes both files and the
    # reviewers consume them. Keeping them in the descriptor is what lets one
    # value (the plan) carry everything a round's panel needs.
    --fix-verification) need_value "plan" "$@"; fix_verification="$2"; shift 2 ;;
    --adjudicated) need_value "plan" "$@"; adjudicated="$2"; shift 2 ;;
    -*) die_usage "plan: unknown flag: $1" ;;
    *) die_usage "plan: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "plan: --repo is required"
  [[ -d "$repo" ]] || { print -u2 -- "plan: --repo not a directory: $repo"; exit 1 }
  # and TRAVERSABLE, the sibling gather script's gate. Without it a directory
  # that exists but cannot be entered makes `cd` fail inside _detect_json, and
  # the failure is reported as "detect-stack failed" — naming a script that never
  # ran, with no stderr to relay, which is exactly the case the relay exists for.
  [[ -r "$repo" && -x "$repo" ]] || {
    print -u2 -- "plan: --repo is not a readable directory: $repo"; exit 1
  }
  # normalise ONLY a path that could be misread as a flag, exactly as
  # gather-kubernetes-findings.zsh does: `[[ -d ]]` is true for `-fixtures/repo`
  # (test operators parse no options) but `cd` reads it as an option, and the
  # failure would then be blamed on detect-stack. Every other relative spelling
  # is already unambiguous — and rewriting them all put a doubled prefix into the
  # emitted `findings_path` for the ordinary `--repo .` (which `./*` never
  # matched), a descriptor field the orchestrator consumes and hands back.
  # An EXPLICIT empty value is the one shape `need_value`'s arg-count check
  # cannot see, and it is the realistic `--prior-tree "$(<tree-1.txt)"` with the
  # file absent. Left alone it reads downstream as "flag omitted": harmless on a
  # --final round (the scope is the full diff either way) but it would silently
  # drop delta_files, and the loop's adjudication invalidation reads exactly that
  # field — so an adjudicated suggestion whose file the last fix pass touched
  # would stay suppressed. Name it instead.
  #
  # Keyed on PRESENCE, not on the value: a `[[ -z "$prior_tree" || … ]]` test
  # short-circuits on its first operand for the empty string, so it would accept
  # the very shape the paragraph above says it exists to catch and refuse only a
  # whitespace-ONLY value — the one spelling no caller produces.
  (( ! prior_tree_given )) || [[ -n "${prior_tree//[[:space:]]/}" ]] || \
    die_usage "plan: --prior-tree requires a non-blank value"
  # A round after the first is an ITERATION (#1434): it must say what it is
  # iterating on, or declare itself the closing full sweep. There is deliberately
  # no fallback to the full diff — that fallback IS the defect this story fixes,
  # and it would be invisible (a full-diff round emitting scope_mode "delta").
  if (( round > 1 && ! final )) && [[ -z "$prior_tree" ]]; then
    die_usage "plan: --round $round needs --prior-tree (the previous round's tree identity), or --final for the closing full sweep"
  fi
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  _verify_base "$repo" "$base" || exit 1
  # next to _verify_base, and BEFORE anything is scoped — the whole point is that
  # an unresolvable identity never reaches a scope computation
  [[ -z "$prior_tree" ]] || _verify_prior_tree "$repo" "$prior_tree" || exit 1

  local detect_json; detect_json=$(_detect_json "$repo") || exit 1
  # All three reads CHECK jq's status (#1177), like the `lang_count` read below.
  # They already failed closed — an empty value matches neither "true" nor a
  # language — so no misroute was reachable; what was wrong is the STATUS. The
  # header contract promises exit 1 (internal error) for a jq failure, and an
  # unchecked read delivered exit 3 instead, telling the orchestrator to escalate
  # an "unsupported repo type" it never determined. A typed escalation is a
  # verdict about the repo; a dead jq is a verdict about the machine.
  local langs_json; langs_json=$(print -r -- "$detect_json" | jq -c '.languages // []') || {
    print -u2 -- "plan: could not read .languages from the detect-stack output"; exit 1
  }
  # `// false` default: an older detect-stack without the key falls through to
  # the clean typed error below rather than crashing (#809).
  local is_plugin; is_plugin=$(print -r -- "$detect_json" | jq -r '.is_claude_plugin // false') || {
    print -u2 -- "plan: could not read .is_claude_plugin from the detect-stack output"; exit 1
  }
  # same `// false` default, same reason (#1153): an older detect-stack without
  # the key falls through to the typed error rather than crashing.
  local is_k8s; is_k8s=$(print -r -- "$detect_json" | jq -r '.is_kubernetes // false') || {
    print -u2 -- "plan: could not read .is_kubernetes from the detect-stack output"; exit 1
  }

  # supported review languages present, preserving nothing but membership
  local -a supported
  local l
  # the last jq whose failure was read as a VERDICT (#1177): `jq -e` exits 1 for
  # false/null but 5 for a program error, and treating both as "this language is
  # absent" turns four jq errors into an `unsupported_repo_type` claim about the
  # repo. Same rule as every other read here — a dead jq is a fact about the
  # machine, not about the repo.
  local probe_rc
  for l in swift python java go; do
    print -r -- "$langs_json" | jq -e --arg l "$l" 'index($l) != null' >/dev/null 2>&1
    probe_rc=$?
    (( probe_rc <= 1 )) || {
      print -u2 -- "plan: could not test the detected-language set for $l"; exit 1
    }
    (( probe_rc == 0 )) && supported+=("$l")
  done

  local repo_type=""
  if (( ${#supported} == 0 )); then
    # Fallbacks ONLY (#809, #1153): these repos detect no language — a plugin
    # repo's content is prose, agent definitions, zsh scripts and JSON
    # manifests; a GitOps repo's is charts, overlays and Argo CD resources.
    # A detected language always wins, and neither joins the `.maintenance.yml`
    # primary tiebreak (which lives in the multi-language `else` branch below).
    #
    # ORDER IS LOAD-BEARING: both markers fire on a plugin repo that ALSO
    # carries Kubernetes content, and such a repo's content is plugin prose, so
    # it must be reviewed by the plugin panel. This repo becomes exactly that
    # case once #1155 lands its Kubernetes fixtures under tests/fixtures/ —
    # reversing these two would then point its own review loop at a manifest
    # panel. (Today is_kubernetes is false here, so only one marker fires.)
    # The kubernetes fallback additionally requires NO detected language at all,
    # not merely no SUPPORTED one. `supported` is the intersection with the four
    # panel languages, so it is empty both for a language-less GitOps repo and
    # for, say, a JavaScript service — and `is_kubernetes` is a topic marker that
    # composes with any language, so a JS/TS service that ships its own Helm
    # chart (a very ordinary shape) would otherwise be handed to the manifest
    # panel for a story whose diff is JS. That panel has no competence there: it
    # would converge finding-free and the loop would record a clean review that
    # never happened. Such a repo keeps the typed `unsupported_repo_type`
    # escalation, which names the languages so a human can route it.
    #
    # claude-plugin deliberately does NOT carry that extra condition (#809): a
    # `.claude-plugin/plugin.json` is definitional for what the repo *is*, and
    # a plugin repo carrying one unsupported-language file is still a plugin
    # repo. A `Chart.yaml` is routinely incidental to an application repo.
    # NOT `local -i`, and the status IS checked — both deliberate. zsh
    # arithmetic-evaluates an empty string assigned to an integer-attributed
    # parameter to **0**, and 0 is precisely the value that OPENS this gate. So
    # an unchecked `-i` read would fail OPEN: a jq that died, or an empty
    # `$langs_json` from a failed earlier read, would hand a language-bearing
    # repo to the manifest panel — reproducing on the error path the exact
    # misrouting this guard exists to prevent. Fail closed instead, with the
    # exit-1 internal-error status the header contract promises.
    local lang_count
    lang_count=$(print -r -- "$langs_json" | jq 'length') || {
      print -u2 -- "plan: could not compute the detected-language count"; exit 1
    }
    [[ "$lang_count" == <-> ]] || {
      print -u2 -- "plan: non-numeric language count: ${lang_count:-<empty>}"; exit 1
    }
    if [[ "$is_plugin" == "true" ]]; then
      repo_type="claude-plugin"
    elif [[ "$is_k8s" == "true" ]] && (( lang_count == 0 )); then
      repo_type="kubernetes"
    else
      jq -nc --argjson langs "$langs_json" \
        '{error:"unsupported_repo_type", languages:$langs, supported:["swift","python","java","go"],
          detail:"no review panel exists for the detected languages"}'
      exit 3
    fi
  elif (( ${#supported} == 1 )); then
    repo_type="${supported[1]}"
  else
    local primary; primary=$(_primary "$repo")
    if [[ -n "$primary" ]] && (( ${supported[(Ie)$primary]} )); then
      repo_type="$primary"
    else
      # the candidate list is CHECKED before it is passed (#1177): an unchecked
      # inner substitution that failed would leave `--argjson cand ''`, jq would
      # reject it, and the `exit 3` below would still run — telling the
      # orchestrator to escalate while handing it nothing to relay.
      local cand_json
      cand_json=$(printf '%s\n' "${supported[@]}" | jq -R . | jq -sc .) || {
        print -u2 -- "plan: could not encode the candidate list"; exit 1
      }
      jq -nc --argjson cand "$cand_json" \
             --arg primary "$primary" \
        '{error:"ambiguous_repo_type", candidates:$cand,
          primary:(if $primary=="" then null else $primary end),
          detail:"multiple review panels apply; set .maintenance.yml primary to one of the candidates"}' || {
        print -u2 -- "plan: could not emit the ambiguous-repo-type error"; exit 1
      }
      exit 3
    fi
  fi

  [[ -n "$findings_path" ]] || findings_path="${repo%/}/.review/findings-round-${round}.json"

  local full_json
  full_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "plan: could not compute changed files"; exit 1
  }

  # The delta is computed whenever --prior-tree is given, INCLUDING on a full
  # round: `changed_files` is then still the whole story diff, but the loop reads
  # delta_files to decide which adjudications the last fix pass invalidated, and
  # the closing sweep is exactly a full round that must still do that.
  local delta_json='null'
  if [[ -n "$prior_tree" ]]; then
    delta_json=$(_delta_files "$repo" "$prior_tree" | jq -R . | jq -sc .) || {
      print -u2 -- "plan: could not compute the delta against --prior-tree: $prior_tree"; exit 1
    }
  fi

  # ONE descriptor value decides the scope, so it is testable on its own and the
  # loop's finality rule (which moves with every human grant) stays in the loop.
  # `round <= 1`, not `round == 1`: `--round` is contracted as any NON-NEGATIVE
  # integer, so 0 is legal, and it satisfies neither `== 1` nor `--final`. It
  # would then be scoped "delta" with no `--prior-tree` required (that guard
  # fires only for `round > 1`), and `changed_files` would take delta_json's
  # `null` default — an emitted descriptor whose review scope is not an array,
  # which the contract says it always is. There is no round 0 to iterate on, so
  # the full scope is the only meaning it can have.
  local scope_mode="delta"
  (( round <= 1 || final )) && scope_mode="full"
  local changed_json="$full_json"
  [[ "$scope_mode" == "delta" ]] && changed_json="$delta_json"

  # the descriptor emitter is checked like every other jq call (#1177). It is the
  # last command of the last function, so an unchecked failure would leave jq's
  # own status (5) as the script's — a code outside the documented set, which the
  # orchestrator cannot map to internal-error vs typed-escalation.
  jq -nc \
    --arg repo_type "$repo_type" \
    --arg review_skill "development-${repo_type}:review" \
    --argjson round "$round" \
    --arg base "$base" \
    --arg findings_path "$findings_path" \
    --argjson changed "$changed_json" \
    --arg scope_mode "$scope_mode" \
    --arg prior_tree "$prior_tree" \
    --argjson delta "$delta_json" \
    --arg fixver "$fix_verification" \
    --arg adjud "$adjudicated" \
    '{repo_type:$repo_type, review_skill:$review_skill, round:$round, base:$base,
      findings_path:$findings_path, changed_files:$changed,
      scope_mode:$scope_mode,
      scope_empty:(($changed | length) == 0),
      prior_tree:(if $prior_tree=="" then null else $prior_tree end),
      delta_files:$delta,
      fix_verification_path:(if $fixver=="" then null else $fixver end),
      adjudicated_path:(if $adjud=="" then null else $adjud end)}' || {
    print -u2 -- "plan: could not emit the dispatch descriptor"; exit 1
  }
}

cmd_scope_findings() {
  local repo="" base="origin/main" findings=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repo) need_value "scope-findings" "$@"; repo="$2"; shift 2 ;;
    --base) need_value "scope-findings" "$@"; base="$2"; shift 2 ;;
    --findings) need_value "scope-findings" "$@"; findings="$2"; shift 2 ;;
    -*) die_usage "scope-findings: unknown flag: $1" ;;
    *) die_usage "scope-findings: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "scope-findings: --repo is required"
  [[ -n "$findings" ]] || die_usage "scope-findings: --findings is required"
  # same leading-dash normalisation as cmd_plan
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  # and the same two directory gates, for the same reason: without them an
  # unreadable --repo is reported by _verify_base as "not a git repository" — a
  # confidently wrong claim about a directory that may be a perfectly good repo
  # this process simply cannot traverse. Both subcommands must name one cause
  # with one wording.
  [[ -d "$repo" ]] || { print -u2 -- "scope-findings: --repo not a directory: $repo"; exit 1 }
  [[ -r "$repo" && -x "$repo" ]] || {
    print -u2 -- "scope-findings: --repo is not a readable directory: $repo"; exit 1
  }
  _verify_base "$repo" "$base" || exit 1

  # missing or empty findings file → nothing in scope
  if [[ ! -s "$findings" ]]; then print -r -- '[]'; return 0; fi

  local changed_json
  changed_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "scope-findings: could not compute changed files"; exit 1
  }

  # keep only findings whose (./-normalized) file is in the story's diff
  # the file arrives on STDIN, never as an operand: `--findings -f.json` is a
  # value a caller can legitimately produce (plan's --findings-path is free-form),
  # and jq would parse it as options and then blame the failure on unparseable
  # JSON — a confidently wrong cause for a file that may be perfectly valid.
  jq -c --argjson changed "$changed_json" \
    '[ .[] | . as $f | ($f.file // "" | sub("^\\./";"")) as $p
       | select($changed | index($p)) ]' < "$findings" || {
    print -u2 -- "scope-findings: could not parse findings JSON: $findings"; exit 1
  }
}

[[ $# -ge 1 ]] || die_usage "usage: review-dispatch.zsh <plan|scope-findings> [flags]"
local sub="$1"; shift
case "$sub" in
  plan) cmd_plan "$@" ;;
  scope-findings) cmd_scope_findings "$@" ;;
  -h|--help) print -r -- "usage: review-dispatch.zsh <plan|scope-findings> [flags]"; exit 0 ;;
  *) die_usage "unknown subcommand: $sub (expected plan|scope-findings)" ;;
esac
