# Motivation & current gaps

## Motivation

This repo exists to bootstrap new projects in no time and ship features and
applications that are high quality — both for the user experience and inside
the code — and that are secure by default. Across all of it, the goal is to
use Claude for maximum automation, pulling a human into the loop only when
human judgment is genuinely required.

I believe that in one or two years AI — and especially Claude — will be
capable enough that human-in-the-loop will be needed even more rarely in a
context like this. So this repo prepares for that now: build the seams,
gates, and policies today so that as the model gets stronger, the share of
work it can safely close out without a human grows automatically.

## How the plugins implement this today

What is shipped and aligned with the motivation:

- **Bootstrap installs the full Zero Tolerance toolchain by default.**
  `/development:bootstrap` doesn't ask which gates you want — ruff, mypy,
  semgrep, Sonar, Snyk, CodeQL, the 90 % new-code coverage floor, branch
  protection, and signed commits all land in one run. That is the
  "fast bootstrap + quality + security baked in by default" half of the
  motivation.
- **Maintenance is policy-driven, not narration-driven.**
  `/development:maintenance` is a JSON-dispatch contract to the language
  plugin. Each per-tool agent fixes what it can, suppresses with a written
  justification when the pattern is a false positive, and only escalates to
  a human when a public-API change would be required. That matches the
  "automate everything safely fixable, escalate only on judgment" half.
