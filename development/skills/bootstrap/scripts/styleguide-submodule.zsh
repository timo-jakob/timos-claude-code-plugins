#!/usr/bin/env zsh
# The styleguide step of /development:bootstrap (#3016): mount a shared UI
# styleguide repository as the `styleguide/` git submodule of a React repo,
# pinned to the remote's newest release tag, and bind it in CLAUDE.md.
#
# The plugin is public and names no styleguide of its own: the URL is the
# user's (`--styleguide-repo <url>` on the skill, `--url` here).
#
# Usage:
#   styleguide-submodule.zsh --repo <path> [--url <url>] [--template <CLAUDE.md.tmpl>]
#
#   --repo      the target repository's root (a git work tree)
#   --url       the styleguide repository; without it, and with no submodule
#               yet, the step is skipped
#   --template  the CLAUDE.md template holding the styleguide section
#               (default: this skill's templates/common/CLAUDE.md.tmpl)
#
# It prints exactly one status line on stdout:
#
#   exit 0  styleguide: added <url> at <tag>
#             `styleguide/` is a new submodule checked out at the commit of the
#             remote's highest vX.Y.Z tag in semver order (pre-release and other
#             tags ignored); `.gitmodules` (no `branch` line) and the gitlink are
#             STAGED, never committed — they land in bootstrap's one commit.
#   exit 0  styleguide: present
#             `.gitmodules` already declares a submodule at `styleguide`: no
#             remote is contacted, --url is ignored and the pin stays where it is.
#   exit 0  styleguide: skipped — no repository supplied; pass --styleguide-repo <url>
#   exit 1  styleguide: failed — <url>: <reason>
#             the URL is relative (`not an absolute URL`: git resolves a relative
#             submodule URL against the repo's own remote), the URL is unreachable,
#             the remote has no vX.Y.Z tag, `styleguide/` exists and is not a
#             submodule, or a git step failed. Everything the
#             script did is undone: no `.gitmodules` entry, no gitlink, no
#             `styleguide/` directory and no CLAUDE.md section is left, and a
#             `styleguide/` that was already there is never touched.
#   exit 1  styleguide: failed — CLAUDE.md: <reason>
#             `.gitmodules` already declares the submodule and the missing
#             CLAUDE.md section could not be appended. The submodule stays mounted.
#   exit 2  usage error (on stderr): a bad flag, --repo not a git work tree's
#           root, or a --template that does not exist
#
# CLAUDE.md: when `<repo>/CLAUDE.md` exists and lacks the heading
# `## Read the styleguide before UI changes` as its own line (outside a fence,
# ignoring case and trailing whitespace), the template's section is appended and
# every existing byte is kept — on `added`, and on `present` when the section is
# missing. With no CLAUDE.md the bootstrap render writes the whole file, section
# included (render.zsh --styleguide true), so nothing is appended here.

emulate -L zsh
setopt pipefail

readonly HEADING='## Read the styleguide before UI changes'
readonly SG=styleguide

usage() {
  [[ -n "${1-}" ]] && print -u2 -- "styleguide-submodule: $1"
  print -u2 -- "usage: styleguide-submodule.zsh --repo <path> [--url <url>] [--template <CLAUDE.md.tmpl>]"
  exit 2
}

