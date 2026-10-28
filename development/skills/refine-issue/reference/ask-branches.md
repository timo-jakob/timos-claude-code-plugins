# refine-issue — ask-branch inventory

On-demand reference for `development/skills/refine-issue/SKILL.md`, pointed to
from its *Defaults taken instead of asking*. It lists every branch of this skill
— `SKILL.md` and every file under `reference/` — that can put a question to a
human, with its kind under ARCHITECTURE.md's *Decision rights — question
taxonomy and the Decisions-taken record* (#2899): `intent`, `gap` or
`implementation`, and "when in doubt, gap". An `implementation` branch is never
asked: it takes the default named here, prints a one-line notice and records a
Decisions-taken entry, as *Defaults taken instead of asking* says. An `intent`
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
| RF-02 | SKILL.md | `## Defaults taken instead of asking (#2903)` · `if the label is **absent**, **proceed` | implementation | **default:** proceed without the label, with a notice; nothing is written without the approval of the exact rewrite |
| RF-03 | SKILL.md | `Step 5 without asking** — no loop needed` | implementation | **default:** clear the label through Step 5's `READY` branch |
| RF-04 | SKILL.md | `relay these as before` | intent / gap | human-owned: the refiner's own questions, governed by the auto-accept threshold and #2898's refiner children |
| RF-05 | SKILL.md | `explicit approval of the exact rewrite` | intent | human-owned: auto-accept never approves a rewrite (#2898) |
| RF-06 | SKILL.md | `show no children and ask once` · `` then ask once (`AskUserQuestion`) `` | intent | human-owned: a split restructures the backlog |
| RF-07 | SKILL.md | `Relay its stderr and offer the parked exit` | gap | human-owned: the filing failure's cause is unknown |
| RF-08 | SKILL.md | `**can't converge now**` | intent | human-owned: the human decides the session cannot converge now |
| RF-09 | SKILL.md | `**Loop back to Step 2 without asking**` | implementation | **default:** loop back to Step 2 with the gate's remaining reasons as objections; the human can still stop from inside the loop |
