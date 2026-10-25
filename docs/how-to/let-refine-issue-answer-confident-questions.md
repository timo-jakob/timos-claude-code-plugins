# Let refine-issue answer the questions it is sure about

`/development:refine-issue` works through a story with you one round at a time.
Each round the refiner asks questions, and each question now comes with the
answer the refiner would recommend and a score for how sure it is. By default
you answer every question yourself. With an **auto-accept threshold**, the
skill answers the questions whose score is high enough itself, and asks you
only the rest.

You still approve the finished rewrite before anything is written to the
issue. The threshold only answers questions.

## Set it for one run

```text
/development:refine-issue 1234 --auto-accept 0.9
```

## Set a default for every run

Add the variable to your settings:

```json title="~/.claude/settings.json"
{
  "env": {
    "refine_auto_accept_threshold": "0.9"
  }
}
```

The `--auto-accept` flag overrides the setting for one run. When neither is
set, the threshold is `1`. Restart the session if a change to the setting does
not seem to apply. The run says which threshold it uses and where it came from,
for example "auto-accept: 0.9 (from settings)".

## Choose a value

The value is a decimal from 0 to 1, with at most three decimals.

| Value | What is answered for you |
| ----- | ------------------------ |
| `1` (the default) | only answers the refiner scored `1` on every criterion, so it sees no other sensible answer |
| `0.9`, `0.8`, … | answers whose weakest criterion scores at least that |
| `0` | every question that comes with a recommended answer |
| anything else, such as `90` or `1.5` | as a flag: the run stops and tells you. As a setting: it is ignored and the run uses `1` |

A question without a recommended answer is always asked, whatever the
threshold.

## How the score is made

The refiner scores its recommended answer from 0 to 1 on five criteria:

| Criterion | The question it answers |
| --------- | ----------------------- |
| Repo consistency | Does the answer agree with ARCHITECTURE.md, earlier story specs and the code? |
| Best practice | Is it the established way to do this, not one option among several? |
| Evidence | Does it rest on something the refiner actually read? |
| Uniqueness | Is there really no other sensible answer? |
| Reversibility | Would a wrong answer be cheap to notice and undo? |

The answer's confidence is its **lowest** score, so one weak criterion is
enough to have the question asked. The skill works out that lowest score
itself; the refiner does not state an overall figure. A question about product
intent or priority scores at most `0.5` on uniqueness, so it is asked at any
threshold above `0.5`.

## Implementation questions are decided, not asked

The refiner also marks each question with a kind: **intent** (what to build,
scope, priority, risk you accept), **gap** (the architecture positions,
requirements or personas are silent or contradict each other) or
**implementation** (the positions and established practice already decide it).
The threshold applies to intent and gap questions. An implementation question
is never put to you, whatever the threshold: the skill takes the refiner's
recommended answer and records it in a **Decisions taken** section of the
rewrite, with the evidence it rests on and how to overrule it. You see that
section in the rewrite you approve, and it stays in the issue body. To overrule
a decision, edit its entry and the story text that rests on it in the issue
body.

## What you see

- **During the loop:** each answer taken for you is shown as one line with its
  confidence and weakest criterion. Questions that are still asked show the
  recommended answer next to them, so you can simply agree.
- **Before anything is written:** the proposed rewrite comes with a list headed
  **Answers taken automatically**. If you disagree with one, say so. It goes
  back to the refiner as your answer, and the loop runs again.
- **On the issue:** the before/after comment lists the answers that were taken
  automatically, so a later reader can tell which parts of the story you stated.
  Implementation answers are in the body's **Decisions taken** section instead.

## What it does not do

It never approves the rewrite for you. It never answers the other prompts
either: whether to refine an issue that is not marked `needs-refinement`,
whether to just clear the label, or whether to loop again after a failed
re-gate.

Scores come from the model and are not calibrated measurements. Start with
the default `1` or a high value, and lower it once you trust what gets
answered for you.

## Follow-ups the pipeline filed

Some follow-up issues are filed by the pipeline, not by you: a finding the
review loop parked, or a child of a story that was split before it was built.
Each one links back to the story it came from. That story was already refined,
so `/development:resolve-issue` refines these follow-ups for you, with
`/development:refine-issue <issue> --follow-up`, before it finishes:

- **When it runs.** On an unattended run, without asking. On a run you are
  driving, it asks once, listing the follow-ups, and recommends refining them.
- **What it uses.** The source story's text and story spec, and the slice the
  follow-up covers: the split child's criteria, or the parked finding. It uses
  the same threshold as above to answer the refiner's questions.
- **When it is accepted.** Only when every question was answered at or above the
  threshold and every objection is resolved, within three rounds. The rewrite is
  then written back without your approval, and the readiness gate runs. This is
  the one place a rewrite is accepted for you.
- **When it is not.** Any question below the threshold, or no agreement after
  three rounds, parks the follow-up. It stays `needs-refinement`, and
  `/development:refine-issue <issue>` resumes from where it stopped.
- **What it leaves.** One comment on the follow-up lists the answers taken for
  you, the threshold and the lowest confidence among them. A follow-up is tried
  once only, and one filed while working on another follow-up is always left for
  you.
