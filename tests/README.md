# Shell-script behavioral tests

The `bats` suite that exercises the repo's shell scripts against fixtures with
asserted outputs — the **A2** layer of [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263)
(complementing the `script_quality` *lint* validator, A1). A plugin repo's scripts
are real code; this is the regression net that the coverage-misreporting incident
([#258](https://github.com/timo-jakob/timos-claude-code-plugins/issues/258) /
PR #259) showed they need.

## Run them

```sh
# Isolated in Docker (default) — won't touch your machine, except the shared
# IaC toolchain cache described below:
tests/run-script-tests.zsh

# Directly on the host — host bats, the mode CI runs in. The toolchain it needs
# is exactly what tests/Dockerfile installs (plus GNU parallel, which CI adds for
# the gate helper); that file is the roster, and it is deliberately NOT restated
# here — an enumerated copy drifts, and this one already did, three times.
# Everything in it is called unguarded on purpose, so an absent tool reds the
# suite rather than silently skipping its coverage. The easiest to miss is `jq`:
# the kubernetes-ci harness executes the argocd step, which pipes `yq -o=json`
# into `jq`, so without it that step fails with the template's own "expression
# does not compile" message — which points at correct shipped content, not at
# your PATH:
tests/run-script-tests.zsh --local
```

**One exception to that isolation, in both modes.** The `kubernetes-ci`
real-tool harness needs a **pinned** IaC toolchain, and `tests/iac-tools.zsh`
fetches roughly 100 MB of it from the network into
`${IAC_TOOLS_CACHE:-${XDG_CACHE_HOME:-~/.cache}/timos-claude-code-plugins/iac-tools}/<os>-<arch>/`
the first time the suite runs — so if you have `XDG_CACHE_HOME` set, it is not
under `~/.cache`, and `IAC_TOOLS_CACHE` overrides both (it is also how the
Docker mode points the container at the mounted host cache). The Docker mode creates that directory on the **host** and
bind-mounts it into the container — the `os-arch` leaf is what lets one cache
root serve both — so the container downloads once per platform rather than once
per run. Nothing else leaves the container.

Four of the six pins (`kubeconform`, `kube-linter`, `kyverno`, `yq`) are read
**from the workflow template**, so bumping the template moves the harness with
it. `helm` and `kustomize` are the exception: the template installs neither
(`ubuntu-latest` ships both), so there is no upstream pin to read and they are
pinned inside `iac-tools.zsh` to the runner image the workflow targets — bump
them there. Never from `brew` or `apt` in either case: kube-linter's default
check set moves between releases — checks are added, renamed and retired — so a
newer binary does not reproduce the fixtures' counts. Measured, not
hypothesised: one minor ahead of the pin reports **three** findings on the
broken fixture where the pin reports **four**.

**It fails rather than skips.** The harness calls the resolver unguarded, so a
machine that cannot fetch the toolchain reds the whole suite — deliberately,
since a silently skipped harness is the failure mode this epic exists to
prevent.

```sh
zsh tests/iac-tools.zsh              # resolve + cache the pinned toolchain
zsh tests/iac-tools.zsh --print-pins # just show what it would pin, offline-safe
```

Two things that caching does **not** buy you, both worth knowing before you
diagnose a red as a harness bug:

- **The cache is per-platform, so warming it once is not enough for both modes.**
  `tests/iac-tools.zsh` on a macOS host fills `darwin-arm64`, which is what
  `--local` uses; the default Docker mode runs the suite inside the debian
  container and needs the `linux-*` leaf, which is filled only by running
  `tests/run-script-tests.zsh` once while online. Each platform you run on needs
  its own online run.
- **The `schema` job needs the network once per cache root, not once per run.**
  The shipped pipeline step is `kubeconform -strict -summary
  -ignore-missing-schemas` with **no** `-cache`, so in a consumer's CI it
  re-downloads the Kubernetes JSON schemas from `raw.githubusercontent.com`
  every time. The harness does not: `kubernetes-ci-fixtures.bats` puts a shim
  ahead of the real binary that prepends `-cache <cache-root>/kubeconform-cache`,
  which lives inside the same cache root as the binaries — so it is
  bind-mounted in Docker mode and restored by `actions/cache` in CI. After one
  online run the schema assertions are offline-safe too. On a **cold** schema
  cache and no network they still fail, with `Errors: N` and a schema-download
  message that names nothing in this repo. (Adding `-cache` to the shipped
  template would help consumers identically, and is deliberately out of this
  story's scope.)

CI runs them on every PR via `.github/workflows/script-tests.yml` (natively — the
runner is already disposable; Docker is only for local isolation). Its entry
point is not this script: the workflow drives
`development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`, which
runs the whole suite once in parallel and exits with bats' real status.

## Layout

| Path | What |
| --- | --- |
| `Dockerfile` | Disposable image — the declared test dependencies; see the file's own header rather than a list that drifts |
| `run-script-tests.zsh` | Runner — Docker by default, `--local` for host bats |
| `run-script-tests.bats` | Tests the runner's Docker wiring — the IaC toolchain cache mount, its precedence and its guards (#1199) |
| `assertions.bash` | Shared assertion helpers (`load assertions`) — the sanctioned way to assert (#1011) |
| `roster.bash` | Derives the helper roster from `assertions.bash` (`load roster`) — the single source both guards use (#1067) |
| `acceptance/` | Outside-in cases against a **running** service built from a bootstrap template — deliberately NOT in the default gate (`bats` does not recurse); see [`acceptance/README.md`](acceptance/README.md) and #243 |
| `find-inert-bracket-assertions.zsh` | Detector behind the inert-assertion suite lint — `bracket` (#1011) and `and-tail` (#1067) rules |
| `iac-tools.zsh` | Resolves the **pinned** helm/kustomize/kubeconform/kube-linter/kyverno/yq the `kubernetes-ci` harness runs on (#1199) |
| `iac-tools.bats` | Tests `iac-tools.zsh` — pin extraction, the usage taxonomy, the anchored version probe and the cache layout, fully offline (#1199) |
| `fixtures/clean/` | A self-contained, finding-free mini plugin repo (a `development-fixture` plugin) |
| `fixtures/kubernetes-repo*/` | Three GitOps repository shapes — clean, broken, untested-policy (#1155) |
| `kubernetes-ci-fixtures.bats` | Executes the bootstrapped `kubernetes-ci` workflow with **real tools** over those fixtures (#1199) |
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
