# Plugin test harness — how `/development-claude-plugin:test` works

Operator-facing reference for the test harness shipped in v1 of the
`development-claude-plugin` family. The implementation lives in
[`skills/test/SKILL.md`](../skills/test/SKILL.md) and
[`skills/test/scripts/run-headless.zsh`](../skills/test/scripts/run-headless.zsh);
this file is the human-readable specification of the same behaviour.

**Human-invoked only.** The harness is for a person verifying their own edit,
never for an autonomous pipeline step: no unattended flow launches a headless
`claude` child (#2191). `/development:resolve-issue`'s epic verification runs
its end-to-end half in the session instead.

## Why it exists

A Claude Code plugin is mostly markdown — skills, agents, and commands that only
*do* anything once loaded into a real session. You can't meaningfully unit-test
them. The faithful test is: load the plugin the way a user would and run it
against a real project, then look at what actually happened.

The wrinkle is feedback. If the authoring session runs the plugin itself, the
target project's whole transcript floods the conversation you're trying to
develop in. The harness solves that with a **two-layer design**.

## The two layers

```text
authoring session  ──launches + waits──▶  headless child `claude -p`
(you, editing the                          (system under test: local plugins
 plugin)                                    loaded, runs against a clone)
       │                                          │ finished transcript + <out>.exit
       └──spawns, once <out>.exit exists──▶  judge subagent  ──▶ structured verdict
                                             (fresh context, firewall + judge)
```

1. **Headless child session (system under test).** A real `claude -p` process
   launched by `run-headless.zsh --detach` from the authoring session. It loads
   the **local, uncommitted** plugins from the worktree via `--plugin-dir`, runs
   against an isolated clone of the target repo, emits a `stream-json`
   transcript, and writes its exit code to `<out>.exit` when it finishes.
2. **The wait belongs to the authoring session.** It waits on `<out>.exit`
   with its own Monitor until-loop. A main session is re-woken by its own
   Monitor; a background subagent that ends its turn is not reliably re-woken
   by its own — which once left a finished child unread for 78 minutes (#2191).
3. **Judge subagent (firewall + verdict).** Spawned via the Task tool, with a
   clean context, only once the marker exists. It parses the finished
   transcript, diffs the clone, and returns only a compact `VERDICT:` block. It
   launches nothing and waits on nothing. The raw child transcript never
   reaches the authoring conversation.

## What gets tested, and against what

- **Surface:** any skill, agent, or slash command in the family — old or new.
  You choose via `--task` (e.g. `/development:maintenance --dry-run --tool ruff`).
- **Target:** a real reference project on disk. Default is
  `/Users/timo/repositories/ai-doc-organizer`, the canonical Python test bed.
  The harness clones it locally (`git clone --local`) into a temp dir so the run
  is **non-destructive and repeatable** — your real working copy is never
  touched, and the clone is deleted afterward.
  - **The clone reflects the target's committed HEAD, not its uncommitted
    working tree.** A `git clone --local` copies committed state only. So a test
    can legitimately surface artifacts an interactive run wouldn't — e.g. a build
    output that the target ignores via an *uncommitted* `.gitignore` edit will
    show as untracked in the clone, because the clone's `.gitignore` is the
    committed one. This is faithful behaviour, not a bug: if you want the test to
    match your live tree, commit the relevant `.gitignore` (or config) change in
    the target first.
- **Verdict:** structured `PASS`/`FAIL` plus which skills/agents fired, which
  tools ran, what files changed in the clone, whether the local plugin
  demonstrably loaded, and a short digest.

## Invocation

```bash
/development-claude-plugin:test \
  --target /Users/timo/repositories/ai-doc-organizer \
  --task "/development:maintenance --dry-run --tool ruff" \
  --expect "dispatcher ran in dry-run and produced a ruff group; no PRs opened"
```

All arguments are optional. With none, it runs a cheap **plumbing smoke test**:
it asks the child to confirm the local `development-claude-plugin` loaded by
listing its slash commands, which verifies the `--plugin-dir` wiring end-to-end
without spending a full maintenance run.

| Argument | Default | Purpose |
| --- | --- | --- |
| `--target <path>` | `…/ai-doc-organizer` | Real repo to clone and run against |
| `--task "<prompt>"` | plumbing smoke test | What the child session should do |
| `--expect "<text>"` | none | Plain-language PASS criteria for the judge |
| `--permission-mode <mode>` | `bypassPermissions` | Forwarded to the child; the child only touches the clone |

## Cost

A *full* maintenance run as a test is tens of thousands of tokens (it's a real
autonomous run in a child session). Keep iteration cheap by narrowing `--task`
to one tool and `--dry-run` (`/development:maintenance --dry-run --tool ruff`),
or use the default plumbing smoke test to check loading before spending a real
run.

## Known limitations

- **Double plugin load.** If a plugin under test is *also* installed from the
  marketplace in the user's Claude config, both copies can load and the
  installed version may shadow the local one. Mitigations: bump the local
  plugin's version above the installed one, or temporarily disable the installed
  copy. The judge flags `plugin_loaded: unclear` when it suspects this.
- **Nested `claude`.** A session launching a child `claude -p` via Bash is
  supported in practice but not formally documented. If the judge subagent
  cannot be spawned, the skill judges the transcript inline instead — at the
  cost of the child transcript entering the authoring context (the firewall is
  bypassed; the skill says so when this happens).
- **macOS / zsh only.** Per the family's scripting conventions, `run-headless.zsh`
  targets zsh on macOS.

## Roadmap

This harness is **Part B** of issue #217 and ships first because it has no
dependency on the maintenance-orchestrator refactor. **Part A** — the
`development-claude-plugin` maintenance dispatcher and its validation agents
(`claude-plugin-version-sync`, `-skill-validator`, `-reference-checker`,
`-structure-validator`) — lands after #249's language-leakage fix, and will
itself become a prime subject *for* this harness.
