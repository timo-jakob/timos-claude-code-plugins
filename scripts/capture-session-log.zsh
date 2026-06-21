#!/usr/bin/env zsh
# capture-session-log.zsh — bundle a Claude Code run's transcript AND its
# subagent transcripts into one .tgz for handoff (#398).
#
# Why: feeding a real run's log back into these plugins is the core loop of this
# repo, but Claude Code stores the main transcript and the subagent transcripts
# separately:
#
#   ~/.claude/projects/<repo-slug>/
#   ├── <session-id>.jsonl          # main transcript (isSidechain:false only)
#   └── <session-id>/subagents/
#       ├── agent-<id>.jsonl        # each subagent's FULL transcript
#       └── agent-<id>.meta.json
#
# Handing over only the main .jsonl loses every dispatcher / triage / planner /
# ci-fixer subagent — the most informative part. This script bundles both.
#
# The bundle's audience is Claude Code, not a human: the point is to feed a real
# run back so Claude can mine it for plugin optimisations + bug fixes. So the
# capture optimises for machine-analyzable COMPLETENESS over a curated subset.
#
# A single logical run also spans MULTIPLE project dirs (#414): a worktree it
# spawns (slug `<main>--claude-worktrees-*`) and headless `plugin-test` /
# `pt-reval` sessions (slug `*-{plugin-test,pt-reval}-*-<repo>`) each become their
# own project dir with their own subagents/. We correlate them by slug + a time
# window around the chosen session and bundle them under `related/<slug>/…`, so
# the user never has to know which temp/worktree dirs belong to their run.
#
# Usage:
#   capture-session-log.zsh                  # interactive: pick project, then
#                                            # session — both default to newest
#   capture-session-log.zsh --list           # list projects (most recent first)
#   capture-session-log.zsh --project <repo-path|slug|dir-name> [--session <id|latest>]
#   capture-session-log.zsh --out <dir>      # output dir (default: ~/Desktop)
#   capture-session-log.zsh --dry-run        # print what would be bundled, don't tar
#   capture-session-log.zsh --main-only      # skip related-session discovery
#   capture-session-log.zsh --related <slug> # force-include a project dir (repeatable)
#   capture-session-log.zsh --window-hours N # related-session time window (default 6)
#
# Non-interactive when --project is given or stdin isn't a TTY (defaults to the
# newest project/session so it never hangs). `--projects-dir <dir>` overrides the
# log root (default ~/.claude/projects) — the seam the bats tests drive.
#
# Exit codes: 0 success · 1 nothing to bundle / resolution failed · 2 usage error

setopt err_exit nounset pipefail

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
opt_project=""
opt_session="latest"
opt_out=""
do_list="false"
dry_run="false"
main_only="false"
opt_window_hours="6"
typeset -a forced_related
forced_related=()

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; }

die()  { print -u2 -- "capture-session-log: $1"; exit "${2:-1}"; }

while (( $# > 0 )); do
  case "$1" in
    --project)      opt_project="${2:-}"; shift 2 ;;
    --session)      opt_session="${2:-}"; shift 2 ;;
    --out)          opt_out="${2:-}";     shift 2 ;;
    --projects-dir) PROJECTS_DIR="${2:-}"; shift 2 ;;
    --related)      forced_related+=("${2:-}"); shift 2 ;;
    --window-hours) opt_window_hours="${2:-}"; shift 2 ;;
    --list)         do_list="true";  shift ;;
    --dry-run)      dry_run="true";  shift ;;
    --main-only)    main_only="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" 2 ;;
  esac
done

[[ -d "$PROJECTS_DIR" ]] || die "projects dir not found: $PROJECTS_DIR"

