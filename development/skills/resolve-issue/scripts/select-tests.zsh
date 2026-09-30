#!/usr/bin/env zsh
# select-tests.zsh — which bats files can a change affect? (#1973)
#
# Why: run-gate.zsh runs the whole bats suite, and the review loop ran it before
# EVERY round. #1973 amends the #979 and #604 guardrails for intermediate
# (delta) review rounds only: the gate before a delta round may run just the
# files the story diff can affect. Round 1, the closing sweep, hook mode and CI
# stay on the full suite — this script only answers the question, and
# run-gate.zsh --select-base is its one caller.
#
# The map is DERIVED, never hand-maintained, so it cannot rot silently:
#   * static extraction — every repo path a bats file spells out (from the
#     first segment of a token that names one of the repo's top-level
#     entries: `development/…`,
#     `$REPO_ROOT/development-go/…`, `$BATS_TEST_DIRNAME/fixtures/…`,
#     `ARCHITECTURE.md`), so the `$REPO_ROOT/`-prefixed references resolve
#     with no special case. A bare top-level DIRECTORY word is never a
#     reference; spelled after a path prefix (`$REPO_ROOT/tests`, `../docs`)
#     it is a select-only one (see the extraction below);
#   * an optional `# covers: <path> …` header line, for what extraction cannot
#     see (a path the file builds at runtime, or a whole tree). `# covers: *`
#     puts the file in the always-run set.
# An EXTRACTED reference P maps a changed path C only when C == P: a directory
# a test happens to spell (`$REPO_ROOT/development/skills`, a scratch
# `$CACHE/development-go/agents`) must not make everything below it look mapped,
# or the unmapped fallback is switched off for that tree. Such a directory
# reference still SELECTS its test for a change below it — a suite that builds
# `$SCRIPTS/x.zsh` from `SCRIPTS=…/scripts` names only the directory — it just
# never counts as mapping the change. Only a `# covers:` path — a deliberate
# declaration — maps what lies under it.
#
# The always-run set joins every selection: position guards (`*-position*.bats`),
# repo-wide sweeps (a file that runs `git ls-files`), manifest and version
# checks (a file that reads `marketplace.json`), and `# covers: *`.
#
# Conservative by construction — the selection is the FULL suite when:
#   * any changed path is unmapped (no bats file spells it, and no `# covers:`
#     header names it or a parent) — a new file no test names included;
#   * a change touches the shared test machinery or the family's shared code:
#     `<tests-dir>/helpers/`, `<tests-dir>/*.bash`, `development/scripts/`,
#     `ARCHITECTURE.md` or `.claude-plugin/marketplace.json`;
#   * the diff is empty, or cannot be computed (a bad --base, no git, a --repo
#     that is not the top level of its work tree).
# A changed bats file is always selected itself.
#
# Pure: the changed paths in, a file list out. No clock, no network; the only
# git call is --base's merge-base diff, and --changed skips even that.
#
# Usage:
#   select-tests.zsh [--repo DIR] [--tests-dir DIR] --base REF
#   select-tests.zsh [--repo DIR] [--tests-dir DIR] --changed FILE
#   select-tests.zsh [--repo DIR] [--tests-dir DIR] --check-map
#     --repo DIR      the repository root (default: .)
#     --tests-dir DIR directory of .bats files, relative to --repo (default: tests)
#     --base REF      diff the working tree (tracked + untracked, .gitignore
#                     honoured) against merge-base(REF, HEAD)
#     --changed FILE  the changed repo-relative paths, one per line (a test seam,
#                     and the pure core --base feeds)
#     --check-map     the map-completeness guard: every bats file must be mapped
#                     (at least one reference) or always-run
#
# Output (stdout, one JSON object):
#   selection: {"selection":"full"|"selected","reason":<string|null>,
#               "changed":[…],"files":[…]}   files = <tests-dir>/<name>.bats,
#               sorted; on "full" it is every bats file, and reason says why.
#   --check-map: {"unmapped":[…]}
#
# Exit codes: 0 a selection was made (full or selected) / the map is complete ·
#             1 --check-map found an unmapped file, or an internal failure (jq) ·
#             2 usage.

emulate -L zsh
setopt nounset pipefail extended_glob
export LC_ALL=C

die_usage() { print -u2 -- "select-tests: $1"; exit 2 }

local repo="." tests_rel="tests" base="" changed_file="" check_map=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo)      { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
  --tests-dir) { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--tests-dir needs a value"; tests_rel="$2"; shift 2 ;;
  --base)      { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--base needs a value"; base="$2"; shift 2 ;;
  --changed)   { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--changed needs a value"; changed_file="$2"; shift 2 ;;
  --check-map) check_map=1; shift ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done
