<!-- Shard of reference/residue.md (#2056), read in its index's order:
     the risk threshold, read before step 1. -->

## Risk threshold — assess before filing (#1920)

The steps this section names are the residue branch's steps 1–5. They are in
`reference/residue/step-1-plan.md`, `reference/residue/steps-2-3.md` and
`reference/residue/steps-4-5.md`.

**First read the variable — it is invisible until you do.** It lives in the
environment your shell commands inherit (a maintainer sets it in their
settings' `env`), so nothing in the conversation shows it. Read it with a
command that expands nothing, so no worktree guard refuses it:

```bash
printenv corner_case_risk_threshold   # exit 1 → unset
```

Then take exactly one of three states — the builder parses the value the same
way:

- **Off — unset, empty, or any spelling of zero (`0`, `0.0`, `.000`).** Skip
  the rest of this section: make no assessment, pass no new flag, and the
  residue branch's step shards run exactly as written.
- **Ignored — set to anything else that is not a decimal in [0, 1] with at most
  three decimals** (`30`, `1.5`, `-0.1`, `0.0005`, `abc`). Behave exactly as off
  — no assessment, no new flag — but say so in the PR Summary in one line naming
  the value, so the maintainer learns the setting did nothing. The builder says
  so on stderr too; that is a run log, not the PR.
- **On — any other value** (`0.05`, `.05`, `1`). Everything below applies.

If the builder ever prints `corner_case_risk_threshold is set but no --risk
assessment was given`, you misread the state: go back to step 1 below, assess,
and re-run the builder. Never proceed on that plan — it files every blocker the
maintainer's floor was set to drop.

Why it exists: every residual blocker used to be filed, however unlikely or
harmless, and each filed issue runs its own review loop that can file more —
epic #1795 grew from 3 children to 21 that way. The threshold lets the
maintainer set a floor on **risk**, and everything below it is reported, not
filed.

### 1. Assess every residual blocker — before step 1

**Assess only what the loop has not already assessed (#1921).** With the
threshold on, the loop's risk pass (`review-loop/risk-pass.md` § *The risk pass*) assessed
every blocking finding afresh each round, and the consolidator stamped each
one's changelist entry with `risk_assessment` — so the final changelist carries
the final round's judgement. A residual blocker that carries that stamp is **not
assessed again**: the builder reuses the stamp's `p` and `impact` against the
current threshold (its dropped record says `assessed_in: "loop"`), and a
`--risk` entry naming a stamped finding is exit 2 (*already assessed in the
loop*). A stamp below its own recorded threshold marks a blocker the loop kept
on purpose — a `CRITICAL`, a tool red, a human pick, a partly assessed group —
and the builder keeps it too. So the set to assess here is the residual
blockers **without** a stamp — typically none in step mode — and when there are
none you still pass `--risk`, holding `[]`, so the builder applies the stamps
and writes the dropped record.

For each **unstamped** finding in the BLOCKING phase's final changelist
`.blocking` (the same file step 1 passes as `--changelist`), record two values,
each with a one-line rationale:

**Probability `p`** — a decimal in [0, 1] with at most two decimals. Which
definition applies follows the finding's `dimension`:

- **`tests`** (a test-strength finding — "mutation X still passes", "branch Y
  is never tested"): the probability that a plausible future change breaks
  exactly that unpinned behaviour without another test catching it.
- **every other dimension** (a defect finding): the probability that the
  described input or state actually arises in this repository's real use.

**Impact** — exactly one of four anchors, the **highest** the consequence
reaches:

| `impact` | consequence if it happens |
|---|---|
| `1.0` | a false result that is trusted — a green gate, a passing check or a merged PR that should have failed; data loss; a security exposure |
| `0.7` | a hang, runaway resource use (CPU, processes, API quota), or a shipped pipeline or skill that does the wrong thing |
| `0.4` | degraded or misleading output, or a run that needs a manual retry or a human to notice and correct it |
| `0.1` | cosmetic, or a test-only nicety with no behavioural consequence |

For a test-strength finding, impact is the impact of the **defect the unpinned
behaviour would let through**, never of the test gap itself.

**Risk** is `p × impact`. A finding is **kept** (filed) when `risk >=
threshold`, **dropped** when `risk < threshold`. The builder computes this in
integer thousandths (`p` in hundredths × `impact` in tenths), so a risk exactly
at the threshold is kept and no floating-point rounding moves a finding across
it. You judge; the builder does the arithmetic — never pre-filter the
changelist yourself.

Write the assessment to `<scratch>/residue-risk.json` — outside the worktree,
for the reason step 1 gives — as one JSON array, one entry per finding, keyed by
the loop-wide finding identity (`file`, `line`, `dimension`, `title`, copied
**verbatim** from the changelist entry, `line` included when it is `null`):

```json
[ { "file": "tests/x.bats", "line": 42, "dimension": "tests",
    "title": "<the changelist entry's title, verbatim>",
    "p": 0.05, "p_why": "…", "impact": 0.4, "impact_why": "…" } ]
```

A finding you leave out is **kept** — a missing assessment never drops anything
— and an entry whose identity matches no finding assesses nothing (the builder
names it on stderr; fix the identity and re-run if you meant to assess that
finding).

### 2. Amendments to the frozen branch

- **Step 1 and step 2** — add `--risk <scratch>/residue-risk.json
  --dropped-file <scratch>/residue-dropped.json` to **both** invocations, the
  real plan and the `--dry-run`. The builder drops the same set in both, before
  either is built, so step 2's length diff still measures only the idempotency
  filter. An **exit 2** naming `--risk` is your own malformed assessment (a `p`
  with three decimals, an impact off the four anchors, a blank rationale, a
  duplicate identity, an entry for a finding the loop already stamped) — the
  message names the entry; fix it and re-run. It is
  never "file everything" or "file nothing".
- **Step 1's exit-1 handling** — the builder has exit-1 causes that name
  neither `--status` nor `--changelist`: `could not write --dropped-file`,
  `could not create a temp file`, `could not write the filtered changelist`,
  `could not build the dropped record`. None of them is the `--status` arm, so
  none of them stops the run with no PR. They are output-side: fix what they
  name (the scratch path, `TMPDIR`) and re-run. If one persists, fall back to
  filing everything: re-run both invocations **without** `--risk` and
  `--dropped-file` and with the variable **blanked for those two calls only**
  (`corner_case_risk_threshold= <builder> …`), so the builder parses it as off
  — then nothing is dropped, every blocker is filed, and the section 1
  guardrail message never fires. Say in the Summary, in one line, that the
  threshold could not be applied and why, and treat the rest of this section as
  off, as the ignored state does — do not read `residue-dropped.json`, which is
  absent or left over. (The one risk-path exit 1 that names
  the changelist, `could not apply the risk threshold to <changelist>`, is the
  frozen `--changelist` arm: that file is what is wrong.)
- **After step 2's `sub_issues` read, settle what the dropped record really
  dropped — before step 3 and before the remainder rule.** Read
  `<scratch>/residue-dropped.json`:
  - **`threshold_state` is `ignored`** → whatever you read in section 1, the
    builder parsed the value as unusable and dropped nothing. Write the ignored
    value's one-line Summary note, and treat the rest of this section as off.
  - **A dropped finding an EARLIER run already filed is not dropped.** The
    threshold can be switched on, and an assessment can move, between two runs
    of one story — and a re-run is exactly what this branch expects after a PR
    that never opened. So look up every dropped record's `issue_title` (the
    title an issue for it would carry) among the `review-residue` issues, and
    classify each exactly as step 3 classifies a builder-filtered candidate,
    because that is what it is. Run the repo-wide listing **once, on its own**
    (`gh issue list --label review-residue --state all --limit 200 --json
    number,title > <scratch>/residue-listing.json`) and note its exit status
    before matching anything — the arm-2 snippet pipes it into `head`, which
    hides a failed listing behind an empty match. Then take the arms **in
    order; the first arm that settles a record settles it**:
    - a sub-issue of **this run's parent** (step 2's `sub_issues` read) →
      **filed**, from an earlier run: it rejoins the remainder as a
      pre-existing follow-up, and step 5 names its number;
    - present in the repo-wide listing but not settled by arm 1 (absent from
      step 2's read, or that read failed) — matched against
      `<scratch>/residue-listing.json`, never by running the listing again → it
      rejoins the remainder and takes **step 3's arm 2**: take its number from
      that file, run only that arm's `read-sub-issues.zsh --child` read for its
      parent, and settle it by **all** of that arm's own sub-arms, exactly as
      written there — including its *any other non-zero* sub-arm, which counts
      the record untracked. A `--child` read that fails never sends a
      listing-matched record to the arm below;
    - **a lookup that did not happen** — a read this record needed exited
      non-zero: **only** step 2's `sub_issues` read, or (for a record absent
      from it) the repo-wide listing; the `--child` read belongs to the arm
      above and is settled there — → it **stays dropped**, and the Summary says in one
      line that its earlier-run status could not be checked. A record an earlier
      arm settled is never moved here by a failure that did not concern it.
      Step 3's read-failed arm (*count the builder-filtered set as filed*) does
      **not** apply here: a dropped record was never filtered by the builder's
      idempotency read, so there is no filtered set to credit;
    - found nowhere, both reads having succeeded → it **stays dropped**.
- **Everywhere the branch says *the remainder*** — `final_changelist.blocking`,
  the candidates, the blockers the remainder rule counts, the set step 3's arms
  match — read it as that set **minus the records that stay dropped** after the
  settling above. That is the only definition: a record that rejoined is in the
  remainder and counted like any other; a record that stays dropped is neither
  filed nor untracked — its own row, decided on purpose.
- **Step 3** — an empty plan **and an empty `--dry-run`** are legitimate
  **because every candidate was dropped** only when both hold: the dropped
  record's `dropped` array is **non-empty** — the builder dropped at least one
  finding, whatever the settling then did with it — and every entry of the
  status JSON's
  `final_changelist.blocking` is among the dropped records — whether it stays
  dropped or rejoined, as filed or as untracked (matched by `file`, `line`,
  `dimension` and `title`). A record that rejoined is still absent from both
  lists, because the builder drops it before either is built; only a blocker
  that **no** dropped record covers makes an empty dry-run suspect. This overrides
  the frozen *dry-run list is itself EMPTY* arm, whose "anomaly, always" was
  written before anything could drop a candidate. When every dropped record
  rejoined, the remainder is the whole set and the remainder rule decides its
  row — an all-filed rejoin is the **all** row, naming the pre-existing numbers,
  with no dropped table. With an **empty** `dropped` array, an empty dry-run is
  still that anomaly arm — the changelist you passed is the suspect — because
  "every candidate was dropped" is vacuously true of no candidates.
- **An EMPTY remainder takes no remainder-rule row.** When every blocker stays
  dropped, the rule's rows all read vacuously true, and its fail-closed clause
  would pick the verbatim *They were NOT filed on this run* disclaimer —
  presenting a deliberate drop as a filing failure. Do **not** write that
  disclaimer. The Summary carries step 5's paragraph and one line: `0 filed,
  <dropped> dropped, 0 untracked of <open> open`.
- **Step 5 (the PR body)** — the dossier's residue wording is gated on the
  status alone, so it still says every open blocker was filed as a follow-up.
  When at least one record stays dropped, write this above the dossier,
  verbatim apart from the placeholder, then the table:

  > **Dropped by the risk threshold (`corner_case_risk_threshold` =
  > `<value>`):** the dossier below counts these blockers as open and filed.
  > **They were NOT filed** — each one's risk (probability × impact) is below
  > the threshold. Re-file any of them by hand if you disagree with its
  > assessment.

  | finding | p | impact | risk | why |
  |---|---|---|---|---|

  followed by **each staying-dropped record's `row`, pasted as it is** — never
  re-rendered from its raw fields. The builder renders that row with the
  finding's untrusted text neutralised (newlines and backticks out, pipes
  escaped), which a hand-built row from `title` or `p_why` would not be. Then,
  unless the remainder is empty (above), apply the remainder rule to what is
  left. When the Summary counts the follow-ups against the dossier's `open`,
  state the three numbers — filed, dropped, and (if any) untracked — so they
  sum to `open`.

What this section does **not** change: which runs reach the residue terminal,
and the dossier's residue counts. What the loop fixes before it gets there is
now shaped by the same threshold — a `WARNING` below it is demoted to a
suggestion in the round that raises it (#1921, `review-loop/risk-pass.md` § *The
risk pass*), so it never reaches this section as residue at all; the blockers the
loop never demotes reach it with their stamp, and section 1 says what happens
to them. The dossier's
hidden block still counts a finding dropped **here** in its `open`, which
`approver-policy-core` reads as tracked risk; step 5's paragraph is the only
place that says otherwise, so a reader of the hidden block alone over-counts
what is tracked. Carrying a dropped count in the dossier is the follow-up story
(#1932).
