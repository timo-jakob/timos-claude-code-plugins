<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     round subagents and their verdict recovery arms. -->

### Round subagents — the conductor reads only verdicts (#1935)

Each round's heavy work runs in **fresh subagents**, not in the conductor's
context: a **panel** subagent reviews, a **decide** subagent settles the
round's `decides:` claims, a **risk** subagent assesses its blockers while
`corner_case_risk_threshold` is on, a **fix** subagent fixes. The conductor
keeps the round boundary, the gate, consolidation and every human decision, and
exchanges work with the subagents only through the `round-handoff/v1` and
`round-verdict/v1` files (ARCHITECTURE.md, *Round handoff and verdict
contracts*). **Where *Each round* above has the conductor plan and dispatch the
panel itself (step 1) or apply the fix pass itself (step 3), this section
governs**: those steps sit in a byte-frozen span, so they are superseded here
rather than edited. What they say a panel or a fix pass must *do* still holds —
the briefs below hand that work to a subagent, they do not change it.

**Depth budget.** No implementation adds a layer:

- single-issue flow: conductor (0) → panel subagent (1) → reviewers (2);
- epic E3 child flow: child conductor (1) → panel (2) → reviewers (3), which is
  Claude Code's default nesting limit;
- the fix subagent dispatches nothing;
- the decide subagent dispatches nothing;
- the risk subagent dispatches nothing.

A panel subagent that has no `Agent` tool cannot dispatch reviewers: it returns
`failed` / `no-agent-tool`, and the conductor reports and stops.

**Dispatch mechanism.** ARCHITECTURE.md's *Subagent dispatch mechanism*
paragraph records a probe **pass**, so the four kinds ship as plugin agents:
`development/agents/round-panel.md`, `development/agents/round-fix.md`,
`development/agents/round-decide.md` and `development/agents/round-risk.md`;
the risk kind is dispatched as *Risk subagent brief* below says. The conductor dispatches `subagent_type:
round-panel` and `subagent_type: round-fix`, and `subagent_type: round-decide`
for the decided pass, one fresh subagent per job — a recovery or a retry is a **new**
dispatch, never a resumed one — with a prompt that names the handoff file and
`<skill-base-dir>`. Make every `round-panel`, `round-fix`, `round-decide` and
`round-risk` dispatch in the foreground (`run_in_background: false`), as
ARCHITECTURE.md's *Subagent dispatch mechanism* records: in the epic E3 child
flow the conductor is itself a subagent, so its own dispatch is nested and
defaults to a background launch, which returns before the verdict is written.
A foreground dispatch returns its verdict in the same turn, so the conductor
carries straight on: **How to wait** governs only the gate — it is not restated
here. A round dispatch that launched in the background anyway is waited on
in-turn, as *A background round dispatch* below says. Each agent body only
points at its brief below.

**Contract usage.** The conductor writes every handoff with `round-handoff.zsh
write-handoff --work-dir <work-dir>` and reads every verdict with
`round-handoff.zsh read-verdict --file <work-dir>/verdict-<R>-<kind>.json`. A
subagent reads its handoff with `round-handoff.zsh read-handoff` and writes its
verdict only with `round-handoff.zsh write-verdict --work-dir <work-dir>`.
Neither side hand-writes or hand-parses those files.

**The round boundary is unchanged, and the conductor owns all of it.** It mints
`T`, launches the detached gate, waits on it, and dispatches the panel subagent
while the gate runs — *The round boundary is concurrent* above, or
`reference/sequential.md`'s serial boundary when that mode is on. No subagent
launches or waits on the gate. The panel handoff's `tree_id` is `T`.

**The carry precondition stays with the conductor.** Before writing a panel
handoff for any round ≥ 2, run step 1's read-before-plan check — `jq length` on
`<work-dir>/verify-<R>.json`. An absent, zero-byte or unreadable carry is
report-and-stop.

**What the conductor puts in a handoff.** Every key ARCHITECTURE.md's
`round-handoff/v1` table lists for the kind — the table is the key set. The
values only the conductor can supply:

- **every kind:** `round`; `tree_id` is the round's `T`; `worktree_root` is the
  implementation worktree (*Build each reviewer's scope block* above says how to
  identify it), resolved with `:A`;
