# Include a UI styleguide in a React repo

A shared UI styleguide keeps every web UI of a platform consistent: one place
states the design and usage rules and the design tokens a UI builds to.
`/development:bootstrap` can mount such a styleguide repository into a React
repo as a pinned git submodule, and tell every Claude session in that repo to
read it before UI work.

The plugin names no styleguide of its own. You supply the repository.

## Before you start

- The repo is a React app, one the React overlay applies to: a JS/TS repo whose
  `package.json` lists `react` in `dependencies` (`detect-stack.sh` reports
  `is_react: true`). A server-rendered `web-ui` repo, such as Flask with Jinja
  templates, does not get the step.
- The styleguide repository has at least one release tag of the form `vX.Y.Z`.
  Bootstrap pins the newest one and never pins a branch head.
- Its root holds `STYLEGUIDE.md` (the rules) and `CHECKLIST.md` (what to check
  before UI work is done), the two files the `CLAUDE.md` section names.

## Mount the styleguide

Pass the repository's URL:

```text
/development:bootstrap --styleguide-repo https://github.com/timo-jakob/timos-platform-styleguide
```

Without the flag, bootstrap asks for the URL once, on a React repo that has no
`styleguide` submodule yet. Leave the answer blank to skip the step.

If that repository's release tags are `v0.1.0` and `v0.1.1`, the bootstrap pull
request then carries:

| What | Where |
| --- | --- |
| a `styleguide/` submodule checked out at the commit of `v0.1.1`, the newest `vX.Y.Z` tag in semver order (`v0.10.0` beats `v0.9.0`; pre-release tags such as `v1.0.0-rc.1` are ignored) | `styleguide/`, `.gitmodules` (no `branch` line) |
| a section `## Read the styleguide before UI changes`: read `styleguide/STYLEGUIDE.md` before a UI change, check `styleguide/CHECKLIST.md` before declaring UI work done | `CLAUDE.md`, appended to an existing file with every byte kept |
| one `gitsubmodule` entry, directory `/`, weekly | `.github/dependabot.yml` |

The submodule is staged with the rest of bootstrap's files and lands in its one
commit. Bootstrap's summary reports the step in one line, such as
`styleguide: added https://github.com/timo-jakob/timos-platform-styleguide at v0.1.1`.

Every React repo also ignores `styleguide/` in ESLint (`eslint.config.js`),
Vitest (`vitest.config.ts`) and Prettier (`.prettierignore`), whether or not a
styleguide is mounted. Without those ignores, Vitest would collect the
styleguide's own `node:test` suites and the repo's gate would go red.

## Take a newer styleguide version

Bootstrap pins only the first checkout. After that, Dependabot opens a pull
request whenever the styleguide's default branch moves, so keep that branch at
released states. A repo that keeps its own Renovate config gets no Dependabot
entry; bootstrap leaves the Renovate config alone and says that submodule bumps
are not configured.

## When the step fails

The step fails as a unit and the rest of bootstrap carries on. Nothing is left
behind: no `.gitmodules` entry, no `CLAUDE.md` section, no Dependabot entry, and
no `styleguide/` directory is created or changed. The summary names the URL and
the reason:

| Reason | What to do |
| --- | --- |
| `unreachable` | check the URL and your access to it, then re-run bootstrap |
| `no vX.Y.Z tag` | tag a release in the styleguide repository, then re-run |
| `styleguide/ exists and is not a submodule` | move your own `styleguide/` directory out of the way, then re-run |

## Re-running bootstrap

A re-run on a repo whose `.gitmodules` already declares the `styleguide`
submodule contacts no remote, asks no question, ignores `--styleguide-repo` and
leaves the pin where it is. It only adds a `CLAUDE.md` section or a Dependabot
entry that is missing.
