# resolve-issue — ask-branch inventory

On-demand reference for `development/skills/resolve-issue/SKILL.md`, pointed to
from §6 and §7 for the parked follow-ups. It lists every branch of this skill —
`SKILL.md` and every file under `reference/` — that can put a question to a human, with
its kind under ARCHITECTURE.md's *Decision rights — question taxonomy and the
Decisions-taken record* (#2899): `intent`, `gap` or `implementation`, and "when
in doubt, gap". An `implementation` branch is never asked: it takes the default
named here, prints a one-line notice and records a Decisions-taken entry. An
`intent` or `gap` branch stays with the human, and its autonomous / interactive
split is the one its own file states, and `scripts/resolve-session.zsh` decides
which arm a run takes. Apart from the RS-06a and RS-09 procedures, the last two
sections below, this file states no rule of its own.

## The inventory

One row per branch and file. **file** is relative to this skill's directory.
**anchors** are verbatim text from that file, one code span each, joined by
` · `. `tests/ask-branches.bats` holds the two directions: every line of the
skill that matches its ask pattern carries one of its file's anchors, and every
anchor still occurs in its file. A new ask branch therefore gets a row here
before it ships, and a row whose text moved is updated here.

| id | file | anchors | kind | outcome |
|---|---|---|---|---|
| RS-01 | SKILL.md | `ask the human to attach native sub-issues` | gap | human-owned: only the author knows which issues a near-miss epic body meant as its children |
| RS-02 | SKILL.md | `offer to clear the blockage` | intent | human-owned: retired by #2941 — every run a human starts takes "resolve the dependency and the named issue" without asking (`reference/interactive/blockers-first.md`), and a pipeline-started run never offers it |
| RS-02 | reference/interactive/remediation.md | `offer to clear the blockage` · `put the choice to the human` · `(AskUserQuestion —` | intent | human-owned: as above; the frozen span keeps the question's text |
| RS-02 | reference/interactive/blockers-first.md | `never puts the choice to the human` | intent | human-owned: as above |
| RS-02 | reference/interactive.md | `offer to clear a shape (i) blockage` | intent | human-owned: as above |
| RS-03 | reference/interactive/remediation.md | `ask the human which it is` | gap | human-owned: an epic-kind blocker the intent half cannot confirm needs the author's reading |
| RS-03 | reference/interactive/blockers-first.md | `The root asks the human, in both session` · `modes, with AskUserQuestion: two options` | gap | human-owned: an epic-kind blocker the intent half cannot confirm needs the author's reading; in a human-started run the root asks it in both session modes and waits (#2941) |
| RS-04 | reference/interactive/remediation.md | `ask for native sub-issues or a` · `Anything else you cannot classify` | gap | human-owned: a near-miss rung or an unclassifiable blocker has no document that settles it; in a human-started run a near-miss blocker stops the run naming its fix, and an unclassifiable one is RS-03's root question (#2941) |
| RS-04 | SKILL.md | `anything else → ask the human` | gap | human-owned: as above |
| RS-05 | SKILL.md | `The override question (a) is retired` | intent | human-owned: retired by #2940 — no run reaches the size pre-flight override or asks it; a human-started run parks and chains a refinement instead, and the human answers that refinement's questions through RS-13 |
| RS-06a | reference/review-loop/briefs/panel.md | `Route a full-round NOT APPLICABLE to the fallback panel (#2909)` | implementation | **default:** run the fallback panel — the repo-type panel's NOT APPLICABLE on a full round dispatches `development-claude-plugin:review` in fallback mode in the same round, so every file it covers is reviewed |
| RS-06a | reference/review-loop/subagents.md | `fires only when the fallback panel is NOT APPLICABLE or unavailable` | implementation | **default:** as above |
| RS-06b | reference/review-loop/exit-2-stale-findings.md | `put it to the human as three options` | intent | human-owned: the fallback is NOT APPLICABLE or unavailable, so waiving or replacing panel review is risk acceptance |
| RS-06b | reference/review-loop/subagents.md | `interactive, its three options, none taken without an explicit choice` | intent | human-owned: as above |
| RS-08 | reference/interactive/extension.md | `` Show all of it *before* the `AskUserQuestion` `` · `` **Offer the choice** with `AskUserQuestion` `` | intent | human-owned: more rounds cost tokens and accept risk; out of scope by design |
| RS-08 | reference/escalation.md | `question with AskUserQuestion, marking` | intent | human-owned: as above; in a human-started run an attended root asks it on a step's clean stop, and a step never asks (#3077) |
| RS-09 | SKILL.md | `without asking, in every session mode` · `RS-09 — the parked follow-up default (#2903)` | implementation | **default:** run `/development:refine-issue <n> --follow-up` for each parked follow-up in every session mode, as an unattended run already did; in a human-started chain (#2942), follow-ups are queued, refined in chained mode and resolved instead |
| RS-10 | SKILL.md | `ask the human to fix the` · `halt and ask rather than proceeding` · `→ **halt** and ask for` · `has no human to ask, so "ask the human to` | gap | human-owned: an epic body's mistyped or near-miss child lines need the author's reading |
| RS-11 | reference/checkpoint.md | `so ask the human before you discard them` | intent | human-owned: discarding a half-finished round's uncommitted changes loses data |
| RS-12 | reference/checkpoint.md | `ask the human whether to delete it` | intent | human-owned: deleting an old run's local branch cannot be undone from this run |
| RS-13 | reference/chain-steps.md | `**Only the root asks the human.**` · `The root asks the verdict's` · `neither with AskUserQuestion` | intent / gap | human-owned: a chained refinement's below-threshold intent and gap questions, which the root relays with AskUserQuestion; a step never asks (#2940) |
| RS-14 | reference/chain-steps/deferred-follow-ups.md | `one question with AskUserQuestion: **File all**` | intent | human-owned: filing a chain step's suggested follow-ups as new work decides what to build; an unattended root files them all (#3077) |

## RS-06a — the fallback review panel default (#2909)

When the repo-type panel reports NOT APPLICABLE on a full round over a
non-empty story diff, the run does not ask: the fallback panel,
`development-claude-plugin:review` in its fallback mode, reviews the round in
both wirings (the panel brief in step mode, `resolve-story-loop.zsh` in hook
mode). Every file it covers gets a real panel with full carry accounting, and
the PR still goes through the Approver, so what is left is which reviewer runs
— an `implementation` decision under ARCHITECTURE.md's *Decision rights*
(#2899), recorded like one. RS-06b, the human-owned arm, applies only when the
fallback is NOT APPLICABLE or unavailable.

**Print one line** when the fallback engages, attended or unattended, naming
both panels — `Decision taken (not asked): <repo-type review_skill> is NOT
APPLICABLE on this diff, so development-claude-plugin:review reviews it in
fallback mode` — and continue the loop. Who prints it depends on the wiring:
in step mode the conductor prints it on the round the fallback engages, from
the line the panel subagent returns beside its `ok` verdict
(`reference/review-loop/briefs/panel.md`, step 5); in hook mode
`resolve-story-loop.zsh` prints it on stderr as it engages the fallback.

**Record it in the body (#2909).** When this run's review loop ran (not a
`--no-review` run, whose status is SKIPPED) and `<work-dir>/.fallback-engaged`
exists as §6 opens the PR, the body's `## Decisions taken` section (ARCHITECTURE.md,
*Decision rights*) holds one entry — question: the repo-type panel was NOT
APPLICABLE, so who reviews the diff?; choice: the fallback panel,
`development-claude-plugin:review` in fallback mode, from round
`<the marker's round>` on; evidence: it reviews every file it covers with full
carry accounting, and the PR still goes through the Approver (ARCHITECTURE.md,
*The fallback review panel (#2909)*); how to overrule:
request changes on the PR, or re-run deliberately with `--no-review`. On an
ending with no PR body, the entry goes in the run's report. A `--no-review` run
never records it.

## RS-09 — the parked follow-up default (#2903)

Outside a human-started chain, §7 refines the run's parked follow-ups without
asking, in every session mode (`resolve-session.zsh`, #2575): the follow-up mode
refines only from the source story and parks whatever it cannot settle, so the
question has one safe, reversible answer. That makes it an `implementation`
decision under ARCHITECTURE.md's *Decision rights* (#2899), and it is recorded
like one. A step of a human-started chain (#2942) neither refines its follow-ups
nor records the line or the entry below: it lists the issues in `follow_ups`,
and the root queues them.

**Print one line** when §7 starts the refinements:
`Decision taken (not asked): auto-refining the parked follow-ups #A, #B`.

**Record the follow-up default in the body (#2903).** In §6, run §7's
`follow-up-origin.zsh parked-issues` read before open-pr opens the PR. When it prints any issue, the body carries a
`## Decisions taken` section (ARCHITECTURE.md, *Decision rights*) holding one
entry — question: refine the parked follow-ups now?; choice: §7 runs
`/development:refine-issue <n> --follow-up` for each issue it names; evidence:
the follow-up mode refines only from the source story and parks what it cannot
settle (#2588); how to overrule: restore a follow-up's body from its edit
history and re-add `needs-refinement`. An exit 1 or 2 adds no section.

**On every other ending** — #2579's clean stop and an escalation terminal —
there is no PR body, so the same entry goes in the run's report, as it does
whenever §7 refines follow-ups an open PR's body does not hold. Either way the
decision is recorded once: §7 adds nothing to a PR whose body already holds it.
