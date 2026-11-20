# Protection Needs Implementation Plan

> **For agentic workers:** this plan is executed through the repo's own pipeline, not through a superpowers execution
> skill. Each task below is one child story of the protection-needs epic (to be filed under super-epic #3194 as
> umbrella project 10); refine it with `/development:refine-issue` when the readiness gate asks, and build it with
> `/development:resolve-issue`. Tasks run **in the order given**, each off fresh `origin/main` — they collide on
> `ARCHITECTURE.md`, `product/.claude-plugin/plugin.json` and the marketplace manifest.

**Goal:** An owner declares one protection scheme; each product gets one protection-needs assessment derived from the
kinds of information it holds, with every component's contribution; and a Feature cannot be defined or made ready
against information the assessment does not know.

**Architecture:** Two contracts mirroring `charter/v1` — a scheme data file and an assessment document with
sentinel-fenced prose and a generated JSON mirror. Four zsh scripts carry everything checkable: a scheme validator, an
assessment validator, a Feature-kind check and a requirement derivation. An attended skill conducts the interview, an
agent proposes and challenges and writes nothing. The Feature side is split: kinds and the product's rating in the
product stage, components and narrowed requirements in the technical stage, the latter using byte-identical copies of
the scripts.

**Tech Stack:** zsh, bats (`tests/assertions.bash`, stub `gh`), jq, yq, Markdown skills and agents.

**Spec:** `docs/superpowers/specs/2026-11-20-protection-needs-design.md` (umbrella:
`docs/superpowers/specs/2026-11-18-product-layer-umbrella-design.md`)

**Prerequisites, all merged before Task 1 starts:** #3195 (the lookup, the charter pattern, the renderer) and #3198
(linked documents). Tasks 5 and 6 additionally need #3199 (the product stage and the technical stage).

## Global Constraints

- The family hard-codes no class, no level name and no level count. Every script reads them from the scheme.
- Scheme path: `docs/product/protection-scheme.yaml`. Assessment path: `docs/product/protection-needs.md`. Both are
  found with `resolve-product-doc.zsh`: the repo's own file, else the first linked submodule that has it.
- No scheme found → everything here is inactive and the repo behaves as today. A declared but uninitialised
  submodule is never "no scheme": it is a stop naming the fix.
- Durations are ISO-8601 with weeks, days, hours and minutes only (`P2W`, `P2D`, `PT8H`, `PT15M`); months and years
  are rejected. Amounts are whole numbers in the scheme's one `currency`.
- A value on a boundary belongs to the lower level.
- Contribution values: `breaks`, `degrades`, `none`. Derivation values: `highest`, `raised`, `lowered`.
- A `lowered` rating sits at most one level below the highest kind level.
- Id shapes: kinds `K-<n>`, changes `PC-<yyyy>-<mm>-<n>`, components a lower-case slug. Ids are never reused.
- No level is written that a human did not confirm in the session.
- `product` must work with `development` not installed, and the reverse. A script both need exists as two
  byte-identical copies with a `cmp` test.
- This repo is public. Every scheme, amount, duration, scenario and product in fixtures, examples and docs is
  invented.
- New scripts are zsh; line length 120; macOS + Homebrew locally, ubuntu in CI.
- Every task bumps the version of each plugin it touches, with the marketplace entry.
- Repo test conventions apply to every new bats file: bump `SWEPT_FILES`, no `[[ ]]` assertions, unset `GIT_*` and
  `GITHUB_ACTIONS` in fixture `setup()`, single-line jq assertions, `git add` new files before the gate,
  MAINTAINING.md figures.

## Review Focus

1. **A scheme with a hole or an overlap** — the usual state of a written policy. The validator names the class and
   the two levels, and does not accept the file. → Task 1.
2. **The same duration written two ways** (`P14D` and `P2W`, `PT24H` and `P1D`) compares equal; a month or a year is
   rejected with the reason. → Tasks 1 and 2.
3. **A scheme that exists but cannot be reached** (a linked repository not initialised). It must stop with the fix,
   never read as "no scheme" — that would silently switch every check off. → Tasks 2 and 5.
