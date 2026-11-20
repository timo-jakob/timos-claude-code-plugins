# Component Library Support Implementation Plan

> **For agentic workers:** this plan is executed through the repo's own pipeline, not through a superpowers execution
> skill. Each task below is one child story of the component-library-support epic (#3253: tasks 1–7 are #3254–#3260,
> under super-epic #3194 as umbrella project 8); refine it with `/development:refine-issue` when the readiness gate
> asks, and build it with `/development:resolve-issue`. Tasks run **in the order given**, each off fresh `origin/main`
> — they collide on `ARCHITECTURE.md`, the bootstrap `SKILL.md` and the `development` plugin version.

**Goal:** A repo's linked styleguide can declare a component library; the family reads what the library offers from
a generated index, holds UI repos to it with gates and review, turns a missing component into work for the library,
and can bootstrap the library's own repo.

**Architecture:** Three small contracts — the library declaration in the styleguide, the component index inside the
library package, and theme roles with theme files. Plugin-side mechanics are zsh scripts with bats suites under
`development/scripts/components/`. Everything that must run inside a target repo's CI (the gates, the index
generator, the catalogue checks) ships as bootstrap templates under
`development/skills/bootstrap/templates/languages/javascript/`, written in JavaScript and reading their lists from
the installed library at check time.

**Tech Stack:** zsh, bats (`tests/assertions.bash`, stub `gh` / `npm`), jq, Node (templates and their tests),
ESLint, stylelint, Storybook and axe (in rendered templates only), Markdown skills and agents.

**Spec:** `docs/superpowers/specs/2026-11-20-design-layer-design.md`, epic A (umbrella:
`docs/superpowers/specs/2026-11-18-product-layer-umbrella-design.md`)

**Prerequisites, all merged before Task 1 starts:** #3198 (linked styleguide), #3016, #3017, #3018, #3019.

## Global Constraints

- The family names no component technology. No file in this repo names a concrete component library, base library
  or theme service; every list a gate enforces is read from the declared library's index or the styleguide.
- A styleguide with no declaration switches all of this off: repos linking it behave exactly as today. So do UI
  repos that are not React.
- The styleguide is found where #3016 puts it: the submodule at `styleguide/`. Its files, as #3016–#3019 assume:
  `STYLEGUIDE.md`, `CHECKLIST.md` (items tagged `design` | `mechanical` | `review`), `tokens/tokens.json`. This
  epic adds two optional files: `components.json` and `tokens/theme-roles.json`.
- Contract names: `component-library/v1` (declaration), `component-index/v1`, `theme-roles/v1`, `theme/v1`.
- The index lives in the library package at `component-index.json`; the two reference themes at
  `themes/reference.json` and `themes/contrast.json`.
- Supported registries: `npm` (public) and `github-packages`. No token is ever written to a file in a repo.
- Gate switch: key `component_gates: warn | block` in the per-repo bootstrap config #3018 introduces for `a11y`.
  Fresh repo `block`; a repo that already has UI code `warn`.
- Theme colour values are six-digit hex (`#rrggbb`) only. Contrast minimums: 4.5 for text pairs, 3 for large-text
  and component pairs, per pair as declared.
- New plugin scripts are zsh; line length 120; macOS + Homebrew locally, ubuntu in CI.
- This repo is public. Every fixture, example and docs sample is invented; nothing from a linked styleguide, a real
  component library or a real theme is copied here.
- Every task bumps the version of each plugin it touches, with the marketplace entry.
- Repo test conventions apply to every new bats file: bump `SWEPT_FILES`, no `[[ ]]` assertions, unset `GIT_*` and
  `GITHUB_ACTIONS` in fixture `setup()`, single-line jq assertions, `git add` new files before the gate,
  MAINTAINING.md figures.

## Review Focus

1. **A styleguide submodule that is declared but not initialised.** The lookup must say so and name the fix; it
   must not report "no library declared", which would silently switch every gate off. → Task 1.
2. **The index cannot be read when a gate runs** (package not installed, registry token missing or expired). In
   `block` the gate fails naming the cause; in `warn` it annotates. It never passes as if there were no rules.
   → Task 3.
