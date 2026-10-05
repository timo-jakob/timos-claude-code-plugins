<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the risk pass. -->

### The risk pass — assess every blocking finding before consolidating (#1921)

**Assess the round's blockers against `corner_case_risk_threshold` after the
decided pass and before the step-2 invocation.** The #1920 variable sets a floor
on risk (probability × impact). Below it, a finding that clears a reviewer's
blocking bar is logged as a suggestion instead of being fixed. That stops the
fix pass chasing negligible corner cases round after round, the treadmill
measured in the #1435 and #1558 post-mortems. It runs in the same slot as the decided
pass, and like that pass it is recorded here because step 2 sits inside a
byte-frozen span.

While the threshold is on, the risk subagent (*Risk subagent brief* below) makes
the assessment this section describes, and the conductor dispatches it and
passes `--risk`.

**First read the variable.** It lives in the environment and nothing in the
conversation shows it:

```bash
printenv corner_case_risk_threshold   # exit 1 → unset
```

Then take exactly one of the three states `reference/residue/risk-threshold.md` § *Risk
threshold — assess before filing (#1920)* defines, which the scripts parse with
one shared parser (`scripts/risk-threshold-lib.zsh`):

- **Off** (unset, empty, any spelling of zero): skip this pass. Make no
  assessment and pass no `--risk`. The round consolidates exactly as before.
- **Ignored** (not a decimal in [0, 1] with at most three decimals): behave as
  off, say so once in your narration, and write the one-line PR Summary note
  naming the value that `reference/residue/risk-threshold.md` prescribes for this state, once per run,
  whichever terminal the run reaches.
- **On**: in step mode, everything below applies, every round, including the
  promotion sub-loop's rounds and the closing sweep. Hook mode supplies no
  assessment (see below).

**What to assess.** Every finding in the round's panel aggregate, the file you
pass as `--findings-file`, whose severity is `CRITICAL` or `WARNING` after the
decided pass. That includes a finding the decided pass promoted: it is exempt
from demotion, but a stamp still records its risk. Do not assess `SUGGESTION`
findings; they already do not block.

**How to assess.** Record `p` and `impact` with a one-line rationale for each.
Use the definitions `reference/residue/risk-threshold.md` § *1. Assess every residual blocker* gives and
do not restate or vary them here:

- `p` is two decimals, with the test-strength definition for `tests` findings
  and the defect definition otherwise;
- `impact` is exactly one of the four anchors `1.0` / `0.7` / `0.4` / `0.1`.

**Severity and impact are independent.** A reviewer's severity decides only
whether a finding is eligible: `CRITICAL` is never demoted, `WARNING` may be,
and `SUGGESTION` is not assessed. Impact is judged on the consequence alone. A
`WARNING` can carry impact `1.0`, and a `CRITICAL` impact `0.1`. Never cap or
floor one by the other.

**Assess afresh every round.** A finding re-raised in a later round is assessed
again, because the fix pass may have changed how likely it is. Never copy an
earlier round's numbers forward unexamined; the changelist keeps each round's
stamp, so the record shows how an assessment moved. When the aggregate gains
findings after this pass — the carry-accounting recovery below merges a
re-dispatch's output into it — re-dispatch the risk subagent over the merged
aggregate before you re-invoke.

**Write and pass it.** Write the assessment to `<work-dir>/risk-<R>.json`,
outside the repo like every other per-round file. It is one JSON array in the
shape #1920 defined, one entry per assessed finding, with the identity copied
**verbatim** from the aggregate — except a digit-string `line` (`"42"`), which
you write as the number it spells, since the validator accepts only a number or
`null` there:

```json
[ { "file": "tests/x.bats", "line": 42, "dimension": "tests",
    "title": "<the finding's title, verbatim>",
    "p": 0.05, "p_why": "…", "impact": 0.4, "impact_why": "…" } ]
```

Add the file to that round's invocation:

```bash
resolve-story-loop.zsh … --resume --findings-file <…> \
  --risk <work-dir>/risk-<R>.json …   # plus the round's other flags, exactly as the templates above
```

- The loop forwards the file to `consolidate-findings.zsh --risk` for that
  round only.
- A malformed file (a `p` with three decimals, an impact off the anchors, a
  blank rationale, a duplicate identity) is **exit 2** before anything is
  written. The message names the entry: make one fresh risk dispatch whose
  prompt carries that stderr line verbatim, then re-invoke the same round with
  the same flags; a second such exit 2 in the same round is report-and-stop.
  This exit 2 is **not** `STALE_FINDINGS` and writes **no**
  status JSON, so `--status-file` still holds the previous invocation's
  verdict — act on the stderr line alone.
- An entry that matches no `CRITICAL` or `WARNING` finding assesses nothing,
  and the consolidator names it on stderr. A finding you leave out keeps its
  severity, because a missing judgement never demotes anything.
- `--risk` is step-mode only. Hook mode supplies no assessment, so every
  blocker is kept.

**What the consolidator does with it.**

- Every assessed item carries `risk_assessment: {p, p_why, impact, impact_why,
  risk, risk_thousandths, threshold, threshold_thousandths}`, recorded beside
  `decided`.
- A `WARNING` item whose risk is **below** the threshold is **demoted**: it
  moves to `suggestions` with `demoted: true` and never blocks convergence. The
  comparison is in integer thousandths, and a risk exactly at the threshold
  stays blocking.
- **Never demoted**, at any threshold or risk: a `CRITICAL` item, a
  human-promoted item (`promoted: true`), and an item a tool decided red
  (`decided: "red"`, or a red anywhere in its dedup group).
- A dedup group is demoted only when every `WARNING` member was assessed and
  its **highest** member risk is below the threshold.

**Where a demotion shows.** A demoted finding never disappears.

- The round's progress block names it.
- The PR dossier lists it in its own table, above the waived suggestions.
- The suggestion-promotion prompt offers it back like any other waived
  suggestion — under `reference/promotion/gate.md`'s own derivation, which keeps a finding's
  earliest occurrence, so a finding that blocked in an earlier round and was
  demoted later is listed in the dossier table but not offered. With
  `enable_suggestions` off there is no prompt, and the progress block and the
  dossier table are the only records. A pick survives the sub-loop's own risk
  pass: the consolidator demotes before its promotion overlay, which raises the
  pick again.
- The residue branch reuses the final round's stamp instead of assessing a
  blocker a second time (`reference/residue/risk-threshold.md` § *Risk threshold*).
