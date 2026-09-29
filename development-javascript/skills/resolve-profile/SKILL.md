---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The javascript repo
  type's driver rules for the resolve-issue conductor: which test gate is blessed
  and how to judge its result, what §4's version bump means here, and which
  review panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **javascript resolve profile**. `/development:resolve-issue` loaded
you at its §1b step because this repo detected as `javascript`. You do not drive
the run — the conductor does. You supply the rules that are true of **this repo
type and no other**, so a Go or claude-plugin run never reads them, and so every
javascript-side edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **The gate runs at the repo root.** Detection counts a `package.json` or
  `tsconfig.json` anywhere in the tree, so a repo can be `javascript` with no
  root `package.json`. When the root has none, report "javascript detected from
  a non-root manifest; the gate runs at the repo root only", naming the manifest,
  and stop — before any `jq` read, so the cause is not misreported as a
  malformed file.
- **The whole suite is `npm run typecheck && npm test`**, with the typecheck
  half **only when `package.json` declares a `typecheck` script** — read it with
  `jq -r '.scripts.typecheck // empty' package.json` and, when it is empty, run
  `npm test` alone. **Check that read's own exit status**: a `jq` that failed
  (a malformed `package.json`, no `jq` at all) also prints nothing, and reading
  that as "no typecheck script" gates green on code that does not type-check —
  report the failure and stop instead. The test/typecheck pair is the one
  `development-javascript/agents/js-ci-fixer.md` runs to confirm a CI fix
  locally, so the gate and the fixer gate on the same suite. Never narrow `npm test`
  to the changed files or to one workspace: a subset can pass while a dependent
  module no longer type-checks or its tests go red.
- **Judge pass/fail by the command's own exit status, never by a `| tail`
  pipeline's.** A pipeline's status is its last command's — always `tail`'s
  `0` — so gating on `$?` of a `… | tail` reports green on a failed suite.
  Capture the suite's own status, as the anchor does with `echo "EXIT=$?"`.
- **A `package.json` with no real `test` script has no suite to gate on.**
  Read `.scripts.test` the same way. When it is absent, or is still npm's
  `init` placeholder (`echo "Error: no test specified" && exit 1`), `npm test`
  exits non-zero on every story, which is not a red this story can fix: report
  that the repo declares no test suite and stop. Adding one is a separate
  change, never part of this story's fix pass.
- **Lint is not the gate.** `npm run lint` exits 1 both when the script is
  missing and when the code has findings, so its status cannot tell the two
  apart; the repo's pre-commit hooks and its CI lint check own lint. Run the
  repo's `pre-commit` hooks as §3's first bullet says, and gate on the two
  commands above.
- **The gate installs from the lockfile before every gate run** —
  `npm ci`, which also replaces a `node_modules/` left stale by a story or fix
  pass that changed `package.json` or the lockfile. The gate's own install is
  never `npm install`, which can rewrite `package-lock.json`. A story that adds
  or bumps a dependency updates `package-lock.json` itself (`npm install
  <pkg>`), and that lockfile diff belongs to the story. npm is the family's
  blessed package manager, so a repo with no `package-lock.json` (none at all,
  or a `yarn.lock` / `pnpm-lock.yaml` instead)
  is not one this gate can install: report that and stop. **A non-zero `npm ci` is not a suite red** —
  a lockfile out of sync with `package.json`, a registry or network failure:
  report the install failure and stop, never hand it to the fix pass as a
  failing test.
- **`--gate-attest`: not applicable.** No attestable single-run runner of the
  `run-gate.zsh` shape (#981) ships for this type, so there is no `tree`
  identity to carry into the next round's `--resume`, and the loop re-runs the
  gate each round. Pass no `--gate-attest`: a value that never came from a green
  gate is not a mismatch — it is a false attestation, and the loop would skip a
  re-run it never earned.
- **Epic verification (§E4) uses this heading's gate unchanged**, plus — where
  the repo ships a runnable service or app — a real
  end-to-end exercise of the affected behaviour against a build of it, for the
  same reason the conductor's E4 asks it of a Java or Python app: a deployable
  thing whose children can integrate badly. A library-only package is exempt
  from the exercise, not from the suite.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none — *unless this repo also ships installable plugin content*.** Ordinarily
a javascript repo has no `<plugin>/` tree, so §4's subject does not exist and
the step is a no-op. A package's own `package.json` `version` is not §4's
subject: it is released by the repo's own release tooling, never hand-bumped by
a story.

**Check rather than assume, because the premise is falsifiable.**
`claude-plugin` is a *fallback* repo type: a detected language always wins, so a
repo that is both a javascript codebase **and** ships plugin content detects as
`javascript` and loads *this* profile — not the plugin one. If the change
touched a `<plugin>/` tree carrying `.claude-plugin/plugin.json`, apply the
conductor's §4 floor: bump that plugin's `plugin.json` **and** its matching
`.claude-plugin/marketplace.json` entry, or installs never see the change. Size
it by MAINTAINING.md's tiers — §4's floor supersedes nothing about sizing, and
deliberately states none of it.

## Panel

**`/development-javascript:review`** — that skill is the panel, and its agents
under `development-javascript/agents/` carry their own severity bars. It is the
same value `review-dispatch.zsh plan` emits as `review_skill` (the script builds
it as `development-${repo_type}:review`), which is what §3.5 actually
dispatches; this heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no javascript-specific fix-pass rule has been established. #1502's
read-out is the evidence that would produce one; until it arrives, a rule here
would encode a guess as contract.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No
javascript-specific documentation duty has been established; #1502's read-out is
where one would come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing javascript-specific in it.
