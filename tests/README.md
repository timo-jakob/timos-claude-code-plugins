# Shell-script behavioral tests

The `bats` suite that exercises the repo's shell scripts against fixtures with
asserted outputs — the **A2** layer of [#263](https://github.com/timo-jakob/timos-claude-code-plugins/issues/263)
(complementing the `script_quality` *lint* validator, A1). A plugin repo's scripts
are real code; this is the regression net that the coverage-misreporting incident
([#258](https://github.com/timo-jakob/timos-claude-code-plugins/issues/258) /
PR #259) showed they need.

## Run them

```sh
# Isolated in Docker (default) — the container gets four mounts in a worktree:
# your repo root at /work and the IaC toolchain cache, both read-WRITE, and your
# git dir + git common dir read-only. In a plain clone those last two resolve to
# the same path and collapse into one, so it is three. The read-only git mounts
# protect a
# WORKTREE checkout only: in a plain clone `.git` sits inside /work and is
# reachable read-write, which is why tests must never run a mutating `git`
# command against the mounted tree. Needs the tree to be a git checkout:
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

**Three exceptions to that isolation.** The first, in both modes: the `kubernetes-ci`
real-tool harness needs a **pinned** IaC toolchain, and `tests/iac-tools.zsh`
fetches roughly 100 MB of it from the network into
`${IAC_TOOLS_CACHE:-${XDG_CACHE_HOME:-~/.cache}/timos-claude-code-plugins/iac-tools}/<os>-<arch>/`
the first time the suite runs — so if you have `XDG_CACHE_HOME` set, it is not
under `~/.cache`, and `IAC_TOOLS_CACHE` overrides both (it is also how the
Docker mode points the container at the mounted host cache). The Docker mode creates that directory on the **host** and
bind-mounts it into the container — the `os-arch` leaf is what lets one cache
root serve both — so the container downloads once per platform rather than once
per run. The second is **Docker-mode only**: the runner also bind-mounts the
repo's **git store** — both `git rev-parse --git-dir` and `--git-common-dir`,
each at its own host-absolute path, **read-only** (in a plain clone the two
resolve to the same path, so it is one mount). Without it a linked **worktree**
checkout has no usable git inside the container at all — its `.git` is a *file*
pointing at a host path the container cannot see — and every `git` call the
suite makes fails. With it, the container can *read* part of your git store.
The third is **PyPI**, described below with the rest of the network story: two
`detect-stack.bats` cases `pip install` into a venv, and unlike the IaC toolchain
that traffic is not cached. All three are in-bound, so *nothing the tests do
escapes to the host* — but do not read the count as "the lane can run with its
network closed": it needs the two release hosts **and** PyPI.

**What `:ro` does and does not buy.** It denies writes *through those mounts*,
which is the whole store only in a **worktree**, where both dirs sit outside the
repo root. In a **plain clone** `.git` is inside the repo root, and the repo root
is mounted read-**write** at `/work` — so `/work/.git` is the copy the
container's git actually resolves, and the read-only mounts grant no protection
there. The rule is the same either way: **tests must never run a mutating `git`
command against the mounted tree.**

The Docker mode also now **requires the tree to be a git checkout**: it resolves
the two git dirs before building the image and exits 1 with a named error —
see the pre-flight at the top of `run-script-tests.zsh` for the exact set, which
is where it can't drift — rather than letting a bare `fatal: not a git
repository` surface from inside the container.

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

**A third thing needs the network, and it is not cached: PyPI.** The two
`verify-python-state:` cases in `detect-stack.bats` call
`verify-python-state.sh`, which creates a venv and runs `pip install`. They have
always done so on the host lane; since #1360 gave the image `python3-venv` and
`python3-pip` they do it in Docker too, and there is no cache for it — with no
network they fail with pip's own error. That is the price of not stubbing the
toolchain: a stubbed test stops proving the thing it exists to prove.

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
| `run-script-tests.bats` | Tests the runner's Docker wiring — the IaC toolchain cache mount, its precedence and its guards (#1199); the read-only git dir + git common dir mounts, in a plain clone and in a worktree (#1360) |
| `no-inert-permission-barriers.bats` | Repo-wide suite lint (#1360) — bans an *unguarded* permission-barrier `chmod` (root bypasses it, so the denial path never runs) and a backticked `@test` description (bats evaluates descriptions) |
| `assertions.bash` | Shared assertion helpers (`load assertions`) — the sanctioned way to assert (#1011) |
| `assertions.bats` | Behavioural coverage of those five helpers — both directions, literal-not-glob matching, case-sensitivity, the misuse statuses, the mismatch diagnostic, and the #1507 perf pin |
| `roster.bash` | Derives the helper roster from `assertions.bash` (`load roster`) — the single source both guards use (#1067) |
| `resolve-issue-corpus.bash` | The resolve-issue skill's file set (`load resolve-issue-corpus`) — `resolve_issue_files` (the conductor plus the declared `reference/*.md` roster, refusing to emit when the roster and the directory disagree) and `resolve_issue_corpus` (their concatenation, for sweeps that COUNT across the skill rather than pin WHERE a sentence lives). Covered by `resolve-issue-corpus.bats` (#1503) |
| `prose-lockstep.bash` | Shared normalisation for **propagation invariants** (`load prose-lockstep`) — `prose_body`, `prose_window`, `prose_gate_lines`; strips comment markers and markdown emphasis so a clause wrapped across two `#` lines still matches, and fails closed (exit 2) on an unreadable site (#1432) |
| `prose-lockstep.bats` | Unit coverage for the above — the normalisations no current sweep exercises (emphasis in a gate, `-F` literalness, the window's forward half, the `## Heading` carve-out) pinned against fixtures (#1432) |
| `acceptance/` | Outside-in cases against a **running** service built from a bootstrap template — deliberately NOT in the default gate (`bats` does not recurse); see [`acceptance/README.md`](acceptance/README.md) and #243 |
| `find-inert-bracket-assertions.zsh` | Detector behind the inert-assertion suite lint — `bracket` (#1011) and `and-tail` (#1067) rules |
| `iac-tools.zsh` | Resolves the **pinned** helm/kustomize/kubeconform/kube-linter/kyverno/yq the `kubernetes-ci` harness runs on (#1199) |
| `iac-tools.bats` | Tests `iac-tools.zsh` — pin extraction, the usage taxonomy, the anchored version probe and the cache layout, fully offline (#1199) |
| `fixtures/clean/` | A self-contained, finding-free mini plugin repo (a `development-fixture` plugin) |
| `fixtures/kubernetes-repo*/` | Three GitOps repository shapes — clean, broken, untested-policy (#1155) |
| `kubernetes-ci-fixtures.bats` | Executes the bootstrapped `kubernetes-ci` workflow with **real tools** over those fixtures (#1199) |
| `no-cluster-deploy.bats` | The #1206 direct-to-cluster gate — `check-no-cluster-deploy.zsh` behaviour, its workflow template's requirable shape (`yq`-structural), and both `branch-protection.sh` directions. Also holds that rule's **propagation invariant**: four clause sweeps plus the roster canary over a derived restatement roster, the guarded-creator clause among them (#1432) |
| `iac-selection-rule.bats` | Propagation invariant for the zero-language **IaC selection rule** (#1432) — every site stating the selection by the absence of a language must name the marker in the same statement; derived roster, roster tripwire against `MAINTAINING.md`, prose + code non-vacuity controls |
| `gather-claude-plugin.bats` | Tests `gather-claude-plugin-findings.zsh` — one mutation of `clean` per validator, asserting the matching finding |
| `check-marketplace-sync.bats` | Tests `check-marketplace-sync.zsh` — in-sync, version mismatch, missing entry, missing plugin.json |
| `api-styleguide-ruleset.bats` | Structural half of the org API styleguide ruleset (#689) — rule ids, severities, scoping, fix hints and doc anchors, parsed with `yq`. Also holds the **repo-wide pin sweep**: every file quoting a `styleguide-v*` jsDelivr URL must quote the same one, and no URL may carry a mistyped owner/repo. Behavioural halves: `check-styleguide-pin.bats` (offline) and `acceptance/cli/api-styleguide.bats` (needs spectral) |
| `check-styleguide-pin.bats` | Behaviour of `scripts/check-styleguide-pin.zsh` (#689 AC 8) against fixture trees with `npx`/`curl` stubbed on PATH — fully offline. Covers the case the script exists for: a pin that resolves but loads no rules must exit non-zero, not report a clean run |
| `helpers/check-renovate-styleguide.py` | Not a bats file — executed BY `api-styleguide-ruleset.bats`. Runs `renovate.json`'s shipped customManager regex against the real shim and resolves which `packageRule` wins, so the pin cannot silently rejoin the batched github-actions PR |
| `fixtures/api-styleguide/` | Eleven OpenAPI specs the styleguide suites lint — conforming, non-conforming, clause-isolating fixtures for error bodies, resource naming, pagination and header conventions, plus corner fixtures for collection detection, idempotent methods, trace headers, deprecated non-operations and path parameters |

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
failure becomes the function's non-zero status* — it is the last command, or its
`||` tail itself returns non-zero (`|| return 1`, or a call ending in one, which
is how `contains` reaches `_assert_mismatch`), or its status is captured and
dispatched (`|| rc=$?` then a `case`, which is how `matches` keeps misuse
distinct from a mismatch) — because the call site is then a simple command
errexit catches; a `[[ ]]` whose status the function discards is as inert as one
in a test body, and an `||` tail that *succeeds* discards it just as thoroughly.
And `[[ ]]` used as an `if`/`while` **condition** is control flow, not
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
what the value actually was, not just what it should have contained.

**Never enable `nocasematch`.** All five helpers match case-sensitively, but
`[[ ]]` and `case` both honour `shopt -s nocasematch`, so setting it anywhere in
a test file case-folds every assertion in that file —
`contains "$output" "ERROR"` would start matching lowercase prose. There is no
scoped exemption to reach for, since the enabling line is what does the damage:
if one comparison must ignore case, use `matches` with an ERE spelling both
cases, or `grep -i`. `assertions.bats` pins the helpers' own case-sensitivity
(#1507); the repo-wide invariant that no tracked `tests/` file enables it is
issue #1508, so today this is a convention rather than an enforced rule.

More scripts (the bash gather, helpers) are follow-on increments of #263.

**Guard every permission-barrier `chmod`.** The Docker lane runs as **uid 0**,
where `chmod` is not a barrier at all: root reads a `chmod 000` file and writes
into a `chmod 555` directory, so the denial path your test exists to exercise
never executes. Pair any mode that denies the **owner** read or write with a
root-bypass guard — either idiom:

```sh
[ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"    # the uid test

chmod 000 "$F"                                                 # the effect test —
if [ -r "$F" ]; then skip "a user that bypasses file permissions"; fi   # AFTER the chmod
chmod 555 "$D"
if [ -w "$D" ]; then skip "a user that bypasses directory permissions"; fi
```

The effect test is the stronger of the two — it also covers `CAP_DAC_OVERRIDE`
and root-squashed mounts — but it has two preconditions the uid test does not:
it must come **after** the `chmod` — on a *later line*, not merely later on the
same line — and it must test **the permission the barrier removed, on the same
path** (`-r` for a mode denying owner read, `-w` for one denying owner write). A
guard that can fire *before* the barrier is set skips the test on every lane and
proves nothing.

`no-inert-permission-barriers.bats` sweeps every tracked `tests/*.bats` and
fails on an unguarded barrier (#1360). It enforces the **ordering** precondition
— an effect marker counts only once a barrier has been seen in the same
`@test`, so an effect guard written above every `chmod` in its test is reported
unguarded — but **not** the path/permission half: it does not check that the
guard tests the same path, or `-r` versus `-w`. Nor does it look outside a
`@test` block, so a barrier in `setup()`, `teardown()` or a helper is out of
scope and must be guarded by hand. **A green sweep proves a guard is present and
correctly ordered, never that it tests the right thing.** It is a **textual**
detector, so it
recognises exactly two shapes: a line whose `id -u` **precedes** its `skip` (or
opens an `if` whose body carries one), and an `if` whose condition is a
`[ -r … ]` / `[ -w … ]` test and whose body carries `skip`. An `id -u` inside a
skip's own *message* is not a guard. A semantically
identical guard written another way — `[ "$EUID" -ne 0 ]`, a `require_nonroot`
helper — is fine shell but **will** be reported unguarded, so write it inline in
one of those two shapes. Conversely `[ -x "$BIN/tool" ] || skip …` is *not*
accepted as a guard, because that is how a dependency skip is written and
accepting it would clear every barrier beside it.

One carve-out worth knowing before you meet it: a `chmod` written into a fixture
by `printf` is reported as a site — at this granularity it is indistinguishable
from code. The fix is to move the fixture into a **heredoc** (heredoc bodies are
skipped as data), **never** to add a root-bypass `skip` to a test that is not
about permissions — that would silently drop its real coverage in the Docker
lane.

**Never put a backtick in a `@test` description.** bats *evaluates* every
description to resolve variable references, so a backticked word runs as command
substitution: it prints `<word>: command not found` to stderr once per test in
the file and silently strips the word from the test's own name. Quote it some
other way (`'kubernetes'`). The same sweep pins this — and it does **not** skip
heredoc bodies, so plant fixture `@test` lines with `printf`, not in a heredoc,
or the sweep will read them as your file's own descriptions.