(( check_map + ${#base} + ${#changed_file} > 0 )) || die_usage "one of --base, --changed or --check-map is required"
[[ -n "$base" && -n "$changed_file" ]] && die_usage "--base and --changed are mutually exclusive"
(( check_map )) && [[ -n "$base$changed_file" ]] && die_usage "--check-map takes no --base/--changed"
[[ -d "$repo" ]] || die_usage "repo dir not found: $repo"
repo="${repo:A}"
tests_rel="${tests_rel%/}"
[[ "$tests_rel" != /* ]] || die_usage "--tests-dir must be relative to --repo: $tests_rel"
[[ -d "$repo/$tests_rel" ]] || die_usage "tests dir not found: $repo/$tests_rel"
[[ -z "$changed_file" || -r "$changed_file" ]] || die_usage "--changed file not readable: $changed_file"
command -v jq >/dev/null 2>&1 || { print -u2 -- "select-tests: jq not found on PATH"; exit 1 }

local -a bats_files=( "$repo/$tests_rel"/*.bats(N:t) )
(( ${#bats_files} )) || die_usage "no .bats files in $repo/$tests_rel"
bats_files=( "${tests_rel}/${^bats_files[@]}" )

# --- the map: reference -> bats files, plus the always-run set ----------------
# Top-level entries of the repo, dotfiles included, .git excluded. A reference
# starts at the first segment of a path-shaped token that names one of them.
local -a tops=( "$repo"/*(DN:t) ) topdirs=( "$repo"/*(DN/:t) )
tops=( ${tops:#.git} ) topdirs=( ${topdirs:#.git} )

typeset -A refs_of=()     # bats file -> count of references
typeset -A tests_of=()    # extracted reference -> space-joined bats files (EXACT path)
typeset -A covers_of=()   # `# covers:` path -> space-joined bats files (path AND subtree)
typeset -A dirsel_of=()   # anchored top-level dir -> space-joined bats files (select-only)
typeset -A always=()
local f ref line
# One pass per question over every file at once, run from the repo root so
# FILENAME is the <tests-dir>/ path. A reference is the rest of a path-shaped
# token from its first segment that names a top-level entry, so
# `$REPO_ROOT/development-go/x` and `../development-go/x` both yield
# `development-go/x`; `$BATS_TEST_DIRNAME/` (braced or not) is read as
# `<tests-dir>/` first, so `$BATS_TEST_DIRNAME/fixtures/x` maps
# `<tests-dir>/fixtures/x`, and `..` segments are resolved before the match.
# A BARE top-level DIRECTORY (`development`, `tests`, `docs` — a word in prose,
# a `--tests-dir tests`, the plugin half of `development:resolve-issue`) is NOT
# a reference: it would cover its whole tree and make every change under it
# look mapped, which is the unmapped fallback switched off. A bare top-level
# FILE (`ARCHITECTURE.md`) is one. A whole-tree dependency is declared with a
# `# covers:` header instead. Trailing dots and slashes (sentence punctuation)
# are dropped, and `sort -u` drops a file's repeated references.
local -a pairs=()
pairs=( ${(f)"$(cd "$repo" && awk -v tops="${(j: :)tops}" -v topdirs="${(j: :)topdirs}" -v td="$tests_rel" '
  BEGIN {
    n = split(tops, a, " "); for (i = 1; i <= n; i++) top[a[i]] = 1
    n = split(topdirs, a, " "); for (i = 1; i <= n; i++) topdir[a[i]] = 1
  }
  {
    s = $0
    gsub(/\$\{BATS_TEST_DIRNAME\}\//, td "/", s)
    gsub(/\$BATS_TEST_DIRNAME\//, td "/", s)
    while (match(s, /[A-Za-z0-9_.@+\/-]+/)) {
      tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      k = split(tok, raw, "/"); d = 0; nonempty = 0
      for (j = 1; j <= k; j++) {
        if (raw[j] == "" || raw[j] == ".") continue
        nonempty++
        if (raw[j] == "..") { if (d > 0) d--; continue }
        seg[++d] = raw[j]
      }
      for (j = 1; j <= d; j++) if (seg[j] in top) {
        out = seg[j]; for (m = j + 1; m <= d; m++) out = out "/" seg[m]
        sub(/[.\/]+$/, "", out)
        if (!(out in topdir)) print FILENAME ":" out
        # a top-level directory spelled AFTER a path prefix (`$REPO_ROOT/tests`,
        # `../docs`) anchors a suite that builds its paths from it: select-only
        else if (nonempty > 1) print FILENAME ":@" out
        break
      }
    }
  }' "${bats_files[@]}" | sort -u)"} )
# the `# covers:` header lines
for line in ${(f)"$(cd "$repo" && grep -HE '^# covers:' "${bats_files[@]}" 2>/dev/null)"}; do
  f="${line%%:*}"
  for ref in ${=${line#*:\# covers:}}; do
    ref="${ref%/}"
    if [[ "$ref" == '*' ]]; then
      always[$f]=1
    elif [[ -n "$ref" ]]; then
      refs_of[$f]=$(( ${refs_of[$f]:-0} + 1 ))
      covers_of[$ref]="${covers_of[$ref]:-} $f"
    fi
  done
done
for line in "${pairs[@]}"; do
  f="${line%%:*}" ref="${line#*:}"
  [[ -n "$ref" ]] || continue
  if [[ "$ref" == @* ]]; then
    # select-only: never a mapping, so it never counts toward the map guard
    dirsel_of[${ref#@}]="${dirsel_of[${ref#@}]:-} $f"
    continue
  fi
  refs_of[$f]=$(( ${refs_of[$f]:-0} + 1 ))
  tests_of[$ref]="${tests_of[$ref]:-} $f"
done
for f in "${bats_files[@]}"; do
  [[ "${f:t}" == *-position*.bats ]] && always[$f]=1
done
for f in ${(f)"$(cd "$repo" && grep -lE 'ls-files|marketplace\.json' "${bats_files[@]}" 2>/dev/null)"}; do
  always[$f]=1
done

if (( check_map )); then
  local -a unmapped=()
  for f in "${bats_files[@]}"; do
    [[ -n "${always[$f]:-}" || -n "${refs_of[$f]:-}" ]] || unmapped+=( "$f" )
  done
  jq -cn --args '{unmapped:$ARGS.positional}' -- "${unmapped[@]}" || exit 1
  (( ${#unmapped} == 0 ))
  exit $?
fi

emit() {  # $1 selection, $2 reason ("" = null), then the file list
  local sel="$1" why="$2"; shift 2
  jq -cn --arg sel "$sel" --arg why "$why" --argjson changed "$changed_json" \
     '{selection:$sel, reason:(if $why == "" then null else $why end),
       changed:$changed, files:$ARGS.positional}' --args -- "$@" || exit 1
  exit 0
}

# --- the changed paths --------------------------------------------------------
local -a changed=()
local changed_json='[]' diff_why=""
if [[ -n "$changed_file" ]]; then
  changed=( ${(f)"$(<"$changed_file")"} )
else
  # Every path must be repo-root-relative, the spelling the map uses, so --repo
  # must BE the top level: from a subdirectory `git diff` and `ls-files` would
  # print two different bases. Each git call is status-checked on its own, so a
  # failed diff is never masked by a successful ls-files. --no-renames lists a
  # rename as the old path AND the new one, so a test that names the old path
  # is still selected.
  local mb="" top="" d="" u=""
  if ! top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || [[ "${top:A}" != "$repo" ]]; then
    diff_why="--repo is not the top level of a git work tree"
  elif ! mb="$(git -C "$repo" merge-base "$base" HEAD 2>/dev/null)" || [[ -z "$mb" ]]; then
    diff_why="the merge-base diff against '$base' could not be computed"
  elif ! d="$(git -C "$repo" diff --no-renames --name-only "$mb" -- 2>/dev/null)" \
       || ! u="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)"; then
    diff_why="the merge-base diff against '$base' could not be computed"
  else
    changed=( ${(f)d} ${(f)u} )
  fi
fi
changed=( ${(ou)changed:#} )
changed_json="$(jq -cn --args '$ARGS.positional' -- "${changed[@]}")" || exit 1

[[ -z "$diff_why" ]] || emit full "$diff_why" "${bats_files[@]}"
(( ${#changed} )) || emit full "the diff is empty" "${bats_files[@]}"

# --- select --------------------------------------------------------------------
typeset -A picked=()
local c p hit
for c in "${changed[@]}"; do
  case "$c" in
  "$tests_rel"/helpers/*|"$tests_rel"/[^/]##.bash|development/scripts/*|ARCHITECTURE.md|.claude-plugin/marketplace.json)
    emit full "a shared path changed: $c" "${bats_files[@]}" ;;
  esac
  hit=0
  if [[ "$c" == "$tests_rel"/[^/]##.bats ]]; then
    hit=1
    [[ -f "$repo/$c" ]] && picked[$c]=1
  fi
  # an extracted reference: the exact path MAPS the change; one that is a parent
  # directory of it only SELECTS its tests (a suite that builds its paths from a
  # `$SCRIPTS/` variable), without mapping — so a path reached through a
  # directory alone still takes the unmapped fallback below
  if [[ -n "${tests_of[$c]:-}" ]]; then
    hit=1
    for f in ${=tests_of[$c]}; do picked[$f]=1; done
  fi
  p="$c"
  while [[ "$p" == */* ]]; do
    p="${p%/*}"
    for f in ${=tests_of[$p]:-} ${=dirsel_of[$p]:-}; do picked[$f]=1; done
  done
  # a `# covers:` path: the path itself, then each parent directory
  p="$c"
  while [[ -n "$p" ]]; do
    if [[ -n "${covers_of[$p]:-}" ]]; then
      hit=1
      for f in ${=covers_of[$p]}; do picked[$f]=1; done
    fi
    [[ "$p" == */* ]] && p="${p%/*}" || p=""
  done
  (( hit )) || emit full "an unmapped path changed: $c" "${bats_files[@]}"
done
for f in "${(k)always[@]}"; do picked[$f]=1; done

emit selected "" "${(ok)picked[@]}"
