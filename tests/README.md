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

# Directly on the host (needs bats on PATH — host bats, the mode CI runs in):
tests/run-script-tests.zsh --local
```

CI runs them on every PR via `.github/workflows/script-tests.yml` (natively — the
runner is already disposable; Docker is only for local isolation). Its entry
point is not this script: the workflow drives
`development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`, which
runs the whole suite once in parallel and exits with bats' real status.

## Layout

| Path | What |
| --- | --- |
| `Dockerfile` | Disposable image (zsh, bats, jq, shellcheck, python3, git) |
| `run-script-tests.zsh` | Runner — Docker by default, `--local` for host bats |
| `assertions.bash` | Shared assertion helpers (`load assertions`) — the sanctioned way to assert (#1011) |
| `roster.bash` | Derives the helper roster from `assertions.bash` (`load roster`) — the single source both guards use (#1067) |
| `find-inert-bracket-assertions.zsh` | Detector behind the inert-assertion suite lint — `bracket` (#1011) and `and-tail` (#1067) rules |
| `fixtures/clean/` | A self-contained, finding-free mini plugin repo (a `development-fixture` plugin) |
| `gather-claude-plugin.bats` | Tests `gather-claude-plugin-findings.zsh` — one mutation of `clean` per validator, asserting the matching finding |
| `check-marketplace-sync.bats` | Tests `check-marketplace-sync.zsh` — in-sync, version mismatch, missing entry, missing plugin.json |

## Adding a test

Most tests copy `fixtures/clean` into `$BATS_TEST_TMPDIR`, apply one mutation, and
assert. To cover a new script, add a `<script>.bats` and (if needed) a fixture
under `fixtures/`. Keep each test to a single planted issue so a failure points at
exactly one behaviour.

**Assert through the shared helpers.** Start the file with `load assertions` and
use `contains` / `lacks` / `starts_with` / `ends_with` / `matches` from
`assertions.bash`. **That list is the roster** ARCHITECTURE.md designates as the
contributor-facing source of truth, and a guard test in
`no-inert-bracket-assertions.bats` fails when a helper defined in
`assertions.bash` is not named here — so add new helpers to this line.
Plain `[ ... ]` is fine too, as a command of its own (it is
never flagged, but it is not exempt from the one-assertion-per-line rule
below). Never assert with a bare
`[[ ... ]]`: bash 3.2 (macOS `/bin/bash`) does not apply errexit to it, so a
false one on a non-final line is silently ignored and the test passes while
proving nothing — while bash >= 4 catches it, making the same test mean
different things on the macOS and Ubuntu CI legs.
`no-inert-bracket-assertions.bats` fails the suite on the shapes it can detect
(#1011), just as `no-inert-negative-assertions.bats` does for a bare `!`
negation at line start (#829) — so what you follow is the convention, not the
guard.

Two carve-outs: `[[ ]]` inside a **named helper function** is fine *when its
status is what the function returns* — its last command, or one carrying an
explicit `|| return` — because the call site is then a simple command errexit
catches; a `[[ ]]` whose status the function discards is as inert as one in a
test body. And `[[ ]]` used as an `if`/`while` **condition** is control flow, not
an assertion, so leave it alone (converting it in a file without
`load assertions` yields 127 and a silently false branch).

**Keep one assertion per line.** `contains "$output" "a" && contains "$output"
"b"` silently drops the first call — the AND-list errexit exemption applies to a
function call exactly as it does to `[[ ]]`, on every bash. The same guard's
`and-tail` rule fails the suite on it (#1067). The **condition** carve-out
carries over unchanged; the named-function one does **not** — an `&&`-swallowed
helper call inside a function is just as inert there, and being unscanned only
hides it. A helper that *ends* the list (`true && contains …`) is genuinely
fine, because its status is the one errexit sees.

The rule is about joining, not about helpers, so it covers `[ ... ]` too:
`[ -n "$a" ] && [ -f "$b" ]` swallows the left test and **no** lint rule catches
it. Nor does anything catch `<helper> … || true` — an `||` tail is only an
assertion when its last member can itself fail (`|| return 1`) — or a **piped**
assertion (`contains … | tee f`), since a pipeline's status is its last
command's and bats does not run test bodies under `pipefail`.

Each helper takes exactly two arguments with a non-empty second one, returns 2 on
misuse (an uncompilable `matches` pattern included), and on a genuine mismatch
prints the needle and a truncated haystack to **stderr** — so a CI failure shows
what the value actually was, not just what it should have contained. More scripts
(the bash gather, helpers) are follow-on increments of #263.