3. **Theme values in other colour notations** (`rgb()`, named colours, three-digit or eight-digit hex). The
   validator rejects each, naming the role; a pair exactly at its minimum passes. → Task 2.
4. **Two stories need the same missing component.** The second finds the open gap issue, adds its own
   "blocked by" and a comment, and files nothing new. → Task 5.
5. **An index written by a newer contract version** than the installed family knows. Exit with a distinct code
   naming both versions, not a list of field errors. → Task 1.

---

### Task 1: The declaration, the component index and their scripts

**Files:**

- Create: `development/scripts/components/resolve-component-library.zsh`,
  `development/scripts/components/validate-component-index.zsh`, `tests/component-library-contract.bats`,
  `tests/fixtures/component-library/` (an invented styleguide and an invented library package)
- Modify: `ARCHITECTURE.md` (new sections *Styleguide layout*, *Component library declaration
  (`component-library/v1`)*, *Component index (`component-index/v1`)*), `docs/reference/repo-scripts.md`

**Interfaces:**

- `components.json` in the styleguide: `schema` (`"component-library/v1"`), `package` (npm name, scoped),
  `repository` (`owner/name`), `registry` (`npm` | `github-packages`).
- `component-index.json`: `schema` (`"component-index/v1"`), `package`, `version`, `catalogue_url` (string or
  null), `internal_packages[]`, `themes` (`{ "reference": <path>, "contrast": <path> }`), `components[]` — each
  `name`, `import`, `purpose` (one line), `replaces[]` (lower-case HTML element names, may be empty), `props[]`
  (`name`, `type`, `required`), `states[]`, `stories[]`.
- `resolve-component-library.zsh [--repo-dir <dir>]` → stdout one JSON object: the declaration plus
  `styleguide_commit` and `index_path` (absolute path of the installed index, or null when the package is not
  installed). Exit 0 · 3 no library declared (no styleguide, or no `components.json`) · 4 styleguide submodule
  declared but not initialised · 2 declaration invalid. Stderr carries one line `component-library: <reason>`.
- `validate-component-index.zsh <path>` → exit 0 · 2 invalid, one stderr line per error as `<json-path>: <what>` ·
  5 unknown schema version, naming the found and the supported version.

- [ ] **Step 1: Write the suite**, failing: a valid fixture resolves to the declared package, repository and
  registry; no `styleguide/` → 3; `components.json` absent → 3; a `.gitmodules` entry with an empty directory → 4
  and stderr names `git submodule update --init styleguide`; an unknown `registry` → 2; a repo path with spaces
  works. Index: the valid fixture passes; each required field removed in turn fails naming its path; a duplicate
  component `name` fails; an upper-case entry in `replaces` fails; `schema` of `component-index/v2` → 5.
- [ ] **Step 2: Run** `LC_ALL=C bats tests/component-library-contract.bats` — expect failures.
- [ ] **Step 3: Implement both scripts.**
- [ ] **Step 4: Document** the styleguide layout and both contracts in `ARCHITECTURE.md`, stating that
  #3016–#3019's layout is taken as fixed and the two new files are optional.
- [ ] **Step 5: Run** the suite and the suites pinning `ARCHITECTURE.md` — expect green.

### Task 2: Theme roles, theme files, validation and contrast

**Files:**

- Create: `development/scripts/components/validate-theme.zsh`,
  `development/scripts/components/check-theme-contrast.zsh`, `tests/component-library-themes.bats`, fixtures under
  `tests/fixtures/component-library/themes/`
- Modify: `ARCHITECTURE.md` (sections *Theme roles (`theme-roles/v1`)* and *Theme file (`theme/v1`)*)

**Interfaces:**

- `tokens/theme-roles.json` in the styleguide: `schema` (`"theme-roles/v1"`), `modes[]` (mode names, at least
  one), `roles[]` — each `name`, `kind`
  (`color` | `font-family` | `shape` | `logo`), `css_variable`, `required` (bool); `contrast_pairs[]` — each
  `foreground`, `background` (role names of kind `color`), `minimum` (4.5 or 3).
