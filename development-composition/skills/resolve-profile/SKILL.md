---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The composition
  repo type's driver rules for the resolve-issue conductor: which gate a change
  to a constellation repo must pass (the claude-workspace/v1 validator plus the
  repo's own bats suite), what §4's version bump means here, and which review
  panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **composition resolve profile**. `/development:resolve-issue` loaded
you at its §1b step because this repo detected as `composition` — a
constellation repo with a root `.claude-workspace.yaml` and no application
language of its own. You do not drive the run — the conductor does. You supply
the rules that are true of **this repo type and no other**, so a Go or
claude-plugin run never reads them, and so every composition-side edit lands
here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **The gate has two halves, run in this order, and both must pass.** First the
  manifest: `<this skill's base dir>/../../scripts/validate-workspace.zsh --repo
  <worktree_root>`, which judges `.claude-workspace.yaml` against the
  `claude-workspace/v1` contract. Then the repo's own bats suite, the whole of
  it, once, from the worktree root:
  `<resolve-issue skill-base-dir>/scripts/run-gate.zsh --tests-dir tests`
  (#980's single-run gate). As one command — the `<full gate>` that §3
  runs and the loop's `--test-cmd` repeats — that is the two joined with `&&`,
  the validator first, so a manifest that fails the contract never spends a
  suite run.
- **Read the validator by its exit code, never by its stdout.** `0` is a valid
  manifest. `1` with the validator's stderr line naming a member or
  environment is a contract violation, and `4` a missing or unreadable
  manifest: both are a **red gate** — fix the manifest the change broke,
  never the validator. `2` is your own malformed call: fix it and re-run. Any
  other status is no verdict about the manifest, red or green — `3`, the
  runner lacking mikefarah's `yq` or a working `jq`, among them:
  **report the missing tool and stop**, and never read it as a pass.
- **An empty bats suite is *nothing to gate*, never green.** When the round's
  tree holds no `*.bats` file under `tests/` — the shape bootstrap's
  composition scaffold leaves — the suite half has nothing to run.
  Do not run `run-gate.zsh` over it (its zero-test guard would report red, a
  claim about tests that do not exist), and
  never report that half as green or as a pass: say *nothing to gate* in those
  words, in the round's narration and in the PR's Test plan. The `<full gate>` of that round is then the
  validator alone, so the change is proven by the manifest check and nothing
  else, and the report says so.
- **`--gate-attest`: not applicable.** The `<full gate>` here is compound —
  the validator joined with `run-gate.zsh` — or the validator alone, which
  reports no tree at all. Either way, omit `--gate-attest` entirely and pass
  only `--findings-tree`: a tree match would let the loop skip the validator,
  which the attested run never executed. The round boundary's compound arm
  states the ordering; this profile restates none of it.
- **Relay a degraded suite run.** When `run-gate.zsh`'s summary reports
  `"mode":"sequential-degraded"`, tell the user up front that each round's gate
  runs several times slower and that `brew install parallel` fixes it.
- **Epic verification (§E4) runs the same two halves** over the merged epic's
  tree: the validator on its `.claude-workspace.yaml`, then the whole bats
  suite through `run-gate.zsh --tests-dir tests`, with the same
  nothing-to-gate rule for an empty suite. A composition repo deploys nothing
  from this gate, so E4 has no end-to-end half to drive here: promotion is the
  repo's own workflow, run on its own schedule, never by this step.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none** — a constellation repo ships no installable plugin content, so §4's
subject does not exist here and the step is a no-op. The fallback ordering
reaches `composition` only when `is_claude_plugin` is false, so a repo that
does carry plugin content loads the claude-plugin profile instead. This heading
supersedes the conductor's generic floor rather than narrowing it: that floor
governs the no-profile case, where the conductor cannot know what kind of repo
it is in. A member's image tag pinned in `.claude-workspace.yaml` is a property
of the change being made, decided in the manifest itself — never a bump this
step performs on the side.

Note that this heading is about a **target** repo of type `composition`. The
`development-composition` **plugin** in this family is a different thing, and
its own shipped-slice version rule lives with the claude-plugin profile that
governs edits to it.

## Panel

**`/development-composition:review`** — that skill is the panel, and the agents
it dispatches carry their own severity bars. It is the same value
`review-dispatch.zsh plan` emits as `review_skill` (the script builds it as
`development-${repo_type}:review`), which is what §3.5 actually dispatches;
this heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no composition-specific fix-pass rule has been established. #1502's
read-out is the evidence that would produce one; until it arrives, a rule here
would encode a guess as contract.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No
composition-specific documentation duty has been established; #1502's read-out
is where one would come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing composition-specific in it.
