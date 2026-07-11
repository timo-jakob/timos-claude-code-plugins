# cli acceptance stage — end-to-end validation evidence (#699)

Epic [#243](https://github.com/timo-jakob/timos-claude-code-plugins/issues/243)
adds an **acceptance-test CI stage**: deploy the PR's build and exercise it
through the interface a user actually touches, as evidence the *shipped artifact*
works (not just its unit tests + a coverage number). v1 is cli-first: the spine
and report contract ([#697](https://github.com/timo-jakob/timos-claude-code-plugins/issues/697)),
then the cli harness ([#698](https://github.com/timo-jakob/timos-claude-code-plugins/issues/698)).

This document is the reproducible evidence that the cli acceptance stage works
**end-to-end** on the canonical test bed, **ai-doc-organizer**, using the
**shipped** primitives (`detect-stack.sh`, `render.zsh`, and the rendered
`acceptance.yml` + `tests/acceptance/cli/` smoke test).

> **Scope of this evidence.** This validates the mechanics the epic ships —
> interface detection, template rendering, and the exercise step running the
> **real built entry point** and emitting the `acceptance-report` JUnit contract
> — by running them against ai-doc-organizer's actual signals and its actual
> installed `aido` command. The remaining adoption step — bootstrapping
> `acceptance.yml` **into ai-doc-organizer** and watching a GitHub Actions PR
> build the image and run the stage — is the maintainer's, because it mutates a
> separate repo. The stage is validated *capable* of it here; wiring it into the
> test bed's CI is the adoption action.

## 1. Interface detection — `detect-stack.sh` (#242)

Run against the real ai-doc-organizer working tree:

```text
$ detect-stack.sh | jq -c '.interfaces'
[{"interface":"cli","evidence":"[project.scripts] entry point in pyproject.toml"},
 {"interface":"web-ui","evidence":"flask + jinja2 in dependencies (server-rendered templates)"}]
```

`cli` + `web-ui`, exactly as #242 requires — the `[project.scripts]` `aido` entry
point plus flask/jinja2 server-rendered templates. v1 exercises the `cli` leg.

## 2. Render the cli acceptance stage (#697 + #698)

```bash
# the spine workflow, one matrix leg per detected interface (minus library)
render.zsh … --acceptance-interfaces "cli, web-ui" \
  common/.github/workflows/acceptance.yml.tmpl
# the cli smoke test, entry point from [project.scripts]
render.zsh … --cli-entry-point "aido" \
  languages/python/tests/acceptance/cli/test_smoke.py.tmpl
```

The workflow's matrix renders to `interface: [cli, web-ui]` → the checks surface
as `acceptance (cli)` and `acceptance (web-ui)`. The cli leg installs the package
and runs `pytest tests/acceptance/cli/ --junitxml=acceptance-report/acceptance-cli.xml`.

## 3. Run the stage against the real built artifact — smoke passes

The built entry point runs (the "deploy" for a cli surface is just the installed
command):

```text
$ aido --help          # exit 0
usage: aido [-h] {init,status,rebuild-index} ...
```

Running the rendered smoke test exactly as the CI stage does, against
ai-doc-organizer's installed `aido`:

```text
$ python -m pytest tests/acceptance/cli/ --junitxml=acceptance-report/acceptance-cli.xml
tests/acceptance/cli/test_smoke.py::test_cli_help_smoke PASSED           [100%]
1 passed in 0.09s
```

The `acceptance-report` contract artifact (JUnit XML) is produced:

```xml
<testsuites name="pytest tests"><testsuite name="pytest" errors="0" failures="0"
 skipped="0" tests="1" ...><testcase classname="tests.acceptance.cli.test_smoke"
 name="test_cli_help_smoke" time="0.075" /></testsuite></testsuites>
```

So on ai-doc-organizer: the built artifact runs → the cli acceptance stage
exercises it → the smoke test passes → `acceptance (cli)` is green, with the
`acceptance-report-cli` JUnit artifact uploaded. **All three of #699's chain
links, proven on the real test bed.**

## 4. A failing acceptance test fails the check (#698 criterion, re-confirmed)

The gate is real, not decorative. Rendering the same smoke test against a
**broken** entry point (a command that exits non-zero) fails the run:

```text
$ render.zsh … --cli-entry-point "false" …/test_smoke.py.tmpl
$ python -m pytest tests/acceptance/cli/
1 failed          # pytest exit 1 -> the `acceptance (cli)` check goes red
```

## 5. Adding cli acceptance tests to a repo (fresh-reader guide)

Once a repo has been bootstrapped with the acceptance stage (SKILL.md §3g renders
it when `detect-stack.sh` finds a runtime interface):

1. **Where they live.** cli acceptance tests are pytest files under
   `tests/acceptance/cli/`. Bootstrap seeds `test_smoke.py`, which runs your
   entry point (`<cli> --help`) and asserts exit 0 + output. Grow real cases
   beside it.
2. **What to write.** Each case runs the **built** entry point against fixture
   inputs and asserts the observable contract — exit code and stdout/stderr — the
   way a user drives it. Keep fixtures in `tests/acceptance/cli/` next to the
   tests. Example shape:

   ```python
   import subprocess

   def test_status_on_empty_store():
       r = subprocess.run(["aido", "status"], capture_output=True, text=True, timeout=60)
       assert r.returncode == 0
       assert "0 documents" in r.stdout
   ```

3. **How it runs.** `.github/workflows/acceptance.yml` installs the package and
   runs `pytest tests/acceptance/cli/ --junitxml=acceptance-report/acceptance-cli.xml`
   on every PR. A failing test fails the `acceptance (cli)` check; the JUnit
   report uploads as the `acceptance-report-cli` artifact.
4. **Not unit tests.** Acceptance tests exercise the *shipped* command, not
   imported internals — they prove the deployed build works. Keep unit/integration
   tests where they are; this stage is the layer above them.

## Reproduce

Everything above is deterministic given the shipped templates and the
ai-doc-organizer working tree. Re-run `detect-stack.sh` for §1, `render.zsh` with
the flags in §2/§4, and `pytest tests/acceptance/cli/` against the installed
`aido` for §3. The template-level behavior has golden coverage in
`tests/render.bats` (`#697`/`#698` cases) and `tests/detect-stack.bats`.