- **Dependabot / Snyk triage merges what is safe — once approved.**
  `python-dependabot-snyk-triage` merges patch + minor bumps when CI is
  green and an approving review exists (from `claude-approver[bot]` or a
  human); otherwise it arms GitHub's native auto-merge. It never posts
  approvals itself (#224). Deduplication keeps Snyk and Dependabot from
  stepping on each other when both target the same package.
- **Worktree isolation + local test verification.** Every agent that
  modifies code runs the project's test suite *locally* in its worktree
  before declaring success. CI is the secondary safety net, not the primary
  verification loop — exactly the shape that makes raising automation safe
  as models improve.
- **The Approver.** The motivation's "movable seam." Two distinct
  GitHub Apps, in-repo policy file, author allowlist, per-type
  criteria, hidden-JSON re-ingest into `/development:maintenance`.
  Phases 0–3 are shipped (App registration, bootstrap install,
  workflow + policy + PR templates, the `python-approver` fable agent); Phases
  4–6 (maintenance re-ingest, local `/approve`, end-to-end validation)
  remain. The Python library-exports API-stability gate (`griffe` +
  version-bump bypass) is also shipped and couples into the Approver's
  per-type rules. See [The Claude Approver](claude-approver.md) for the design and the
  current ship-status table.
- **Autonomous story delivery — readiness gate + local review loop.**
  `/development:resolve-issue` runs a **story-readiness gate** before any code is
  written (testable acceptance, bounded scope, resolved dependencies, plus a
  risk classification — [#559](https://github.com/timo-jakob/timos-claude-code-plugins/issues/559)),
  then a **local, pre-push review loop**
  ([#562](https://github.com/timo-jakob/timos-claude-code-plugins/issues/562)):
  the language review panel is invoked **diff-scoped**
  ([#560](https://github.com/timo-jakob/timos-claude-code-plugins/issues/560)),
  emits **machine-readable findings**
  ([#558](https://github.com/timo-jakob/timos-claude-code-plugins/issues/558)),
  and a **consolidator** turns them into one prioritised changelist
  ([#561](https://github.com/timo-jakob/timos-claude-code-plugins/issues/561)).
  The loop fixes blockers and re-reviews up to five rounds, so a PR is only
  opened — and CI minutes only spent — on code the panel has already converged
  on. Convergence attaches a **review dossier** the Approver re-ingests
  ([#563](https://github.com/timo-jakob/timos-claude-code-plugins/issues/563));
  every non-converged exit is a **typed `needs-human-decision` escalation** with
  no draft PR
  ([#564](https://github.com/timo-jakob/timos-claude-code-plugins/issues/564));
  each run appends **JSONL telemetry**
  ([#566](https://github.com/timo-jakob/timos-claude-code-plugins/issues/566)).
  The epic flow drives all children in one invocation, halting only on those
  escalations
  ([#565](https://github.com/timo-jakob/timos-claude-code-plugins/issues/565)).
  Epic [#557](https://github.com/timo-jakob/timos-claude-code-plugins/issues/557),
  validated end-to-end on the `ai-doc-organizer` test bed
  ([#567](https://github.com/timo-jakob/timos-claude-code-plugins/issues/567)):
  a well-specified story ran gate → review loop → dossier PR → Approver →
  auto-merge; an underspecified one halted at the readiness gate; and a
  security-conflicted one escalated to `needs-human-decision` with no PR.
- **Dependency-aware resolve-issue — GitHub-native `blockedBy` as the enforced
  source of truth.** Before the readiness gate or any branch, a **dependency
  precheck** walks the issue's native blocked-by graph transitively
  ([#584](https://github.com/timo-jakob/timos-claude-code-plugins/issues/584))
  and rejects on open blockers — autonomous runs post an argumentation
  comment plus the `blocked` label and **never auto-chain**
  ([#585](https://github.com/timo-jakob/timos-claude-code-plugins/issues/585));
  interactive runs offer **guided remediation** (resolve blocker + named issue,
  or just the blocker; deepest-first, one PR per blocker
  — [#586](https://github.com/timo-jakob/timos-claude-code-plugins/issues/586));
  an **epic blocker remediates as a whole epic** (full Epic flow to a closed
  epic before the dependent proceeds —
  [#587](https://github.com/timo-jakob/timos-claude-code-plugins/issues/587));
  cycles are refused, not looped (GitHub only rejects direct 2-cycles — our
  transitive detection caught a live 3-cycle). Epic
  [#583](https://github.com/timo-jakob/timos-claude-code-plugins/issues/583),
  validated end-to-end on a native-relationship test bed
  ([#588](https://github.com/timo-jakob/timos-claude-code-plugins/issues/588)
  — evidence in [`development/skills/resolve-issue/docs/DEPENDENCY-VALIDATION.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/resolve-issue/docs/DEPENDENCY-VALIDATION.md)).
- **Issue refinement + persona registry — the definition layer.** When the gate
  says "not ready," `/development:refine-issue` is the guided path back: a human
  loops the `issue-refiner` agent
  ([#575](https://github.com/timo-jakob/timos-claude-code-plugins/issues/575)),
  which turns the gate's objections into questions, a prose rewrite, and a
  durable **`story-spec/v1`** block
  ([#574](https://github.com/timo-jakob/timos-claude-code-plugins/issues/574)) —
  machine-readable and provenance-stamped so a later prose edit is detectable as
  staleness — written back onto the issue (human-authored). For a
  **surface-touching** story the gate's **interface-aware check 5**
  ([#670](https://github.com/timo-jakob/timos-claude-code-plugins/issues/670))
  classifies the runtime `surface` (`rest`/`grpc`/`web-ui`/`cli`) and
  hard-requires a concrete `use_case` plus outside-in happy/corner/error
  `test_cases`; those cases spin out into linked **`test-case` issues**
  ([#671](https://github.com/timo-jakob/timos-claude-code-plugins/issues/671))
  that `resolve-issue` then implements as acceptance tests **in the same PR** as
  the feature, closing story + test-case issues together so tests and feature
  can never drift
  ([#696](https://github.com/timo-jakob/timos-claude-code-plugins/issues/696)).
  The block's **outside-in** test data is drawn from a repo's **persona
  registry**: `/development:define-personas` builds `personas/v1`
  ([#665](https://github.com/timo-jakob/timos-claude-code-plugins/issues/665))
  via the `persona-definer` agent
  ([#666](https://github.com/timo-jakob/timos-claude-code-plugins/issues/666)),
  the readiness gate validates persona references as **advisories** (never a hard
  fail), and `refine-issue` mines their `data_traits` for realistic payloads
  ([#668](https://github.com/timo-jakob/timos-claude-code-plugins/issues/668)).
  A session that can't converge takes a **typed parked exit** a later run resumes
  from ([#578](https://github.com/timo-jakob/timos-claude-code-plugins/issues/578)),
  every run emits JSONL **telemetry**
  ([#579](https://github.com/timo-jakob/timos-claude-code-plugins/issues/579)),
  and pointed at an **epic** `refine-issue` walks each `needs-refinement` child
  ([#580](https://github.com/timo-jakob/timos-claude-code-plugins/issues/580)).
  Epics [#573](https://github.com/timo-jakob/timos-claude-code-plugins/issues/573)
  (refinement) + [#664](https://github.com/timo-jakob/timos-claude-code-plugins/issues/664)
  (personas); a **documented end-to-end run** is in
  [`development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md)
  ([#581](https://github.com/timo-jakob/timos-claude-code-plugins/issues/581) /
  [#669](https://github.com/timo-jakob/timos-claude-code-plugins/issues/669)).

## Current gaps

Honest list of where the implementation does not yet match the motivation.
Each gap has a tracking issue, and that issue is responsible for updating
this section when it lands.

1. **Approver shipped; live validation in progress.** Phases 0–5 of
   [#89](https://github.com/timo-jakob/timos-claude-code-plugins/issues/89)
   plus [#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174)
   have merged — App registration, bootstrap install, workflow / policy
   / PR templates, the `python-approver` fable agent, maintenance
   re-ingest of the Approver's hidden-JSON findings, local `/approve`
   dry-run, and the griffe-based API-stability gate. Adoption docs
   shipped in [`development/skills/bootstrap/docs/APPROVER.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER.md)
   ([#88](https://github.com/timo-jakob/timos-claude-code-plugins/issues/88)).
   **Remaining:** Phase 6 — end-to-end validation against the
   `ai-doc-organizer` test bed. The first bot PR after a fresh
   bootstrap will exercise the workflow including the
   Claude-Code-install detail.
2. **Coverage is a number, not a judgment — addressed.** Phase 3 of
   #89 shipped the agent's test-quality detection (`assert True`
   filler, mock-return-only assertions, tests-mocking-the-unit,
   name-promises-the-assertions-don't-verify); Phase 4 closed the loop
   so `/development:maintenance` re-ingests test-quality findings and
   dispatches `python-coverage-improver` to rewrite the offending
   tests. Live validation that this works end-to-end is part of
   Phase 6.
3. **Maintenance language parity.** Python, Java, Swift, and Go each have
   the full triage + worktree + autonomous-fix pipeline (Java via epic #296,
   Swift via epic #297, Go via epic #868). JavaScript has the dispatcher and
   a format/lint group only (epic #683; that slice is #729); PowerShell, zsh,
   and Rust are not implemented. Those gaps are intentional sequencing — Python was the
   proving ground for the dispatch contract; the other languages follow once
   each prior loop is solid. Tracked:
   [#170](https://github.com/timo-jakob/timos-claude-code-plugins/issues/170).
   Angular is a different case entirely: it is **not** a sequencing gap but a
   standing position — React is the family's single browser-UI default, so
   Angular is deliberately not a target and no `development-angular` is
   planned. It is not waiting its turn.
4. **macOS + Homebrew lock-in.** `/development:bootstrap`'s automation
   scripts assume macOS + Homebrew. The generated `SETUP.md` is
   platform-agnostic but the one-shot bootstrap isn't. Tracked:
   [#171](https://github.com/timo-jakob/timos-claude-code-plugins/issues/171).
5. **Two topic plugins are still aspirational.** `development-container` and
   `development-opentofu` are described in
   [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)
   but not implemented. `development-kubernetes` has landed its ownership
   boundary and marketplace registration
   ([#1151](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1151))
   its topic marker, gather script and maintenance dispatcher
   ([#1152](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1152)),
   and its five agents and review panel
   ([#1153](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1153)),
   and the bootstrap check pipeline that finally gives a GitOps repo checks it
   can require
   ([#1154](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1154));
   its self-contained test fixtures are the remaining child of
   [#1150](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1150).
   Security-by-default really wants the container plugin
   (Trivy, SBOM, distroless) shipped. Tracked:
   [#172](https://github.com/timo-jakob/timos-claude-code-plugins/issues/172).
