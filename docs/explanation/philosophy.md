# Philosophy

<!-- Every pillar carries the same four H3s by design, so duplicates are allowed across pillars, never within one. -->
<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

These six pillars describe the family as it is designed to be — the convictions
the plugins act on when they refuse, escalate, park or split. They are a
statement of intent, not a claim about what ships today. Each section therefore
has the same shape: the **Statement** is the pillar as designed;
**What enforces it today** is the honest current state, linked to the real
mechanisms and tests; and the **Gap** is the distance between the two — the epic
that closes it, or a plain note that the current state already matches the
design.

Other pages link to a pillar by its anchor (`philosophy.md#pillar-1` …
`#pillar-6`) rather than restating it, so the wording below is the one place it
lives.

## Opinionated {#pillar-1}

*Opinionated — one blessed path, one good default, no options to choose between.*

### Statement

The family picks one way of doing each thing and makes that the only way it
maintains: one build format, one default per decision, no switch to reach for a
second. Where a real repo is off that path, the family converts it or refuses it
clearly — it does not quietly grow a second path to accommodate it.

### Why

Every supported option is a permanent maintenance cost for the family and an
expertise cost for the person who has to choose between them. One good default
spends that cost once, on getting the default right.

### What enforces it today

- [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md),
  section *Build policy — Gradle + Kotlin DSL only (Java/Spring)*: Maven is not
  accepted and a Groovy build must be converted before it is maintained.
- [Why per-language plugins?](why-per-language-plugins.md), reason 1 — the
  plugins are opinionated because their author is, and each opinion is a
  decision rather than knowledge.
- The `nils-unblessed-stack` persona in [Personas](../personas.md) — the adopter
  whose repo is off the blessed path, kept as a deliberate test that the family
  offers a conversion path or a clear refusal instead of a silent no-op.
- [`tests/detect-stack.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/detect-stack.bats)
  — detection still recognises a Groovy or Maven build so it can flag it. The
  [Java](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-java/skills/maintenance/SKILL.md)
  and
  [Spring](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-spring/skills/maintenance/SKILL.md)
  maintenance dispatchers then halt such a repo with a convert-or-migrate
  recommendation, rather than half-maintaining it.
- [`tests/gather-java.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/gather-java.bats)
  — pins that the Java gather scans only `build.gradle.kts`, leaving the refusal
  to the dispatcher.

### Gap

No open gap epic — enforced today.

## Never asks "how" {#pillar-2}

*Never asks "how" — the family's architecture positions decide, stated in its own
words.*

### Statement

When a question has an architectural answer — which broker, which UI shape,
which framework — the family already holds a position and applies it. It asks a
human *what* to build, never *how* to build it. Each position is written in the
family's own words, with its rationale, so a reader can evaluate it on its
merits and disagree with it explicitly.

### Why

A "how" question pushed to the person running the tool turns every run into a
design review and lets the answer drift from one repo to the next. Deciding once,
in writing, is what makes the result consistent and the decision contestable.

### What enforces it today

