#!/usr/bin/env bats
#
# Unit coverage for tests/prose-lockstep.bash (#1432) — the shared normalisation
# every propagation invariant is built on.
#
# WHY THIS FILE EXISTS. The library is a load-able sibling of
# tests/assertions.bash, which has tests/assertions.bats; without the same, the
# helpers are exercised only INCIDENTALLY, by whichever needles the two sweeps
# happen to use today. That is not coverage: several of the documented
# normalisations could be deleted with every sweep still green, because no
# current site needs them — the comment-marker strip in `prose_gate_lines`, the
# `-F` literalness, the forward half of `prose_window`'s span, the `## Heading`
# carve-out, and every misuse guard. Each is here because a FUTURE site will
# need it, so each is pinned against a fixture rather than against the repo's
# present contents.
#
# One exception, stated so nobody "simplifies" it on this file's authority: the
# EMPHASIS strip in `prose_gate_lines` IS load-bearing today, for
# bootstrap/SKILL.md's `the **resolved** language set is empty` — removing it
# takes tests/iac-selection-rule.bats's statement count from 8 to 7 and reds
# there, not here.
#
# Every case writes its own fixture into $BATS_TEST_TMPDIR: the point is to test
# the helpers, not the repo, and a fixture cannot drift underneath the assertion
# the way a real restatement site can.

bats_require_minimum_version 1.5.0

load assertions
load prose-lockstep

setup() {
  F="$BATS_TEST_TMPDIR/fixture"
}

# --- prose_body -------------------------------------------------------------

@test "prose_body strips one comment marker so a clause wrapped across two # lines matches (#1432)" {
  # the motivating case: the workflow-template header wraps mid-clause
  printf '# the rule exempts only a step\n# carrying the byte-identical condition\n' > "$F"
  run prose_body "$F"
  [ "$status" -eq 0 ]
  contains "$output" 'exempts only a step carrying the byte-identical condition'
}

@test "prose_body keeps a # on a markdown heading (#1432)" {
  # one marker and one space at most, so a heading stays recognisable as one
  printf '## Heading\n' > "$F"
  run prose_body "$F"
  contains "$output" '# Heading'
}

@test "prose_body normalises a shebang to a bare bang, as its header says (#1432)" {
  # pinned because the header makes a promise about it: never write a needle
  # containing `#!`, because this is what the haystack looks like
  printf '#!/usr/bin/env bash\n' > "$F"
  run prose_body "$F"
  contains "$output" '!/usr/bin/env bash'
  lacks "$output" '#!/usr/bin/env bash'
}

@test "prose_body strips markdown emphasis and code ticks (#1432)" {
  # the same sentence is bolded differently at every site; a needle carrying
  # either spelling would pass on one and fail on the other
  printf 'carrying an **`if:` guard exempts only** a step\n' > "$F"
  run prose_body "$F"
  contains "$output" 'carrying an if: guard exempts only a step'
}

@test "prose_body fails CLOSED on an absent file rather than returning empty (#1432)" {
  # the whole point: an empty string reads as "this site is clean", so an
  # unreadable site must be a typed failure, not silence
  run --separate-stderr prose_body "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  # nothing on STDOUT — a caller reading the prose gets no prose at all…
  [ -z "$output" ]
  # …and the reason is named, so the failure is debuggable from a CI log
  contains "$stderr" 'not a readable file'
}

@test "prose_body refuses a wrong argument count (#1432)" {
  run prose_body
  [ "$status" -eq 2 ]
}

# --- prose_window -----------------------------------------------------------

@test "prose_window reaches BOTH sides of the target line (#1432)" {
  # the forward half is the one no current site exercises — every restatement
  # today keeps its marker on or above the gate line, so a one-sided window
  # would pass the whole suite
  printf 'above2\nabove1\nTARGET\nbelow1\nbelow2\nbelow3\n' > "$F"
  run prose_window "$F" 3 2
  [ "$status" -eq 0 ]
  contains "$output" 'above2'
  contains "$output" 'below2'
  lacks "$output" 'below3'
}

@test "prose_window clamps the low bound at line 1 (#1432)" {
  # a statement in the first two lines must not produce a negative sed address
  printf 'TARGET\nbelow1\n' > "$F"
  run prose_window "$F" 1 2
  [ "$status" -eq 0 ]
  contains "$output" 'TARGET'
}

@test "prose_window refuses a non-numeric line instead of an arithmetic crash (#1432)" {
  # `grep -n` on a file grep deems binary prints "Binary file ... matches", and
  # that string reaching the arithmetic is a bash SYNTAX error whose message
  # names arithmetic rather than the file
  printf 'x\n' > "$F"
  run prose_window "$F" 'Binary file (standard input) matches' 2
  [ "$status" -eq 2 ]
}

@test "prose_window fails CLOSED on an absent file (#1432)" {
  run --separate-stderr prose_window "$BATS_TEST_TMPDIR/does-not-exist" 1 2
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a readable file'
}

# --- prose_gate_lines -------------------------------------------------------

