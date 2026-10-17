# How refine-issue works

`/development:refine-issue` is the guided path from *"this story is not ready"* back to *"ready"*. It takes an issue the
readiness gate labelled `needs-refinement` and, with you present throughout, turns it into a story that can be built:
plain prose a reviewer can read, plus a machine-readable `story-spec/v1` block that resolve-issue builds and tests from.

Two things hold for the whole run. **A human is always present** — the skill relays every question it cannot answer
with confidence, and only you can approve a rewrite. And **nothing is written by a bot** — the issue edit and the
comments go out under your own `gh` login, not through a PR. The colour key for the diagrams is on
[How the plugins work](how-the-plugins-work.md).

![refine-issue end to end: diagnose, loop with the refiner until you approve a rewrite, write it back and
re-gate](diagrams/refine-issue.svg)

## Diagnose and converge {#refine-diagnose-and-converge}

1. **Classify the target.** An issue is an *epic* when it has native sub-issues, carries the `epic` label, or its body
   declares child issues as a task list. An epic is walked child by child — see [Epics](#refine-epics) below.
   Everything else continues here.
2. **Step 0 — fetch and check preconditions.** The skill reads the issue and stops if it is closed. If the
   `needs-refinement` label is missing it asks whether to refine anyway. If an earlier run *parked* this issue, the
   saved conversation and open questions are restored, and you are told what the last run stopped on.
3. **Step 1 — diagnose.** The `story-readiness` agent judges the story afresh, because the gate comment on the issue
   may be stale. Its questions become this session's **objections** — the list every later turn works through. If the
   story is already READY, the skill offers to simply clear the label.
4. **Step 2 — one refiner turn.** The conductor hands `issue-refiner` the issue, the objections, the conversation so
   far and your latest reply. The agent returns:
   - for every objection, a plain-language *why it is not ready yet*;
   - questions, each with a recommended answer and a confidence score on five criteria;
   - concrete recommendations;
   - a rewritten prose draft and a proposed `story-spec/v1` block;
   - which objections it now considers resolved.
5. **Relay the questions.** A script splits the questions by confidence. Those at or above the auto-accept threshold
   are answered with the agent's recommendation, and you see one line for each. The rest are put to you with their
   recommended answer. A question's confidence is its lowest criterion score, and the threshold defaults to `1`, so by
   default only answers the refiner scored `1` on every criterion are taken automatically — see
   [Let refine-issue answer confident questions](../how-to/let-refine-issue-answer-confident-questions.md).
6. **Converge.** The loop repeats until every objection is resolved and no question is left. If it cannot get there
   yet — a decision belongs to someone else, the story should be split, or it should wait — you take a **typed parked
   exit**: `needs-decision`, `split-recommended` or `deferred`. The skill posts a resume comment with the conversation
   saved inside it, keeps the label, and writes nothing else. Running the skill again resumes from that comment.
7. **Size the draft.** Before you see the final rewrite, the skill lists every file the drafted story would touch and
   runs it through the same size check resolve-issue applies just before it builds. A story too big to build as one
   change is never written back. The refiner proposes a split into child stories instead, each with its own file
   list, and you choose: file the children, revise the draft, or park the story as `split-recommended`. Filing checks
   every child first and writes nothing if one is still too big. It then files them as sub-issues of the original,
   each labelled `needs-refinement`, turns the original into an epic and posts a comment listing them. The readiness
   gate runs the same check, so a story too big to build is sent back for refinement before anyone starts on it.
   A story that resolve-issue's own size check stopped arrives with that objection already open, carrying the list
   of files the plan would have touched, so the skill asks for a split straight away instead of offering to clear
   the label.
8. **Approve the exact rewrite.** The skill shows you the final prose, the story spec and every answer that was taken
   automatically, any of which you can overturn. Only your explicit approval of that exact text moves the run on.
   Auto-accept never approves a rewrite.

### What one refinement turn looks like {#refine-what-one-refinement-turn-looks-like}

The refiner reads the repository on every turn — OpenAPI and proto specs, UI routes, existing acceptance tests and the
persona registry — so that it drafts the outside-in parts of the spec (the use case, the test cases, the personas)
and you curate them rather than write them from scratch.

## Write back and re-gate {#refine-write-back-and-re-gate}

1. **Step 2.5 — spin out test cases.** Each test case in the approved spec becomes its own `test-case`-labelled
   issue. The step is idempotent: re-running it edits those issues in place and closes the ones the spec no longer
   lists. A story that touches no interface has no test cases to spin out.
2. **Step 3 — write back.** The approved prose goes between `story-spec:prose` sentinels, followed by the
   `story-spec/v1` block in a collapsed *"generated, do not hand-edit"* section. The block records who generated it,
   when, and a hash of the prose, so a later hand-edit to the prose shows up as a stale block. It is written with your
   `gh` login and replaces any earlier block.
3. **Step 4 — re-gate.** `story-readiness` judges the rewritten story, now also checking the block against the prose.
   Persona advisories — an unknown persona, a stale or missing registry — are relayed to you but never change the
   verdict.
4. **Step 5 — the label.** On READY the skill removes `needs-refinement` and checks that it is really gone. On
   NEEDS_REFINEMENT it keeps the label and offers another loop, or stopping here as `deferred`.
5. **Step 6 — the before/after comment.** One durable comment records the starting objections, a before/after of the
   prose, the re-gate verdict and the label state, and every answer that was taken automatically with its confidence.
6. **Step 7 — telemetry.** Exactly one record per run, with the outcome `refined-ready` or `parked`. It also records
   the readiness gate's size verdict and how many children a split filed.

## What the story spec carries {#refine-what-the-story-spec-carries}

The `story-spec/v1` block is what makes a refined story buildable without guesswork:

| Field | What it holds |
| --- | --- |
| `acceptance_criteria` | The testable statements the PR must satisfy |
| `scope_boundaries` | What is in scope and what is explicitly out |
| `risk_classification` | `low`, `normal` or `elevated` — carried to the PR and the Approver |
| `interface_surfaces` | Which of `rest`, `grpc`, `web-ui`, `cli` the story touches |
| `use_case` | The actor, their goal and a sketch of the data they bring |
| `personas` | Registry ids of who the story serves — advisory, may be empty |
| `test_cases` | Happy, corner and error cases per surface, each with its tooling and its spun-out issue |
| `provenance` | Who generated the block, when, and the hash of the prose it was generated from |

A story's dependencies are not in the block: they are GitHub's native *blocked by* links, which resolve-issue checks
before it builds anything.

## Epics {#refine-epics}

Pointed at an epic, the skill lists the epic's open sub-issues that carry `needs-refinement` and walks each one
through the whole single-issue flow above, one child fully before the next. A child that parks does not stop the walk.
At the end it posts one summary on the epic: which children are now ready, which are still parked and why, and any
that failed. The epic's own body is never refined, and re-running the skill on the epic resumes the walk.

## Who does what {#refine-who-does-what}

| Actor | Does |
| --- | --- |
| You | Start the run, answer the questions put to you, approve the exact rewrite, choose to park or loop again |
| `refine-issue` (conductor) | Every GitHub read and write, the question split, the write-back, the label, the comments |
| `story-readiness` | Diagnoses the story at step 1 and re-gates it at step 4 |
| `issue-refiner` | Drafts each turn: explanations, scored questions, the prose and the story spec |
