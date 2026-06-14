# Shell-script behavioral tests

The `bats` suite that exercises the repo's shell scripts against fixtures with
asserted outputs — the **A2** layer of [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263)
(complementing the `script_quality` *lint* validator, A1). A plugin repo's scripts
are real code; this is the regression net that the coverage-misreporting incident
([#258](https://github.com/timo-jakob/timos-claude-code-plugins/issues/258) /
PR #259) showed they need.

## Run them

```sh
# Isolated in Docker (default) — won't touch your machine:
tests/run-script-tests.zsh

# Directly on the host (needs bats on PATH; this is what CI uses):
tests/run-script-tests.zsh --local
```

CI runs them on every PR via `.github/workflows/script-tests.yml` (natively — the
runner is already disposable; Docker is only for local isolation).

## Layout

| Path | What |
|---|---|
| `Dockerfile` | Disposable image (zsh, bats, jq, shellcheck, python3, git) |
| `run-script-tests.zsh` | Runner — Docker by default, `--local` for host bats |
| `fixtures/clean/` | A self-contained, finding-free mini plugin repo (a `development-fixture` plugin) |
| `gather-claude-plugin.bats` | Tests `gather-claude-plugin-findings.zsh` — one mutation of `clean` per validator, asserting the matching finding |
| `check-marketplace-sync.bats` | Tests `check-marketplace-sync.zsh` — in-sync, version mismatch, missing entry, missing plugin.json |

## Adding a test

Most tests copy `fixtures/clean` into `$BATS_TEST_TMPDIR`, apply one mutation, and
assert. To cover a new script, add a `<script>.bats` and (if needed) a fixture
under `fixtures/`. Keep each test to a single planted issue so a failure points at
exactly one behaviour. More scripts (the bash gather, helpers) are follow-on
increments of #263.
