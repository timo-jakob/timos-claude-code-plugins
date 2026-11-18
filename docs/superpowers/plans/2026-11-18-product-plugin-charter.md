# Product Plugin, Charter and Renderer Implementation Plan

> **For agentic workers:** this plan is executed through the repo's own pipeline, not through a superpowers
> execution skill. Each task below is one child story of the project-1 epic (#3195: tasks 1–7 are #3202–#3208,
> under super-epic #3194); refine it with
> `/development:refine-issue` when the readiness gate asks, and build it with `/development:resolve-issue`. Tasks run
> **in the order given**, each off fresh `origin/main` — they collide on `ARCHITECTURE.md`,
> `.claude-plugin/marketplace.json` and `product/.claude-plugin/plugin.json`.

**Goal:** A `product` plugin that holds `define-personas`, writes a product charter with a dated direction log
(`charter/v1`), and renders any product document to both PDF and ePub in one house style.

**Architecture:** Skills conduct, agents think, scripts decide anything checkable. The charter mirrors `personas/v1`:
sentinel-fenced prose that a human owns plus a generated JSON mirror with a prose hash. Three zsh scripts carry the
mechanics — a product-document lookup, a charter validator, a renderer (pandoc → Typst for PDF, pandoc for ePub) — and
every skill calls them rather than describing them.

**Tech Stack:** zsh, bats (`tests/assertions.bash`), jq, pandoc, Typst, `pdftotext` (tests only), Markdown skills and
agents.

**Spec:** `docs/superpowers/specs/2026-11-18-product-plugin-charter-design.md` (umbrella:
`docs/superpowers/specs/2026-11-18-product-layer-umbrella-design.md`)

## Global Constraints

- Plugin name `product`, directory `product/`, first version `0.1.0`; every task bumps
  `product/.claude-plugin/plugin.json` and the marketplace entry together, and any other plugin it touches likewise.
- `product` has no gather script, no maintenance dispatcher, no resolve profile, no review panel.
- `product` must work with `development` not installed: no path from `product/` into another plugin's directory.
- Charter path in a target repo: `docs/product/charter.md`. Persona registry path unchanged: `docs/personas.md`.
- Rendered output: `<repo-root>/dist/product/<basename>.pdf` and `.epub`, always both, never committed.
- Renderer has no styling options. A4. Fonts come from the template directory or Typst's built-ins only.
- New scripts are zsh; line length 120; macOS + Homebrew locally, ubuntu in CI.
- This repo is public. Every fixture, example and docs sample is invented; nothing from any linked private
  repository is copied here.
- The pillar rule in `CLAUDE.md` binds every new file: link `philosophy.md#pillar-N`, never restate a pillar.
- Repo test conventions apply to every new bats file: bump `SWEPT_FILES`, no `[[ ]]` assertions, unset `GIT_*` in
  fixture `setup()`, single-line jq assertions, `git add` new files before the gate, MAINTAINING.md figures.

## Review Focus

1. **A linked submodule that is declared but not initialised** (empty directory). The lookup must report "not
   found" with a message naming the uninitialised submodule, not "no charter". → Task 2.
2. **A failed render after an earlier successful one.** Old `dist/product/` files must not survive looking current:
   the renderer builds into a temporary directory and moves both files in only when both succeeded. → Task 3.
3. **Non-ASCII text** in a charter (umlauts, typographic quotes, an emoji). The PDF must contain the umlauts and
   quotes; a glyph no bundled font has fails the render with the character named. → Task 3.
4. **A repo with no remote, or a directory that is not a git repo.** Links to other repo files become plain text,
   the footer says `uncommitted`, the cover says DRAFT, exit 0. → Task 3.
5. **Paths with spaces** in the repo root or the document path, for all three scripts. → Tasks 2, 3, 4.

---

### Task 1: The `product` plugin and the personas move

**Files:**

- Create: `product/.claude-plugin/plugin.json`, `product/scripts/prose-hash.zsh`,
  `tests/product-plugin.bats`
- Move: `development/skills/define-personas/SKILL.md` → `product/skills/define-personas/SKILL.md`;
  `development/agents/persona-definer.md` → `product/agents/persona-definer.md`
- Modify: `.claude-plugin/marketplace.json`; `ARCHITECTURE.md` (new section *The `product` plugin*, and every
  `define-personas` / `persona-definer` mention); `README.md`; `development/agents/issue-refiner.md`;
  `development/agents/story-readiness.md`; `development/skills/refine-issue/SKILL.md`;
  `development/skills/refine-issue/docs/PERSONA-CONSUMPTION-VALIDATION.md`; `docs/personas.md`;
  `docs/explanation/motivation.md`; `docs/explanation/how-the-plugins-work.md`;
  `docs/explanation/diagrams/sdlc.mmd` and `sdlc.svg`; `docs/how-to/read-pipeline-telemetry.md`;
  `docs/reference/agents.md`, `commands.md`, `plugins.md`; `tests/persona-derivations.bats`;
  `development/.claude-plugin/plugin.json`

**Interfaces:**

- Produces: command `/product:define-personas`; agent type `product:persona-definer`;
  `product/scripts/prose-hash.zsh [--file <path>]` — byte-identical copy of
  `development/skills/refine-issue/scripts/story-spec-prose-hash.zsh` (same stdin/`--file` input, lowercase-hex
  SHA-256 on stdout, exit 0 / 1 / 2).
- `provenance.generated_by` written from now on: `persona-definer via /product:define-personas`.

- [ ] **Step 1: Write `tests/product-plugin.bats`**, failing:
  - `product plugin.json names the plugin and a version` — `jq -r .name` is `product`, `.version` matches
    `^[0-9]+\.[0-9]+\.[0-9]+$`.
  - `marketplace lists product from ./product` — entry with `name == "product"`, `source == "./product"`,
    `category == "product"`, version equal to plugin.json's.
  - `product ships no gather script, dispatcher or resolve profile` — no `product/scripts/gather-*`, no
    `product/skills/maintenance`, no `product/skills/resolve-profile`, no `product/skills/review`.
  - `the two prose-hash copies are byte-identical` — `cmp` of the two scripts.
  - `no tracked file names the old command or agent type` — `git ls-files` sweep, excluding `docs/superpowers/`
    and `tests/fixtures/`, finds neither `/development:define-personas` nor `development:persona-definer`.
  - `nothing under product/ reaches into another plugin` — no `../development` or `/development/` path in
    `product/**`.
  - `define-personas calls the product hash script` — the moved SKILL.md contains
    `<skill-base-dir>/../../scripts/prose-hash.zsh` and not `story-spec-prose-hash.zsh`.
- [ ] **Step 2: Run** `LC_ALL=C bats tests/product-plugin.bats` — expect every test to fail.
- [ ] **Step 3: Create the plugin manifest and marketplace entry.** Description (both files): "Product-side skills:
  the product charter, the persona registry, and PDF + ePub rendering of product documents. Not a language or
  topic plugin — it takes no part in maintenance, review or resolve."
- [ ] **Step 4: `git mv` the skill and the agent; copy the hash script; repoint the skill's hash call.**
- [ ] **Step 5: Update every reference** in the files listed. Where `refine-issue` and `issue-refiner` send a human
  to define a missing persona, the text names `/product:define-personas` and adds: "it ships in the `product`
  plugin". Persona checks stay advisory; no text may make `development` fail when `product` is absent.
- [ ] **Step 6: Add the ARCHITECTURE.md section** *The `product` plugin — outside the language/topic model*: what it
  owns (charter, personas, rendering), that it is neither language nor topic plugin and maintenance discovery never
  sees it, that `development` refers to it by command name only, and that an old `generated_by` value stays valid.
- [ ] **Step 7: Regenerate `sdlc.svg`** from the edited `.mmd` the way the repo's docs tooling does.
- [ ] **Step 8: Run** the new suite, `tests/persona-derivations.bats`, `tests/check-marketplace-sync.bats` and the
  docs check — expect green.

### Task 2: The product-document lookup

**Files:**

- Create: `product/scripts/resolve-product-doc.zsh`, `tests/product-resolve-doc.bats`
- Modify: `product/skills/define-personas/SKILL.md` (stop rule), `ARCHITECTURE.md` (lookup rule, in the `product`
  section)

**Interfaces:**

- Produces: `resolve-product-doc.zsh [--repo <dir>] <relative-path>`
  - stdout on success, one line, tab-separated: `<absolute path>\t<origin>` where origin is `own` or
    `linked:<submodule path>`.
  - exit 0 found · 2 usage · 3 not found (stderr: `product-doc: not found: <relative-path>`) · 4 a declared
    submodule is not initialised and no earlier location had the file (stderr names it and the
    `git submodule update --init <path>` line).
  - Rule: the repo's own file wins; else the submodules of `.gitmodules` in file order, first hit. No
    configuration. A repo with no `.gitmodules` is simply `own`-or-not-found.

- [ ] **Step 1: Write `tests/product-resolve-doc.bats`**, failing. Fixtures are built in `setup()` with plain
  directories and a hand-written `.gitmodules` (no network, no real submodule):
  - `own file wins over a linked one` → exit 0, origin `own`.
  - `falls back to the first submodule that has the file` — two declared, second has it → `linked:<second>`.
  - `not found anywhere` → exit 3.
  - `declared submodule directory is empty` → exit 4, stderr contains the submodule path and
    `git submodule update --init`.
  - `works with spaces in the repo path and the submodule path`.
  - `no arguments` → exit 2.
- [ ] **Step 2: Run** — expect failures.
- [ ] **Step 3: Implement the script.** Read submodule paths with `git config -f .gitmodules --get-regexp`; a
  submodule counts as initialised when its directory is non-empty.
- [ ] **Step 4: Add the stop rule to `define-personas`:** in create mode, when the lookup returns `linked:…` for
  `docs/personas.md`, the skill says the product's registry lives in that linked repository, names the path, and
  stops without writing. Pin the sentence in the suite.
- [ ] **Step 5: Run** — expect green.

### Task 3: The renderer

**Files:**

- Create: `product/scripts/render-document.zsh`, `product/templates/house.typ`, `product/templates/house.css`,
  `product/templates/product-doc.lua`, `product/templates/fonts/` (redistributable fonts + their licence files),
  `tests/product-render-document.bats`, `tests/fixtures/product-render/` (invented documents)
- Modify: `.github/workflows/script-tests.yml` (install pandoc, Typst, poppler at pinned versions on both legs),
  `product/skills/define-personas/SKILL.md` (render step), `ARCHITECTURE.md`

**Interfaces:**

- Produces: `render-document.zsh [--title <text>] [--appendix <path>]... <document.md>`
  - Title and appendices come from the document's machine block when it has `title` / `appendices`; the flags are
    for a document with none and are a usage error (exit 2) when the block already supplies them.
  - stdout on success, two lines: the absolute path of the PDF, then of the ePub.
  - exit 0 ok · 2 usage · 3 pandoc or Typst missing or older than the minimum (stderr ends with the exact
    `brew install pandoc typst` line; nothing written) · 4 unsupported content (a `mermaid` fenced block; stderr
    names file and line) · 5 the toolchain failed (its stderr passed through).
  - Constants at the top of the script: `MIN_PANDOC`, `MIN_TYPST` — the builder sets them to the lowest versions the
    suite passes with, and the CI pins are at or above them.
- Consumes: Task 2's lookup only indirectly (callers resolve the document first).

- [ ] **Step 1: Write `tests/product-render-document.bats`**, failing. Content assertions read the PDF with
  `pdftotext` and the ePub with `unzip -p`:
  - `renders both files and prints both paths` — exit 0; both exist under `dist/product/`; PDF starts `%PDF`.
  - `the machine block and the sentinels never reach either output` — neither contains `prose_sha256`,
    `charter:prose:start` or `"schema"`.
  - `cover carries title, repo name and DRAFT when the source is uncommitted`; `no DRAFT when committed`.
  - `footer carries the source commit's short SHA` (committed fixture repo).
  - `appendix files follow the main document and a link into one resolves inside the output`.
  - `a link to another repo file becomes an absolute URL when a remote exists, plain text when none does`.
  - `a mermaid block is refused` → exit 4, stderr has the file name and line, `dist/product/` unchanged.
  - `pandoc missing` / `typst missing` / `typst too old` (stub directory first in `PATH`, host `/usr/bin` hidden
    per the repo's `HIDE_BIN` convention) → exit 3, stderr ends with the brew line, nothing written.
  - `a failing render leaves an earlier output untouched and adds nothing` (Review Focus 2).
  - `umlauts and typographic quotes survive into the PDF text` (Review Focus 3).
  - `not a git repo: DRAFT, footer says uncommitted, exit 0` (Review Focus 4).
  - `spaces in the repo path and the document name` (Review Focus 5).
  - `two renders of the same committed source produce the same PDF text and the same ePub file list`.
  - `title flag with a block that already has a title` → exit 2.
- [ ] **Step 2: Run** — expect failures.
- [ ] **Step 3: Implement the Lua filter** `product-doc.lua`: drop the `<details>` machine block and sentinel
  comments; turn the callout markers into styled blocks; rewrite links (appendix → internal, other repo file →
  absolute URL or text). Callout marking in the source is the builder's choice within the spec's constraint
  (readable as plain Markdown on github.com); document the chosen marking in ARCHITECTURE.md.
- [ ] **Step 4: Implement `house.typ` and `house.css`:** cover (title, repo name, date, version line, DRAFT mark),
  table of contents, Summary on its own page, callouts for values / non-goals / direction changes, footer stamp.
- [ ] **Step 5: Implement `render-document.zsh`:** version checks, refusal scan, build both outputs in a `mktemp -d`
  directory, move both into `dist/product/` only when both succeeded.
- [ ] **Step 6: Install the tools in CI** at pinned versions on the ubuntu and macOS legs of `script-tests`.
- [ ] **Step 7: Add the render step to `define-personas`:** after its write it runs the renderer on the registry
  with `--title "<repo name> — Personas"`, adds `dist/` to `.gitignore` when not already ignored, and reports both
  paths; a renderer failure is reported with its output and never as success.
- [ ] **Step 8: Run** — expect green on macOS; confirm the ubuntu leg in CI.

### Task 4: The `charter/v1` contract and its validator

**Files:**

- Create: `product/scripts/validate-charter.zsh`, `tests/product-validate-charter.bats`,
  `tests/charter-contract.bats`, `tests/fixtures/product-charter/` (one valid charter and one file per violation,
  all invented)
- Modify: `ARCHITECTURE.md` — new section *Product charter contract (`charter/v1`)* beside the persona contract

**Interfaces:**

- The file: prose between `<!-- charter:prose:start -->` and `<!-- charter:prose:end -->`, sections in the spec's
  order; then a collapsed `<details>` holding one fenced `json` object.
- The block: `schema` (`"charter/v1"`), `provenance` (`generated_by`, `generated_at`, `prose_sha256`), `title`,
  `appendices[]`, `purpose`, `background`, `serves[]`, `values[]`, `scope[]`, `non_goals[]`,
  `direction_changes[]`. Entry fields: `id`, `status` (`active` | `retired`), then exactly one of `statement` or
  `ref` (`{ "path", "anchor", "title" }`); `rationale` on non-goals with a `statement`. Change fields: `id`, `date`,
  `from`, `to`, `rationale`, `affects[]`, `evidence[]`.
- Id shapes: `V-<n>`, `S-<n>`, `NG-<n>`, `DC-<yyyy>-<mm>-<n>`.
- Produces: `validate-charter.zsh <charter.md>` — exit 0 valid (stdout `charter: valid`) · 1 invalid, one stderr
  line per violation `charter: <rule>: <detail>` · 2 usage or unreadable file. Rules: `schema`, `bad-id-shape`,
  `duplicate-id`, `statement-and-ref`, `neither-statement-nor-ref`, `retired-unnamed`, `unresolved-affects`,
  `unresolved-serves`, `ref-missing`, `appendix-missing`, `bad-date`, `stale-prose`.
- Consumes: `product/scripts/prose-hash.zsh` (Task 1), `resolve-product-doc.zsh` (Task 2) to find the persona
  registry for `unresolved-serves`; with no registry anywhere, a non-empty `serves` is `unresolved-serves` and an
  empty one is valid.

- [ ] **Step 1: Write `tests/product-validate-charter.bats`**, failing: the valid fixture passes; one test per rule
  with its fixture, asserting exit 1 and the exact `charter: <rule>:` prefix; `reports every violation, not the
  first` (a fixture with two); `a ref whose path resolves only through a linked submodule is ref-missing` (refs are
  repo-local); `spaces in the path`; `CRLF prose hashes the same as LF`.
- [ ] **Step 2: Write `tests/charter-contract.bats`**, failing: pins the contract section's load-bearing sentences
  — the section order, "an entry is never deleted", "never reused or renumbered", the single-file limit of the
  validator, and that the provenance mechanism is the persona contract's (a link, not a restatement).
- [ ] **Step 3: Run both** — expect failures.
- [ ] **Step 4: Write the contract section**, with one invented example (a small note-taking product, three values,
  two non-goals, one direction change that retires a non-goal).
- [ ] **Step 5: Implement the validator** with jq over the extracted block.
- [ ] **Step 6: Run both** — expect green. Mutation-check each rule: break the rule's branch, see its test go red.

### Task 5: The `charter-definer` agent

**Files:**

- Create: `product/agents/charter-definer.md`, `tests/product-charter-definer-prose.bats`
- Modify: `docs/reference/agents.md`

**Interfaces:**

- Tools: Read, Grep, Glob, Bash. No writes of any kind.
- Input (from the skill, as JSON in the prompt): `mode` (`create` | `update`), `evidence` (paths and excerpts),
  `charter_so_far` (the block or null), `conversation[]`, `latest_reply`.
- Output — one JSON object, nothing else: `explanation`, `candidates[]` (`kind`, `proposed_id`, `text`,
  `evidence`), `direction_change` (object or null: `from`, `to`, `rationale`, `date` or null, `retires[]`,
  `rewrites[]`, `adds[]`), `questions[]` (`id`, `text`, `why`), `draft_prose`, `charter_block`,
  `ready_for_approval` (boolean).

- [ ] **Step 1: Write the prose-pin suite**, failing. It pins: the output key list; "returns a JSON object only";
  that the agent asks nothing about tooling, layout or file placement, with the pillar link in the published-page
  form the repo rule requires for files shipped in a plugin; that it never invents a date and asks when the
  evidence gives none; that a contradiction between a stated non-goal and an open epic is put to the human as a
  question; that a changed meaning always comes with a `direction_change`; that when the repo already states its
  principles, values are `ref`s and never restated; that ids already in `charter_so_far` are never changed.
- [ ] **Step 2: Run** — expect failures.
- [ ] **Step 3: Write the agent**, following `persona-definer.md`'s structure.
- [ ] **Step 4: Run** — expect green; run the repo's agent frontmatter validation.

### Task 6: `/product:define-charter`

**Files:**

- Create: `product/skills/define-charter/SKILL.md`, `tests/product-define-charter-prose.bats`
- Modify: `ARCHITECTURE.md` (the *no charter, no guessing* rule in the `product` section),
  `docs/reference/commands.md`

**Interfaces:**

- Consumes: `resolve-product-doc.zsh` (exit codes of Task 2), agent `product:charter-definer` (Task 5 keys),
  `prose-hash.zsh`, `validate-charter.zsh` (Task 4), `render-document.zsh` (Task 3).
- Produces: `docs/product/charter.md` in the working tree; `dist/product/charter.pdf` and `.epub`.

- [ ] **Step 1: Write the prose-pin suite**, failing. It pins the step order and each branch:
  - lookup `own` → update mode; exit 3 → create mode; `linked:…` → say where the charter lives and stop, no write;
    exit 4 → relay the init line and stop.
  - evidence list: README, explanation pages, persona registry (through the lookup), ARCHITECTURE.md positions,
    `.maintenance.yml`, open and recently closed epics, issues closed as not planned.
  - the loop: relay the agent's questions, never add questions of its own, stop looping on approval.
  - the write: prose between the sentinels, block with a fresh `prose_sha256` from `prose-hash.zsh`,
    `generated_by` `charter-definer via /product:define-charter`.
  - after the write: validator, then renderer; either failing is reported with its output, never as success, and
    the Markdown stays written.
  - `dist/` added to `.gitignore` when not ignored; no commit, no push.
  - when the repo has a `mkdocs.yml`: the closing line that the page needs a nav entry.
  - the closing report: both output paths, that the PDF is a DRAFT until the file is committed, and the one
    command that renders the sendable copy.
  - missing persona or no registry: name `/product:define-personas`, continue with `serves` as it is.
  - the *no charter, no guessing* rule sentence in ARCHITECTURE.md.
- [ ] **Step 2: Run** — expect failures.
- [ ] **Step 3: Write the skill**, following `define-personas`' structure.
- [ ] **Step 4: Run** — expect green; run the skill frontmatter validation.
- [ ] **Step 5: One real run** with `/development-claude-plugin:test` against a throwaway target repo: task "define
  a charter for this repo", expect a valid `docs/product/charter.md` and both rendered files. Record the verdict in
  the PR's test plan.

### Task 7: Reference and how-to documentation

**Files:**

- Create: `docs/how-to/write-and-send-your-product-charter.md`
- Modify: `mkdocs.yml` (nav), `docs/reference/plugins.md`, `docs/reference/commands.md`,
  `docs/reference/agents.md`, `README.md`, `docs/explanation/how-the-plugins-work.md`

- [ ] **Step 1: Write the how-to**, in this order: install the two tools; run the skill; what the interview asks;
  recording a direction change later; where the files land; DRAFT versus the sendable copy and the one command;
  the nav entry for a mkdocs repo; one product across several repos (run it in the shared docs repository).
- [ ] **Step 2: Update the reference pages and README** so `product`, both skills and both agents are listed with
  the descriptions their frontmatter carries.
- [ ] **Step 3: Run** `mkdocs build --strict` and the docs checks — expect green.

---

## After the epic

Not a build task: the maintainer runs `/product:define-charter` in this repo. Its first direction-log entries are the
four changes listed under *Intent* in the spec. The PR that adds `docs/product/charter.md` also adds its `mkdocs.yml`
nav entry. If the rendered look needs a revision, that is one follow-up story against `house.typ` / `house.css`.
