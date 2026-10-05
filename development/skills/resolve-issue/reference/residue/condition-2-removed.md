<!-- Shard of reference/residue.md (#2056), read when a residue condition
     is in question: why condition 2 is gone. -->

## Condition 2 — removed; the story-diff rail is upstream (#1571)

The residue terminal once took **three** conditions. It now takes **two** —
condition 1 (the last two rounds are both zero-CRITICAL) and condition 3 (the
declaring round ran as a full sweep). Condition 2 —

> every remaining blocking finding's `.file` is in the **previous** round's
> fix-touched set

— was **removed**. Nothing replaced it, and the numbering keeps its gap on
purpose: every other surface names the survivors as 1 and 3, so renumbering 3
to 2 would silently repoint them at the condition that was deleted.

**The guarantee it stood for still holds — one step earlier.** Its purpose was
that residue lives in what *this story* wrote, never in shipped behaviour nobody
has just rewritten. That is enforced by `review-dispatch.zsh scope-findings`,
which filters **every** round's findings to the story diff (`_changed_files`:
`git diff --name-only <base>` plus `ls-files --others --exclude-standard`)
before consolidation. The filtered array `$scoped` is the **only** input to the
changelist's `.blocking` — the fix-verification carry goes to `plan`, never to
the consolidator. So every blocker that can reach `_residue_holds()` is in the
story diff **by construction**, and a blocker in a file this run never opened is
dropped long before it could become residue.

Re-testing that inside the predicate would be a test that can never fail, which
is worse than no test: it reads as a rail while guaranteeing nothing.

**Why the round-granular reading had to go.** A zero-blocking delta round
promotes the closing sweep and runs **no fix pass**, so the loop deliberately
writes it an empty fix-touched set (that empty write is load-bearing, and for a
narrower reason than it looks: an **empty** set is a real answer, so every
blocker the sweep raises is stamped `new_defect`, whereas an **absent** file
makes the loop omit `--fix-touched` and stamp nothing at all. Writing it is what
keeps hook mode and step mode agreeing on which of those two the sweep is).
Against an empty set every blocker counts as "outside" — so condition 2 was
false *by construction on precisely the path that earns the sweep*, and the
terminal built for the closing sweep was unreachable from the closing sweep.
That is why `CONVERGED_WITH_RESIDUE` never fired in the #1558 session even
though its sweeps were zero-CRITICAL twice.

**What is deliberately NOT changed.** The fix-touched capture stays exactly as
it was. It still feeds `consolidate-findings.zsh --fix-touched`, which stamps
each blocker's `class` (`new_defect` / `incomplete_propagation`) for the progress
histogram and the grant decision, and it still keys the waived-suggestion
exemption in `review-loop/step-1-panel.md`. Those are different consumers; deleting the
capture because the residue predicate stopped reading it would blank every
blocker's `class`. `scope-findings` is not changed either — this rule *relies*
on it, and pins it with a test rather than touching it.