# Projects (immediate subdirs holding ≥1 session .jsonl), newest session first.
typeset -a projects_ordered
{
  local f proj seen=""
  for f in "$PROJECTS_DIR"/*/*.jsonl(N.om); do
    proj="${${f:h}:t}"
    [[ " $seen " == *" $proj "* ]] && continue
    seen="$seen $proj"
    projects_ordered+=("$proj")
  done
}
(( ${#projects_ordered} > 0 )) || die "no sessions found under $PROJECTS_DIR"

# newest session timestamp for a project, for display.
proj_when() {
  local s=( "$PROJECTS_DIR/$1"/*.jsonl(N.om) )
  (( ${#s} )) && date -r "${s[1]}" '+%Y-%m-%d %H:%M' 2>/dev/null || print -- "?"
}

if [[ "$do_list" == "true" ]]; then
  print -- "Projects under $PROJECTS_DIR (most recent first):"
  local i=1 p
  for p in $projects_ordered; do
    local s=( "$PROJECTS_DIR/$p"/*.jsonl(N.om) )
    printf '  %2d) %s  —  %s  (%d session(s))\n' "$i" "$p" "$(proj_when "$p")" "${#s}"
    (( i++ ))
  done
  exit 0
fi

# --- resolve the project ------------------------------------------------------
resolve_project() {
  local in="$1"
  [[ -d "$PROJECTS_DIR/$in" ]] && { print -- "$in"; return 0; }   # exact dir name
  if [[ "$in" == */* ]]; then                                     # repo path → slug
    local slug="${in//\//-}"
    [[ -d "$PROJECTS_DIR/$slug" ]] && { print -- "$slug"; return 0; }
  fi
  local m=( ${(M)projects_ordered:#*-${in}} )                     # bare-name suffix match
  (( ${#m} == 1 )) && { print -- "${m[1]}"; return 0; }
  return 1
}

local project=""
if [[ -n "$opt_project" ]]; then
  project="$(resolve_project "$opt_project")" \
    || die "no project matches '$opt_project' (try --list)"
elif [[ -t 0 ]]; then
  print -- "Select a project (most recent first):"
  local i=1 p
  for p in $projects_ordered; do
    printf '  %2d) %s  —  %s\n' "$i" "$p" "$(proj_when "$p")"
    (( i++ ))
  done
  local pick=""
  read "pick?Project number [1]: " || true
  pick="${pick:-1}"
  [[ "$pick" == <-> && "$pick" -ge 1 && "$pick" -le ${#projects_ordered} ]] \
    || die "invalid selection: $pick"
  project="${projects_ordered[$pick]}"
else
  project="${projects_ordered[1]}"   # non-tty, unspecified → newest
fi

# --- resolve the session ------------------------------------------------------
typeset -a sessions
sessions=( "$PROJECTS_DIR/$project"/*.jsonl(N.om) )   # newest first
(( ${#sessions} > 0 )) || die "no sessions in project $project"

local sid=""
if [[ "$opt_session" != "latest" && -n "$opt_session" ]]; then
  [[ -f "$PROJECTS_DIR/$project/$opt_session.jsonl" ]] \
    || die "session $opt_session not found in $project"
  sid="$opt_session"
elif [[ -t 0 && -z "$opt_project" ]]; then
  print -- "\nSessions in $project (most recent first):"
  local i=1 s
  for s in $sessions; do
    local id="${${s:t}:r}" sz subc=0
    sz=$(du -h "$s" 2>/dev/null | cut -f1)
    [[ -d "$PROJECTS_DIR/$project/$id/subagents" ]] \
      && subc=$(print -- "$PROJECTS_DIR/$project/$id/subagents"/agent-*.jsonl(N) | wc -w | tr -d ' ')
    printf '  %2d) %s  %s  %s  (%s subagent log(s))\n' \
      "$i" "$id" "$(date -r "$s" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$sz" "$subc"
    (( i++ )); (( i > 10 )) && break
  done
  local pick=""
  read "pick?Session number [1 = newest]: " || true
  pick="${pick:-1}"
  [[ "$pick" == <-> && "$pick" -ge 1 && "$pick" -le ${#sessions} ]] \
    || die "invalid selection: $pick"
  sid="${${sessions[$pick]:t}:r}"
else
  sid="${${sessions[1]:t}:r}"        # newest
fi

# --- related-session discovery (#414) ----------------------------------------
# A logical run spans multiple project dirs. Correlate the chosen session's
# sibling dirs by slug + a time window so the bundle is complete without the user
# having to know which temp/worktree dirs belong to the run. This is the
# slug+window heuristic; a future refinement can parse the main transcript for
# the exact spawned paths/session-ids (authoritative). `--related <slug>` forces
# a dir in; `--main-only` skips discovery entirely.
zmodload zsh/stat 2>/dev/null

# repo basename from a project slug: the tail after a known home→repo boundary.
# Only used for headless-test matching; worktree matching needs no basename.
slug_basename() {
  local slug="$1" m
  for m in repositories repos projects src work Documents Desktop; do
    [[ "$slug" == *-$m-* ]] && { print -- "${slug##*-$m-}"; return 0; }
  done
  return 1
}

is_forced() {
  local c="$1" f
  for f in ${forced_related[@]+"${forced_related[@]}"}; do
    [[ -n "$f" && "$c" == *"$f"* ]] && return 0
  done
  return 1
}

typeset -a related   # entries: "slug<TAB>session_id<TAB>signal"
related=()
discover_related() {
  local main_slug="$1" main_sess="$2"
  local window=$(( ${opt_window_hours:-6} * 3600 ))
  local main_mt; main_mt=$(zstat +mtime -- "$PROJECTS_DIR/$main_slug/$main_sess.jsonl" 2>/dev/null) || return 0
  local repo_base; repo_base="$(slug_basename "$main_slug")" || repo_base=""
  local cand sig sess sm
  for cand in "$PROJECTS_DIR"/*(/N:t); do
    [[ "$cand" == "$main_slug" ]] && continue
    sig=""
    if is_forced "$cand"; then
      sig="manual"
    elif [[ "$cand" == ${main_slug}--claude-worktrees-* ]]; then
      sig="worktree"
    elif [[ ( "$cand" == *-plugin-test-* || "$cand" == *-pt-reval-* ) \
            && -n "$repo_base" && "$cand" == *-$repo_base ]]; then
      sig="headless"
    fi
    [[ -z "$sig" ]] && continue
    for sess in "$PROJECTS_DIR/$cand"/*.jsonl(N.om); do
      sm=$(zstat +mtime -- "$sess" 2>/dev/null) || continue
      if [[ "$sig" == "manual" ]] || (( sm >= main_mt - window && sm <= main_mt + window )); then
        related+=( "${cand}"$'\t'"${${sess:t}:r}"$'\t'"${sig}" )
      fi
    done
  done
}

# count an agent-log dir, printing 0 when absent.
sub_count() { print -- "$1"/agent-*.jsonl(N) | wc -w | tr -d ' '; }

# print each related entry under a prefix, with its match signal + subagent count.
print_related() {
  local prefix="$1" e slug ses sig n
  for e in ${related[@]+"${related[@]}"}; do
    IFS=$'\t' read -r slug ses sig <<< "$e"
    n=0; [[ -d "$PROJECTS_DIR/$slug/$ses/subagents" ]] && n=$(sub_count "$PROJECTS_DIR/$slug/$ses/subagents")
    printf '%s%s/%s  [%s]  (%s subagent log(s))\n' "$prefix" "$slug" "$ses" "$sig" "$n"
  done
}

# --- bundle -------------------------------------------------------------------
local main_rel="$sid.jsonl"
local subdir_rel="$sid/subagents"
local has_sub="false"
[[ -d "$PROJECTS_DIR/$project/$subdir_rel" ]] && has_sub="true"

[[ "$main_only" == "true" ]] || discover_related "$project" "$sid"

local out_dir="${opt_out:-$HOME/Desktop}"
[[ -d "$out_dir" ]] || out_dir="$HOME"
local out="$out_dir/claude-session-$sid.tgz"

if [[ "$dry_run" == "true" ]]; then
  print -- "would bundle from: $PROJECTS_DIR/$project"
  print -- "  main:      $main_rel"
  if [[ "$has_sub" == "true" ]]; then
    print -- "  subagents: $subdir_rel ($(sub_count "$PROJECTS_DIR/$project/$subdir_rel") agent log(s))"
  else
    print -- "  subagents: (none — no subagent dir for this session)"
  fi
  if (( ${#related} )); then
    print -- "  related sessions (${#related}):"
    print_related "    related/"
  elif [[ "$main_only" == "true" ]]; then
    print -- "  related:   (skipped — --main-only)"
  else
    print -- "  related:   (none found)"
  fi
  print -- "  output:    $out"
  exit 0
fi

if (( ${#related} == 0 )); then
  # Fast path: single project dir, tar straight from it (no staging copy).
  if [[ "$has_sub" == "true" ]]; then
    tar -czf "$out" -C "$PROJECTS_DIR/$project" "$main_rel" "$subdir_rel"
  else
    print -u2 -- "note: no subagents/ dir for this session — bundling the main transcript only."
    tar -czf "$out" -C "$PROJECTS_DIR/$project" "$main_rel"
  fi
else
  # Multi-dir: stage main at the archive root + related/<slug>/… , then tar once.
  local stage; stage="$(mktemp -d)" || die "could not create staging dir"
  cp "$PROJECTS_DIR/$project/$main_rel" "$stage/$main_rel"
  [[ "$has_sub" == "true" ]] && { mkdir -p "$stage/$sid"; cp -R "$PROJECTS_DIR/$project/$subdir_rel" "$stage/$subdir_rel"; }
  local e slug ses sig
  for e in $related; do
    IFS=$'\t' read -r slug ses sig <<< "$e"
    mkdir -p "$stage/related/$slug"
    cp "$PROJECTS_DIR/$slug/$ses.jsonl" "$stage/related/$slug/$ses.jsonl"
    [[ -d "$PROJECTS_DIR/$slug/$ses/subagents" ]] \
      && { mkdir -p "$stage/related/$slug/$ses"; cp -R "$PROJECTS_DIR/$slug/$ses/subagents" "$stage/related/$slug/$ses/subagents"; }
  done
  tar -czf "$out" -C "$stage" .
  rm -rf "$stage"
fi

local n=0
[[ "$has_sub" == "true" ]] && n=$(sub_count "$PROJECTS_DIR/$project/$subdir_rel")
print -- "✓ bundled session $sid"
print -- "  project:   $project"
print -- "  subagents: $n log(s)"
if (( ${#related} )); then
  print -- "  related:   ${#related} session(s) from sibling project dir(s):"
  print_related "    "
fi
print -- "  size:      $(du -h "$out" | cut -f1)"
print -- "  → $out"
print -- "\nHand that path to Claude to feed the run back into the plugins."
