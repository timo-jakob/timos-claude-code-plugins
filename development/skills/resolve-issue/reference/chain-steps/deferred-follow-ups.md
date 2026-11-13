<!-- Part of reference/chain-steps.md, kept in its own file because chain-steps.md
     sits at the 20,000-byte reference cap: how the root handles a step verdict's
     `deferred` follow-ups (#3077), which chain-steps.md § The issue step points at. -->

## A step's deferred follow-ups (#3077)

A step of a human-started run never asks. Its verdict carries `deferred`
instead, on any verdict of a run whose review loop ran: `suggested_follow_ups`,
each `{title, body}`, for every follow-up the run would otherwise name only in
prose without filing it. It is `[]` when there are none, and a follow-up the
run filed goes in `follow_ups`, never here. A suggestion the run waived is not
handed back: it stays waived. The root mode is the one the root resolved
before its first dispatch with `scripts/resolve-session.zsh --inferred
attended`, never a step's own mode. The root handles them by its root mode
(`reference/chain-steps.md` § The step model (#2940)) before the verdict's own
arm, except on an attended clean stop:

- **An attended root asks once per step.** When `deferred` holds any item, it
  renders one numbered list, each suggested follow-up by its title, and asks
  one question with AskUserQuestion: **File all** · **File none**, with "Other"
  taking the numbers to file. Filing work is a question of what to build, an
  `intent` question under ARCHITECTURE.md's *Decision rights*, so it is asked
  and never decided for the human. On a clean stop it asks after the
  extension's answer, Stop included. On a grant it asks about this verdict's
  items before it deletes the verdict file and re-dispatches, and asks about the
  re-dispatched step's verdict only for the items not in that answered list: the
  step resumes on the same status file, so its verdict names the earlier items
  again.
- **An unattended root files every suggested follow-up.**
- **Each filed item** is read from the step's verdict file, never retyped, so
  no shell expands its title. Item `<k>`'s title is
  `jq -r --argjson i <k> '.deferred.suggested_follow_ups[$i].title' <verdict>`,
  passed as one argument, and its finding is
  `jq -c --argjson i <k> '.deferred.suggested_follow_ups[$i] |
  {file: "follow-up", line: null, dimension: "follow-up", title}' <verdict>`.
  It becomes an issue, `gh issue create --title <title> --body-file <file>`,
  whose body is the item's `body`, read the same way, and names the step's issue
  and its PR when there is one, and is queued like a listed follow-up:
  `chain-queue.zsh add --entry <new> --kind follow-up --after <the entry that
  filed it>` (for an E3 child, its epic-kind entry), as the chain queue's step 2
  adds and stops on its exits, with `--finding` `{"file": "follow-up", "line":
  null, "dimension": "follow-up", "title": <its title>}`. Nothing in `deferred`
  is dropped without the human's answer.