@test "prose_gate_lines returns 1-based line numbers of the normalised match (#1432)" {
  printf 'nope\nnope\nthe GATE PHRASE here\nnope\n' > "$F"
  run prose_gate_lines "$F" 'GATE PHRASE'
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "prose_gate_lines finds a gate whose span is BROKEN by emphasis (#1432)" {
  # The emphasis must fall INSIDE the needle's span or the case proves nothing:
  # `# a **GATE PHRASE** in a header` with needle `GATE PHRASE` matches the RAW
  # line too, so that shape passes with `tr -d '*`'` deleted. Splitting the
  # needle across the markers is what makes the assertion discriminate.
  #
  # This strip is load-bearing in production, not just here: bootstrap/SKILL.md
  # states one selection statement as `the **resolved** language set is empty`,
  # so dropping it takes the IaC tripwire's statement count from 8 to 7.
  printf '# a GATE **PHRASE** in a script header\n' > "$F"
  run prose_gate_lines "$F" 'GATE PHRASE'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "prose_gate_lines matches the needle LITERALLY, not as a regex (#1432)" {
  # -F: no current gate carries a metacharacter, so its loss is invisible today
  printf 'a.c\nabc\n' > "$F"
  run prose_gate_lines "$F" 'a.c'
  [ "$output" = "1" ]
}

@test "prose_gate_lines reports every matching line, not just the first (#1432)" {
  printf 'GATE\nnope\nGATE\n' > "$F"
  run prose_gate_lines "$F" 'GATE'
  # the EXACT two lines: a single-digit needle is satisfied by any line number
  # containing that digit, so `contains 1` would also pass on 13 or 31
  [ "$output" = "1
3" ]
}

@test "prose_gate_lines refuses an EMPTY needle rather than matching every line (#1432)" {
  # the assertions.bash doctrine: a dropped or renamed gate constant must be a
  # loud failure, never a sweep that suddenly matches everything
  printf 'a\nb\n' > "$F"
  run --separate-stderr prose_gate_lines "$F" ''
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'needle must be non-empty'
}

@test "prose_gate_lines fails CLOSED on an absent file (#1432)" {
  run --separate-stderr prose_gate_lines "$BATS_TEST_TMPDIR/does-not-exist" 'GATE'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a readable file'
}

# --- misuse guards, from the direction that exercises them ------------------
#
# A zero-argument call is the WRONG direction to test an arg-count guard:
# `_prose_lockstep_readable ""` already returns 2, so the guard could be deleted
# and the case would still pass. Too MANY arguments is the direction where
# deleting it changes behaviour, and each case needles the guard's own message,
# so it cannot pass on a sibling arm that also returns 2.

@test "prose_body refuses TWO files rather than silently reading the first (#1432)" {
  printf 'alpha\n' > "$F"
  printf 'beta\n' > "$F.2"
  run --separate-stderr prose_body "$F" "$F.2"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'prose_body needs exactly one file'
}

@test "prose_window refuses TOO FEW arguments (#1432)" {
  # kept for the MESSAGE, which is what discriminates the arity arm from the
  # `bad span` arm — but it does not pin the arity, see the next case
  printf 'a\nb\nc\n' > "$F"
  run --separate-stderr prose_window "$F" 2
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'prose_window needs a file, a line and a span'
}

@test "prose_window refuses FOUR arguments rather than ignoring the fourth (#1432)" {
  # the direction that actually pins EXACT arity: relax the guard to `-ge 3`
  # and the too-few case above still trips it and still prints the same
  # message, so only this case reds. A caller passing a stray fourth argument
  # — a needle where a span was meant — would otherwise get silent truncation
  # instead of the typed 2 the library promises.
  printf 'a\nb\nc\n' > "$F"
  run --separate-stderr prose_window "$F" 2 1 EXTRA
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'prose_window needs a file, a line and a span'
}

@test "prose_window refuses a non-numeric SPAN, naming the span (#1432)" {
  # distinct from the bad-line case: both return 2, so only the message tells
  # them apart, and the span guard had no case of its own
  printf 'a\nb\nc\n' > "$F"
  run --separate-stderr prose_window "$F" 2 x
  [ "$status" -eq 2 ]
  contains "$stderr" 'bad span'
}

@test "prose_window's bad-line diagnostic names the LINE, not the span (#1432)" {
  printf 'a\n' > "$F"
  run --separate-stderr prose_window "$F" nope 2
  [ "$status" -eq 2 ]
  contains "$stderr" 'bad line number'
}

@test "prose_gate_lines refuses THREE arguments rather than ignoring the third (#1432)" {
  printf 'GATE\n' > "$F"
  run --separate-stderr prose_gate_lines "$F" 'GATE' 'EXTRA'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'prose_gate_lines needs a file and a needle'
}

@test "prose_gate_lines survives a NUL byte instead of reporting a binary match (#1432)" {
  # without `grep -a` this returns "Binary file (standard input) matches", which
  # `cut` turns into a non-numeric "line number" — a silent skip of the site
  printf 'first\000line\nthe GATE PHRASE here\n' > "$F"
  run prose_gate_lines "$F" 'GATE PHRASE'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "prose_window strips an INDENTED comment marker when joining a wrapped clause (#1432)" {
  # The shape every YAML and workflow header actually uses. Pinned against
  # prose_WINDOW, not prose_gate_lines: the strip there can only ever remove a
  # PREFIX, and `grep -F` is a substring search, so on a suffix it can lose a
  # hit but never create one — no fixture can make it discriminate. In the
  # window the strip IS observable, because the whitespace collapse would
  # otherwise leave the marker mid-string ("... an if: # guard does ...") and no
  # needle could span the wrap.
  printf 'x\n      # the rule exempts only a step\n      # carrying the condition\nx\n' > "$F"
  run prose_window "$F" 2 1
  [ "$status" -eq 0 ]
  contains "$output" 'exempts only a step carrying the condition'
}