4. **The prose edited by hand** — a level changed in the text, the block not regenerated. The assessment is
   `stale-prose`, and a Feature stops on it. → Tasks 2 and 5.
5. **A Feature that says nothing about information** versus one that says it touches none. Saying nothing is a
   stop; an explicit "none" passes. → Task 5.

---

### Task 1: The protection scheme and its validator

**Files:**

- Create: `product/scripts/validate-protection-scheme.zsh`, `product/scripts/duration-seconds.zsh`,
  `tests/product-protection-scheme.bats`, `tests/fixtures/product-protection/` (one valid invented scheme and one
  file per violation)
- Modify: `ARCHITECTURE.md` — new section *Protection scheme (`protection-scheme/v1`)*

**Interfaces:**

- The scheme file: `schema` (`"protection-scheme/v1"`), `currency`, `levels[]` (ordered lowest first; `id`, `name`),
  `classes[]` — each `id`, `name`, `guide` (`none` | `duration`), `guide_label`, and `levels` (object: level id →
  `{ criteria, damage_up_to, tolerates }`; `damage_up_to` an integer or null, `tolerates` a duration or null).
- `duration-seconds.zsh <duration>` → prints the number of seconds; exit 2 for anything but weeks, days, hours and
  minutes, with stderr `duration: unsupported: <value>`.
