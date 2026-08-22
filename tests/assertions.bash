# shellcheck shell=bash
#
# Shared bats assertion helpers (#1011).
#
# WHY THESE EXIST: on bash 3.2 — the `/bin/bash` macOS still ships, and what
# `#!/usr/bin/env bash` resolves to on this repo's primary platform — errexit
# does NOT fire on a failing `[[ ... ]]`. So a false `[[ "$output" == *"x"* ]]`
# in the middle of a test body is SILENTLY IGNORED: the test reports `ok` while
# proving nothing, unless the assertion happens to be the block's last statement
# (where its status becomes the block's own).
#
# On bash >= 4 the same assertion fails correctly. That is WORSE, not better: it
# makes an assertion's meaning depend on which machine ran it — inert on the
# maintainer's Mac and on the `bats (macos-latest)` CI leg, enforced on
# `bats (ubuntu-latest)`. A repo-wide ban is the only way to make the suite say
# one thing everywhere. This is the same bash-3.2-vs-bash-5 divergence the
# two-lane script-tests matrix exists to catch (#292/#293) — that lane is what
# surfaced it here, by reddening the premise tests when they pinned the macOS
# outcome as universal.
#
# The macos-latest leg named above is DEACTIVATED as of #1407 (#1408 tracks
# restoring it), so read it as why this ban exists, not as what enforces it
# today. The ban matters MORE while the lane is down, not less: bash 3.2 is now
# exercised only on the maintainer's Mac before a push, so a newly-inert
# assertion would reach main unchallenged. This ban is repo-wide and runs on
# ubuntu, so it keeps holding with the lane off.
#
# Verified empirically: bats 1.10.0/1.11.0/1.12.0/1.13.0/1.14.0 ALL report `ok`
# under bash 3.2.57 and `not ok` under bash 4.4/5.2 — the bats version is not the
# variable, the bash version is. `[ ... ]` in the same position fails correctly
# on every bash, which is why it is never flagged.
#
# Each helper below is an ordinary function, so calling it is a simple command
# that errexit catches wherever it appears AS A COMMAND OF ITS OWN — which is the
# whole of the guarantee, and no more: position stops mattering, the WAY YOU
# JOIN IT TO OTHER COMMANDS does not. See the neutralisation list below (#1067);
# an earlier version of this paragraph stopped at "position stops mattering",
# which is precisely the belief that produces `contains … && contains …`.
# tests/no-inert-bracket-assertions.bats bans the inert `[[ ]]` form these
# replace, and fails any tests/*.bats that calls a helper without
# `load assertions`. Plain `[ ... ]` is never flagged and needs no ban — errexit
# catches it on every bash — but "never flagged" is not "always safe": it is
# subject to the same joining rules below.
#
# Ways to neutralise a helper call. The first is now caught by a lint; the rest
# are caught partially or not at all, so read this list as the convention, not as
# a description of what the guards enforce (#1067):
#   * `a && b` — the AND-list errexit exemption applies to a function call
#     exactly as it does to `[[ ]]`, so a failing `a` is swallowed. Put each
#     assertion on its own line. The `and-tail` rule of
#     tests/find-inert-bracket-assertions.zsh flags the swallowed left operand.
#   * a bare `!` negation — inert for its own reason. #829's
#     tests/no-inert-negative-assertions.bats catches it at LINE START only, so a
#     mid-line `run x; ! lacks …` is on you. Use `lacks` instead of negating
#     `contains`.
#   * `<helper> … || <something that succeeds>` — NOT flagged by anything, and
#     the easiest of these to write by accident. An `||` list is fine only
#     when its LAST member can itself fail: `contains … || return 1` is an
#     assertion, `contains … || true` (or `|| echo note`) discards the result
#     entirely. The `and-tail` rule deliberately stays out of `||` because that
#     judgment is about the tail, not the shape.
#   * `<helper> … | <cmd>` — also unflagged. A pipeline's status is its LAST
#     command's, and bats does not run test bodies under `pipefail`, so piping an
#     assertion discards it just as `|| true` does. Never pipe an assertion.
#
# ALL FOUR apply to a plain `[ ... ]` as well — none of them is about helpers.
# `[ -n "$a" ] && [ -f "$b" ]` swallows the left test on EVERY bash and no rule
# here flags it (`bracket` keys on `[[`, `and-tail` on the helper roster); so do
# `[ … ] || true`, a piped `[ … ]`, and a bare `! [ … ]` — that last one caught
# by #829 only at line start, exactly as for a helper. One assertion per line is
# the rule for every form.
#
# Load from a test file with `load assertions` (bats resolves it relative to the
# test's directory).
#
# NAMING IS LOAD-BEARING: a public, top-level function in this file IS an
# assertion helper; internals are `_`-prefixed. Both bats guards derive the
# roster from that rule rather than restating it (#1067) — the detector's awk
# `H` is the only other CODE copy, and a roster-sync test fails if the two
# disagree. So a new helper is named plainly, a new internal starts with `_`,
# and a non-assertion utility does not belong here at all.
#
# Adding one also means updating the copies no derivation can reach: the
# LITERAL-vs-REGEX paragraph just below, which owes every helper a verdict
# (nothing checks it); the measured EMPTY-NEEDLE table further down, which owes
# every helper a ROW and whose "three of the five" count is read off it (#1507 —
# and its cells are measured, so a new helper means running it, not guessing);
# and tests/README.md's roster (a guard test does check that).
# tests/find-inert-bracket-assertions.zsh's header carries the full checklist.
#
# LITERAL vs REGEX: `contains`, `lacks`, `starts_with` and `ends_with` match
# LITERALLY, and in all four the literalness comes from the SAME thing — a
# QUOTED `"$2"` in a pattern position: `[[ "$1" == *"$2"* ]]` for the first two
# (#1507), a `case` arm with a quoted pattern for the other two. Both treat `$2`
# as plain text. That is deliberate: an UNQUOTED `$2` in either construct would
# silently reinterpret a literal like `[worktree]` as a character class, which is
# exactly the kind of quiet semantic drift this file removes — so if you ever
# touch these four, the quotes are the thing not to drop. `matches` is the sole
# exception and takes an ERE — use it only when you actually want a regex.
#
# `contains`/`lacks` used to spell this `${1#*"$2"}`, which is equally literal
# but QUADRATIC on bash 3.2 (#1507 — see the note on `contains` below for the
# measured cost). The idiom changed; the literal guarantee did not.
#
# CASE-SENSITIVE too — and since #1507 that is a convention rather than a
# structural guarantee for `contains`/`lacks`. `[[ ]]` and `case` both honour
# `shopt -s nocasematch`, where parameter expansion does not. Verified on bash
# 3.2.57: with the option set, `[[ ABC == *a* ]]` and `case ABC in *a*)` both
# match, while `${v#a}` on `ABC` returns `ABC` unchanged. So a
# `shopt -s nocasematch` in any calling file's `setup()` would make all five
# helpers case-insensitive across that file, turning
# `contains "$output" "ERROR"` into a match on lowercase prose.
#
# SO NO TESTS FILE MAY ENABLE IT — a convention today, NOT YET ENFORCED. #1508
# carries the repo-wide invariant (a `git ls-files` sweep over the tracked
# `tests/` files); until it lands, nothing reds if a suite file turns the option
# on, so treat this paragraph as the rule and #1508 as the guard that will make
# it real.
#
# There is no SCOPED exemption to reach for: a case-insensitive comparison needs
# a `shopt -s` line, and that is exactly what makes every helper in the file
# case-fold from that point on. If one comparison genuinely needs to ignore
# case, use `matches` with an ERE that spells both cases, or `grep -i` — do not
# reach for the option. tests/assertions.bats pins the library-side behaviour
# (all five helpers, both directions).
#
# EVERY helper requires exactly TWO arguments and a NON-EMPTY `$2`, enforced
# below. Without that guard a dropped argument would make THREE of the five
# return true unconditionally (bats does not run test bodies under `set -u`, so
# `$2` would quietly expand to empty) — a vacuous assertion, which is the very
# defect class this file exists to eliminate.
#
# WHICH three changed in #1507, and it is a SWAP, not a widening. Measured on
# bash 3.2.57 with the guard bypassed — every cell run, none inferred:
#
#                empty `$2`   old idiom          new idiom
#   contains                  1  fails CLOSED    0  fails OPEN
#   lacks                     0  fails OPEN      1  fails CLOSED
#   starts_with               0  fails OPEN      0  fails OPEN
#   ends_with                 0  fails OPEN      0  fails OPEN
#   matches                   1  fails CLOSED    1  fails CLOSED
#
# — because `${1#*""}` leaves `$1` unchanged (so the old `contains` compared
# equal and failed, while the old `lacks` succeeded), whereas `*""*` matches
# everything (so the new `contains` succeeds and the new `lacks` does not). The
# COUNT is therefore three both before and after; `contains` simply took
# `lacks`'s place on the unsafe side. `matches` is closed on this shell because
# an empty ERE does not reach its `0)` arm — do not generalise that to other
# bash versions without re-running the table.
#
# If you ever narrow `_assert_args`, `contains` is emphatically not the safe one
# to exempt — and do not reach for this table to justify calling any helper with
# an empty needle, since the guard rejects that first, by design.