- A theme file: `schema` (`"theme/v1"`), `name`, `modes` (object: mode name → object of role name → string), with
  exactly the modes the role file lists.
- `validate-theme.zsh --roles <theme-roles.json> <theme.json>` → exit 0 · 2 with one stderr line per error: a
  mode missing or unknown, a required role missing in a mode, a role the list does not know, a `color` value that
  is not `#rrggbb`, an empty value.
- `check-theme-contrast.zsh --roles <theme-roles.json> <theme.json>` → stdout one JSON array, per mode and pair
  `mode`, `foreground`, `background`, `ratio` (two decimals), `minimum`, `ok`; exit 0 all ok · 1 at least one below · 2
  input invalid. Ratio by the WCAG 2.x relative-luminance formula.

- [ ] **Step 1: Write the suite**, failing: the valid theme passes; each error class above; black on white is
  `21.00`; a pair computed to exactly its minimum is `ok`; a pair just below fails with exit 1; `rgb(0,0,0)`, `red`,
  `#fff` and `#ffffffff` are each rejected by the validator naming the role; a pair naming a non-colour role makes
  the roles file invalid (exit 2); a theme lacking one listed mode is rejected; a pair that fails in one mode only
  exits 1 and its row names that mode.
- [ ] **Step 2: Run** the suite — expect failures.
- [ ] **Step 3: Implement both scripts** (zsh floating-point arithmetic; no external colour tool).
- [ ] **Step 4: Document** both contracts and that the styleguide alone is authoritative for the role list.
- [ ] **Step 5: Run** the suite — expect green.

### Task 3: The three gates, as bootstrap templates

**Files:**

- Create, under `development/skills/bootstrap/templates/languages/javascript/component-library-consumer/`:
  `eslint-component-library.mjs`, `stylelint-brand-values.mjs`, `load-component-index.mjs`;
  `tests/component-library-gates.bats`, `tests/fixtures/component-library/app/` (an invented small React app)
- Modify: `ARCHITECTURE.md` (the gates, under the component-library sections)

**Interfaces:**

- `load-component-index.mjs` exports `loadComponentIndex(cwd): { index, gates: "warn" | "block" }`; throws an
  error with `code` `INDEX_UNREADABLE` and a message naming the cause (package not installed, file missing,
  invalid JSON).
