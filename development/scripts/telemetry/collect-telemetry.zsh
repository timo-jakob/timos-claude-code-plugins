#!/usr/bin/env zsh
# collect-telemetry.zsh — salvage telemetry/v1 records from in-repo sinks into
# the user-level default directory (#1972).
#
# Why this exists: before #1972 every record landed in the checkout it was
# emitted from (`<checkout>/.claude/telemetry/`), so a run in a worktree left its
# record inside that worktree — and removing the worktree deleted it. The
# default sink is now `$HOME/.claude/telemetry/<repo-slug>.jsonl`, outside every
# checkout; this script copies what the old sinks still hold into it, once,
# before any more worktrees are removed.
#
# Usage:
#   collect-telemetry.zsh ROOT [ROOT…]
#
#   ROOT  a checkout root. Its `.claude/telemetry/*.jsonl` is swept, and so is
#         the same path in every linked worktree `git worktree list --porcelain`
#         names for it. A second CLONE of the same repo is never discovered —
#         pass it as another ROOT. A ROOT that is not a git checkout has only
#         its own `.claude/telemetry/` swept.
#
# What is copied: every line that is a telemetry/v1 record (a JSON object whose
# `schema` is "telemetry/v1"), VERBATIM, appended to
# `$HOME/.claude/telemetry/<slug of the record's own repo>.jsonl` (the slug
# emit-telemetry.zsh uses — tlm_repo_slug, telemetry-sink-lib.zsh) under the
# same exclusive lock emit holds. It is a COPY: no source is ever modified,
# moved or truncated.
#
# What is not:
#   * skipped — a blank line is ignored silently; a line that is not a JSON
#     object, a pre-contract v0 record (no `schema` key), a record of any other
#     schema, or a v1 record with no usable `repo` string is counted as skipped;
#   * duplicate — a record whose (run_id, kind, ts, payload.event) is already in
#     its destination file, or was already copied by this run, is counted as a
#     duplicate and not appended again. A second run over the same ROOTs
#     therefore appends nothing.
#
# Output: one line on stdout, `copied N, duplicate N, skipped N`.
#
# Exit codes (the taxonomy emit-telemetry.zsh uses):
#   0  ok — including nothing to copy
#   2  usage: no ROOT, an unknown flag, or a ROOT that is missing or not a
#      directory. Every ROOT is checked before anything is read or written.
#   3  internal: jq or the zsh/system module missing, HOME unset, a source that
#      cannot be read, a destination that cannot be created or appended to, or
#      a destination lock not acquired within 10 s

emulate -L zsh
setopt nounset pipefail

local usage="usage: collect-telemetry.zsh ROOT [ROOT…]

