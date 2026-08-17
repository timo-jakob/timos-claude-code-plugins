# Acceptance tests

Outside-in test cases spun out from a story's `story-spec/v1` block (the
`test-case` issue convention, #671 — see ARCHITECTURE.md). Each file here
implements one story's `test_cases[]`, one bats test per `tc-*` id, named for
that id so the mapping back to its issue is mechanical.

Layout follows the #243 convention — one directory per **surface**, keyed by the
case's `tooling`:

| `tooling` | directory |
| --- | --- |
| `curl` | `rest/` |
| `grpcurl` | `grpc/` |
| `playwright` | `web/` |
| `cli` | `cli/` |

## These are NOT part of the default gate — on purpose

`run-gate.zsh` runs `bats tests`, and **bats does not recurse without `-r`**, so
nothing under `tests/acceptance/` runs in the normal suite or in `script-tests`.
That is deliberate, not an oversight:

- these cases exercise a **running service** built from a bootstrap template, so
  they need a toolchain the default suite deliberately does not have
  (`tests/ops-api-language-payloads.bats` states the same rule for every ops-api
  payload). Note the default suite is not literally offline — it fetches the
  pinned IaC toolchain, and since #1360 the two `verify-python-state:` cases
  reach PyPI in the container too — but that is a short, declared list, not a
  package registry standing up a running service;
- **standing up this tier and its CI execution is #243's concern.** A story that
  writes cases into the tree does not also get to wire the runner.

So treat a green run here as *authoring-time and on-demand* evidence, not as a
gate. The always-on gate for these payloads is the grep-based structural suite in
`tests/ops-api-language-payloads.bats`, plus the `ops-conformance` CI job that
bootstrap installs in the **target** repo.

## Running them

Each suite provisions its **own** sandbox — one directory per test file, under a
cache directory **outside** the repository — and reuses it on later runs. First
run downloads dependencies.

The split is not tidiness: provisioning prunes `src/` and `dist/` before
recompiling, so one shared directory would let one suite's prune land while the
other's fixtures are executing `node dist/main.js`. The sandbox is therefore
keyed by **test file *and* worktree** — the second because this repo works in
`.claude/worktrees/`, and a run in one tree would otherwise recompile over
another tree's payload and report green about the wrong source. On top of that,
each provision takes an atomic lock on its own sandbox, so a re-run started
before the previous one finished cannot interleave two `npm install`s in one
tree.

The keying is what makes `--jobs` and concurrent runs safe; the lock only covers
provisioning, which is why it could not have done the job on its own.

One case neither can separate is a **re-run of the same suite in the same tree**
while the previous run's tests are still going — same key, and the lock is long
released. So the provisioner **refuses** rather than recompiling under a live
fixture: it exits `3` with `node-ops-sandbox: … is in use by a running fixture`.
Wait for that run to finish, or kill the fixture. (Exit `1` is a provisioning
failure on the harness's side and `2` means the inputs are wrong — bad usage, a
missing tool, or a missing/malformed template file — so a runner can tell the
three apart without matching on wording.)

```bash
# the Node ops-api payload (#936) — 15 story cases + 2 harness cases
bats tests/acceptance/rest tests/acceptance/cli

# the org API styleguide ruleset (#689 + #944) — 39 cases:
#   9 + 13 story, 15 clause-isolating, 2 #1330 premise
bats tests/acceptance/cli/api-styleguide.bats
```

**The styleguide suite is the one file here that stands up no service.** It
lints committed fixtures with `npx --yes @stoplight/spectral-cli@<pinned>`, so
it needs `node`, `npx`, `jq` and network access on the first run (to fetch
spectral) — but none of the sandbox machinery below. It pins spectral to an
exact version rather than the shipped job's floating `@6`, because an upstream
minor can retire an inherited `spectral:oas` rule and change these fixtures'
verdicts with no change in this repo. Note that the `bats tests/acceptance/cli`
invocation above also runs it.

Requirements: `node` (24+), `npm`, `curl`, `jq`, `zsh`, `pgrep` (procps), and
network access on the first run. `pgrep` is what the in-use refusal above is
built on, so a missing one is a hard error rather than a silently disarmed guard.
A suite whose toolchain is missing **fails loudly** rather than skipping — a
skipped check that reads as green is the failure mode this repo's test
conventions are written against.

Override the cache location with `$ACCEPTANCE_CACHE` (default:
`${TMPDIR:-/tmp}/claude-acceptance-cache`). Delete it to force a clean rebuild.
