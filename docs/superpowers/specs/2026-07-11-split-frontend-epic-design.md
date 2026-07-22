# Split-frontend — epic decomposition design (2026-07-11)

Tracking epic: **#717**. Depends on epic **#682** (WebUI plugin family + API
lifecycle).

## Context

ARCHITECTURE.md's polyrepo section is explicit about the shape the plugin family
optimizes for: **many small, independently-deployable repos held together by
published contracts** — a frontend team and a backend team owning *separate*
repos, not one mixed repo. The family can already *bootstrap* repos into that
shape, but there is **no supported path to get there from an existing mixed
backend+frontend repo.** Teams that started with one repo are stuck.

This epic closes that gap with a standalone skill that performs the migration:
carve the frontend out of a mixed repo into a new `<name>-ui` repo (history
preserved), then compose bootstrap on both sides so each lands independently
deployable, communicating only through the backend's published OpenAPI contract.

The immediate motivating case: **ai-doc-organizer** — small, real, and (by the
maintainer's own account) "too little" to be a standalone WebUI target. That
smallness is exactly what makes it the safe capstone validation for the split.

## Decisions (approved 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| Where does it live? | **Standalone skill/command**, e.g. `development:split-frontend` — **NOT** a bootstrap mode | Bootstrap is single-repo and idempotent by design; cross-repo surgery must not leak into it |
| Epic or child of #682? | **Its own epic (#717)**, `blocked-by #682` | Distinct deliverable with its own decomposition; downstream of the WebUI family |
| Git history | **Preserve** via `git filter-repo` subtree extraction | Blame/archaeology survives into the `-ui` repo; the respectful default for real projects |
| Frontend detection | **Auto-detect confined subtree + confirm; refuse on interleaved** | Clean when the frontend is a subdirectory; refuse rather than attempt risky per-file untangling |
| Skill scope | **Thin orchestrator** — composes bootstrap twice + wires one contract link | Producer publish + consumer client-gen are owned by bootstrap / #682, not duplicated here |
| Backend safety | **Non-destructive** — `-ui` repo created additively; backend frontend-removal lands as a **reviewable PR**, never a direct push | Reversible until merge; matches the org's "human approval, never push to main" rule |

## Architecture — thin orchestrator, five phases

The skill is a **thin orchestrator**. Its unique responsibility is the
*extraction and repo choreography*; every toolchain and contract concern is
delegated to bootstrap (and therefore to epic #682).

### Phase 1 — Detect & confirm

Locate the frontend as a **confined subtree**: an obvious directory (`frontend/`,
`ui/`, `web/`) or a nested `package.json` with framework markers (Angular/React).
Present the proposed path set to the user for confirmation/correction. **No
surgery happens until the user confirms.**

**Precondition — separable subtree.** If the frontend is *interleaved* with the
backend inside shared directories (the "full untangling" case), the skill
**refuses** and instructs the user to disentangle into a subtree first. It never
attempts risky file-by-file separation across shared directories.

### Phase 2 — Extract with history

`git filter-repo` subtree-extracts the confirmed paths into a fresh working copy.
Every commit that touched the frontend is preserved; this working copy becomes
`<name>-ui`.

### Phase 3 — Create & bootstrap the UI repo

`gh repo create <name>-ui` with **visibility inherited from the source repo**,
push the extracted tree, then invoke the **WebUI bootstrap** (#682) on it. That
bootstrap — not this skill — installs the toolchain and the **consumer-side
client generation** against the backend's published contract.

### Phase 4 — Slim the backend as a PR

On a branch off the backend's fresh `main`: delete the frontend paths, strip
frontend-specific build/CI steps, and re-run the backend bootstrap so the
toolchain reconciles to a backend-only repo. Open a **normal PR** — never a
direct push — so a human/Approver reviews the deletion. The split is
**reversible until that PR merges.**

### Phase 5 — Wire the one cross-repo link

Point the UI repo at the backend's **published contract package** (the npm spec
package from #684(a)). This single link is the skill's only contract concern;
the publish machinery, the semver gate, and the client generator all belong to
bootstrap / #682.

## Isolation & boundaries

| Unit | Does | Depends on |
|---|---|---|
| detection | Identifies the frontend subtree, refuses on interleaved, gets confirmation | repo file layout, framework markers |
| extraction | History-preserving subtree carve + `-ui` repo creation | `git filter-repo`, `gh repo create` |
| ui-bootstrap wiring | Runs WebUI bootstrap on the new repo, wires contract consumer | #682 (#683, #685), #684(a) |
| backend-slim | Deletes FE paths + CI, re-bootstraps, opens reviewable PR | backend bootstrap, PR flow |
| validation | End-to-end proof on ai-doc-organizer | all of the above |

Each unit has a single purpose and a well-defined interface; the orchestrator
sequences them but holds no toolchain logic of its own.

## Epic decomposition (children)

Filed as bounded stories when work starts (after #682 lands the prerequisites):

- **(a)** Frontend-subtree detection + interleaved-refusal + confirmation UX
- **(b)** History-preserving extraction (`git filter-repo`) + `-ui` repo creation
- **(c)** UI-side bootstrap invocation + contract-consumer wiring
- **(d)** Backend slimming as a reviewable PR (delete paths, strip FE CI, re-bootstrap)
- **(e)** **User-facing documentation** — document the new split command in the user
  docs / command reference: what it does, its preconditions (separable subtree),
  the two-repo outcome, and the backend-PR review step
- **(f)** End-to-end validation on **ai-doc-organizer** (capstone)

## Dependencies

**Blocked by #682.** The split composes bootstrap paths that #682 delivers; it
cannot run until they exist:

- **#683** — `development-javascript` foundation **+ consumer-side client generation**
- **#686** — `development-react` bootstrap (stands up the new `-ui` repo; React
  first per the 2026-07-22 reordering on #682 — an Angular frontend needs #685)
- **#684(a)** — producer-side per-major `contracts/` layout + npm spec publish

GitHub-native `blocked-by` (#583) is authoritative.

## Sequencing

1. File this epic (#717) — done.
2. Build #682 far enough: **#683 + #685 + #684(a)**.
3. Build this epic's children (a)–(e).
4. Validate end-to-end on ai-doc-organizer (f).

## Acceptance (umbrella)

- [ ] The split is a standalone skill/command, not a bootstrap mode.
- [ ] Extraction preserves frontend git history in `<name>-ui`.
- [ ] Detection auto-proposes the subtree, confirms with the user, and refuses on
      interleaved layouts.
- [ ] The `-ui` repo is created and WebUI-bootstrapped; the backend change lands as
      a reviewable PR (never a direct push).
- [ ] The UI repo consumes the backend's published contract package; no repo
      depends on another repo directly.
- [ ] **User-facing documentation** describes the new command.
- [ ] End-to-end validated by splitting ai-doc-organizer into backend + `-ui`.
- [ ] #717 stays open as the tracker and closes only when all children close.