- **panel:** `base` is the loop's `--base`, resolved to a commit; `mode` is
  `round`, so `carry_entries` is `[]`, except on the two carry recoveries
  (*Verdict recovery arms (#1937)*); `delta_base` is the tree identity
  **read from** `<work-dir>/tree-<R-1>.txt` on every round ≥ 2 — its content,
  never the path — and `null` on round 1; `carried_finding_ids` names the
  entries of `verify-<R>.json`, and is `[]` when it holds none.

A non-zero `round-handoff.zsh write-handoff` exit, or a `read-verdict` exit 1 or
2, is report-and-stop.

**Consolidation stays with the conductor.** On an `ok` panel verdict, and then
an `ok` decide verdict where the round's decided pass runs (*Decide subagent
brief*), the conductor runs step-mode `resolve-story-loop.zsh` itself, exactly as step 2
says, passing the verdict's `aggregate_findings_file` as `--findings-file` and,
when it is non-null, its `carry_accounting_file` as `--carry-accounting`. It
opens neither file. It narrates the round from the verdict's `findings_count`,
the status JSON and the progress block the loop appended. A non-`ok` panel
verdict takes *Verdict recovery arms (#1937)* below.

**When the fix subagent runs.** On exit 20, read `final_changelist.summary.blocking`
from the status JSON:

- **non-zero** → dispatch the fix subagent with `trigger: awaiting-fix`, and
  `changelist` naming `<work-dir>/changelist-<R>.json`, the round's changelist
  the loop wrote. After an `ok` verdict, take the next round's boundary.
- **zero** → the closing-sweep promotion (step 3). No fix runs; take the next
  round's boundary as step 3 says.

On a **red gate** (the boundary's step 6), dispatch the fix subagent with
`trigger: gate-red` and `gate_log` naming the gate's recorded output. After an
`ok` verdict, the conductor restarts the boundary from its step 1.

In both cases the handoff also carries the round's `grant` (`null` when none was
granted) and its `guidance` (the human's granted-round guidance, or `null`),
`rule2_mandatory` (step 3's histogram trigger), and `profile_fix_rules` — the
loaded profile's *Fix-pass rules* reference, or `null` when that heading begins
with `none` (§1b's test). When it is non-null, the dispatch prompt carries that
heading's body, since the subagent cannot load a skill.

**A fix verdict that is not `ok` is report-and-stop**, on either trigger; on
`gate-red` it is §3's *abandon and report*. **A fix that changed nothing is
report-and-stop** too: an `ok` verdict with `fix_applied: false` or
`files_changed: 0` never restarts the boundary on an unchanged tree. The one
exception is an `awaiting-fix` pass that parked every blocker under step 3's
rule 1 — the `- parked:` notes in `<work-dir>/progress.md` name each of the
round's blocking items. Take the next boundary there, so the parked items are
re-raised as step 3 says.

**Before every dispatch, clear what an earlier dispatch of the same round and
kind left behind**: delete `<work-dir>/verdict-<R>-<kind>.json` and, for a
panel, what its mode replaces:

- a **`round`**-mode panel also deletes `findings-round-<R>.json`,
  `carry-lines-<R>.txt` and `carry-round-<R>.json`;
- a **`carry-repair`** panel deletes nothing more;
- a **`carry-redispatch`** panel also deletes
  `<work-dir>/findings-round-<R>-carry.json` and
  `<work-dir>/verify-<R>-carry.json`, and keeps `findings-round-<R>.json`,
  `carry-lines-<R>.txt` and `carry-round-<R>.json`.

A delete that fails is report-and-stop. Without it, a re-dispatched subagent
that dies reads back as the earlier one's verdict.

**Stall retry.** A missing or invalid verdict is exactly a `round-handoff.zsh
read-verdict` exit 3, a missing file included. It gets exactly one re-dispatch,
then report-and-stop — a fresh subagent with a freshly written handoff. A
verdict that validates but is not `ok` is not a stall, and recovery dispatches
(#1937's) don't count against the retry.

**A background round dispatch is waited on in-turn, never by ending the turn
(#2034).** When a `round-panel`, `round-fix`, `round-decide` or `round-risk`
dispatch launched in the background anyway — the flag left out, or ignored —
the conductor waits for that dispatch's `<work-dir>/verdict-<R>-<kind>.json`
with one bounded `Monitor` call for that file, never a Bash poll, then reads it
with `round-handoff.zsh read-verdict`. That call's timeout is the bound: set it
generous enough for that kind's whole job — a panel, which fans out to
reviewers, is routinely the longest — since a bound that expires on a healthy
subagent spends the stall retry. This holds on the single-issue flow and the
epic E3 child flow alike: an E3 child conductor is itself a subagent, and one
that ended its turn would return to its parent mid-round, with no verdict read
and its gate left running, and never be re-invoked. A verdict still missing
when the bound expires is a stall, but the stall retry above applies to it only
once that background dispatch is stopped and confirmed ended, so no two
subagents of one round and kind ever run at once; the re-dispatch is made in
the foreground. A background dispatch that cannot be stopped is
report-and-stop, never re-dispatched.

**Everything else is unchanged.** Exit codes 0, 14, 10, 11, 12, 13, 2 and 1 take
their existing paths, from the status JSON alone — except a mid-run exit 2 on
the CARRY-UNACCOUNTED, CADENCE or never-ran arm, which takes
`#### Verdict recovery arms (#1937)`.
Promotion, residue and
escalation stay in the conductor, because each needs a human. A promotion
sub-loop's rounds dispatch the same panel, decide, risk and fix subagents
(`reference/promotion.md`).

**The structural criterion.** The conductor reads only verdicts, status JSON and
its work-dir state — never reviewer output, a findings file's contents or a
diff. There are two named exceptions, both human-driven: NOT APPLICABLE option
(2) on a full round (step 2), *"you read the story diff yourself"*, which only
the human can choose; and the promotion seed procedure with its step-7
verification (`reference/promotion.md`). The risk pass (#1921) is not an
exception: while `corner_case_risk_threshold` is on, the risk subagent assesses
the aggregate and the conductor passes its verdict's `risk_file` as `--risk`
unopened; when the threshold is off or ignored, no risk subagent is dispatched.

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
| `not-applicable` | `not_applicable` | the **NOT APPLICABLE on a full round** arm: autonomous, stop with no commit and no PR; interactive, its three options, none taken without an explicit choice. Never coerced to `[]`, and the panel is not re-run |
| `story-diff-empty` | `not_applicable` | the **empty story diff** shape: go back to **§2 (Implement)** and take the boundary again, or, if the story needs no code change, say so and stop. The three NOT APPLICABLE options are never offered, and, per the #1485 note, neither the re-invoke arm nor the panel re-run arm is taken |

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