- `validate-protection-scheme.zsh <file>` → exit 0 (stdout `protection-scheme: valid`) · 1 invalid, one stderr line
  per violation `protection-scheme: <rule>: <detail>` · 2 usage or unreadable. Rules: `schema`, `duplicate-id`,
  `missing-level-entry`, `damage-not-increasing` (a level's bound not above the one before), `top-level-bounded`
  (the highest level has a `damage_up_to`), `duration-not-stricter` (a `tolerates` longer than the level below's,
  or null above a level that has one), `guide-without-duration` (a `duration` class with no `tolerates` anywhere),
  `bad-duration`, `bad-amount`.

- [ ] **Step 1: Write the suite**, failing: the valid fixture passes; one test per rule with its fixture and the
  exact `protection-scheme: <rule>:` prefix; a fixture with two violations reports both; a hole between two levels
  is impossible to express and an overlap is `damage-not-increasing` naming class and levels; `P14D` equals `P2W`
  and `PT24H` equals `P1D` in seconds; `P1M` and `P1Y` exit 2; a path with spaces works.
- [ ] **Step 2: Run** `LC_ALL=C bats tests/product-protection-scheme.bats` — expect failures.
- [ ] **Step 3: Implement both scripts** (yq to JSON, then jq).
- [ ] **Step 4: Write the contract section** with one invented scheme (three levels, two classes), stating the
  boundary rule and that the owner closes any gap of a written policy when writing the file.
- [ ] **Step 5: Run** the suite and the suites pinning `ARCHITECTURE.md` — expect green.

### Task 2: The assessment contract and its validator

**Files:**

- Create: `product/scripts/validate-protection-needs.zsh`, `tests/product-protection-needs.bats`,
  `tests/protection-needs-contract.bats`, fixtures under `tests/fixtures/product-protection/assessments/`
- Modify: `ARCHITECTURE.md` — new section *Protection needs (`protection-needs/v1`)*

**Interfaces:**

- The file: prose between `<!-- protection-needs:prose:start -->` and `<!-- protection-needs:prose:end -->`,
  sections in the spec's order; then a collapsed `<details>` holding one fenced `json` object.
- The block: `schema` (`"protection-needs/v1"`), `provenance` (`generated_by`, `generated_at`, `prose_sha256`),
  `scheme` (`{ "path", "origin", "version" }` — version is the commit of the repository holding the scheme),
  `components[]` (`id`, `name`, `status`), `kinds[]` (`id`, `name`, `status`, `classes`: class id → `{ level,
  scenario }`), `rating` (class id → `{ level, derivation, justification }`), `contributions[]` (`component`,
  `handles[]`, `classes`: class id → `{ contribution, reason }`), `targets[]` (`class`, `value`, `decided_in`),
  `changes[]` (`id`, `date`, `what`, `why`, `affects[]`, `evidence[]`). `status` is `active` | `retired`.
- `validate-protection-needs.zsh [--scheme <file>] <assessment.md>` → exit 0 valid · 1 invalid, one stderr line per
  violation `protection-needs: <rule>: <detail>` · 2 usage · 3 no scheme found · 4 a declared submodule is not
  initialised · 6 valid but stale (the recorded scheme version differs from the current one). Without `--scheme` the
  scheme is found by the lookup.
- Rules: `schema`, `stale-prose`, `bad-id-shape`, `duplicate-id`, `bad-date`, `unknown-class`, `unknown-level`,
  `missing-class`, `missing-scenario`, `rating-not-highest`, `unjustified-derivation`, `raised-not-above`,
  `lowered-too-far`, `kind-unhandled`, `component-without-contribution`, `unresolved-id`, `nobody-breaks`,
  `target-too-weak`, `bad-duration`, `retired-unnamed`. Retired kinds and components take no part in
  `rating-not-highest`, `kind-unhandled` and `nobody-breaks`.
- Consumes: `prose-hash.zsh`, `resolve-product-doc.zsh`, Task 1's two scripts.

- [ ] **Step 1: Write `tests/product-protection-needs.bats`**, failing: the valid fixture passes; one test per rule;
  two violations are both reported; a `highest` rating below the highest kind is `rating-not-highest`; `raised`
  without justification, `raised` to a level not above the highest, and `lowered` by two levels each fail by their
  own rule; a class above the lowest level with no `breaks` component is `nobody-breaks`, and the lowest level
  needs none; a target of `PT8H` against a level tolerating `PT4H` is `target-too-weak` and `PT4H` passes; a
  retired kind with the highest level does not raise the rating; a retired entry no change names is
  `retired-unnamed`; a recorded scheme version differing from the current one on an otherwise valid file → 6; no
  scheme → 3; an empty declared submodule → 4 naming `git submodule update --init`; CRLF prose hashes as LF.
- [ ] **Step 2: Write `tests/protection-needs-contract.bats`**, failing: pins the section's load-bearing
  sentences — the section order, highest wins, raising and lowering need a written reason, the one question asked
  per class for a contribution, nothing is deleted, the single-file limit, and that provenance is the persona
  contract's by link.
- [ ] **Step 3: Run both** — expect failures.
- [ ] **Step 4: Write the contract section** with one invented example (a small booking product: three kinds, two
  components, one raised rating with its aggregation argument, one decided target).
- [ ] **Step 5: Implement the validator.**
- [ ] **Step 6: Run both** — expect green. Mutation-check each rule: break its branch, see its test go red.

### Task 3: The `protection-assessor` agent and its reference product

**Files:**

- Create: `product/agents/protection-assessor.md`, `tests/product-protection-assessor.bats`,
  `tests/fixtures/protection-reference/` (an invented multi-tenant product: a data model, an API specification,
  personas, a charter, a scheme), `docs/how-to/test-the-protection-assessor.md`
- Modify: `docs/reference/agents.md`, `docs/how-to/index.md`, `mkdocs.yml`, `MAINTAINING.md`

**Interfaces:**

- Agent `product:protection-assessor` — tools Read, Grep, Glob, Bash; no file or GitHub writes. A function of one
  turn. Input: the scheme, the assessment so far, the evidence directories, the conversation, the human's latest
  reply. Returns one JSON object: `kinds[]` and `components[]` (proposals, each with `basis` — what in the evidence
  it rests on), `challenges[]`, `questions[]`, `rating`, `contributions[]`, `targets[]`, `change_entries[]`,
  `unconfirmed[]` (every kind-and-class level, rating and contribution the human has not yet confirmed),
  `draft_prose`, `draft_block`.
- Rules the instructions state: levels and scenarios are worded from the scheme's own criteria; every proposal
  names its basis; the agent challenges a kind the evidence shows but nobody named, personal data at the lowest
  level, many tenants' or users' records in one store with no aggregation argument, and a class no component
  breaks; it never moves an item out of `unconfirmed` on its own judgement; in update mode every changed rating
  comes with a change entry.

- [ ] **Step 1: Write the suite**, failing: frontmatter passes the plugin file contract; the instructions name
  every return key and each rule above; the agent has no Edit or Write tool.
- [ ] **Step 2: Write the agent.**
- [ ] **Step 3: Build the reference product** and the task and expectation for `/development-claude-plugin:test`:
  the session proposes the kinds the fixture's data model shows, raises the aggregation question the shared store
  is built to provoke, and the written file contains no level the scripted human did not confirm.
- [ ] **Step 4: Run** the suite — expect green. Run the behaviour test once and record the verdict in the how-to;
  it is a by-hand check before a `product` release, not part of the per-PR suite.

### Task 4: `/product:assess-protection-needs`

**Files:**

- Create: `product/skills/assess-protection-needs/SKILL.md`, `tests/product-assess-protection-needs.bats`
- Modify: `docs/reference/commands.md`

**Interfaces:**

- Consumes: Tasks 1–3, `resolve-product-doc.zsh`, `prose-hash.zsh`, `render-document.zsh`.
- `/product:assess-protection-needs [--evidence <dir>]…` — run in the repository that holds the product's
  documents. Lookup `own` → update mode; not found → create mode; `linked:…` → say where the assessment lives and
  to run the skill there.
- Clean stops, each naming its reason: no scheme found; scheme invalid (the validator's lines are relayed); a
  linked repository not initialised.
- The skill refuses to write while the agent's `unconfirmed` is non-empty.
- Before the first write into a repository whose visibility is public, it says an assessment contains damage
  scenarios and asks for explicit confirmation; when visibility cannot be read it asks instead of assuming.
- Ending: the human approves the draft → the skill writes the file, runs the validator (a failure is shown and the
  session continues), renders PDF and ePub, prints both paths. It does not commit or push.

- [ ] **Step 1: Write the suite**, failing: the SKILL names each stop, each script it calls, the `unconfirmed`
  rule, the public-repository confirmation and its "cannot read" branch, the three lookup outcomes, and that it
  never commits; a stale assessment opens in update mode with the re-confirmation and its change entry.
- [ ] **Step 2: Write the skill.**
- [ ] **Step 3: Run** the suite — expect green.

### Task 5: The product stage — a Feature's kinds and the product's rating

**Files:**

- Create: `product/scripts/check-feature-kinds.zsh`, `product/scripts/protection-requirements.zsh`,
  `tests/product-feature-kinds.bats`, `tests/product-protection-requirements.bats`
- Modify: the product-stage skill and agent that #3199 delivers, `ARCHITECTURE.md`

**Interfaces:**

- `check-feature-kinds.zsh (--kinds <K-1,K-2,…> | --none) [--repo <dir>]` → exit 0 every kind is an active kind of
  a valid, current assessment (or `--none`) · 1 an unknown or retired kind, stderr naming each · 2 usage (neither
  flag given is a usage error: saying nothing is not allowed) · 3 no scheme — the caller skips the check · 4 a
  linked repository not initialised · 5 no assessment · 6 assessment stale · 7 assessment invalid.
- `protection-requirements.zsh [--components <a,b,…>] [--repo <dir>]` → stdout one JSON object: `assessment`
  (`path`, `prose_sha256`, `scheme_version`) and `classes[]` — each `class`, `name`, `level`, `level_name`,
  `requirement` (`meet` | `must-not-worsen` | `none`), `damage_up_to`, `tolerates`, `target` (the decided value or
  null). Without `--components` every class is `meet` (the whole product). With it, per class the strongest
  contribution among the named components decides: `breaks` → `meet`, `degrades` → `must-not-worsen`, `none` →
  `none`. Exit codes as above, plus 1 for an unknown component.
- In the product stage, where the lookup finds a scheme: the agent proposes the Feature's kinds; the definition
  records them (or an explicit none) and the output of `protection-requirements.zsh` with no flag; exits 1, 5, 6
  and 7 are stops that send the human to `/product:assess-protection-needs`; exit 4 is a stop naming the fix.

- [ ] **Step 1: Write both suites**, failing. Kinds: known kinds pass; an unknown and a retired kind are each
  named; `--none` passes; neither flag → 2; every other exit code from its fixture. Requirements: the whole-product
  output lists every class as `meet` with its guide values; with one `degrades` and one `breaks` component the
  class is `meet`; with only `none` it is `none`; an unknown component → 1; the decided target appears.
- [ ] **Step 2: Run** both — expect failures.
- [ ] **Step 3: Confirm #3199's interface** from the spec's "To verify first": where a Feature's definition can
  carry a list and a block, and where the product stage takes an extra stop. Wire to what exists; if it offers
  neither, stop and raise it against #3199.
- [ ] **Step 4: Implement** both scripts and the product-stage wiring.
- [ ] **Step 5: Run** both suites — expect green.

### Task 6: The technical stage — components and per-story requirements

**Files:**

- Create: `development/scripts/protection/` holding byte-identical copies of `validate-protection-scheme.zsh`,
  `duration-seconds.zsh`, `validate-protection-needs.zsh`, `protection-requirements.zsh` and the scripts they
  consume; `development/scripts/protection/check-story-components.zsh`; `tests/protection-technical-stage.bats`
- Modify: the technical-stage skill and agent that #3199 delivers, `ARCHITECTURE.md`

**Interfaces:**

- `check-story-components.zsh --components <a,b,…> --kinds <K-1,…> [--repo <dir>]` → exit 0 · 1 a named component
  is not listed as handling a named kind, stderr `<component> does not handle <kind>` per pair · the other exit
  codes of `check-feature-kinds.zsh`.
- In the technical stage, where the Feature's definition carries kinds: each story names the components it changes;
  exit 1 is a stop; the agent also judges whether the story alters a component's contribution and, when it does,
  stops with the component, the class and the reason. Otherwise `protection-requirements.zsh --components …` runs
  and its output is written into the story's non-functional requirements with the assessment's hash.
- Every stop sends the human to `/product:assess-protection-needs`.

- [ ] **Step 1: Write the suite**, failing: every copy is `cmp`-identical to its `product` original; a component
  handling the kind passes; one that does not is named; the technical-stage instructions name both stops and the
  write of the narrowed requirements; a Feature whose definition carries no kinds because no scheme exists is left
  alone.
- [ ] **Step 2: Run** — expect failures.
- [ ] **Step 3: Confirm #3199's interface**: that the technical stage records the components a story changes, or
  can be made to. If it cannot, stop and raise it.
- [ ] **Step 4: Implement** the script, the copies and the wiring.
- [ ] **Step 5: Run** the suite — expect green.

### Task 7: How-to, reference and explanation pages

**Files:**

- Create: `docs/how-to/declare-a-protection-scheme.md`, `docs/how-to/assess-a-products-protection-needs.md`,
  `docs/reference/protection-contracts.md`, `docs/explanation/protection-needs.md`, `tests/protection-docs.bats`
- Modify: `mkdocs.yml`, the three bucket indexes, `docs/reference/commands.md`, `docs/reference/plugins.md`

- [ ] **Step 1: Write the suite**, failing: each page exists and is registered in its index and the nav; the
  reference page's rule tables match the two validators' own rule lists and their exit-code tables match each
  script's `--help`; every example scheme on the pages passes `validate-protection-scheme.zsh`; no page contains a
  real organisation's scale.
- [ ] **Step 2: Write the pages.** The scheme how-to covers closing a gap in a written policy. The assessment how-to
  walks one session, an update after a scheme change, and what each Feature stop means. The explanation page
  covers: why the whole product is rated, how kinds lead to the rating, what a contribution is, and why a decided
  target is checked against its level.
- [ ] **Step 3: Run** the suite and the docs build — expect green.
