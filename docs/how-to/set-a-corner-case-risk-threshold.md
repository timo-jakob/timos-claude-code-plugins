# Set a corner-case risk threshold

The [local review loop](../explanation/review-loop.md) stops only when the
reviewers have no blockers left. Many of the warnings a panel raises describe
corner cases nobody would ever hit, and without a floor every one of them costs
a fix round. In epic #1795 the runs that could not clear such warnings filed them
as follow-up issues, and the epic grew from 3 children to 21 that way. That
ending is retired (#2580): a run now either converges or stops.

`corner_case_risk_threshold` sets a floor. In every review round the run assesses
each blocking finding's **risk** — how likely it is, times how bad it would be —
and demotes a non-critical one below your floor to a suggestion: logged and
listed in the PR, but not fixed.

## Turn it on

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "corner_case_risk_threshold": "0.05"
  }
}
```

The next `/development:resolve-issue` run uses it, in every review round. As with
any `env` setting, restart the session if a mid-session edit does not seem to
apply.

## Choose a value

The value is a decimal from 0 to 1 — a risk, not a percentage.

| Value | State |
| ----- | ----- |
| unset, `""`, `0` (or `0.0`) | **off** — no finding is demoted, exactly as before |
| `0.001` … `1` (at most three decimals; `.05` and `1.0` work too) | **on** |
| anything else — `30`, `1.5`, `-0.1`, `0.0005`, `abc` | **ignored**, and the run says so |

An ignored value fails safe to "demote nothing": a percent-style `5` or `30`
never silently waves every warning through, and the PR says the value was
ignored.

Risk is `p × impact`, so a useful floor is small. As a guide, from a
retrospective assessment of the 15 non-critical blockers #1795's runs left over:

| Threshold | Still block | Demoted |
| --------- | ----------- | ------- |
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

A finding whose risk is **equal to** the threshold still blocks. A finding the
run did not assess blocks too — only an explicit assessment below the floor
demotes anything.

## What it does inside the review loop

The floor applies to every review round (#1921), so the loop no longer spends
fix rounds on a corner case below your floor.

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

## A higher bar in extra rounds

When a run spends its whole round budget and is granted more rounds — by you,
or automatically when it is converging (#2576) — those **extension rounds**
apply a higher floor (#2577). Extra rounds only finish a run if they stop
finding new low-impact blockers faster than they fix them, so a Warning has to
be riskier to block there.

```json title="~/.claude/settings.json"
{
  "env": {
    "corner_case_risk_threshold": "0.04",
    "extension_risk_threshold": "0.10"
  }
}
```

| `extension_risk_threshold` | Extension rounds use |
| -------------------------- | -------------------- |
| unset or `""` | the default, `0.10` |
| `0.001` … `1` | that value |
| `0` (or `0.0`) | the extension bar is **off**: the normal floor, exactly like other rounds |
| anything else | the default, `0.10`, and the PR says the value was ignored |

The floor in an extension round is the **higher** of `corner_case_risk_threshold`
and `extension_risk_threshold`, so it is never lower than in a normal round. It
applies even when `corner_case_risk_threshold` is off. Criticals, your own picks
and tool-confirmed findings are still never demoted.

The one extra round a run gets to re-check everything after its last clean round
is not an extension round unless a grant paid for it, so it keeps the normal
floor.

A finding demoted this way shows like any other, marked with the bar: the
progress log reads `demoted by the extension bar (effective threshold = 0.10)`,
and its row in the PR table says `extension bar, threshold 0.10`.

**Why 0.10.** Across 576 assessments the risk pass wrote in 174 rounds, 58% were
below `0.04`, 81% below `0.10` and 91% below `0.15`. At a floor of `0.04`, 243 of
them block; at `0.10`, 109 still do.

## Where the procedure lives

The procedure the run follows is in `development/skills/resolve-issue/reference/`:
`review-loop/risk-pass.md`, section *The risk pass*.
