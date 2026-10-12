# Explanation

Understanding-oriented material: the concepts, rationale, and design decisions
behind the plugins. Read these to understand *why* things are the way they are.

- [Motivation & current gaps](motivation.md) — why this repo exists, what's
  shipped, and an honest list of where it falls short.
- [Why per-language plugins?](why-per-language-plugins.md) — the five things a
  per-language plugin encodes that a generic prompt cannot.
- [How the plugins work](how-the-plugins-work.md) — the main workflows step by
  step: one end-to-end lifecycle diagram and one per workflow, who acts (you,
  the conductor, its subagents, the two bots), the agent cast, and how the
  persona registry feeds a story.
  One page each for [refine-issue](workflow-refine-issue.md),
  [resolve-issue](workflow-resolve-issue.md), [bootstrap](workflow-bootstrap.md)
  and [maintenance](workflow-maintenance.md). Also published as the standalone
  workflows booklet (PDF and ePub).
- [How the family learns](how-the-family-learns.md) — above the single run:
  the positions the family builds towards, what every run records, and the
  self-improvement loop that turns that evidence into the next release — with
  what ships today and what is still planned.
- [The Claude Approver — design summary](claude-approver.md) — the movable
  human/AI approval seam, its two-App identity model, and the gating rules.
- [The C4 architecture docs](c4-architecture-docs.md) — the two-level C4 model
  this family keeps, and what the same-PR currency check does and does not
  verify.
- [The target-repo docs stack](target-repo-docs-stack.md) — what bootstrap
  installs into every repo, the three publication channels, and the same-PR
  lifecycle that keeps target-repo docs from rotting.
- [The local review loop](review-loop.md) — the pre-push review→fix→test loop
  `/development:resolve-issue` runs before any PR, and the interactive
  escalation that lets a present human grant more rounds or give guidance.
- [The IaC gate](iac-gate.md) — why a GitOps repository gets one gate command
  run locally, in the pre-push hook and in one CI job, over rendered output.
- [Pipeline telemetry](pipeline-telemetry.md) — why the pipelines record
  anything, what is deliberately not collected, and why the sink stays on your
  machine.
- [The Grafana hand-off](telemetry-grafana-handoff.md) — why the reporting stack
  lives in another repo, why the telemetry envelope is closed, and why the
  hand-off is a committed artifact rather than a conversation.
- [Philosophy](philosophy.md) — the six pillars the family is designed around,
  what enforces each one today, and the epic that closes each remaining gap.
