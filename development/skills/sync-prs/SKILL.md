---
name: sync-prs
description: >
  Re-sync open Maintenance-App PRs that have become conflicting with main since
  they were opened: rebase each one onto origin/main with the rebase engine (the
  repo type's merge driver resolves mechanical manifest conflicts by rule),
  force-push it as the Maintenance App under a lease pinned to its pre-rebase
  head, and re-trigger CI so armed auto-merge can fire. A PR with a real
  conflict gets the needs-manual-rebase label and one comment naming the files;
  human-authored PRs are reported and never touched. Idempotent — meant to be
  run repeatedly, e.g. under /loop. Supports --dry-run.
disable-model-invocation: false
---

You are a thin conductor over one script. `scripts/sync-prs.zsh` inside this
skill's base directory does all the work; you run it, relay its report, and
explain what each entry means. Never rebase, push, comment or label by hand
alongside it.

**User input:** $ARGUMENTS — empty, or `--dry-run`.

## Step 1 — run the script

Run it from the **root of the repository** whose PRs are to be synced:

```bash
"<skill-base-dir>/scripts/sync-prs.zsh"             # sync
"<skill-base-dir>/scripts/sync-prs.zsh" --dry-run   # rebase only, change nothing
```

A PR is a **candidate** when its `mergeable` is `CONFLICTING`, its author is
this repository owner's Maintenance App (`app/claude-maintenance-<owner>`, the
App `mint-maintenance-token.zsh` mints), its head branch lives in this
repository, and it does not carry the `needs-manual-rebase` label. For each
candidate, in order of PR number, the script:

1. adds a scratch worktree on the PR head and runs
   `development/scripts/merge/rebase-onto-main.zsh` in it (#1822);
2. on `clean` or `resolved`, force-pushes the rebased head as the Maintenance
   App with `--force-with-lease` pinned to the pre-rebase sha, then runs
   `retrigger-pr-ci.zsh --grace 0` — a push made with an App installation token
   to an open PR runs no workflows (#605), so without that close+reopen nudge
   armed auto-merge would never fire;
3. on `conflict`, adds the `needs-manual-rebase` label (created if absent) and
   then posts **one** PR comment naming the conflicting files. Later runs skip
   the PR until a human rebases it and removes the label. The label goes on
   first: if it fails, no comment is posted and the next run tries again;
4. removes the worktree, on every path.

The token is minted once, at the first push, comment or label, and never under
`--dry-run`. It is read from its mode-600 file at the point of use, the same
rules `open-pr` Step 2 follows, and never appears in the output.

`--dry-run` still runs the rebases (in scratch worktrees, which are removed), so
its verdicts are real — but it pushes, comments and labels nothing, and never
invokes the mint script.

## Step 2 — relay the report

Stdout is one JSON object:

```json
{"prs":[{"number":412,"verdict":"resolved","action":"pushed",
  "resolved":[{"path":"development/.claude-plugin/plugin.json","plugin":"development",
    "field":"version","main":"1.215.0","pr":"1.214.1","result":"1.215.1"}],
  "reason":"result: NUDGED — closed+reopened PR #412 to re-trigger CI on 3f2a…"}]}
```

- `verdict` — the engine's: `clean`, `resolved`, `conflict`, or `null` when it
  did not run or printed none.
- `action` — `pushed`, `push-rejected`, `conflict` (labelled and commented),
  `engine-failed` (the engine exited 2 or 3, or printed no verdict — nothing was
  pushed, commented or labelled), `unchanged` (already on main's tip),
  `skipped`, `failed` (the head could not be fetched or checked out), or under
  `--dry-run` `would-push` / `would-mark-conflict`.
- `resolved` — the engine's records, one per manifest field the merge driver
  resolved; list each (path, plugin, field, main → PR → result).
- `reason` — for `skipped`: `human-authored`, `cross-repository`, `labelled`,
  `mergeable-unknown` (GitHub was still computing it; a later run picks it up)
  or `empty-after-rebase` (every commit of the PR is already on `main`). For the
  other actions: the conflicting files, the engine's exit and last stderr line,
  the push's last stderr line, or, on `pushed`, the CI nudge's outcome. Relay
  any other value verbatim.

`MERGEABLE` PRs have nothing to do and are left out of the report.

| Exit | Meaning |
|---|---|
| `0` | every PR was handled — conflicts, skips and per-PR failures included |
| `2` | usage: any argument other than `--dry-run` |
| `3` | runtime: `gh`, `git` or `jq` unavailable, not in a git work tree, the repo or PR listing failed, a temp file could not be written, or the token mint failed — all before any PR was changed. The one exception is a report that cannot be assembled at the end, after the per-PR work: say so, and read stderr. Stdout is empty |
| `130` | interrupted; stdout is empty and the scratch worktrees are removed |

Summarise per PR, and say plainly which PRs need a human:

- every `conflict` entry — someone rebases it by hand and removes the label;
- a `conflict` entry whose `reason` says the label failed — nothing was
  posted; the next run retries it, so say that the label step is failing;
- every `engine-failed` and `failed` entry;
- a `push-rejected` entry — a lease rejection (`stale info`, the head moved
  since the listing) is retried by the next run; anything else (a local
  pre-push hook, a branch rule, permissions) needs a human;
- a `pushed` entry whose `reason` begins `pushed, but` — CI was not
  re-triggered, or auto-merge was left disarmed and must be re-armed by hand;
- a `skipped` entry with `empty-after-rebase` — its work is already on `main`,
  so it should be closed; every later run will re-rebase it until it is.

## Run it repeatedly

The skill is **idempotent**: a run over a state an earlier run already synced
pushes nothing. Merging one PR moves `main`, which can make another PR conflict
again, so repeated runs are the expected mode — for example
`/loop 15m /development:sync-prs`.

## Approvals may be dismissed

A push can dismiss the PR's existing approval — on a repository where a human
approves each PR, a synced PR then needs approving again before auto-merge
fires. Carrying that approval across a mechanical re-sync is #1824. Until it
lands, after every run with a `pushed` entry, check each one with
`gh pr view <n> --json reviewDecision,state` and tell the user which are still
open and not `APPROVED`.

Out of scope: calling this automatically from `resolve-issue`, and any PR that
is not authored by the Maintenance App.