- `eslint-component-library.mjs` default-exports a flat-config array with three rules, severity from `gates`:
  `component-library/no-replaced-element` (a JSX element whose name is in any component's `replaces`),
  `component-library/no-internal-import` (an import of, or below, an `internal_packages` entry),
  `component-library/no-brand-value` (in JSX `style` objects and style constants: a colour literal — hex, `rgb()`,
  `hsl()`, named colour — or a `fontFamily` string that is not a `var(--…)` reference).
- `stylelint-brand-values.mjs` default-exports the stylelint config for the same brand-value rule on `color`,
  `background*`, `border*-color`, `outline-color`, `fill`, `stroke`, `font-family`: only `var(--…)`, `inherit`,
  `currentColor`, `transparent` pass.
- In `warn`, a violation is reported at warning severity and the run exits 0; in `block` it is an error.

- [ ] **Step 1: Write the suite**, failing, running real ESLint and stylelint over the fixture app: a raw
  `<button>` is reported when the fixture index has a component replacing `button`, and not reported for an
  element nothing replaces; a deep import below an internal package is reported; `style={{ color: "#333" }}`,
  `color: red` and `font-family: Arial` are reported, `var(--x)` and `currentColor` are not; with `warn` the
  process exits 0 and prints the findings, with `block` it exits non-zero; with the package absent the run fails
  in `block` and reports one warning naming the cause in `warn` — it never reports zero findings silently.
- [ ] **Step 2: Run** the suite — expect failures.
- [ ] **Step 3: Implement the three modules.**
- [ ] **Step 4: Document** the gates and the composite-versus-primitive rule.
- [ ] **Step 5: Run** the suite — expect green.

### Task 4: Bootstrap for a UI repo that declares a library

**Files:**

- Create: `development/skills/bootstrap/templates/languages/javascript/component-library-consumer/npmrc.tmpl`,
  `…/component-library-consumer/claude-md-fragment.md`, `tests/bootstrap-component-library-consumer.bats`
- Modify: `development/skills/bootstrap/SKILL.md`, `development/skills/bootstrap/scripts/render.zsh` (or the
  script that selects templates), the Renovate and Dependabot templates, the UI CI workflow template

**Interfaces:**

- Consumes: `resolve-component-library.zsh` (Task 1), the gate modules (Task 3).
- Bootstrap runs this section only when the repo is detected as web UI, `is_react` is true and the resolver exits
  0. Exit 3 skips silently; exit 4 stops with the resolver's message.
- For `registry: github-packages` it renders `.npmrc` with the scope mapped to `https://npm.pkg.github.com` and
  the token as `${NODE_AUTH_TOKEN}`; grants CI read access to packages; configures the dependency bot with the
  registry. For `npm` none of these.
- Sets `component_gates` to `block` when the repo has no `.tsx`/`.jsx` file outside tests, else `warn`.

- [ ] **Step 1: Write the suite**, failing: a React web UI fixture with a declaring styleguide gains the
  dependency, the `CLAUDE.md` fragment exactly once, the ESLint and stylelint wiring and the gate key; a second
  run changes nothing; a non-declaring styleguide leaves the repo byte-identical to today's bootstrap output; a
  non-React UI repo likewise; `github-packages` renders `.npmrc` with no literal token (assert the file contains
  `${NODE_AUTH_TOKEN}` and no `ghp_`/`github_pat_` string) and the dependency-bot registry entry; `npm` renders
  neither; an existing UI repo gets `warn`, an empty one `block`.
- [ ] **Step 2: Run** the suite — expect failures.
- [ ] **Step 3: Implement** the templates and the bootstrap wiring.
- [ ] **Step 4: Settle the CI identity** from the spec's "To verify first": try the workflow's own token against a
  private package that has granted the repo access; record the result in the SKILL and the how-to. If it does not
  work, stop and raise it — do not fall back to a personal token in a repo secret.
- [ ] **Step 5: Run** the suite and the existing bootstrap suites — expect green.

### Task 5: The review check and gap filing

**Files:**

- Create: `development-react/agents/react-component-library-reviewer.md`,
  `development/scripts/components/file-component-gap.zsh`, `tests/component-gap.bats`,
  `tests/react-component-library-review.bats`
- Modify: `development-react/skills/review/SKILL.md` (a fourth dimension `component_library`, dispatched only when
  the resolver exits 0), `development/skills/resolve-issue/SKILL.md` (the gap stop), `docs/reference/agents.md`,
  `ARCHITECTURE.md` (review-panel tables)

**Interfaces:**

- Agent `development-react:react-component-library-reviewer` — tools Read, Grep, Glob. Reads the index and the
  diff. Findings in the review finding schema, dimension `component_library`, for: a hand-built component where
  the index has a matching one; a local primitive (own interaction behaviour, focus handling or ARIA semantics); a
  logo or brand image not taken from the theme. A composite of library components is never a finding.
- `file-component-gap.zsh --component <name> --needed-by <owner/repo#n> --states <csv> --description-file <path>
  [--repo-dir <dir>]` → files an issue titled `component: <name>` in the declared library repository, labelled
  `type: enabler` and `component-gap`, and sets "blocked by" on the needing issue. When an open issue with that
  title exists it adds the "blocked by" and one comment instead. Stdout: the gap issue's URL. Exit 0 · 3 no library
  declared · 6 the cross-repo link could not be set (the issue is still filed and its URL printed).
- In `resolve-issue`, a needed primitive the index lacks ends that story with the typed escalation for an
  architect gap, after the script has run.

- [ ] **Step 1: Write both suites**, failing. Gap script against a stub `gh`: first call creates one issue with
  both labels and the title; second call for the same component creates none and comments; a title that differs
  only in case is treated as the same component; exit 6 path prints the URL. Review: the dimension appears in the
  panel table and launch count; it is skipped and recorded in `skipped_dimensions_by_round` when no library is
  declared; the agent's frontmatter passes the plugin file contract.
- [ ] **Step 2: Run** both suites — expect failures.
- [ ] **Step 3: Implement** the script, the agent and the two skill changes.
- [ ] **Step 4: Verify the cross-repo "blocked by"** from the spec's "To verify first" with the bot identity on two
  scratch repos of one owner; record the result. If it cannot be set, exit 6 is the permanent path and the comment
  on the needing issue carries the link.
- [ ] **Step 5: Run** both suites and the review-dispatch suites — expect green.

### Task 6: The component-library bootstrap flavour

**Files:**

- Create, under `development/skills/bootstrap/templates/languages/javascript/component-library/`:
  `scripts/build-component-index.mjs`, `scripts/check-catalogue.mjs`, `.storybook/main.ts`, `.storybook/preview.ts`,
  `.github/workflows/component-library-ci.yml.tmpl`, `.github/workflows/component-library-release.yml.tmpl`,
  `themes/reference.json`, `themes/contrast.json` (invented starter themes);
  `tests/bootstrap-component-library.bats`, `tests/fixtures/component-library/library-src/`
- Modify: `development/skills/bootstrap/SKILL.md` and its flavour selection, `docs/reference/plugins.md`

**Interfaces:**

- A repo is a component library when its root `package.json` has `"componentLibrary": true` **(plan's call; the
  spec leaves it to the builder)**.
- `build-component-index.mjs [--check]` writes `component-index.json` from the library's exported components,
  their TypeScript prop types and their catalogue entries; `replaces` and `purpose` come from a JSDoc tag on the
  component (`@replaces button`, first sentence of the comment). `--check` writes nothing and exits 1 when the
  committed file differs.
- `check-catalogue.mjs` exits 1, naming each offender, when: a public component has no catalogue entry for one of
  its `states`; an entry has an accessibility violation in any reference theme and mode; a reference theme fails
  `validate-theme` or the contrast check against the styleguide's roles.
- CI workflow: lint, the token gate, the brand-value gate, tests, `build-component-index.mjs --check`,
  `check-catalogue.mjs` — all blocking; there is no `warn` in a library repo.
- Release workflow: publishes the package (index and themes inside it) with the workflow's own token and
  `packages: write`, and attaches the static catalogue build to the release.

- [ ] **Step 1: Write the suite**, failing: bootstrapping the fixture library renders every file above and is
  idempotent; the generated index for the fixture source validates with Task 1's validator and lists the fixture's
  props, states and `replaces`; `--check` fails after a prop is added to the source; a component with a state but
  no catalogue entry is named by `check-catalogue.mjs`; both workflows pass `actionlint` and the repo's `yamllint`
  config; the release workflow requests `packages: write` and names no secret.
- [ ] **Step 2: Run** the suite — expect failures.
- [ ] **Step 3: Verify index generation** from the spec's "To verify first" on the fixture before building the
  rest: props, states and replaced elements must come out of types and catalogue entries dependably. If a field
  cannot be derived, it becomes a required JSDoc tag and the check enforces the tag.
- [ ] **Step 4: Implement** the templates and the flavour selection.
- [ ] **Step 5: Run** the suite and the existing bootstrap suites — expect green.

### Task 7: Reference and how-to documentation

**Files:**

- Create: `docs/how-to/adopt-a-component-library.md`, `docs/how-to/bootstrap-a-component-library.md`,
  `docs/reference/component-library-contracts.md`, `tests/component-library-docs.bats`
- Modify: `mkdocs.yml`, `docs/how-to/index.md`, `docs/reference/index.md`, `docs/reference/plugins.md`,
  `docs/reference/requirements.md`

- [ ] **Step 1: Write the suite**, failing: each page exists and is registered in its index and in the nav; the
  reference page's field tables match the validators' own key lists (derived, not restated); the how-to names the
  `warn | block` switch and the registry setup for both registries; no page names a concrete component library.
- [ ] **Step 2: Write the pages.** The adopt how-to covers: declaring a library in a styleguide, re-running
  bootstrap, reading the gate count, flipping to `block`, what a gap issue is. The contracts page documents the
  four contracts and the gap script.
- [ ] **Step 3: Run** the suite and the docs build — expect green.
