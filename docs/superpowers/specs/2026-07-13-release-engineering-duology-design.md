# Release engineering duology — observe-and-release for the plugin repo, release-please for target repos

**Date:** 2026-07-13
**Relation:** fourth parallel track (alongside #729, #740, #744). Parked from the
documentation-trilogy spec's out-of-scope list (PR #743). The tag→image contract
here is the socket the composition deploy-test epics (#719a) later plug into.

## Motivation

This repo has **zero git tags, zero GitHub releases, no CHANGELOG** — yet the
`development` plugin alone is at version 1.94.1: 94 minor versions of invisible
history, recoverable only from git log of `plugin.json`. Target repos are no
better: bootstrap ships no release machinery at all, while the composition
epics (#719/#720) assume target repos publish **version-tagged images** that
constellation repos pin and Renovate bumps.

The raw material is already in place: ~430 squash commits follow
`type(scope): subject (#PR)` where **the scope is the plugin name** — exactly
the component mapping monorepo release tooling needs — and the manual
version-bump convention (every content PR bumps `plugin.json` +
`marketplace.json`, guarded by the version-sync agent) is enforced habit.

## Decisions (settled in brainstorming, 2026-07-13)

| Decision | Choice |
|---|---|
| This repo's release model | **Observe-and-release**: the per-PR bump convention stays untouched; CI observes version changes on main and creates per-plugin tags + GitHub releases. Explicitly decided against release-please here |
| Target repos' release model | **release-please** (release-PR flow through normal CI + Approver gates); **nebula-release stays for Java** (declared policy), same external contract |
| Enforcement | **PR-title lint gate** (squash merge ⇒ PR title = commit subject), here and templated to target repos; zsh script, not a third-party action |
| Changelog (this repo) | **Releases are the changelog**; the docs site (#744 machinery) renders a per-plugin changelog page from release data at build time. No committed CHANGELOG.md here |
| Changelog (target repos) | Committed CHANGELOG.md, written by release-please's release PR |
| History | Anchor tags for the six **current** versions only; the 93 historic versions are NOT reconstructed (guessed history violates the reliability rule) |
| Packaging | **Duology 1/2 → 2/2**, native blocked-by |

## Epic 1/2 — this repo (observe-and-release)

### PR-title lint gate

A required CI check validates every PR title: `type(scope): subject` with
`type ∈ {feat, fix, docs, chore, refactor, test, perf, ci}` and `scope` empty
(repo-wide) or an actual plugin directory name — the scope list derived from
`ls */.claude-plugin/plugin.json` at check time, never hardcoded. A ~30-line
zsh script + thin workflow; no third-party action (one less pinned dependency;
scripting conventions apply).

### The observe workflow

On push to `main` touching `*/.claude-plugin/plugin.json`:

1. Diff each plugin's version against the previous commit.
2. For each bumped plugin: create tag `<plugin>-v<X.Y.Z>` at that commit and a
   GitHub release whose notes are the **scope-filtered** conventional commits
   since that plugin's previous tag, grouped by type (Features / Fixes / Docs /
   Internal).
3. Multiple plugins bumped in one merge → one tag + release each. First
   release → notes since the anchor tag.

Runs on the Actions `GITHUB_TOKEN` (`contents: write`); no App token.
**Caveat:** the PR introducing these workflow files must be **user-authored**
(the Writer App lacks the `workflows` permission by design).

### Children (epic 1/2)

- [ ] (a) PR-title lint gate (zsh script + workflow + branch-protection wiring).
- [ ] (b) Observe workflow (version-diff → tag + release with scope-filtered
      notes) + the release-notes builder script, bats-tested.
- [ ] (c) One-time anchor tags for the six current plugin versions.
- [ ] (d) Docs-site per-plugin changelog page generated from release data at
      docs build time — **this child alone is blocked by #744** (needs the docs
      machinery); the rest of the epic is independent.
- [ ] (e) User-facing docs (how releases work here, how to read the history).

### Acceptance (epic 1/2)

- A content PR with a bad title cannot merge; a good one merges and, on main,
  yields exactly one tag + one release for the bumped plugin, with notes
  containing only that plugin's commits.
- Two plugins bumped in one PR yield two tag/release pairs.

## Epic 2/2 — target repos (release-please; nebula for Java)

### Non-Java repos (Python now; JavaScript when #683 lands)

Bootstrap templates `release-please-config.json`, `.release-please-manifest.json`,
and a pinned `release-please-action` workflow. Flow: conventional commits
accumulate → release-please maintains a release PR (version file bump,
CHANGELOG.md, notes) → the release PR passes normal CI + Approver gates like
any bot PR → merging tags `vX.Y.Z` and creates the GitHub release.

### Java repos

nebula-release stays (version derived from git tags, bump from conventional
commits). Release trigger: the nebula flow (`gradlew final` via a
manual-dispatch workflow); notes via `gh release create --generate-notes` on
the resulting tag. Different mechanism, **same external contract** — consumers
cannot tell the difference.

### The tag→image contract (the socket for composition)

In every dockerized target repo, tag `vX.Y.Z` triggers image build + push
`ghcr.io/<owner>/<repo>:X.Y.Z`. This is the publish point where #719(a)'s
deploy-spec OCI-attach later hooks in. No `:latest` mutation games —
composition repos pin versions and Renovate bumps the pins.

### Children (epic 2/2)

- [ ] (a) release-please templates (config + manifest + pinned workflow) +
      bootstrap wiring + State-D adoption.
- [ ] (b) PR-title gate template (the script proven in epic 1/2).
- [ ] (c) Vendor-PR title compliance: Renovate `semanticCommits: enabled`,
      Dependabot `commit-message` prefix config, folded into the existing
      bootstrap templates.
- [ ] (d) Tag→image publish workflow template (`vX.Y.Z` → GHCR `:X.Y.Z`).
- [ ] (e) Java realization: nebula-flow release workflow (manual dispatch →
      `gradlew final` → tag → generated notes → same tag→image contract).
- [ ] (f) End-user docs (the release flow from a target-repo team's view).
- [ ] (g) Capstone validation on **ai-doc-organizer**: bootstrap → merge a feat
      PR → release PR appears → merge → tag + release + image `:X.Y.Z` +
      CHANGELOG, end-to-end.

### Acceptance (epic 2/2)

- A bootstrapped Python repo produces its first `v0.x` release through the
  release-PR flow with zero manual steps beyond approving PRs.
- The image tagged with the release version exists in GHCR after the release.
- A Java repo releases through nebula and lands the identical external
  contract (tag, release with notes, versioned image).

## Sequencing + GitHub packaging

- Duology chained with GitHub-native blocked-by (#583): **1/2 → 2/2**
  ("template only what's proven" + the shared title-gate script).
- Epic 1/2 is immediately runnable — a fourth parallel track.
- Epic 2/2 bumps the development plugin version (template changes reach installs).
- Titles: `Epic: release engineering (1/2 … 2/2)`.

## Out of scope

- Historic version backfill (guessed history is withheld, not published).
- Changing marketplace/install distribution — installs keep tracking main;
  releases are history + rollback anchors + notes, not a distribution gate.
- The composition repo's own release model (#687 territory).
- Switching this repo to release-please (explicitly decided against).
- Swift target-repo releases (revisit when a Swift app repo needs images).

## Interplay

- Telemetry #742 (downstream-outcome enrichment) can read release/tag facts
  for free once these exist.
- Deploy-test epics #719/#720 get real pinned image versions to compose; the
  deploy-spec attach rides the tag→image publish point.
- Docs trilogy #744 renders the changelog page (epic 1/2 child (d)).

## Risks

- **Observe-workflow races**: two merges in quick succession each trigger a
  run; tagging is idempotent per (plugin, version) so the second run is a
  no-op for the first run's work. The builder script must tolerate
  already-existing tags.
- **Scope-filter misses**: a mis-scoped commit lands in the wrong plugin's
  notes — bounded by the title gate (scope validated against real plugin
  names) so only *plausible-but-wrong* scopes slip through; human review of
  PR titles remains the backstop.
- **release-please + Approver interaction** in target repos: the release PR is
  bot-authored and must be approvable by the Approver App identity; validated
  in the ai-doc-organizer capstone before the template is declared done.