Copies every telemetry/v1 record from ROOT/.claude/telemetry/*.jsonl, and the
same path in each of ROOT's linked worktrees, into
\$HOME/.claude/telemetry/<repo-slug>.jsonl. Sources are never modified."

typeset -a roots=()
while (( $# )); do
  case "$1" in
    -h|--help) print -r -- "$usage"; exit 0 ;;
    --) shift; roots+=("$@"); break ;;
    -*) print -ru2 -- "collect-telemetry: unknown flag: $1
$usage"; exit 2 ;;
    *) roots+=("$1"); shift ;;
  esac
done

(( ${#roots} )) || { print -ru2 -- "collect-telemetry: at least one ROOT is required
$usage"; exit 2 }

local r=""
for r in "${roots[@]}"; do
  [[ -e "$r" ]] || { print -ru2 -- "collect-telemetry: no such directory: $r"; exit 2 }
  [[ -d "$r" ]] || { print -ru2 -- "collect-telemetry: not a directory: $r"; exit 2 }
done

command -v jq >/dev/null 2>&1 || {
  print -ru2 -- "collect-telemetry: jq not found on PATH"; exit 3 }

source "${0:A:h}/telemetry-sink-lib.zsh" || {
  print -ru2 -- "collect-telemetry: cannot load telemetry-sink-lib.zsh"; exit 3 }

local user_dir=""
user_dir=$(tlm_user_dir) || {
  print -ru2 -- "collect-telemetry: HOME is not set, so there is no user-level directory to collect into"
  exit 3 }

# --- the source files: each root's sink dir and each linked worktree's -------

typeset -a checkouts=() sources=()
typeset -A seen_src=()
local wt_line="" c="" f=""
for r in "${roots[@]}"; do
  checkouts+=("${r:A}")
  # `worktree <path>` lines name the main checkout and every linked worktree.
  # A root that is not a git checkout lists none — only the root is swept.
  while IFS= read -r wt_line; do
    [[ "$wt_line" == "worktree "* ]] && checkouts+=("${${wt_line#worktree }:A}")
  done < <(git -C "$r" worktree list --porcelain 2>/dev/null)
done
for c in "${checkouts[@]}"; do
  for f in "$c"/.claude/telemetry/*.jsonl(N-.); do
    f="${f:A}"
    (( ${+seen_src[$f]} )) && continue
    seen_src[$f]=1
    sources+=("$f")
  done
done

# --- classify every line, in one jq pass per source ---------------------------
# Each non-blank line becomes one tab-separated row: `S` (skipped) or
# `R<TAB><slug-input repo><TAB><dedupe key><TAB><the line, as a JSON string>`.
# The line rides as a JSON STRING so a tab inside it can never split the row;
# `fromjson` restores it byte-for-byte below. The dedupe key is the compact JSON
# of [run_id, kind, ts, payload.event].

local classify_prog='
  def key: [.run_id, .kind, .ts, (if (.payload | type) == "object" then .payload.event else null end)] | tojson;
  inputs
  | select(test("^\\s*$") | not)
  | . as $line
  | ([$line | fromjson?]) as $p
  | if ($p | length) == 1 and ($p[0] | type) == "object"
       and $p[0].schema? == "telemetry/v1"
       and ($p[0].repo | type) == "string" and ($p[0].repo | length) > 0
    then "R\t\($p[0].repo | gsub("[\t\n\r]"; " "))\t\($p[0] | key)\t\($line | tojson)"
    else "S" end'

local stage=""
stage=$(mktemp -d) || { print -ru2 -- "collect-telemetry: failed to create a scratch directory"; exit 3 }
trap 'rm -rf -- "$stage"' EXIT

local -i skipped=0 copied=0 duplicate=0
local tag="" repo="" key="" line_json="" slug=""
typeset -A slug_of=()
for f in "${sources[@]}"; do
  jq -R -r -n "$classify_prog" < "$f" > "$stage/rows" || {
    print -ru2 -- "collect-telemetry: cannot read $f"; exit 3 }
  while IFS=$'\t' read -r tag repo key line_json; do
    if [[ "$tag" != "R" ]]; then
      (( skipped++ )); continue
    fi
    slug=$(tlm_repo_slug "$repo")
    # Two staging files per destination, line N of each describing the same
    # record — its key, and the line itself — so each destination is appended
    # under ONE lock below.
    print -r -- "$key" >> "$stage/$slug.keys"
    print -r -- "$line_json" >> "$stage/$slug.lines"
    slug_of[$slug]=1
  done < "$stage/rows"
done

# --- append each destination's new records, under its lock -------------------

local err="" dest="" k="" lj=""
typeset -A have=()
err=$(mkdir -p -- "$user_dir" 2>&1) || {
  print -ru2 -- "collect-telemetry: cannot create $user_dir (${err:-unknown error})"; exit 3 }

for slug in "${(ok)slug_of[@]}"; do
  dest="$user_dir/$slug.jsonl"
  # The keys already in the destination, read before its lock is taken. A
  # record emit appends meanwhile is a NEW run, never one of the old records
  # being salvaged, so it cannot be duplicated by this copy; the salvage is a
  # one-off a single maintainer runs, never two at once.
  have=()
  if [[ -e "$dest" ]]; then
    while IFS= read -r k; do
      have[$k]=1
    done < <(jq -R -r 'fromjson? | objects
      | [.run_id, .kind, .ts, (if (.payload | type) == "object" then .payload.event else null end)]
      | tojson' < "$dest")
  fi
  : > "$stage/out.json"
  while IFS= read -r k && IFS= read -r lj <&3; do
    if (( ${+have[$k]} )); then
      (( duplicate++ )); continue
    fi
    have[$k]=1
    print -r -- "$lj" >> "$stage/out.json"
    (( copied++ ))
  done < "$stage/$slug.keys" 3< "$stage/$slug.lines"
  [[ -s "$stage/out.json" ]] || continue
  # Each staged entry is the source line as a JSON string; `jq -r` restores it
  # byte-for-byte, one line each.
  jq -r '.' < "$stage/out.json" > "$stage/out" || {
    print -ru2 -- "collect-telemetry: failed to stage the records for $dest"; exit 3 }
  err=$(tlm_locked_append "$dest" < "$stage/out") || {
    print -ru2 -- "collect-telemetry: cannot append to $dest (${err:-unknown error})"; exit 3 }
done

print -r -- "copied $copied, duplicate $duplicate, skipped $skipped"
exit 0
