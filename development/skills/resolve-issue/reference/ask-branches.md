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
which arm a run takes. Apart from RS-09's procedure, the last section below, this
file states no rule of its own.

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
| RS-02 | SKILL.md | `offer to clear the blockage` | intent | human-owned: remediation widens the run's scope to other issues |
| RS-02 | reference/interactive/remediation.md | `offer to clear the blockage` · `put the choice to the human` · `(AskUserQuestion —` | intent | human-owned: as above |
| RS-02 | reference/interactive.md | `offer to clear a shape (i) blockage` | intent | human-owned: as above |
| RS-03 | reference/interactive/remediation.md | `ask the human which it is` | gap | human-owned: an epic-kind blocker the intent half cannot confirm needs the author's reading |
| RS-04 | reference/interactive/remediation.md | `ask for native sub-issues or a` · `Anything else you cannot classify` | gap | human-owned: a near-miss rung or an unclassifiable blocker has no document that settles it |
| RS-04 | SKILL.md | `anything else → ask the human` | gap | human-owned: as above |
| RS-05 | SKILL.md | `` one `AskUserQuestion` naming `` | intent | human-owned: overriding the size pre-flight is risk acceptance, and only that explicit answer overrides (#2589) |
| RS-06 | reference/review-loop/exit-2-stale-findings.md | `put it to the human as three options` | intent | human-owned: waiving or replacing panel review is risk acceptance, and no fallback review panel exists |
| RS-06 | reference/review-loop/subagents.md | `interactive, its three options, none taken without an explicit choice` | intent | human-owned: as above |
| RS-07 | reference/promotion/step-3-select.md | `**Multi-select** which to promote` | intent | human-owned: promotion widens the story's scope, and it is opt-in by design (`enable_suggestions`) |
| RS-07 | reference/promotion/gate.md | `` `AskUserQuestion` turns, and each `bash` invocation `` | intent | human-owned: as above |
| RS-08 | reference/interactive/extension.md | `` Show all of it *before* the `AskUserQuestion` `` · `` **Offer the choice** with `AskUserQuestion` `` | intent | human-owned: more rounds cost tokens and accept risk; out of scope by design |
| RS-09 | SKILL.md | `without asking, in every session mode` · `RS-09 — the parked follow-up default (#2903)` | implementation | **default:** run `/development:refine-issue <n> --follow-up` for each parked follow-up in every session mode, as an unattended run already did |
| RS-10 | SKILL.md | `ask the human to fix the` · `halt and ask rather than proceeding` · `has no human to ask, so "ask the human to` | gap | human-owned: an epic body's mistyped or near-miss child lines need the author's reading |
| RS-11 | reference/checkpoint.md | `so ask the human before you discard them` | intent | human-owned: discarding a half-finished round's uncommitted changes loses data |
| RS-12 | reference/checkpoint.md | `ask the human whether to delete it` | intent | human-owned: deleting an old run's local branch cannot be undone from this run |

## RS-09 — the parked follow-up default (#2903)

§7 refines the run's parked follow-ups without asking, in every session mode
(`resolve-session.zsh`, #2575): the follow-up mode refines only from the source
story and parks whatever it cannot settle, so the question has one safe,
reversible answer. That makes it an `implementation` decision under
ARCHITECTURE.md's *Decision rights* (#2899), and it is recorded like one.

**Print one line** when §7 starts the refinements:
`Decision taken (not asked): auto-refining the parked follow-ups #A, #B`.

**Record the follow-up default in the body (#2903).** In §6, run §7's
`follow-up-origin.zsh parked-issues` read before open-pr opens the PR. When it prints any issue, the body carries a
`## Decisions taken` section (ARCHITECTURE.md, *Decision rights*) holding one
entry — question: refine the parked follow-ups now?; choice: §7 runs
`/development:refine-issue <n> --follow-up` for each issue it names; evidence:
the follow-up mode refines only from the source story and parks what it cannot
settle (#2588); how to overrule: restore a follow-up's body from its edit
history and re-add `needs-refinement`. An exit 1 adds no section.

**On every other ending** — #2579's clean stop and an escalation terminal —
there is no PR body, so the same entry goes in the run's report. Either way the
decision is recorded once: §7 adds nothing to a PR whose body already holds it.