# Guard shared by every helper. Returns 2, distinct from a genuine mismatch (1),
# so a caller that pins `$status` can tell misuse from a real failure.
#
# NOTE: bats' `run ! …` accepts ANY non-zero status, so it canNOT tell 2 from 1
# — a negated call would swallow the misuse it was meant to expose. Write a
# negative assertion as `run <helper> …; [ "$status" -eq 1 ]`, or simply use
# `lacks`. tests/assertions.bats pins both halves of this.
_assert_args() {
  if [ "$1" -ne 2 ]; then
    printf 'assertion helper: expected 2 arguments, got %s\n' "$1" >&2
    return 2
  fi
  if [ -z "$2" ]; then
    printf 'assertion helper: the needle/pattern must be non-empty\n' >&2
    return 2
  fi
}

# The mismatch (1) diagnostic, shared by every helper — and the reason a failure
# is now debuggable from a CI log (#1067). bats prints the failing SOURCE line,
# so the needle was always visible; the haystack never was, which is what the
# `[[ "$output" == *x* ]]` form these helpers replaced at least left inspectable
# in context.
#
# ON fd 2, deliberately: hundreds of call sites pin `$status` after
# `run <helper>`, and bats folds a helper's stdout into `$output`. Writing the
# diagnostic to stdout would rewrite `$output` under every one of them. Sending
# it to stderr leaves plain `run` callers seeing it in `$output` only when they
# do not use `--separate-stderr`, which is exactly where a human wants it.
#
# `${FUNCNAME[1]}` names the helper that failed, so one shared printer needs no
# per-helper label. It is guarded with `-` because a helper called from a context
# without a call stack would otherwise be an unbound-variable error INSIDE the
# failure path — turning a legible mismatch into a confusing one.
#
# The haystack is truncated because `$output` in this suite routinely runs to
# kilobytes (a whole bats run, a whole JSON dossier); an untruncated dump would
# bury the assertion it is meant to explain. The truncation is announced with the
# full length, so a reader is never misled into thinking they saw everything.
_assert_mismatch() {
  local who="${FUNCNAME[1]-assertion helper}" hay="$1" needle="$2" max=400
  printf '%s: assertion failed\n  needle:   %s\n' "$who" "$needle" >&2
  if [ "${#hay}" -gt "$max" ]; then
    printf '  haystack: %s\n  … haystack truncated at %s of %s characters\n' \
      "${hay:0:$max}" "$max" "${#hay}" >&2
  else
    printf '  haystack: %s\n' "$hay" >&2
  fi
  return 1
}

