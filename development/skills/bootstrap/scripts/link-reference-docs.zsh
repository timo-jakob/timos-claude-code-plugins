#!/usr/bin/env zsh
# Link a docs repository as a reference-documents submodule (#3355, epic #3198).
#
# `/development:bootstrap --docs-repo <url>` mounts a docs repository the repo
# owner controls as a git submodule pinned to its newest version tag, marks it
# `reference-docs = true` in `.gitmodules` (ARCHITECTURE.md, *Linked reference
# documents*), and appends the `## Linked reference documents` section that binds
# such links to CLAUDE.md. Re-running changes nothing.
#
# Usage:
#   link-reference-docs.zsh check         --repo-dir <dir> --url <url> [--path <mount>]
#   link-reference-docs.zsh apply         --repo-dir <dir> --url <url> [--path <mount>]
#   link-reference-docs.zsh check-section --claude-md <file>
#   link-reference-docs.zsh apply-section --claude-md <file> --template <tmpl>
#
# --path defaults to `linked-docs`. The submodule's name is the mount path. The
# URL is compared byte for byte with `submodule.<name>.url` in `.gitmodules`.
#
# check / apply print one word on stdout, `linked` or `gap`; a stop prints
# nothing on stdout and one reason line on stderr, and changes nothing.
#   exit 0 — linked: the mount is a submodule of that URL marked
#            `reference-docs` (apply: after linking it, or already linked)
#   exit 1 — gap (check only): no such submodule at the mount yet, or one of
#            that URL without the key
#   exit 2 — usage error; a URL that is not absolute (`./x`, `../x`, or neither
#            a path from `/` nor a `scheme:` or `host:` form) is one, since git
#            resolves a relative submodule URL against the repo's own remote
#   exit 3 — the URL cannot be reached, credentials the session lacks included
#            (apply only)
#   exit 4 — the repository has no version tag (apply only)
#   exit 5 — the mount exists and is not a submodule of that URL
#   exit 6 — --repo-dir is not the root of a git work tree
#   exit 7 — a git step failed after these checks; everything the run did is
#            undone (apply only)
# check never contacts a remote. apply contacts one only when it has to add the
# submodule: a submodule of that URL that only lacks the key gets the key and
# keeps its pin. apply adds the submodule at the newest version tag, writes no
# `branch` line, stages `.gitmodules` and the gitlink, and commits nothing. It
# never prompts for credentials.
#
# The newest version tag: the highest, by numeric comparison of the three parts,
# of the remote's tags of the exact form `vX.Y.Z` or `X.Y.Z` (no leading zeros);
# pre-release and every other tag are ignored. Where `vX.Y.Z` and `X.Y.Z` name
# one version, the `v` form is used.
#
# check-section / apply-section use the words and exit codes of
# claude-md-decision-rights.zsh unchanged, for the heading
# `## Linked reference documents`:
#   check-section  exit 0 present, 1 gap, 3 no such file, 5 the file unreadable
#   apply-section  exit 0 applied (or present, untouched), 3 no such file,
#                  4 the template carries no such section or an unrendered
#                  {{PLACEHOLDER}}, 5 a read or write failed (nothing appended)
#   both           exit 2 usage error, a --template that does not exist included
# apply-section is append-only: an empty file gets no separator, a file whose
# last line lacks its newline gets that newline, then one blank line precedes
# the section; a CRLF file gets the section in CRLF.

emulate -L zsh
setopt pipefail

readonly HEADING='## Linked reference documents'
readonly ME=link-reference-docs

usage() {
  [[ -n "${1-}" ]] && print -u2 -r -- "$ME: $1"
  print -u2 "usage: link-reference-docs.zsh check|apply --repo-dir <dir> --url <url> [--path <mount>]"
  print -u2 "       link-reference-docs.zsh check-section --claude-md <file>"
  print -u2 "       link-reference-docs.zsh apply-section --claude-md <file> --template <tmpl>"
  exit 2
}

# One reason line on stderr, then the stop's exit code.
stop() {
  print -u2 -r -- "$ME: $2"
  exit "$1"
}

(($# > 0)) || usage
mode="$1"; shift
case "$mode" in
  check|apply|check-section|apply-section) ;;
  *) usage "unknown command: $mode" ;;
esac