repo="" url="" url_set=0 template="${0:A:h}/../templates/common/CLAUDE.md.tmpl"
while (($# > 0)); do
  case "$1" in
    --repo) (($# > 1)) || usage "--repo needs a value"; repo="$2"; shift 2 ;;
    --url) (($# > 1)) || usage "--url needs a value"; url="$2"; url_set=1; shift 2 ;;
    --template) (($# > 1)) || usage "--template needs a value"; template="$2"; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || usage "--repo is required"
((url_set)) && [[ -z "${url//[[:space:]]/}" ]] && url=""
[[ -d "$repo" ]] || usage "--repo is not a directory: $repo"
repo="${repo:A}"
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || usage "--repo is not a git work tree: $repo"
[[ "${top:A}" == "$repo" ]] || usage "--repo is not the root of its work tree: $repo"
[[ -e "$template" ]] || usage "no such template: $template"

g() { git -C "$repo" "$@"; }

# --- CLAUDE.md ----------------------------------------------------------------

# Exit 0 when the heading is a line of its own outside any ``` / ~~~ fence.
has_section() {
  awk -v h="$(print -r -- "$HEADING" | tr '[:upper:]' '[:lower:]')" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    line ~ /^(```|~~~)/ { fenced = !fenced; next }
    !fenced && tolower(line) == h { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# The section: its heading up to the next H2, the block's END marker, or EOF.
template_section() {
  awk -v h="$HEADING" '
    $0 == h { on = 1; print; next }
    on && (/^## / || /^<!-- --- STYLEGUIDE-END/) { exit }
    on { print }
  ' "$template" 2>/dev/null
}

# Append the section to an existing CLAUDE.md that lacks it, keeping every
# existing byte. Returns 0 (appended or nothing to do) or 1 (could not).
ensure_claude_md() {
  local f="$repo/CLAUDE.md" section eol=$'\n' sep="" lf=$'\n'
  [[ -f "$f" ]] || return 0
  [[ -r "$f" ]] || { reason="cannot read CLAUDE.md"; return 1; }
  has_section "$f" && return 0
  section="$(template_section)" || { reason="cannot read the CLAUDE.md template"; return 1; }
  [[ -n "$section" && "$section" != *'{{'* ]] ||
    { reason="the CLAUDE.md template carries no usable styleguide section"; return 1; }
  [[ -w "$f" ]] || { reason="cannot write CLAUDE.md"; return 1; }
  grep -q $'\r$' "$f" && eol=$'\r\n'
  if [[ -s "$f" ]]; then
    sep="$eol"
    [[ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" == '\n' ]] || sep="$eol$eol"
  fi
  [[ "$eol" == $'\r\n' ]] && section="${section//$lf/$eol}"
  printf '%s%s%s' "$sep" "$section" "$eol" >>"$f" || { reason="cannot write CLAUDE.md"; return 1; }
}

# --- present: .gitmodules already declares the submodule ----------------------

declares_styleguide() {
  [[ -f "$repo/.gitmodules" ]] || return 1
  # -z: each record is `<key>\n<value>\0`, so a name or path holding a space is
  # compared whole, never word-split
  local rec lf=$'\n'
  for rec in "${(@0)$(git config -f "$repo/.gitmodules" -z --get-regexp '^submodule\..*\.path$' 2>/dev/null)}"; do
    [[ "${rec#*$lf}" == "$SG" || "${rec#*$lf}" == "$SG/" ]] && return 0
  done
  return 1
}

fail() {
  print -r -- "styleguide: failed — ${url}: $1"
  exit 1
}

if declares_styleguide; then
  reason=""
  ensure_claude_md || { print -r -- "styleguide: failed — CLAUDE.md: $reason"; exit 1; }
  print -r -- "styleguide: present"
  exit 0
fi

if [[ -z "$url" ]]; then
  print -r -- "styleguide: skipped — no repository supplied; pass --styleguide-repo <url>"
  exit 0
fi

# --- preconditions, before any write -------------------------------------------

# A styleguide/ path that is not a declared submodule is the user's: never touch it.
if [[ -e "$repo/$SG" || -L "$repo/$SG" ]] || [[ -n "$(g ls-files -- "$SG" 2>/dev/null)" ]]; then
  fail "styleguide/ exists and is not a submodule"
fi
modules_dir="$(g rev-parse --path-format=absolute --git-path "modules/$SG" 2>/dev/null)" ||
  fail "cannot locate the repository's git directory"
[[ -e "$modules_dir" ]] && fail "a stale submodule git directory exists at $modules_dir; remove it and re-run"

# A relative URL names two repositories: ls-remote reads it as a local path,
# `submodule add` resolves it against the repo's own remote. Refuse it.
[[ "$url" != (./*|../*) && "$url" == (/*|*:*) ]] || fail "not an absolute URL"

# The tag: the highest vX.Y.Z in semver order. ls-remote reads the remote without
# cloning; an unreachable URL fails here, before anything is written.
refs="$(GIT_TERMINAL_PROMPT=0 g ls-remote --tags --refs -- "$url" 2>/dev/null)" || fail "unreachable"
tag="$(print -r -- "$refs" | awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' |
  grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' |
  sed 's/^v//' | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
[[ -n "$tag" ]] || fail "no vX.Y.Z tag"
tag="v$tag"

# --- the add, undone as a unit on any failure -----------------------------------

index="$(g rev-parse --path-format=absolute --git-path index)" || fail "cannot locate the git index"
config="$(g rev-parse --path-format=absolute --git-path config)" || fail "cannot locate the git config"
snap="$(mktemp -d "${TMPDIR:-/tmp}/styleguide-submodule.XXXXXX")" || fail "cannot create a scratch directory"
had_index=0 had_gitmodules=0 had_claude=0
# a copy that fails must stop the run here: undo would read it as "no such file"
no_snapshot() {
  rm -rf "$snap"
  fail "cannot snapshot $1"
}
if [[ -f "$index" ]]; then
  cp -p "$index" "$snap/index" 2>/dev/null || no_snapshot "the git index"
  had_index=1
fi
cp -p "$config" "$snap/config" 2>/dev/null || no_snapshot "the git config"
if [[ -f "$repo/.gitmodules" ]]; then
  cp -p "$repo/.gitmodules" "$snap/gitmodules" 2>/dev/null || no_snapshot ".gitmodules"
  had_gitmodules=1
fi
if [[ -f "$repo/CLAUDE.md" ]]; then
  cp -p "$repo/CLAUDE.md" "$snap/CLAUDE.md" 2>/dev/null || no_snapshot "CLAUDE.md"
  had_claude=1
fi

undo() {
  rm -rf "$repo/$SG" "$modules_dir"
  if ((had_index)); then cp -p "$snap/index" "$index"; else rm -f "$index"; fi
  cp -p "$snap/config" "$config"
  if ((had_gitmodules)); then cp -p "$snap/gitmodules" "$repo/.gitmodules"; else rm -f "$repo/.gitmodules"; fi
  # restore only a CLAUDE.md the run changed: an unwritable one was never touched
  if ((had_claude)) && ! cmp -s "$snap/CLAUDE.md" "$repo/CLAUDE.md"; then
    cp -p "$snap/CLAUDE.md" "$repo/CLAUDE.md" 2>/dev/null
  fi
  rm -rf "$snap"
}

abort() {
  undo
  fail "$1"
}

trap 'undo; exit 130' INT TERM

GIT_TERMINAL_PROMPT=0 g submodule --quiet add --name "$SG" -- "$url" "$SG" >/dev/null 2>&1 ||
  abort "git submodule add failed"
GIT_TERMINAL_PROMPT=0 g -C "$SG" fetch --quiet origin "refs/tags/${tag}:refs/tags/$tag" >/dev/null 2>&1 ||
  abort "cannot fetch $tag"
g -C "$SG" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/${tag}^{commit}" >/dev/null 2>&1 ||
  abort "cannot check out $tag"
[[ "$(g -C "$SG" rev-parse HEAD 2>/dev/null)" == "$(g -C "$SG" rev-parse "refs/tags/${tag}^{commit}" 2>/dev/null)" ]] ||
  abort "the checkout is not at $tag"
# no `branch` line: the pin is a commit, and Dependabot proposes each move of it
git config -f "$repo/.gitmodules" --unset "submodule.$SG.branch" >/dev/null 2>&1
g add -- .gitmodules "$SG" >/dev/null 2>&1 || abort "cannot stage the submodule"
reason=""
ensure_claude_md || abort "$reason"

trap - INT TERM
rm -rf "$snap"
print -r -- "styleguide: added $url at $tag"
