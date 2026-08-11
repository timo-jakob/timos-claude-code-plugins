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
   the repo, generates the policy + PR template. (**No workflow** — since
   epic #476 the Approver is user-invoked locally, and
   `claude-approver.yml.tmpl` was removed in #479.)
3. **Per-policy** — amend `.claude/approver-policy.md` as your team's norms
   evolve. Changes go through normal PR review.

## Local dry-run

`python-approver` runs locally too: spawn the agent in your worktree **with
`DRY_RUN=true`** and it executes the same logic and prints the verdict
instead of posting it. Useful for predicting what the Approver will say
before pushing.

**The `approve` skills are not a dry-run path.** `/development-python:approve`,
`/development-java:approve` and `/development-swift:approve` take an optional
PR number and nothing else — they pass `DRY_RUN=false`, so every invocation
**posts a binding review** under the `claude-approver-<owner>[bot]` identity.
Only `/development-go:approve` accepts a `--dry-run` flag (in any position).
Spawning the agent directly, with `DRY_RUN` set, is the print-only path on the
other three.

## Language support

Python, Java, and Swift ship `<lang>-approver` agents (fable) **and**
bootstrap-rendered policy templates today. Bootstrap wires the per-language
approver via `{{APPROVER_LANG}}`, which resolves **only** to those three.

**Go is a special case.** It ships `go-approver` and `/development-go:approve`,
but `{{APPROVER_LANG}}` does not resolve for it — so `--claude-approver true`
on a Go repo warns and skips the Approver wiring: **no App installed on the
repo** and **no policy file**. (Credential *registration* is language-independent,
so the Keychain half still happens; what is missing is the per-repo install, and
without it no installation token can be minted.) To use
`/development-go:approve` today you must therefore do both by hand: install the
Apps on the repo yourself
(`development/skills/bootstrap/scripts/install-claude-apps.zsh`), **or the token
mint fails**, and hand-author `.claude/approver-policy.md`, **without which the
agent hard-fails at its Step 1**.

Running `--claude-approver true` on any language `{{APPROVER_LANG}}` cannot
resolve — currently anything but Python, Java and Swift — warns and skips.
