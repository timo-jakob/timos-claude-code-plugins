# Explanation

Understanding-oriented material: the concepts, rationale, and design decisions
behind the plugins. Read these to understand *why* things are the way they are.

- [Motivation & current gaps](motivation.md) — why this repo exists, what's
  shipped, and an honest list of where it falls short.
- [Why per-language plugins?](why-per-language-plugins.md) — the five things a
  per-language plugin encodes that a generic prompt cannot.
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
- [The Grafana hand-off](telemetry-grafana-handoff.md) — why the reporting stack
  lives in another repo, why the telemetry envelope is closed, and why the
  hand-off is a committed artifact rather than a conversation.
