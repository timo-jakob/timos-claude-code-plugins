# Fixture: a softening phrase SPLIT ACROSS A LINE BREAK (#1186)

NOT the family's position. This file proves one specific property of
`tests/identity-position.bats`'s softening detector, and it is the only file that
can: `ARCHITECTURE.md` is hard-wrapped at roughly 78 columns, so a softening
phrase can straddle a line break, where a `grep -F` over **raw** lines never sees
it. Every needle in `softened-position.md` sits contiguously on one line — which
is what makes that file a good per-needle control and a useless wrap control.

So the guard runs its detection over the **collapsed** rendering as well as the
raw one, and a companion test asserts, against this file, that the raw pass finds
nothing while the collapsed pass fires. Without this fixture that second pass
would be an unproven addition — the permanent-pass class the whole suite exists
to remove.

**Do not reflow the paragraph below.** Its needle is broken mid-phrase on
purpose; joining the lines makes the raw pass find it too, and the test that
asserts raw-misses-collapsed-catches goes red.

Where an ingress gateway fronts the service, the identity headers it forwards may
be
trusted by the handler behind it, so a second validation pass buys nothing.