# `$1` contains the literal substring `$2`.
#
# WHY `[[ == *"$2"* ]]` AND NOT `${1#*"$2"}` (#1507): the prefix-removal form is
# QUADRATIC in the haystack on bash 3.2 — the only bash this suite is guaranteed
# to run under. Measured on bash 3.2.57 against the 380 KB `ARCHITECTURE.md`
# slurped into a variable: 57 s for a hit and 94 s for a miss, against 0.0205 s
# either way for the form below (mean of 100 calls — a single timed call is
# dominated by measurement overhead, and quoting an unamortised figure here is
# exactly how an earlier draft of tests/assertions.bats drew a headroom claim
# that was ~50x wrong). That is not a micro-optimisation: five such
# calls in tests/kubernetes-topic-marker.bats cost 9 minutes, which was the
# WHOLE GATE's wall-clock floor, paid on every review round of every story.
#
# The literal guarantee is unchanged and comes from the QUOTES: `"$2"` inside a
# `[[ ]]` pattern is matched as plain text, so a needle like `[worktree]` stays a
# literal bracket expression rather than becoming a character class. Removing
# those quotes would silently turn every needle into a glob — the exact drift the
# LITERAL-vs-REGEX paragraph above exists to prevent. tests/assertions.bats pins
# both halves: the literal semantics (`[worktree]`, `*`, `?`, `\`, hit and miss
# each) and a perf pin that reds if the quadratic idiom ever comes back.
#
# The `[[ ]]` here is the sanctioned form, not a violation of this file's own
# ban: the ban is about a `[[ ]]` whose status errexit never sees. The rule
# (tests/find-inert-bracket-assertions.zsh) is ONE thing — the `[[ ]]`'s FAILURE
# must become the function's non-zero status — and there are three ways to
# satisfy it:
#   1. the `[[ ]]` is the function's last command (its status IS the return);
#   2. it carries an `||` tail that ITSELF returns non-zero — `|| return 1`, or
#      `|| _assert_mismatch …`, which ends in `return 1`. This is `contains`;
#   3. its status is CAPTURED and dispatched (`|| rc=$?` then a `case`). This is
#      `matches`, which needs it to keep misuse (2) distinct from mismatch (1).
# Case 2 is the one to get right, because it is the one that can be faked: an
# `||` tail that SUCCEEDS discards the failure entirely, so
# `has_prefix() { [[ "$1" == "$2"* ]] || printf 'no\n' >&2; }` returns 0 always —
# a permanently-passing assertion. Nothing scans this file to catch that, so the
# tail's own status is what you must check when adding a helper.
contains() {
  _assert_args "$#" "${2-}" || return 2
  [[ "$1" == *"$2"* ]] || _assert_mismatch "$1" "$2"
}

