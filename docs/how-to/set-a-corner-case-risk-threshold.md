# Set a corner-case risk threshold for review residue

When the [local review loop](../explanation/review-loop.md) ends **with
residue** — converged, but with non-critical blockers left over —
`/development:resolve-issue` opens the PR and files every remaining blocker as a
`review-residue` follow-up issue. Each
of those, once resolved, runs its own review loop — which can file residue of
its own. Epic #1795 grew from 3 children to 21 that way, and most of the
follow-ups described corner cases nobody would ever hit.

`corner_case_risk_threshold` sets a floor. Before filing, the run assesses each
remaining blocker's **risk** — how likely it is, times how bad it would be — and
does not file the ones below your floor. It lists them in the PR instead, so you
can see what was dropped and why.

## Turn it on

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "corner_case_risk_threshold": "0.05"
  }
}
```

The next `/development:resolve-issue` run uses it, in every review round and
again when it files residue. As with
any `env` setting, restart the session if a mid-session edit does not seem to
apply.

## Choose a value

The value is a decimal from 0 to 1 — a risk, not a percentage.

| Value | State |
| ----- | ----- |
| unset, `""`, `0` (or `0.0`) | **off** — every residual blocker is filed, exactly as before |
| `0.001` … `1` (at most three decimals; `.05` and `1.0` work too) | **on** |
| anything else — `30`, `1.5`, `-0.1`, `0.0005`, `abc` | **ignored**, and the run says so |

An ignored value fails safe to "file everything": a percent-style `5` or `30`
never silently drops the whole remainder, and the PR says the value was ignored.

Risk is `p × impact`, so a useful floor is small. As a guide, from a
retrospective assessment of #1795's 15 residue issues:

| Threshold | Filed | Dropped |
| --------- | ----- | ------- |
| off | 15 | 0 |
| `0.05` | 4 | 11 |
| `0.1` | 3 | 12 |

At `0.05` the survivors included a finding that was only 10% likely but would
have made a failing gate report green (impact `1.0`, risk `0.10`) — the case the
impact half exists to keep.

## How each finding is assessed

**Probability `p`** — from 0 to 1, two decimals at most:

- for a **test** finding ("this mutation still passes", "this branch is never
  tested"): how likely a plausible future change breaks exactly that unpinned
  behaviour without another test catching it;
- for **any other** finding: how likely the described situation actually
  arises in real use of the repository.

**Impact** — one of four fixed values, the highest the consequence reaches:

| Impact | Consequence |
| ------ | ----------- |
| `1.0` | a false result that is trusted (a green gate, a passing check, a merged PR that should have failed), data loss, or a security exposure |
| `0.7` | a hang, runaway resource use, or a shipped pipeline or skill that does the wrong thing |
| `0.4` | misleading output, or a run that needs a manual retry or a human to notice |
| `0.1` | cosmetic, or a test-only nicety |

A finding whose risk is **equal to** the threshold is kept. A finding the run
did not assess is kept too — only an explicit assessment below the floor drops
anything.

## What you see in the PR

A PR whose residue had findings dropped carries a **Dropped by the risk
threshold** paragraph above the review dossier: one row per dropped finding with
its probability, impact, risk and the reasoning behind both. The dossier itself
still counts them as open, so the paragraph is what tells you they were **not**
filed. If you disagree with an assessment, file that finding by hand.

## What it does inside the review loop

The same floor applies to every review round, not only to residue (#1921). The
loop no longer spends fix rounds on a corner case below your floor.

In each round, the run assesses every blocking finding the reviewers raised,
using the same probability and impact rules. A **Warning** whose risk is below
the threshold is **demoted to a suggestion**: it is logged, it is not fixed, and
it no longer stops the loop converging.

Some findings are never demoted, however low their risk:

- a **Critical** finding;
- a suggestion you promoted yourself;
- a finding a tool actually confirmed.

A demoted finding never disappears:

- **Progress log:** the round's block has a `demoted by risk threshold` line,
  then one line per finding with its probability, impact and risk.
- **PR body:** a **Demoted by the risk threshold** table above the waived
  suggestions lists each finding with its assessment and reasoning.
- **Promotion prompt:** at convergence, the suggestion-promotion prompt offers
  demoted findings back like any other suggestion. Pick one to have the loop fix
  it after all. A finding that blocked in an earlier round before it was
  demoted is not offered; it appears only in the PR table.

If you turned the promotion prompt off (`enable_suggestions`), the progress log
and the PR table are the only places a demotion shows.

A finding the loop already assessed is not assessed again when it ends up as
residue: the residue filter reuses the loop's assessment. A finding the loop
assessed but never demotes — a Critical, your own pick, a tool-confirmed one —
is kept at residue too, whatever its risk.

## What it does not touch

The floor does not change when a run ends in residue. It also does not change
how the review dossier's machine-readable block counts residue it dropped: that
block still counts those findings as open. Carrying a separate dropped count
there is #1932.

The procedures the run follows are in `development/skills/resolve-issue/reference/`:

- `review-loop.md`, section *The risk pass*;
- `residue.md`, section *Risk threshold — assess before filing*.
