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

The next `/development:resolve-issue` run that ends in residue uses it. As with
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

## What it does not touch

Only which residue gets **filed**. It does not change when a run ends in residue,
nor what the review loop fixes before it gets there — applying the floor to the
loop's own findings is planned as a follow-up (#1921). The procedure the run
follows is `development/skills/resolve-issue/reference/residue.md`, section
*Risk threshold — assess before filing*.
