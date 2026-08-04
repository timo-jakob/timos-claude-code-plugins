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
#   2  usage error
#   3  typed escalation — unsupported or ambiguous repo type; a JSON error object
#      { error, ... } is printed on stdout for the orchestrator to relay
#   1  internal error (detect-stack / git / jq failed)

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local detect_bin="${DETECT_STACK_BIN:-${self_dir}/../../bootstrap/scripts/detect-stack.sh}"
local git_bin="${GIT_BIN:-git}"

die_usage() { print -u2 -- "$1"; exit 2 }

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
  local repo="$1" out
  if ! out=$( cd "$repo" && "$detect_bin" 2>/dev/null ); then
    print -u2 -- "review-dispatch: detect-stack failed for $repo"; return 1
  fi
  print -r -- "$out" | jq -c . 2>/dev/null || {
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
    case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --round) round="$2"; shift 2 ;;
    --findings-path) findings_path="$2"; shift 2 ;;
    -*) die_usage "plan: unknown flag: $1" ;;
    *) die_usage "plan: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "plan: --repo is required"
  [[ -d "$repo" ]] || { print -u2 -- "plan: --repo not a directory: $repo"; exit 1 }
  _verify_base "$repo" "$base" || exit 1

  local detect_json; detect_json=$(_detect_json "$repo") || exit 1
  local langs_json; langs_json=$(print -r -- "$detect_json" | jq -c '.languages // []')
  # `// false` default: an older detect-stack without the key falls through to
  # the clean typed error below rather than crashing (#809).
  local is_plugin; is_plugin=$(print -r -- "$detect_json" | jq -r '.is_claude_plugin // false')
  # same `// false` default, same reason (#1153): an older detect-stack without
  # the key falls through to the typed error rather than crashing.
  local is_k8s; is_k8s=$(print -r -- "$detect_json" | jq -r '.is_kubernetes // false')

  # supported review languages present, preserving nothing but membership
  local -a supported
  local l
  for l in swift python java go; do
    if print -r -- "$langs_json" | jq -e --arg l "$l" 'index($l) != null' >/dev/null 2>&1; then
      supported+=("$l")
    fi
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
      jq -nc --argjson cand "$(printf '%s\n' "${supported[@]}" | jq -R . | jq -sc .)" \
             --arg primary "$primary" \
        '{error:"ambiguous_repo_type", candidates:$cand,
          primary:(if $primary=="" then null else $primary end),
          detail:"multiple review panels apply; set .maintenance.yml primary to one of the candidates"}'
      exit 3
    fi
  fi

  [[ -n "$findings_path" ]] || findings_path="${repo%/}/.review/findings-round-${round}.json"

  local changed_json
  changed_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "plan: could not compute changed files"; exit 1
  }

  jq -nc \
    --arg repo_type "$repo_type" \
    --arg review_skill "development-${repo_type}:review" \
    --argjson round "$round" \
    --arg base "$base" \
    --arg findings_path "$findings_path" \
    --argjson changed "$changed_json" \
    '{repo_type:$repo_type, review_skill:$review_skill, round:$round, base:$base,
      findings_path:$findings_path, changed_files:$changed}'
}

cmd_scope_findings() {
  local repo="" base="origin/main" findings=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --findings) findings="$2"; shift 2 ;;
    -*) die_usage "scope-findings: unknown flag: $1" ;;
    *) die_usage "scope-findings: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "scope-findings: --repo is required"
  [[ -n "$findings" ]] || die_usage "scope-findings: --findings is required"
  _verify_base "$repo" "$base" || exit 1

  # missing or empty findings file → nothing in scope
  if [[ ! -s "$findings" ]]; then print -r -- '[]'; return 0; fi

  local changed_json
  changed_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "scope-findings: could not compute changed files"; exit 1
  }

  # keep only findings whose (./-normalized) file is in the story's diff
  jq -c --argjson changed "$changed_json" \
    '[ .[] | . as $f | ($f.file // "" | sub("^\\./";"")) as $p
       | select($changed | index($p)) ]' "$findings" || {
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
