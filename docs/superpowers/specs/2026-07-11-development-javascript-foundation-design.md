# development-javascript slice 1 — plugin foundation design (2026-07-11)

Tracking issue: **#729**. Slice 1 of epic **#683**; part of **#682**. The
foundation MVP that gates every other slice (slice 2 #727 is blocked by it).

## Context

Slice 1 stands up `development-javascript` far enough that **the plugin exists,
detects a JS/TS repo, and formats/lints it end-to-end.** It is **not greenfield**:

- `detect-stack.sh` already emits a `typescript` language token from
  `package.json` / `tsconfig.json` (and fires on `package.json` alone, so plain-JS
  repos are covered).
- A legacy `templates/languages/typescript/.eslintrc.json` exists but predates the
  committed **flat-config** decision — it is modernized, not written fresh.
- No `development-javascript` plugin exists yet — the net-new part.

The surface mirrors `development-python`'s foundation (plugin.json, a mechanical
format_lint agent like `python-ruff-fixer`, bootstrap toolchain templates).

## Decisions (approved 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| Language token | **Rename `typescript` → `javascript`** | Token matches the plugin name + the JS+TS-combined intent; contained change to the detect-stack enum + dispatch map |
| format_lint runnable | **Minimal maintenance dispatcher (format_lint-only) + `js-format-lint-fixer`** | Makes slice 1 an end-to-end MVP; slice 4 grows the dispatcher |
| Lint/format | flat **`eslint.config.js`** + **Prettier @120** | The committed toolchain; replaces the legacy `.eslintrc.json` |
| Test | **vitest + v8** | |
| Runtime baseline | **Node 24 LTS** (`.nvmrc`) | Current Active LTS as of 2026-07; slice 5's runtime-upgrade keeps it moving |
| Package manager | **npm** | Zero-install, polyrepo default |

## Scope — four parts

### 1. Plugin skeleton

`development-javascript/.claude-plugin/plugin.json`, the `marketplace.json` entry
(name / description / version / author / `source: ./development-javascript` /
`category: development`), and the directory layout (`agents/`, `skills/`).

### 2. Detection → dispatch

Rename the `detect-stack.sh` enum token `typescript` → `javascript` (detection
inputs unchanged: `package.json` primary, `tsconfig.json` strengthening). Wire the
orchestrator's language→plugin dispatch so `javascript` routes to
`development-javascript`.

### 3. format_lint

`js-format-lint-fixer` — mechanical, `model: haiku`, runs ESLint `--fix` +
Prettier `--write`, reports what changed, and returns a missing-tool
recommendation when `configured == false` (mirrors `python-ruff-fixer`). Plus the
minimal `development-javascript:maintenance` dispatcher: a pure function of its
JSON payload that validates it and returns a plan for the format_lint group only
(slice 4 extends it with planner + sonar + code_scanning + coverage).

### 4. Bootstrap toolchain templates

Modernize + rename `templates/languages/typescript/` → `javascript/` with the
blessed set: flat `eslint.config.js`, Prettier config (@120), `vitest.config.ts`
(+ v8 coverage), a strict `tsconfig.json` base, `.nvmrc` (Node 24 LTS), the
package.json scripts (`lint` / `format` / `test` / `test:coverage`), gitignore
additions, pre-commit hooks (ESLint + Prettier), and the CI lint/format/test
steps. The legacy `.eslintrc.json` template is removed.

## Boundaries

| Unit | Does | Depends on |
|---|---|---|
| plugin skeleton | plugin.json + marketplace entry + layout | marketplace schema |
| detection/dispatch | `javascript` token + routing | detect-stack.sh, orchestrator |
| format_lint | ESLint+Prettier autofix agent + minimal dispatcher | ESLint, Prettier |
| toolchain templates | the blessed JS config file set | bootstrap templates tree |

## Acceptance criteria

- [ ] `development-javascript` plugin created; appears in the marketplace.
- [ ] `detect-stack.sh` emits `javascript`; the orchestrator dispatches it to
      `development-javascript`.
- [ ] `js-format-lint-fixer` runs ESLint `--fix` + Prettier `--write`, reports
      changes, and returns the missing-tool recommendation when unconfigured.
- [ ] The minimal maintenance dispatcher validates its payload and plans the
      format_lint group.
- [ ] Bootstrap renders the blessed JS toolchain (flat `eslint.config.js`,
      Prettier @120, vitest + v8, tsconfig, `.nvmrc` Node 24 LTS, package scripts,
      gitignore, pre-commit, CI).
- [ ] The legacy `.eslintrc.json` template is removed.

## Dependencies

- **Gates all other #683 slices.** No upstream.

## Implementation note

JS bootstrap templates that include workflow files
(`templates/languages/javascript/.github/workflows/*`) are no obstacle to
the bot-authored path — the Maintenance App has the `workflows` permission
since #750.

## Open item flagged for review

- **Node LTS baseline** is set to **Node 24**; confirm that's the intended pin
  (vs Node 22) for the initial `.nvmrc`.
