# shellcheck shell=bash
#
# The assertion-helper roster, DERIVED from tests/assertions.bash (#1067).
#
# WHY THIS FILE EXISTS: the roster used to be restated — in the detector's awk
# `H`, in two greps and two loops across the bats guards, and in prose. Every
# copy was a chance for a new helper to ship half-guarded while the whole suite
# stayed green, and testing that the copies agreed could never say WHICH one had
# drifted. So the copies were removed instead. This is the one derivation; both
# bats files `load roster` and use it, and its self-test in
# tests/no-inert-bracket-assertions.bats therefore covers every consumer. The
# detector's `H` is the only remaining copy a machine must keep, and one
# set-equality test pins it in both directions.
#
# THE RULE IT ENCODES: a public, top-level function in tests/assertions.bash IS
# an assertion helper; internals are `_`-prefixed. That convention is stated in
# assertions.bash's header, because this derivation depends on it.
#
# It accepts all four definition spellings bash admits — `equals() {`,
# `equals () {`, `function equals() {`, and the paren-less `function equals {` —
# and names carrying digits or capitals. Breadth is the point: a spelling this
# missed would be absent from the derived roster AND from the comparison against
# `H`, so the sync test would agree vacuously and the helper would ship
# unguarded. The self-test plants every one of those shapes, so the claim is
# checked rather than asserted.
#
# Prints the roster as a sorted, space-separated list with no trailing space —
# the trim matters, because a caller building an alternation with `tr ' ' '|'`
# would otherwise get a pattern ending in `|`, which matches everything and
# makes the fixture canaries built on it vacuous.
helper_roster_of() {
  grep -oE '^(function[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*([[:blank:]]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[[:blank:]]*\(\))' "$1" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
    | grep -vx 'function' \
    | grep -v '^_' \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/ $//'
}
