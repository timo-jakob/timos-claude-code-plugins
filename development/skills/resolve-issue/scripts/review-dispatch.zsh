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
# Subcommands:
#   plan --repo PATH [--base REF] [--round N] [--findings-path PATH]
#       Emit the dispatch descriptor JSON on stdout:
#         { repo_type, review_skill, round, base, findings_path, changed_files[] }
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
#   GIT_BIN           overrides the `git` binary.
#
# Exit codes:
#   0  success — descriptor (plan) or filtered array (scope-findings) on stdout
#   2  usage error — an unknown flag or subcommand, a value-taking flag with no
#      value, or a `--round` that is not a non-negative integer. Every one of
#      these is checked at PARSE time, so the message names the flag rather than
#      surfacing later as a zsh nounset abort or a jq --argjson parse error.
#   3  typed escalation — unsupported or ambiguous repo type; a JSON error object
#      { error, ... } is printed on stdout for the orchestrator to relay
#   1  internal error — detect-stack / git / jq failed, or `--repo` names
#      something unusable (absent, not a directory, not readable/traversable).
#      Note the split from 2: a MISSING `--repo` is a usage error (2), a `--repo`
#      that is present but unusable is this one, because the invocation was
#      well-formed and the environment is what failed.

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local detect_bin="${DETECT_STACK_BIN:-${self_dir}/../../bootstrap/scripts/detect-stack.sh}"
local git_bin="${GIT_BIN:-git}"

die_usage() { print -u2 -- "$1"; exit 2 }

# A value-taking flag must be followed by its value. Called as
# `need_value <subcommand> "$@"` from inside the parse loop, so $2 is the flag
# and $3 its value — present only when the caller supplied one. Without this,
# `setopt nounset` turns a trailing `--round` into a raw abort (exit 1) instead
# of the exit-2 usage path the header documents.
need_value() {
  (( $# >= 3 )) || die_usage "$1: $2 requires a value"
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
_changed_files() {
  local repo="$1" base="$2"
  # A failed diff or ls-files must FAIL the scope computation (#910) — the old
  # 2>/dev/null swallow let an unresolvable base degrade to an empty/garbage
  # scope on which the loop happily CONVERGED. Base resolvability is validated
  # up front by _verify_base, so a failure here is a genuine git error.
  {
    "$git_bin" -C "$repo" diff --name-only "$base" -- || return 1
    "$git_bin" -C "$repo" ls-files --others --exclude-standard || return 1
  } | sed -E 's#^\./##' | sort -u \
    | sed -e '/^$/d' -e '\#^\.review/#d' -e '\#^\.claude/telemetry/#d'
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
             [[ "$2" == <-> ]] || die_usage "plan: --round must be a non-negative integer: $2"
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
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  _verify_base "$repo" "$base" || exit 1

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

  local changed_json
  changed_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "plan: could not compute changed files"; exit 1
  }

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
    '{repo_type:$repo_type, review_skill:$review_skill, round:$round, base:$base,
      findings_path:$findings_path, changed_files:$changed}' || {
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