repo_dir="" url="" mount="" claude_md="" template=""
seen_link=0 seen_section=0
while (($# > 0)); do
  case "$1" in
    --repo-dir)  (($# > 1)) || usage "--repo-dir needs a value"; repo_dir="$2"; seen_link=1; shift 2 ;;
    --url)       (($# > 1)) || usage "--url needs a value"; url="$2"; seen_link=1; shift 2 ;;
    --path)      (($# > 1)) || usage "--path needs a value"; mount="$2"; seen_link=1; shift 2 ;;
    --claude-md) (($# > 1)) || usage "--claude-md needs a value"; claude_md="$2"; seen_section=1; shift 2 ;;
    --template)  (($# > 1)) || usage "--template needs a value"; template="$2"; seen_section=1; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

# --- the CLAUDE.md section ------------------------------------------------------

# Exit 0 when the heading is a line of its own outside any ``` / ~~~ fence.
has_section() {
  awk -v h="$(print -r -- "$HEADING" | tr '[:upper:]' '[:lower:]')" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    line ~ /^(```|~~~)/ { fenced = !fenced; next }
    !fenced && tolower(line) == h { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

if [[ "$mode" == check-section || "$mode" == apply-section ]]; then
  ((seen_link == 0)) || usage "$mode takes no --repo-dir, --url or --path"
  [[ -n "$claude_md" ]] || usage "--claude-md is required"
  if [[ "$mode" == apply-section ]]; then
    [[ -n "$template" ]] || usage "--template is required"
  else
    [[ -z "$template" ]] || usage "check-section takes no --template"
  fi
  [[ -f "$claude_md" ]] || stop 3 "no such file: $claude_md"
  [[ -r "$claude_md" ]] || stop 5 "cannot read: $claude_md"
  if has_section "$claude_md"; then
    print "present"
    exit 0
  fi
  if [[ "$mode" == check-section ]]; then
    print "gap"
    exit 1
  fi
  [[ -e "$template" ]] || usage "no such template: $template"
  [[ -r "$template" ]] || stop 5 "cannot read template: $template"
  [[ -w "$claude_md" ]] || stop 5 "cannot write: $claude_md"
  # The section runs from its heading to the next H2 or the end of the template.
  section="$(awk -v h="$HEADING" '
    $0 == h { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' "$template")" || stop 5 "cannot read template: $template"
  [[ -n "$section" ]] || stop 4 "template carries no '$HEADING' section: $template"
  [[ "$section" != *'{{'* ]] || stop 4 "the template's section holds an unrendered placeholder: $template"
  # Keep every existing byte: only ever append.
  eol=$'\n'
  grep -q $'\r$' "$claude_md" && eol=$'\r\n'
  sep=""
  if [[ -s "$claude_md" ]]; then
    sep="$eol"
    [[ "$(tail -c 1 "$claude_md" | od -An -c | tr -d ' ')" == '\n' ]] || sep="$eol$eol"
  fi
  if [[ "$eol" == $'\r\n' ]]; then
    lf=$'\n'
    section="${section//$lf/$eol}"
  fi
  printf '%s%s%s' "$sep" "$section" "$eol" >>"$claude_md" || stop 5 "cannot write: $claude_md"
  print "applied"
  exit 0
fi

# --- check / apply: arguments -----------------------------------------------------

((seen_section == 0)) || usage "$mode takes no --claude-md or --template"
[[ -n "$repo_dir" ]] || usage "--repo-dir is required"
[[ -n "$url" ]] || usage "--url is required"
[[ "$url" != (./*|../*) && "$url" == (/*|*:*) ]] || usage "not an absolute URL: $url"
[[ -n "$mount" ]] || mount=linked-docs
# a trailing slash names the same mount
while [[ "$mount" == */ && "$mount" != / ]]; do mount="${mount%/}"; done
[[ -n "$mount" && "$mount" != /* && "$mount" != -* ]] || usage "--path must be a path inside the repository: $mount"
for part in "${(@s:/:)mount}"; do
  [[ -n "$part" && "$part" != . && "$part" != .. && "$part" != .git ]] ||
    usage "--path must be a path inside the repository: $mount"
done

[[ -d "$repo_dir" ]] || stop 6 "not the root of a git work tree: $repo_dir"
repo="${repo_dir:A}"
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || stop 6 "not the root of a git work tree: $repo_dir"
[[ "${top:A}" == "$repo" ]] || stop 6 "not the root of a git work tree: $repo_dir"

g() { git -C "$repo" "$@"; }
gm() { git config -f "$repo/.gitmodules" "$@"; }

# --- the mount's state -------------------------------------------------------------

# The name of the `.gitmodules` entry whose path is the mount, or nothing.
# -z: each record is `<key>\n<value>\0`, so a name or path holding a space is
# compared whole, never word-split.
entry_name() {
  [[ -f "$repo/.gitmodules" ]] || return 1
  local rec key value lf=$'\n'
  for rec in "${(@0)$(gm -z --get-regexp '^submodule\..*\.path$' 2>/dev/null)}"; do
    [[ -n "$rec" ]] || continue
    key="${rec%%$lf*}" value="${rec#*$lf}"
    while [[ "$value" == */ ]]; do value="${value%/}"; done
    if [[ "$value" == "$mount" ]]; then
      key="${key#submodule.}"
      print -r -- "${key%.path}"
      return 0
    fi
  done
  return 1
}

name="$(entry_name)"
if [[ -n "$name" ]]; then
  [[ "$(gm --get "submodule.$name.url" 2>/dev/null)" == "$url" ]] ||
    stop 5 "$mount exists and is not a submodule of $url"
  if [[ "$(gm --type=bool --get "submodule.$name.reference-docs" 2>/dev/null)" == true ]]; then
    print "linked"
    exit 0
  fi
  state=unmarked
else
  if [[ -e "$repo/$mount" || -L "$repo/$mount" ]] || [[ -n "$(g ls-files -- "$mount" 2>/dev/null)" ]]; then
    stop 5 "$mount exists and is not a submodule of $url"
  fi
  state=absent
fi

if [[ "$mode" == check ]]; then
  print "gap"
  exit 1
fi

# --- apply: preconditions that need the remote, before any write -------------------

if [[ "$state" == absent ]]; then
  modules_dir="$(g rev-parse --path-format=absolute --git-path "modules/$mount" 2>/dev/null)" ||
    stop 7 "cannot locate the repository's git directory"
  [[ ! -e "$modules_dir" ]] ||
    stop 7 "a stale submodule git directory exists at $modules_dir; remove it and re-run"

  # Never prompt: no terminal prompt, no askpass helper, ssh in batch mode, no stdin.
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false SSH_ASKPASS=false
  # The caller's own ssh choice is kept: GIT_SSH_COMMAND and GIT_SSH are left
  # alone, and core.sshCommand (which GIT_SSH_COMMAND would override) is carried.
  if [[ -z "${GIT_SSH_COMMAND-}" && -z "${GIT_SSH-}" ]]; then
    ssh_cmd="$(g config --get core.sshCommand 2>/dev/null)"
    export GIT_SSH_COMMAND="${ssh_cmd:-ssh} -o BatchMode=yes"
  fi

  refs="$(g ls-remote --tags --refs -- "$url" </dev/null 2>/dev/null)" ||
    stop 3 "$url cannot be reached"
  # tags of the exact form vX.Y.Z or X.Y.Z; sort by the three numbers, then the
  # `v` form after the bare one, so the last line is the newest, `v` preferred
  tag="$(print -r -- "$refs" | awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' |
    grep -E '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' |
    awk '{ t = $0; v = (substr(t, 1, 1) == "v"); if (v) t = substr(t, 2); split(t, p, ".");
           print p[1] "\t" p[2] "\t" p[3] "\t" v "\t" $0 }' |
    LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1 | cut -f5)"
  [[ -n "$tag" ]] || stop 4 "$url has no version tag (vX.Y.Z or X.Y.Z): tag a release and re-run"
fi

# --- apply: the writes, undone as a unit on any failure ---------------------------

index="$(g rev-parse --path-format=absolute --git-path index 2>/dev/null)" ||
  stop 7 "cannot locate the git index"
config="$(g rev-parse --path-format=absolute --git-path config 2>/dev/null)" ||
  stop 7 "cannot locate the git config"
snap="$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX")" || stop 7 "cannot create a scratch directory"
had_index=0 had_gitmodules=0
no_snapshot() {
  rm -rf "$snap"
  stop 7 "cannot snapshot $1"
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

undo() {
  if [[ "$state" == absent ]]; then
    rm -rf "$repo/$mount" "$modules_dir"
  fi
  if ((had_index)); then cp -p "$snap/index" "$index"; else rm -f "$index"; fi
  cp -p "$snap/config" "$config"
  if ((had_gitmodules)); then cp -p "$snap/gitmodules" "$repo/.gitmodules"; else rm -f "$repo/.gitmodules"; fi
  rm -rf "$snap"
}

abort() {
  undo
  stop 7 "$1; nothing was changed"
}

trap 'undo; exit 130' INT TERM

if [[ "$state" == absent ]]; then
  g submodule --quiet add --name "$mount" -- "$url" "$mount" </dev/null >/dev/null 2>&1 ||
    abort "git submodule add of $url failed"
  g -C "$mount" fetch --quiet origin "refs/tags/${tag}:refs/tags/$tag" </dev/null >/dev/null 2>&1 ||
    abort "cannot fetch $tag from $url"
  g -C "$mount" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/${tag}^{commit}" >/dev/null 2>&1 ||
    abort "cannot check out $tag"
  [[ "$(g -C "$mount" rev-parse HEAD 2>/dev/null)" == "$(g -C "$mount" rev-parse "refs/tags/${tag}^{commit}" 2>/dev/null)" ]] ||
    abort "the checkout is not at $tag"
  name="$mount"
  # no `branch` line: the pin is a commit at a version tag
  gm --unset-all "submodule.$name.branch" >/dev/null 2>&1
fi
gm "submodule.$name.reference-docs" true >/dev/null 2>&1 || abort "cannot set the reference-docs key"
if [[ "$state" == absent ]]; then
  g add -- .gitmodules "$mount" >/dev/null 2>&1 || abort "cannot stage the submodule"
else
  g add -- .gitmodules >/dev/null 2>&1 || abort "cannot stage .gitmodules"
fi

trap - INT TERM
rm -rf "$snap"
print "linked"
