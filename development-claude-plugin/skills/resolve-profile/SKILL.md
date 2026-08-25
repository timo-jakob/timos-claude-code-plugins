---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The claude-plugin
  repo type's driver rules for the resolve-issue conductor: which test gate is
  blessed and what to capture from it, what §4's version bump means here, which
  review panel applies, and what this type expects of a fix pass, its docs and
  its residue. The conductor detects the repo type at §1b and loads the matching
  `development-<repo_type>:resolve-profile` by name; a type with no profile keeps
  the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **claude-plugin resolve profile**. `/development:resolve-issue`
loaded you at its §1b step because this repo detected as `claude-plugin`. You do
not drive the run — the conductor does. You supply the rules that are true of
**this repo type and no other**, so a Go or Python run never reads them, and so
every plugin-side edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **Run the blessed single-run parallel gate rather than bare `bats`:**
  `<resolve-issue skill-base-dir>/scripts/run-gate.zsh --tests-dir tests` (#980)
  — it runs the whole `bats tests` suite **exactly once**, parallelised via
  `--jobs` = CPU count on a multi-core host with GNU `parallel`, and run
  sequentially otherwise — loudly (a degraded warning) only on a multi-core host
  missing GNU `parallel`, quietly on a single-core host where there is nothing to
  parallelise — prints the ok/not-ok counts plus bats' **real** exit code (a JSON
  summary on stdout), and exits with that code, so it drops in as the gate
  command. A run that reports **zero** tests is forced to a non-zero (red) exit
  — never a false green. Never hand-roll a `bats … | grep -c` that runs the
  suite twice to count.
  - **Capture the gate attestation (#981).** On a **green** `run-gate.zsh`,
    keep its stdout `"tree"` field — the working-tree identity it just gated. On
    the **next** review round's `--resume` you pass it as `--gate-attest` (§3.5)
    so the loop skips a byte-identical re-run of the exact same tree it already
    proved green — the single biggest per-round duplicate the #976 session paid.
    It is a plain identity, not a verdict; `exit`/`ok` counts remain the pass
    signal, and the loop re-runs the gate on any mismatch (fail-closed). From
    §3.5's round boundary on, that identity is the `T` minted **before** this
    gate was started, and the gate's `tree` field is what confirms it — see
    *The round boundary is concurrent* (§3.5), which states the ordering; this
    profile restates none of it.
- **Relay a DEGRADED gate to the user, up front (#980).** `run-gate.zsh`'s
  stdout summary carries a `"mode"` field. When it is `"sequential-degraded"`
  (GNU `parallel` is not installed), the gate still ran the **whole** suite at
  full rigor — but sequentially, so every review round's gate takes multiple
  times longer. Tell the user **clearly and immediately**: that parallelization
  is unavailable, that each round's gate will be several times slower, and that
  the fix is `brew install parallel`. Never quietly absorb the slowdown.
- **Epic verification (§E4) uses the same command.** The holistic end-to-end
  test of a merged epic's domain is the full `bats` suite via that same blessed
  single-run gate — `<resolve-issue skill-base-dir>/scripts/run-gate.zsh
  --tests-dir tests` (#980 — same parallel, single-run, real-exit command as
  Step 3; never a bare `bats … | grep -c` that runs the suite twice) — **and**
  `/development-claude-plugin:test` driving the affected skills/agents
  end-to-end (the same pattern used to verify slices by hand).

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

If you changed any plugin's installable content (`<plugin>/…`), bump that
plugin's `plugin.json` **and** its matching `.claude-plugin/marketplace.json`
entry (per the version-bump convention) — otherwise installs never see the
change. A patch for a fix, a minor for a feature, a **major** for a breaking
change to a plugin's external contract (input schema, response shape, expected
file layout) — MAINTAINING.md's table is the authoritative statement of the
tiers, and this heading adds only the type-specific exception that follows.

**One plugin-local override.** A plugin whose version prefix is pinned to a
shipped-slice label moves only its **patch** digit until the slice itself grows,
whatever the tiers above would say (MAINTAINING.md states the rule under that
same name). Today that is `development-kubernetes`, whose `0.3.` prefix
`tests/kubernetes-plugin-skeleton.bats` asserts, so cutting a minor there means
moving the label sites in the same PR. Skip for root-only docs.

## Panel

**`/development-claude-plugin:review`** — that skill is the panel, and its
agents under `development-claude-plugin/agents/` carry their own severity bars.
It is the same value `review-dispatch.zsh plan` emits as `review_skill`, which is
what §3.5 actually dispatches; this heading **records** that, it does not
override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — for now. The claude-plugin fix-pass rules that exist today live
inside `development/skills/resolve-issue/reference/*.md` byte-frozen
`<!-- moved: … -->` sentinel spans, which #1504 deliberately did not touch.
Extracting them into this heading is **#1506**.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767) —
which is not the same as no duty at all. A change here that alters a contract
still carries a **maintainer-facing** duty, stated once in ARCHITECTURE.md,
MAINTAINING.md and `docs/reference/commands.md` rather than restated here. Read
them there; this heading adds no type-specific rule of its own.

## Residue

**none**, and — unlike the two headings above — not because the rule is parked
in a frozen span. The residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is entirely
repo-type-agnostic: issue filing, labels and the dossier, with nothing specific
to a plugin repo in it. So there is no claude-plugin residue rule to extract;
**#1506** confirms that rather than moving anything here.
