#!/usr/bin/env zsh
# toggle-fable.zsh — flip every agent whose frontmatter declares `model: fable`
# to `model: opus`, and restore them, driven by an `on`/`off` parameter.
#
#   toggle-fable.zsh off   add the current `model: fable` agents to a saved
#                          manifest, then rewrite each to `model: opus`.
#   toggle-fable.zsh on    restore `model: fable` on the agents in the saved
#                          manifest (fails loudly if none was saved).
#
# The manifest (scripts/.fable-agents, git-ignored) is the single source of
# truth for which agents flip back to fable — an agent that was opus/haiku/
# sonnet to begin with is never touched in either direction. `off` UNIONS the
# current fable set into the manifest rather than replacing it, so a newly-added
# fable agent is captured while a previously-recorded entry is never dropped
# (an interrupted or repeated `off` can never strand an agent on opus with no
# record). Only the frontmatter `model:` line is edited; a prose "model: ..."
# elsewhere in a file is left alone.
#
# Exits 0 on success, 1 on a restore with no saved manifest, 2 on usage errors.
#
# Why this script exists: see issue #990. Running the whole agent family on
# opus locally (to compare behaviour, or when fable is unavailable) otherwise
# means hand-editing dozens of files and risking promoting a non-fable agent to
# fable on the way back.

setopt err_exit nounset pipefail

# Capture the program name here at top level — inside a function zsh rebinds $0
# to the function name. Repo root is one level up from scripts/<file>.zsh.
readonly PROG="${0:t}"
readonly REPO_ROOT="${0:A:h:h}"
readonly MANIFEST="${REPO_ROOT}/scripts/.fable-agents"
readonly FABLE="fable"
readonly OPUS="opus"

usage() {
  print -u2 -- "usage: $PROG <on|off>"
  print -u2 -- "  off  add the current fable agents to the manifest, switch them to opus"
  print -u2 -- "  on   restore fable on the saved agents"
}

# frontmatter_model <file> — print the value of the frontmatter `model:` line,
# or nothing when the file has no *proper* frontmatter (a `---` on line 1 AND a
# closing `---`) or no model line. awk (no pipe) so it can't hit the pipefail +
# SIGPIPE trap a `grep -q` over a long file body would, and so it never reads
# past the closing fence — a prose "model: ..." in the body is invisible here.
frontmatter_model() {
  awk '
    NR == 1     { if ($0 != "---") exit; next }
    /^---$/     { print val; exit }          # closing fence (only reached >1)
    /^model: /  { val = substr($0, 8) }
  ' "$1"
}

# rewrite_model <file> <from> <to> — replace `model: <from>` with `model: <to>`
# on the frontmatter model line only. Writes back through the original inode
# (cat, not mv) so the file keeps its mode/links/xattrs; untouched lines pass
# through byte-for-byte, so an off/on round trip is exact. sed's `1,/^---$/`
# range is bounded because callers only reach here for files with a closing
# fence (frontmatter_model gated them).
rewrite_model() {
  local f="$1" from="$2" to="$3" tmp
  tmp="$(mktemp)" || return 1
  sed "1,/^---\$/ s/^model: ${from}\$/model: ${to}/" "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

toggle_off() {
  local f m
  local -a current manifest_prev
  # Currently-fable agents (relative paths).
  for f in "$REPO_ROOT"/*/agents/*.md(N); do
    [[ "$(frontmatter_model "$f")" == "$FABLE" ]] && current+=("${f#"$REPO_ROOT"/}")
  done

  # Union with any previously-saved manifest so prior entries (which may already
  # be on opus, hence invisible to the scan above) are never dropped.
  if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r m || [[ -n "$m" ]]; do
      [[ -n "$m" ]] && manifest_prev+=("$m")
    done < "$MANIFEST"
  fi

  local -aU union
  union=("${manifest_prev[@]}" "${current[@]}")   # -aU dedups on assignment

  if (( ${#union} == 0 )); then
    print -- "No agents on fable and no saved manifest — nothing to do."
    return 0
  fi

  # Write the manifest atomically, sorted for stable/idempotent content.
  local tmp
  tmp="$(mktemp)" || return 1
  print -rl -- ${(o)union} > "$tmp"
  mv "$tmp" "$MANIFEST"

  local flipped=0
  for f in "${current[@]}"; do
    rewrite_model "$REPO_ROOT/$f" "$FABLE" "$OPUS"
    flipped=$((flipped + 1))
  done
  print -- "Switched ${flipped} agent(s) to opus (${#union} in manifest ${MANIFEST#"$REPO_ROOT"/})."
}

toggle_on() {
  if [[ ! -f "$MANIFEST" ]]; then
    print -u2 -- "No saved manifest at ${MANIFEST#"$REPO_ROOT"/} — run '$PROG off' first."
    return 1
  fi

  local f model restored=0
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -z "$f" ]] && continue
    if [[ ! -f "$REPO_ROOT/$f" ]]; then
      print -u2 -- "warning: manifest lists '$f' but it no longer exists — skipping."
      continue
    fi
    model="$(frontmatter_model "$REPO_ROOT/$f")"
    case "$model" in
      "$OPUS")
        rewrite_model "$REPO_ROOT/$f" "$OPUS" "$FABLE"
        restored=$((restored + 1))
        ;;
      "$FABLE")
        : ;;  # already fable — idempotent no-op, don't count
      *)
        # Deliberately changed to something else since the snapshot — never
        # promote it; this is exactly the mistake the manifest exists to avoid.
        print -u2 -- "warning: '$f' is now 'model: ${model:-<none>}', not opus — leaving it alone."
        ;;
    esac
  done < "$MANIFEST"
  print -- "Restored ${restored} agent(s) to fable from ${MANIFEST#"$REPO_ROOT"/}."
}

(( $# == 1 )) || { usage; exit 2; }

case "$1" in
  off) toggle_off ;;
  on)  toggle_on ;;
  *)   usage; exit 2 ;;
esac
