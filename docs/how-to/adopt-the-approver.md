# Adopt the Claude Approver on your repo

The Claude Approver is the final synthesis layer that can supply the approving
review branch protection requires — from Claude rather than (or in addition to)
a human. For the design and *why*, see
[The Claude Approver — design summary](../explanation/claude-approver.md). The
operator-facing adoption guide is
[`development/skills/bootstrap/docs/APPROVER.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER.md).

## Steps

1. **Per-org (one-time)** — register both GitHub Apps (Claude Approver +
   Claude Maintenance); capture App IDs and private keys. The
   [`development/skills/bootstrap/scripts/register-claude-apps.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/scripts/register-claude-apps.zsh)
   script walks the manifest flow; see
   [`development/skills/bootstrap/docs/CLAUDE-APPS.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/CLAUDE-APPS.md)
   for the design and the manual fallback.
2. **Per-repo** — `/development:bootstrap --claude-approver true`. Bootstrap
   stores credentials (via `install-claude-apps.zsh`), installs the Apps on
   the repo, generates the workflow + policy + PR template.
3. **Per-policy** — amend `.claude/approver-policy.md` as your team's norms
   evolve. Changes go through normal PR review.

## Local dry-run

`python-approver` runs locally too: invoke the agent in your worktree and
it executes the same logic without posting a review. Useful for predicting
what CI's Approver will say before pushing. (The `/development-python:approve`,
`/development-java:approve`, and `/development-swift:approve` skills wrap this.)

## Language support

Python, Java, and Swift ship `<lang>-approver` agents (fable) + policy
templates today. Bootstrap wires the per-language approver via
`{{APPROVER_LANG}}`; running `--claude-approver true` on a language with no
approver warns and skips.
