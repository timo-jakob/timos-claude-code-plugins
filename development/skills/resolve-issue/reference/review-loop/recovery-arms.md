<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the verdict recovery arms, moved verbatim out of subagents.md (#3293). -->

#### Verdict recovery arms (#1937)

This is the one statement of what the conductor does with a non-`ok` panel
verdict, and with the loop's CARRY-UNACCOUNTED, CADENCE and never-ran
refusals. Each row names an arm
that already exists; for its reasoning read that arm, which is not restated
here.

**A non-`ok` panel verdict is boundary step 3 refusing or aborting the round.**
Stop the gate with the handle step 2 recorded, then take the arm below. An arm
that resumes the round resumes at step 1, except on a no-fix round, exactly as
step 3 says. **A non-`ok` verdict from a `carry-repair` or `carry-redispatch`
panel takes no row:** its gate has already finished, so nothing is stopped or
resumed, and it is that ground's cap — report-and-stop.

**Dispatch on `cause`.** `not-applicable` and `story-diff-empty` pair with
`not_applicable`; the other nine causes pair with `failed`. A verdict whose
outcome/cause pair is off this table is report-and-stop.

| `cause` | `outcome` | arm |
|---|---|---|
| `dimension-not-run`, `render-failed` | `failed` | step 2's **FAILED** arm: one fresh round-mode panel; the same cause again is report-and-stop |
| `fix-verification-null` | `failed` | the FAILED arm's null carry: re-run the carry precondition on `verify-<R>.json`, then one fresh round-mode panel, whose brief plans with `--fix-verification`; the same cause again is report-and-stop |
| `fix-verification-unreadable` | `failed` | the FAILED arm's unreadable carry: re-run the carry precondition — an unreadable `verify-<R>.json` is report-and-stop — then one fresh round-mode panel; the same cause again is report-and-stop |
| `carry-unconfirmed` | `failed` | the **missing-confirmation** arm: one fresh round-mode panel, and "if the re-run again reports no confirmation count, report it in the conversation and stop" |
| `plan-failed` | `failed` | report-and-stop: the panel brief has already fixed and re-run a `plan` exit 2 once |
| `wrong-worktree-root` | `failed` | report-and-stop: the panel brief has already re-planned against the implementation worktree |
| `empty-excerpt` | `failed` | report-and-stop: the panel brief has already applied *An empty excerpt is not always a stop*, and a fresh panel "fails the same way" |
| `no-agent-tool` | `failed` | report-and-stop |
| `not-applicable` | `not_applicable` | fires only when the fallback panel is NOT APPLICABLE or unavailable, or on a round that never engages it (#2909): the panel brief has already routed the repo-type panel's NOT APPLICABLE to the fallback wherever the round engages it. Then the **NOT APPLICABLE on a full round** arm: autonomous, stop with no commit and no PR; interactive, its three options, none taken without an explicit choice. Never coerced to `[]`, and the panel is not re-run |
| `story-diff-empty` | `not_applicable` | the **empty story diff** shape: go back to **§2 (Implement)** and take the boundary again, or, if the story needs no code change, say so and stop. The three NOT APPLICABLE options are never offered, and, per the #1485 note, neither the re-invoke arm nor the panel re-run arm is taken |

Whether a human is present is §0a's determination, read from
`scripts/resolve-session.zsh`: `attended` takes the interactive arm, `unattended`
takes the autonomous arm and never prompts.

**The never-ran arm is not a verdict.** It applies only when the conductor can
show that no panel subagent was dispatched this round — on a missing/empty
STALE_FINDINGS refusal, say. Dispatch one round-mode panel, then a decide
subagent over its aggregate, then re-invoke. A
panel that was dispatched and returned no valid verdict is a stall, not
never-ran.

**CARRY-UNACCOUNTED.** A mid-run exit 2 on that arm takes this section. Read the
ground from the loop's refusal stderr and the status JSON's
`carry_unconfirmed[]` — loop output, never reviewer output. The #1647
tool-verdict exception applies only on the *neither confirmed nor re-raised*
ground, and only to an entry the refusal names in `carry_unconfirmed[]`: such
an entry stamped `"decided": "red"` in
`verify-<R>.json`, or one the *Decide subagent brief*'s narrow `decided-<R'>.log`
lookup finds a red for, is a tool-verdict carry — report it and its `decides:`
command and stop, dispatching nothing. It reaches no other entry and no other
ground: the three `carry-repair` grounds and an unevidenced re-raise never take
it, whatever else `verify-<R>.json` holds. Otherwise, by ground (*Carry
accounting → Recover by ground*):

- **no accounting supplied, a file of the wrong shape, a record naming no
  carried identity** → one panel in **`carry-repair`** mode, `carry_entries`
  every carried identity projected from `verify-<R>.json`. On `ok`, re-invoke
  with the same `--findings-file` and the rebuilt `--carry-accounting`; no
  decide dispatch follows;
- **an unevidenced re-raise, an entry neither confirmed nor re-raised** → one
  panel in **`carry-redispatch`** mode, `carry_entries` the refused identities
  only. On `ok`, dispatch a decide subagent over the merged aggregate, then
  re-invoke.

The cap is that arm's own, per ground: "If the re-run again leaves an entry
unaccounted, report it in the conversation and stop". A different ground takes
its own arm once.

**A stalled `carry-redispatch` is restored, not re-merged.** Before that
dispatch, copy `findings-round-<R>.json` and `carry-lines-<R>.txt` to
`<work-dir>/findings-round-<R>.pre-carry.json` and
`<work-dir>/carry-lines-<R>.pre-carry.txt` without opening them, and before its
stall re-dispatch restore both over the originals, so the retry merges and
appends exactly once. A failed copy or restore is report-and-stop.
`carry-repair` takes no snapshot: it only reads the lines and rebuilds the
accounting, so a re-dispatch repeats it exactly.

**Every recovery is a fresh subagent with a fresh handoff.** The FAILED re-run,
the missing-confirmation arm, the never-ran arm and the CADENCE re-run dispatch
in `round` mode, reusing the original `delta_base` and `carried_finding_ids`
with `carry_entries` `[]`. Before every recovery dispatch, rewrite
`handoff-<R>-panel.json` with `round-handoff.zsh write-handoff` and clear as
*Before every dispatch, clear* says for its mode, which always deletes the
previous `verdict-<R>-panel.json`, so a stalled recovery reads as a stall and
never as the superseded verdict.

**The CADENCE refusal, in full.** First the *Decide subagent brief*'s sequence,
unchanged. Then, for the panel re-run recovery: mint a fresh `--findings-tree`,
dispatch a new round-mode panel, dispatch a decide subagent over its aggregate,
and consolidate with the fresh `--findings-tree` and the **held**
`--gate-attest`, or with it omitted — never the fresh mint. The other recovery,
discarding the fix and re-consolidating, dispatches no panel.

**Caps and the stall retry are separate.** Each arm's cap is its own, and never
the stall retry. The stall retry applies to every recovery dispatch as to any
other — for a `carry-redispatch`, after the snapshot restore — and a recovery
dispatch neither consumes nor resets it. A verdict that validates but is not
`ok` is never a stall.