# `$1` does NOT contain the literal substring `$2`.
#
# Same idiom, same reason, same literal guarantee as `contains` above — and the
# miss case is the one that was slowest of all (94 s on a 380 KB haystack),
# because `lacks` SUCCEEDS precisely when the quadratic scan has to run to
# completion without finding anything.
lacks() {
  _assert_args "$#" "${2-}" || return 2
  [[ "$1" != *"$2"* ]] || _assert_mismatch "$1" "$2"
}

# `$1` begins with the literal string `$2`.
starts_with() {
  _assert_args "$#" "${2-}" || return 2
  case "$1" in "$2"*) return 0 ;; *) _assert_mismatch "$1" "$2" ;; esac
}

# `$1` ends with the literal string `$2`.
ends_with() {
  _assert_args "$#" "${2-}" || return 2
  case "$1" in *"$2") return 0 ;; *) _assert_mismatch "$1" "$2" ;; esac
}

# `$1` matches the extended regular expression `$2` — the replacement for
# `[[ "$x" =~ re ]]`, with the SAME whole-string semantics: `^`/`$` anchor the
# whole value, not a line. (An earlier draft piped through `grep -qE`, which
# anchors per LINE and would have silently weakened every anchored assertion to
# "some line matches".) `$2` is deliberately unquoted — quoting it would make
# the ERE literal.
# An UNCOMPILABLE `$2` is misuse (2), not a mismatch (1). `[[ =~ ]]` returns 2
# for an ERE it cannot compile — verified on bash 3.2.57 — where a plain
# non-match returns 1. Routing every non-zero status through _assert_mismatch
# would flatten the two, so a typo'd pattern in the sanctioned negative form
# (`run matches …; [ "$status" -eq 1 ]`) would PASS while matching nothing at
# all: the vacuous-assertion class this whole library exists to remove, and the
# reason misuse is a distinct status in the first place.
matches() {
  _assert_args "$#" "${2-}" || return 2
  local rc=0
  # shellcheck disable=SC2319  # the condition's status IS what we want here:
  # `[[ =~ ]]` returns 2 for an uncompilable ERE and 1 for a non-match, and
  # telling those apart is the entire point. The `|| rc=$?` form is also what
  # keeps the assertion out of errexit's way while we read it — a bare
  # `[[ … ]]` followed by `rc=$?` would abort the function on bash >= 4 before
  # the assignment ran, and silently not abort it on bash 3.2.
  [[ "$1" =~ $2 ]] || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) _assert_mismatch "$1" "$2" ;;
    *)
      printf 'assertion helper: not a valid extended regular expression: %s\n' "$2" >&2
      return 2
      ;;
  esac
}
