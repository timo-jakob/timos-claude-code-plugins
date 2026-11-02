#!/usr/bin/env zsh
# The decision-rights rule's State D adoption gap (#2905, epic #2898).
#
# common/CLAUDE.md.tmpl carries a "## Who decides what" section. A repo
# bootstrapped before that section existed has a CLAUDE.md without it, and the
# drift detector cannot see the difference: CLAUDE.md is a scaffold file, never
# stamped. This script is how State D finds that gap and closes it.
#
# Usage:
#   claude-md-decision-rights.zsh check --claude-md <file>
#   claude-md-decision-rights.zsh apply --claude-md <file> --template <tmpl>
#
# The rule counts as present when the file holds the heading as its own line,
# outside a fenced code block, ignoring case, trailing whitespace and a CRLF
# line ending.
#
# check  exit 0 — the rule is present (prints "present")
#        exit 1 — adoption gap: the file exists and lacks the rule ("gap")
#        exit 3 — no such file: not this gap; the missing-file gap-fill renders
#                 the whole template, rule included
#        exit 5 — the file exists but cannot be read
# apply  appends the template's section to the file and leaves every existing
#        byte unchanged (append-only). The separator: an empty file gets none;
#        a file whose last line lacks its newline gets that newline; then one
#        blank line precedes the section. A CRLF file gets the section in CRLF.
#        Idempotent: a file that already carries the rule is left alone, before
#        the template is even read.
#        exit 0 — applied ("applied"), or already present ("present")
#        exit 3 — no such file
#        exit 4 — the template exists but carries no such section, or the
#                 section holds an unrendered {{PLACEHOLDER}} (a broken template)
#        exit 5 — a read or write failed (the file or the template unreadable,
#                 the file not writable); nothing was appended
# Both:  exit 2 — usage error, including a --template path that does not exist
#                 (a mis-substituted path is the caller's to fix).

set -euo pipefail

readonly HEADING='## Who decides what'

usage() {
  print -u2 "usage: claude-md-decision-rights.zsh check --claude-md <file>"
  print -u2 "       claude-md-decision-rights.zsh apply --claude-md <file> --template <tmpl>"
  exit 2
}

(( $# > 0 )) || usage
mode="$1"; shift
case "$mode" in
  check|apply) ;;
  *) usage ;;
esac

claude_md=""
template=""
while (( $# > 0 )); do
  case "$1" in
    --claude-md) (( $# > 1 )) || usage; claude_md="$2"; shift 2 ;;
    --template)  (( $# > 1 )) || usage; template="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$claude_md" ]] || usage
if [[ "$mode" == apply ]]; then
  [[ -n "$template" ]] || usage
else
  [[ -z "$template" ]] || usage
fi

# Exit 0 when the heading is a line of its own outside any ``` / ~~~ fence.
has_rule() {
  awk -v h="$(print -r -- "$HEADING" | tr '[:upper:]' '[:lower:]')" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    line ~ /^(```|~~~)/ { fenced = !fenced; next }
    !fenced && tolower(line) == h { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

if [[ ! -f "$claude_md" ]]; then
  print -u2 "claude-md-decision-rights: no such file: $claude_md"
  exit 3
fi
if [[ ! -r "$claude_md" ]]; then
  print -u2 "claude-md-decision-rights: cannot read: $claude_md"
  exit 5
fi

if has_rule "$claude_md"; then
  print "present"
  exit 0
fi
if [[ "$mode" == check ]]; then
  print "gap"
  exit 1
fi

# apply
if [[ ! -e "$template" ]]; then
  print -u2 "claude-md-decision-rights: no such template: $template"
  usage
fi
if [[ ! -r "$template" ]]; then
  print -u2 "claude-md-decision-rights: cannot read template: $template"
  exit 5
fi
if [[ ! -w "$claude_md" ]]; then
  print -u2 "claude-md-decision-rights: cannot write: $claude_md"
  exit 5
fi

# The section runs from its heading to the next H2 or the end of the template.
section="$(awk -v h="$HEADING" '
  $0 == h { on = 1; print; next }
  on && /^## / { exit }
  on { print }
' "$template")" || { print -u2 "claude-md-decision-rights: cannot read template: $template"; exit 5; }
[[ -n "$section" ]] || {
  print -u2 "claude-md-decision-rights: template carries no '$HEADING' section: $template"
  exit 4
}
if [[ "$section" == *'{{'* ]]; then
  print -u2 "claude-md-decision-rights: the template's section holds an unrendered placeholder: $template"
  exit 4
fi

# Keep every existing byte: only ever append. Decide the separator before
# opening the file for writing.
eol=$'\n'
if grep -q $'\r$' "$claude_md"; then
  eol=$'\r\n'
fi
sep=""
if [[ -s "$claude_md" ]]; then
  sep="$eol"
  if [[ "$(tail -c 1 "$claude_md" | od -An -c | tr -d ' ')" != '\n' ]]; then
    sep="$eol$eol"
  fi
fi
if [[ "$eol" == $'\r\n' ]]; then
  lf=$'\n'
  section="${section//$lf/$eol}"
fi
printf '%s%s%s' "$sep" "$section" "$eol" >> "$claude_md" || {
  print -u2 "claude-md-decision-rights: cannot write: $claude_md"
  exit 5
}
print "applied"
