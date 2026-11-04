# refine-issue — ask-branch inventory

On-demand reference for `development/skills/refine-issue/SKILL.md`, pointed to
from its *Defaults taken instead of asking*. It lists every branch of this skill
— `SKILL.md` and every file under `reference/` — that can put a question to a
human, with its kind under ARCHITECTURE.md's *Decision rights — question
taxonomy and the Decisions-taken record* (#2899): `intent`, `gap` or
`implementation`, and "when in doubt, gap". An `implementation` branch is never
asked: it takes the default named here, prints a one-line notice and records a
Decisions-taken entry, as *Defaults taken instead of asking* says. RF-11 is the
one standing rule among them: the human approved it once, so it prints no
notice and records no entry. An `intent`
or `gap` branch stays with the human. This file states no rule of its own.

## The inventory

One row per branch and file. **file** is relative to this skill's directory.
**anchors** are verbatim text from that file, one code span each, joined by
` · `. `tests/ask-branches.bats` holds the two directions: every line of the
skill that matches its ask pattern carries one of its file's anchors, and every
anchor still occurs in its file. A new ask branch therefore gets a row here
before it ships, and a row whose text moved is updated here.

| id | file | anchors | kind | outcome |
|---|---|---|---|---|
| RF-01 | SKILL.md | `ask for native sub-issues, or for the list` · `halt and ask rather than` · `ask for native sub-issues or for the list` | gap | human-owned: only the author knows which issues an epic body's near-miss or mistyped lines meant as its children |
| RF-02 | SKILL.md | `## Defaults taken instead of asking (#2903)` · `if the label is **absent**, **proceed` | implementation | **default:** proceed without the label, with a notice; nothing is written without the approval of the exact rewrite, an all-auto refinement (#2938), or a chained refinement (#2939) |
| RF-03 | SKILL.md | `Step 5 without asking** — no loop needed` | implementation | **default:** clear the label through Step 5's `READY` branch |
| RF-04 | SKILL.md | `relay these as before` | intent / gap | human-owned: the refiner's own questions, governed by the auto-accept threshold and #2898's refiner children |
| RF-05 | SKILL.md | `explicit approval of the exact rewrite` | intent | human-owned: auto-accept approves the rewrite only when it answered everything (#2898) — the all-auto exception: a refinement `scripts/all-auto-check.zsh` reports `all-auto` (no intent or gap question reached the human, no size check stopped or went unjudged, no split was proposed) is written back with no approval prompt (#2938); a chained refinement (#2939) presents no approval prompt either: the human's relayed answers, the auto-accepted answers and the Decisions taken stand in for it |
| RF-06 | SKILL.md | `show no children and ask once` | intent | human-owned: a split that names no children is the human's to revise or park in a direct run, and stops a chained run; a split that names its children is filed without asking in every run, chained or direct (#2939), since `file-split-children.zsh` sizes every child before any write |
| RF-07 | SKILL.md | `Relay its stderr and offer the parked exit` | gap | human-owned: the filing failure's cause is unknown |
| RF-08 | SKILL.md | `**can't converge now**` | intent | human-owned: the human decides the session cannot converge now |
| RF-09 | SKILL.md | `**Loop back to Step 2 without asking**` | implementation | **default:** loop back to Step 2 with the gate's remaining reasons as objections; the human can still stop from inside the loop |
| RF-10 | SKILL.md | `` Show it, then ask once (`AskUserQuestion`): **Approve all** `` | intent | human-owned: the batch approval of an epic walk's rewrites (#2904) is RF-05's approval, asked once per batch instead of once per child; an all-auto child is written back in phase A and never batched (#2938) |
| RF-11 | SKILL.md | `closes the story's test-case issues through` | implementation | **default:** Step 2.5 files, edits and closes the story's test-case issues without asking, in every run (#2939); the approval of the rewrite, or the all-auto or chained write-back that replaces it, covers them — a standing rule the human approved on 2026-10-30 |
| RF-12 | SKILL.md | `never asked in place or through a side channel` | intent / gap | human-owned: a chained refinement's intent or gap question is relayed, not asked — the run returns `questions-pending` and its caller puts it to the human (#2939) |
