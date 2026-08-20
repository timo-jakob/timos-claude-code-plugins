# shellcheck shell=bash
#
# Shared normalisation for PROPAGATION INVARIANTS (#1432).
#
# A propagation invariant sweeps a rule's restatement sites and holds each one
# to the rule's substantive clauses (MAINTAINING.md, *Propagation invariants*).
# Every such sweep needs the same thing first: the site's prose, in a shape a
# literal needle can match. This is that one derivation — `load prose-lockstep`
# — rather than a copy per suite, which is the very defect the pattern exists
# to remove.
#
# THREE NORMALISATIONS, each earning its place:
#
#   * the leading COMMENT MARKER. A restatement living in a script header or a
#     workflow header is prose that happens to be commented. Without this, a
#     clause wrapping across two comment lines reads as `… an if: # guard does
#     not …` and no needle can match it — so a genuinely-carrying site would be
#     reported stale, and an author would "fix" it by reflowing the paragraph.
#     One `#` and one following space at most, so `## Heading` keeps a `#`.
#     A SHEBANG is not spared: `#!/usr/bin/env bash` normalises to
#     `!/usr/bin/env bash`, so never write a needle containing `#!`.
#
#   * markdown EMPHASIS and CODE ticks. The same sentence is bolded differently
#     at every site — ``**`if:` guard exempts only**`` at one, ``guard
#     **exempts only**`` at another. A needle carrying either spelling would
#     pass on one site by accident and fail on the other for no reason that
#     matters.
#
#   * WHITESPACE, collapsed to single spaces, so a reflowed paragraph is not a
#     false positive. This is the same `tr -s '[:space:]' ' '` the #1206 sweeps
#     have always used; the two above are what this file adds.
#
# It deliberately does NOT lowercase: the sites agree on case, and folding it
# would let `NOT` and `not` read alike in a rule whose whole content is a
# negation.
#
# NEEDLES MUST BE PRE-NORMALISED. Because the haystack loses `*` and `` ` ``
# and its newlines, a needle pasted from the source as it reads — ``carrying an
# **`if:` guard exempts**`` — can never match, and the failure mode is a silent
# skip, not a diagnostic. Write needles without emphasis, ticks or newlines.
#
# FAIL CLOSED ON AN UNREADABLE SITE. Every helper returns 2 rather than an empty
# string when `$1` is not a readable file. Without that, `sed`'s failure is
# swallowed by the trailing `tr`/`cut` and the helper returns 0 with empty
# output — which a sweep reads as "this site says nothing", indistinguishable
# from "this site is clean". The rosters are derived by `grep -rl` and re-open
# their paths later, so a renamed or worktree-absent site is a real path to a
# green sweep of nothing. Callers must ALSO guard, because `case "$(…)"`
# discards the helper's status.
#
# ARGUMENT GUARD. Every helper below requires its exact argument count and a
# non-empty needle, returning 2 for misuse — the doctrine tests/assertions.bash
# states for this repo's shared test libraries. Without it, `grep -F -e ""`
# matches every line and a sweep whose gate constant was renamed becomes noise
# rather than a loud failure.

_prose_lockstep_readable() {
  [ -f "$1" ] && [ -r "$1" ] && return 0
  printf 'prose-lockstep: not a readable file: %s\n' "$1" >&2
  return 2
}

_prose_lockstep_needle() {
  [ -n "$1" ] && return 0
  printf 'prose-lockstep: the needle must be non-empty\n' >&2
  return 2
}

# The whole file's prose, normalised. Safe only on a file whose SUBJECT is the
# rule; on a large artifact use prose_gate_lines + prose_window instead, or an
# unrelated paragraph will satisfy the needle (MAINTAINING.md's *Scope the
# needle to the statement* rule).
prose_body() {
  [ "$#" -eq 1 ] || { printf 'prose-lockstep: prose_body needs exactly one file\n' >&2; return 2; }
  _prose_lockstep_readable "$1" || return 2
  sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$1" | tr -d '*`' | tr -s '[:space:]' ' '
}

# The normalised WINDOW around one statement — line `$2` of file `$1`, plus
# `$3` lines either side.
#
# WHY A WINDOW rather than the whole file: a rule restated inside a large
# artifact (a 5000-line SKILL.md) cannot be swept file-scoped without going
# vacuous — the needle proving the clause is present will be satisfied by some
# unrelated paragraph. Scoping to the statement makes the sweep say what it
# means: *wherever this site states the rule, it states it in full.* The window
# is lines rather than sentences because the sites wrap mid-clause, which is
# exactly what defeats a per-line grep.
prose_window() {
  local f="$1" ln="$2" span="$3" lo hi
  [ "$#" -eq 3 ] || { printf 'prose-lockstep: prose_window needs a file, a line and a span\n' >&2; return 2; }
  _prose_lockstep_readable "$f" || return 2
  # A non-numeric line would be a bash arithmetic SYNTAX error below, aborting
  # with a message about arithmetic rather than about the file. `grep -n` on a
  # file grep deems binary prints "Binary file … matches" instead of `N:line`,
  # which is exactly how a non-numeric value reaches here.
  case "$ln" in ''|*[!0-9]*) printf 'prose-lockstep: bad line number: %s\n' "$ln" >&2; return 2 ;; esac
  case "$span" in ''|*[!0-9]*) printf 'prose-lockstep: bad span: %s\n' "$span" >&2; return 2 ;; esac
  lo=$(( ln - span ))
  # `if`, not `[ … ] && lo=1`: the AND-list form is exempt from errexit (bash
  # documents it), so it is not a bug — but it reads like one to every reviewer
  # who meets it, and control flow is what this actually is.
  if [ "$lo" -lt 1 ]; then lo=1; fi
  hi=$(( ln + span ))
  sed -n "${lo},${hi}p" "$f" \
    | sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' | tr -d '*`' | tr -s '[:space:]' ' '
}

# The 1-based line numbers of `$1` whose NORMALISED text contains the literal
# gate phrase `$2`. The EMPHASIS strip is what earns its place here: it deletes
# mid-line characters, so it can rejoin a needle's span that `**` had broken.
#
# The comment-marker strip, by contrast, is a NO-OP FOR MATCHING and is retained
# only so the three helpers normalise identically. It removes a line PREFIX, so
# its output is a suffix of the original; a literal substring match on a suffix
# is a strict subset of the matches on the whole line. It can therefore lose a
# hit (for a needle that itself contains the marker) but never create one — do
# not write a fixture claiming to pin it here, and do not write a gate needle
# beginning with `#`. In `prose_body` and `prose_window` the same strip IS
# load-bearing, because the whitespace collapse would otherwise leave the marker
# mid-string and no needle could span a wrap.
#
# PER-LINE, deliberately: the whitespace collapse is omitted so line numbers
# survive. The consequence is a real constraint on callers — A GATE NEEDLE MUST
# NOT SPAN A SOURCE LINE. Pick a gate short enough to survive any reflow (a few
# words, or a single distinctive token) and leave the wrap-tolerant phrase test
# to prose_window, which does collapse. A gate that wraps stops matching and the
# site leaves the sweep silently.
#
# `-a` so a stray NUL cannot turn the output into "Binary file … matches";
# `-F` so a needle containing `.` or `*` is matched literally.
prose_gate_lines() {
  [ "$#" -eq 2 ] || { printf 'prose-lockstep: prose_gate_lines needs a file and a needle\n' >&2; return 2; }
  _prose_lockstep_readable "$1" || return 2
  _prose_lockstep_needle "$2" || return 2
  sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$1" | tr -d '*`' \
    | grep -a -n -F -e "$2" | cut -d: -f1
}
