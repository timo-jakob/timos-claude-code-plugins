# Feature Mockups Implementation Plan

> **For agentic workers:** this plan is executed through the repo's own pipeline, not through a superpowers
> execution skill. Each task below is one child story of the feature-mockups epic (to be filed under super-epic
> #3194 as umbrella project 9); refine it with `/development:refine-issue` when the readiness gate asks, and build
> it with `/development:resolve-issue`. Tasks run **in the order given**, each off fresh `origin/main` — they
> collide on `ARCHITECTURE.md`, `product/.claude-plugin/plugin.json` and the marketplace manifest.

**Goal:** `/product:design-feature` produces, for a Feature with a UI, mockups of every affected view and state,
composed from the declared component library and filled with pseudo data, checked against the styleguide before a
human sees them, approved by a human, required by the readiness gate and compared against the build.

**Architecture:** A mockup is a directory of files next to the Feature's product documents: React sources, one data
file, generated screenshots and design sheet, and a `mockup/v1` record whose approval is bound to a hash of sources
and data. One zsh script renders and checks, delegating the browser work to a small Node runner that installs the
library into a scratch workspace of its own. The agent proposes and drafts; the skill owns every write. The build
side receives the data file and the approved default screenshots as test fixtures.

**Tech Stack:** zsh, bats (`tests/assertions.bash`, stub `gh` / `npm` / `security`), jq, Node, a bundler, a
headless browser and axe (inside the runner only), Markdown skills and agents.

**Spec:** `docs/superpowers/specs/2026-11-20-design-layer-design.md`, epic B

**Prerequisites, all merged before Task 1 starts:** the component-library-support epic
(`docs/superpowers/plans/2026-11-20-component-library-support.md`) and #3204 (the renderer). Tasks 3 and 4
additionally need umbrella project 5 (the product stage and the two-step readiness gate).

## Global Constraints

- Mockup directory in the repo where the Feature is filed: `docs/product/mockups/<issue-number>-<slug>/`,
  containing `views/<view>.mockup.tsx`, `data.json`, `mockup.json`, `design.md`,
  `screenshots/<view>--<state>--<theme>--<width>.png`.
- Widths: `1280` and `320`. Themes: the library's `reference` and `contrast`. States: `default` always, plus one
  per state the acceptance criteria name.
- A mockup source default-exports a React component taking `{ data, state }`, imports only `react` and the
  declared library package, and holds no logic beyond choosing what to show for `state`.
- `data.json`: `{ "scenarios": { "default": {…}, "<state>": {…} } }`, one scenario per state of any view.
- Screenshots and `design.md` are generated and never edited. Screenshots are written only at approval.
- Approval covers the whole Feature and is impossible while a library gap is open.
- No fallback: no declared library → clean stop.
- The render script never uses or changes the dependencies of the repo it runs in. Scratch workspace:
  `~/.cache/timos-claude-code-plugins/mockups/<package>@<version>/`.
- For `registry: github-packages` a local session reads its token from the macOS Keychain; a missing or refused
  token is a clean stop naming the one command that fixes it.
- `product` must work with `development` not installed, and the reverse: no path from one plugin's directory into
  the other's. A script both need exists as two byte-identical copies with a `cmp` test, as `prose-hash.zsh` does.
- Pseudo data is invented. No fixture, example or docs sample comes from a real system or a linked private repo.
- New scripts are zsh; line length 120; macOS + Homebrew only for running the skill; ubuntu in CI for the suites.
- Every task bumps the version of each plugin it touches, with the marketplace entry.
- Repo test conventions apply to every new bats file: bump `SWEPT_FILES`, no `[[ ]]` assertions, unset `GIT_*` and
  `GITHUB_ACTIONS` in fixture `setup()`, single-line jq assertions, `git add` new files before the gate,
  MAINTAINING.md figures.

## Review Focus

1. **The hash must not move for reasons that are not edits.** File order, CRLF line endings and a repo path with
   spaces give the same hash; renaming a view, or adding one, changes it. → Task 1.
2. **Offline rendering.** With the scratch workspace warm, rendering works with the network off. Cold and offline
   is a clean stop that names the cause, not a browser timeout. → Task 1.
3. **Pseudo data containing markup** (`<script>`, `&`, a Markdown table pipe). It appears as text in the rendered
   page and in the design sheet, never as markup. → Tasks 1 and 3.
4. **A parked session resumed after the library moved on.** The record's library version becomes the new latest
   release and every view is rendered again, not only the one that had the gap. → Task 3.
5. **The Feature's definition changes after approval while the mockup files do not.** The record carries a hash of
   the Feature's product-stage prose; a mismatch is reported as its own state and the Feature is not ready.
   → Tasks 1 and 4.

---

### Task 1: The mockup record, its hash, and the render-and-check script

**Files:**

- Create: `product/scripts/mockup-hash.zsh`, `product/scripts/validate-mockup.zsh`,
  `product/scripts/render-mockup.zsh`, `product/scripts/resolve-component-library.zsh` and
  `product/scripts/validate-component-index.zsh` (byte-identical copies of the `development` ones),
  `product/mockup-runner/package.json`, `product/mockup-runner/package-lock.json`, `product/mockup-runner/render.mjs`,
  `product/mockup-runner/rules/` (byte-identical copies of the gate modules a UI repo gets: the three
  component-library modules and #3017's token rules),
  `tests/product-mockup-record.bats`, `tests/product-render-mockup.bats`, `tests/fixtures/product-mockup/` (an
  invented library package, styleguide and two-view mockup)
- Modify: `ARCHITECTURE.md` (section *Mockup record (`mockup/v1`)*), `tests/Dockerfile` and
  `.github/workflows/script-tests.yml` (the runner's declared dependencies)

**Interfaces:**

- `mockup.json`: `schema` (`"mockup/v1"`), `issue` (`owner/repo#n`), `status` (`draft` | `approved`), `library`
  (`{ "package", "version" }`), `styleguide` (`{ "commit" }`), `feature_prose_sha256`, `views[]` (`name`, `source`,
  `states[]`), `checks` (`imports`, `brand_values`, `tokens` — each `pass` | `fail`; `a11y` — `{ "violations": n }`;
  `checklist[]` — `item`, `verdict` (`pass` | `fail` | `n-a`), `reason`), `gaps[]` (`component`, `issue`),
  `approval` (`{ "by", "at", "content_sha256" }` or null).
- `mockup-hash.zsh <mockup-dir>` → prints the sha256 over `data.json` and every `views/*.mockup.tsx`, each
  normalised to LF, in byte order of their relative paths, with each path fed into the hash before its content.
- `validate-mockup.zsh <mockup-dir> [--feature-prose-sha256 <hash>]` → exit 0 approved and matching · 1 `draft`
  or open gaps · 2 record invalid · 3 no record · 4 files changed since approval · 5 Feature prose changed since
  approval (only with the flag). One stderr line `mockup: <reason>`.
- `render-mockup.zsh <mockup-dir> [--write-screenshots] [--serve]` → installs the library at the record's version
  into the scratch workspace when absent, bundles every view × state × theme × width, runs the mechanical checks
  and writes their results into the record's `checks` (never `checklist`, never `approval`). Without
  `--write-screenshots` images go to a temporary directory whose path is printed. `--serve` keeps a local preview
  running and prints its URL. Exit 0 all checks pass · 1 a check failed (stdout lists each as `<check>: <view>
  <state> <theme> <width>: <what>`) · 3 no library declared · 7 library cannot be installed (registry
  unreachable, token missing or refused — stderr names which and the fixing command) · 8 a tool is missing, with
  its install line.
- Mechanical checks: `imports` (only `react` and the library package), `brand_values` and `tokens` (the same rule
  modules a UI repo gets), `a11y` (zero violations over the rule tags #3018 uses).

- [ ] **Step 1: Write `tests/product-mockup-record.bats`**, failing: the valid record validates; each required
  field removed fails with exit 2; the hash is stable across file order, CRLF and a path with spaces, and changes
  on an edit, a rename and an added view; an approved record with an edited source → 4; `draft` → 1; a non-empty
  `gaps` → 1 even when `status` says `approved`; the prose flag with a different hash → 5; both script copies and
  every file under `mockup-runner/rules/` are `cmp`-identical to their `development` originals.
- [ ] **Step 2: Write `tests/product-render-mockup.bats`**, failing, against the fixture library served from a
  local directory: a clean mockup exits 0 and produces 2 views × states × 2 themes × 2 widths images; a source
  importing another package fails `imports`; a hex colour in a source fails `brand_values`; a control with no
  accessible name fails `a11y` naming view, state, theme and width; a data value of `<script>alert(1)</script>`
  appears as text in the page; a second run with the registry stubbed unreachable succeeds from the warm
  workspace; a cold workspace with the registry unreachable exits 7; a refused token exits 7 naming the Keychain
  command; nothing in the fixture repo's working tree changes without `--write-screenshots`.
- [ ] **Step 3: Run** both suites — expect failures.
- [ ] **Step 4: Verify headless rendering** from the spec's "To verify first": bundle, scan and capture the fixture
  on a Mac with only the Homebrew toolchain, network off after the first install. Record what the runner pins.
- [ ] **Step 5: Implement** the three scripts and the runner; document the contract.
- [ ] **Step 6: Run** both suites — expect green.

### Task 2: The `mockup-designer` agent

**Files:**

- Create: `product/agents/mockup-designer.md`, `tests/product-mockup-designer.bats`
- Modify: `docs/reference/agents.md`

**Interfaces:**

- Agent `product:mockup-designer` — tools Read, Grep, Glob, Bash; no file or GitHub writes. A function of one
  turn. Input: the Feature, the personas, the styleguide path, the component index, the conversation, the human's
  latest reply, the last check failures. Returns one JSON object: `views[]` (`name`, `purpose`, `states[]`),
  `questions[]`, `sources[]` (`path`, `content`), `data` (the whole `data.json`), `gaps[]` (`component`,
  `needed_by_view`, `states[]`, `description`), `checklist[]` (every `design`-tagged item with `verdict` and a
  one-line `reason`), `notes`.
- Rules the agent's instructions state: propose the view and state list first and draft nothing until it is
  confirmed; compose only from the index; a primitive the index lacks is a gap, never built; pseudo data is
  invented, plausible for the persona, and awkward in at least one place per view (a very long name, a missing
  optional value, enough rows to scroll); never a colour, font or logo value.

- [ ] **Step 1: Write the suite**, failing: frontmatter passes the plugin file contract; the instructions name
  every key of the return object and each rule above; the agent has no Edit or Write tool.
- [ ] **Step 2: Write the agent.**
- [ ] **Step 3: Run** the suite — expect green.

### Task 3: `/product:design-feature`

**Files:**

- Create: `product/skills/design-feature/SKILL.md`, `product/scripts/build-design-sheet.zsh`,
  `product/scripts/file-component-gap.zsh` (byte-identical copy of the `development` one),
  `tests/product-design-feature.bats`, `tests/product-design-sheet.bats`
- Modify: `docs/reference/commands.md`

**Interfaces:**

- Consumes: Task 1's scripts, Task 2's agent, `resolve-product-doc.zsh` (personas), `render-document.zsh` (#3204),
  `prose-hash.zsh`.
- `/product:design-feature <issue>`; with an existing `draft` record for the issue it resumes from it.
- Clean stops, each naming its reason: the issue is not a Feature that passed the product stage; its definition
  names no UI; no library declared; styleguide submodule not initialised; no persona registry; a tool missing.
- Session order: views and states proposed and confirmed → drafts → `render-mockup.zsh` → failures back to the
  agent, the human sees only a passing draft → `--serve` preview → corrections loop → approval.
- A gap: `file-component-gap.zsh` runs, the gap goes into the record, the session continues with the other views
  and ends **parked**: sources, data and a `draft` record written; no screenshots, no design sheet, no approval.
- On resume the library version is re-read as the latest release and every view is rendered again; a gap whose
  issue is closed and whose component is now in the index is removed from the record.
- At approval the skill runs `render-mockup.zsh --write-screenshots`, `build-design-sheet.zsh`, then
  `render-document.zsh` on the sheet, writes `approval` with `mockup-hash.zsh`'s value and `feature_prose_sha256`,
  and posts one issue comment linking `design.md`. It does not commit or push.
- `build-design-sheet.zsh <mockup-dir>` → writes `design.md`: the Feature's title and link, per view its purpose
  and its screenshots as relative image links grouped by state, the decisions recorded in the session, the check
  results and the checklist verdicts. Text taken from data or the issue is escaped for Markdown.

- [ ] **Step 1: Write `tests/product-design-sheet.bats`**, failing: every screenshot of the fixture is linked with
  a relative path that exists; a view name or data string containing `|`, `<` and `*` appears escaped; the sheet
  is identical on a second run; the sheet names the library version and the styleguide commit.
- [ ] **Step 2: Write `tests/product-design-feature.bats`**, failing: the SKILL names each clean stop and each
  script it calls with the flags above; it states that drafts failing a check are not shown; that the skill never
  commits; that a gap parks the session; that resume re-renders every view; the gap-script copy is `cmp`-identical.
- [ ] **Step 3: Run** both suites — expect failures.
- [ ] **Step 4: Implement** the script and the skill.
- [ ] **Step 5: Run** both suites — expect green.

### Task 4: The readiness gate and the build side

**Files:**

- Create: `development/scripts/mockups/mockup-hash.zsh` and `development/scripts/mockups/validate-mockup.zsh`
  (byte-identical copies), `development/skills/resolve-issue/scripts/import-mockup-fixtures.zsh`,
  `development-react/agents/react-mockup-conformance-reviewer.md`, `tests/mockup-readiness.bats`,
  `tests/mockup-fixture-import.bats`
- Modify: the technical-stage readiness gate that project 5 delivers, `development/skills/resolve-issue/SKILL.md`,
  `development-react/skills/review/SKILL.md` (dimension `mockup_conformance`, dispatched only when the story links
  a mockup), the default-view test template from #3018, `ARCHITECTURE.md`, `docs/reference/agents.md`

**Interfaces:**

- Readiness: for a Feature whose definition names a UI, the gate runs `validate-mockup.zsh` with the Feature's
  product-stage prose hash. Exit 0 passes; any other exit is a not-ready objection quoting the script's reason. A
  Feature with no UI is not checked. The technical stage writes the mockup's location (`owner/repo`, commit,
  directory) into every child story that builds one of its views.
- `import-mockup-fixtures.zsh --from <owner/repo>@<commit>:<dir> --dest <dir>` → copies `data.json` and every
  `screenshots/*--default--*.png` into `<dest>` and writes `<dest>/SOURCE` naming repo, commit and directory.
  Exit 0 · 3 source not reachable · 4 the record at that commit is not approved. Default `--dest`:
  `tests/fixtures/mockups/<issue-number>/`.
- The default-view test template: reads its mocked data from the imported `data.json` scenario `default`, applies
  the library's reference and contrast themes, and saves `test-results/default-view/<view>--<theme>--<width>.png`
  at widths 1280 and 320.
- Agent `development-react:react-mockup-conformance-reviewer` — tools Read, Grep, Glob. Reads each built
  screenshot beside the approved one of the same view, theme and width. Findings, dimension `mockup_conformance`:
  an element in the mockup missing from the build; a different component for the same element; a changed order or
  hierarchy; different label wording. Differences that come only from data are never findings. A missing built
  screenshot is one blocking finding naming the file.

- [ ] **Step 1: Write both suites**, failing. Readiness: approved and matching passes; `draft`, edited files,
  changed prose and a missing record each produce the objection with the script's reason; a Feature with no UI is
  not checked; the copies are `cmp`-identical to `product`'s. Import, against a local fixture repo: the data file
  and only the default-state screenshots arrive; `SOURCE` names the commit; a commit whose record is `draft` → 4.
- [ ] **Step 2: Run** both suites — expect failures.
- [ ] **Step 3: Confirm project 5's interface** from the spec's "To verify first": where the product stage records
  that a Feature has a UI, and where the technical-stage gate takes extra checks. Wire to what exists; if it does
  not record a UI in a readable form, stop and raise it against project 5 rather than inferring it from prose.
- [ ] **Step 4: Implement** the gate wiring, the import script, the template change and the agent.
- [ ] **Step 5: Run** both suites, the review-dispatch suites and the bootstrap suites — expect green.

### Task 5: The reference Feature and its behaviour test

**Files:**

- Create: `tests/fixtures/design-feature-reference/` (an invented repo: a Feature with two views and an error
  state, personas, a styleguide declaring the fixture library), `docs/how-to/test-the-mockup-designer.md`
- Modify: `docs/how-to/index.md`, `mkdocs.yml`, `MAINTAINING.md`

- [ ] **Step 1: Build the fixture** and the task and expectation text for `/development-claude-plugin:test`. The
  expectation: the session proposes both views and the error state before drafting; the result passes
  `render-mockup.zsh`; no source names a colour, font or logo; `data.json` holds at least one awkward value per
  view; the one component the fixture index deliberately lacks is filed as a gap and not built.
- [ ] **Step 2: Run it once** and record the verdict in the how-to. This test is run by hand before a release of
  the `product` plugin and is not part of the per-PR suite.

### Task 6: How-to, reference and explanation pages

**Files:**

- Create: `docs/how-to/design-a-feature.md`, `docs/reference/mockup-record.md`,
  `docs/explanation/the-design-step.md`, `tests/design-feature-docs.bats`
- Modify: `mkdocs.yml`, the three bucket indexes, `docs/reference/commands.md`, `docs/reference/requirements.md`,
  `docs/reference/plugins.md`

- [ ] **Step 1: Write the suite**, failing: each page exists and is registered in its index and the nav; the
  reference page's field table matches `validate-mockup.zsh`'s own key list and its exit-code table matches the
  script's `--help`; the requirements page lists the runner's tools; no page names a concrete component library.
- [ ] **Step 2: Write the pages.** The how-to walks one session from start to approval, including a parked
  session and its resume. The explanation page covers: why a mockup is code, why it is built only from the
  library, what approval binds to, and how the build is compared against it.
- [ ] **Step 3: Run** the suite and the docs build — expect green.