- [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md),
  sections *Messaging — NATS JetStream carrying CloudEvents 1.0 (#1060)*,
  *Browser UI — SPA shell, micro-frontends, React default (#1059)*,
  *Deployment — GitOps promotion and immutable references (#1189)* and
  *Identity and authorization — OIDC at the edge, claims as the only input
  (#1186)* — recorded positions, each with its rationale and the alternatives it
  rejects.
- [`tests/messaging-position.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/messaging-position.bats),
  [`tests/webui-positions.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/webui-positions.bats),
  [`tests/deployment-position.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/deployment-position.bats)
  and
  [`tests/identity-position.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/identity-position.bats)
  — each pins its position clause by clause, so a position cannot be softened
  or reversed with the suite still green.

This is thin. Each position is pinned by its own suite, but the positions live
as prose sections, and there is no single registry that pairs every position
with the mechanism enforcing it.

### Gap

[#1626](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1626) —
a `positions/v1` registry, each position with its enforcing mechanism and the
test that pins it.

## An automated state machine {#pillar-3}

*An automated state machine — escalates only when it cannot understand or fix a
problem with the guidance it has.*

### Statement

A run moves through defined states on its own — gate, implement, review, fix,
converge — and every exit is a typed outcome rather than a shrug. It pulls a
human in only when it cannot understand or fix a problem with the guidance it
already has, and when it does, the escalation says exactly what it needs.

### Why

A human's attention is the scarcest input in the loop. Spending it only where
judgment is genuinely required is what lets the share of work the family closes
out alone grow as the models get stronger.

### What enforces it today

- [The local review loop](review-loop.md) — the pre-push review → fix → test
  loop, its bounded round budget, and its typed terminal statuses.
- [`development/skills/resolve-issue/reference/review-loop.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/resolve-issue/reference/review-loop.md)
  — the round protocol the conductor follows, state by state.
- [`tests/resolve-story-loop.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/resolve-story-loop.bats)
  — the loop's transitions and exit codes.
- [`tests/build-escalation.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/build-escalation.bats)
  — the typed escalation a non-converging run produces instead of a pull request.

One honest limit: the loop's round budget is a hard cap, so a run that is still
making progress also pauses for a human when it runs out — who can grant more
rounds rather than decide anything.

### Gap

No open gap epic — enforced today.

## Unclear requirements are refined with AI guidance {#pillar-4}

*Unclear requirements are refined with AI guidance, not guessed at.*

### Statement

A story that is not specified well enough to build is never built on a guess.
It is sent back, and a human and an AI agent work through it together — the
agent explains why it is not ready, asks targeted questions and drafts the
rewrite — until the story carries testable acceptance criteria and a bounded
scope.

### Why

Guessing past an ambiguity is cheap at the start and expensive at the end: the
wrong thing gets built, reviewed and converged on. Asking before any code exists
is the cheapest point to resolve it.

### What enforces it today

- The `/development:refine-issue` row in [Commands](../reference/commands.md).
- [`development/skills/refine-issue/SKILL.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/SKILL.md)
  — the human-present refinement conductor.
- [`development/agents/story-readiness.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/agents/story-readiness.md)
  — the readiness gate that sends an unready story back before any branch exists.
- [`development/agents/issue-refiner.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/agents/issue-refiner.md)
  — the per-turn engine that turns the gate's objections into questions and a
  draft rewrite.
- [`tests/refine-parked-exit.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/refine-parked-exit.bats)
  and
  [`tests/build-refine-telemetry-record.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/build-refine-telemetry-record.bats)
  — a session that cannot converge parks with its state, and every run is
  recorded.

### Gap

No open gap epic — enforced today.

## Epics and issues are split when too big {#pillar-5}

*Epics and issues are split when too big.*

### Statement

Work that is too large to be one bounded story is broken into ordered pieces
that each are one. An oversized story becomes sub-issues in dependency order and
the run carries on with them — size is a reason to split, never a reason to stop.

### Why

A story too big to review is a story too big to converge. Smaller pieces keep
each change reviewable, each gate meaningful, and each merge independent.

### What enforces it today

- The `split-recommended` typed parked exit in
  [`development/skills/refine-issue/SKILL.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/SKILL.md),
  section *Step 2 — the typed parked exit (#578)*.
- [`development/skills/refine-issue/scripts/build-parked-comment.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/scripts/build-parked-comment.zsh)
  — records the candidate children on the parked issue.
- [`development/skills/refine-issue/scripts/list-refinement-children.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/scripts/list-refinement-children.zsh)
  — enumerates an epic's children for the refinement walk.
- [`tests/refine-parked-exit.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/refine-parked-exit.bats)
  and
  [`tests/list-refinement-children.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/list-refinement-children.bats).

Today the family only *recommends* a split: it parks the story with its
candidate children and waits for a human to file them.

### Gap

[#1625](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1625) —
executable splitting: an oversized story or epic becomes ordered sub-issues,
never a halt.

## The AI owns a self-optimising loop {#pillar-6}

*The AI owns a self-optimising loop — it assesses its own runs, learns from them,
improves the plugins itself, and proves each improvement worked.*

### Statement

The family improves itself from its own runs. It assesses how each run went,
learns what to change, changes the plugins, and then shows — with evidence from
later runs — that the change made things better rather than merely different.

### Why

The people best placed to notice where a pipeline wastes effort are not reading
every transcript; the runs themselves are the evidence. A loop that closes on
measured outcomes improves on facts instead of on recollection.

### What enforces it today

- [`scripts/capture-session-log.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/scripts/capture-session-log.zsh)
  and
  [`tests/capture-session-log.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/capture-session-log.bats)
  — bundle a run's full transcript for analysis; see *Feeding real runs back
  into the plugins* in [Maintain this repo](../how-to/maintain-this-repo.md).
- [Pipeline telemetry](pipeline-telemetry.md) — why the pipelines record each
  run's outcome, and what they deliberately leave out.
- [`development/scripts/telemetry/emit-telemetry.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/scripts/telemetry/emit-telemetry.zsh)
  — the one shared emitter behind those records.

Today the loop only *captures* runs. Nothing yet assesses them, learns from
them, or proves an improvement worked — those steps are still done by hand.

### Gap

[#1624](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1624) —
close the self-improvement loop: a retrospective skill, a self-assessment
scorecard, and eval suites.
