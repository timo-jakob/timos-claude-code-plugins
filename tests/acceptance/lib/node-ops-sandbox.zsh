#!/usr/bin/env zsh
# node-ops-sandbox.zsh — provision a runnable Node service from the shipped
# ops-api template, so the acceptance cases (#936) can exercise the real surface.
#
# Prints the sandbox directory on stdout; everything else goes to stderr, so a
# caller can `SANDBOX="$(zsh tests/acceptance/lib/node-ops-sandbox.zsh)"`.
#
# The sandbox lives OUTSIDE the repository (under $ACCEPTANCE_CACHE) for two
# reasons: `npm install` writes a node_modules tree that has no business in a
# working copy, and resolve-issue's review loop hashes the working tree to skip a
# redundant gate re-run — a build directory inside the repo would change that
# identity on every run and defeat every match.
#
# It is INCREMENTAL: the dependency install is keyed on the shipped
# package.json.deps, so it re-runs only when that fragment changes. The payload
# itself is copied and recompiled every time, which is the point — these cases
# must test the file as it stands in the working tree, never a stale copy.
#
# It is also CONCURRENCY-SAFE, in the three ways it has to be — and the first two
# are the sandbox KEY, not the lock, because the lock covers only provisioning
# while the tests then run for minutes afterwards:
#
#   * per test FILE (`--suite`), because provisioning prunes `src/` and `dist/`
#     before recompiling: with one shared directory the rest suite's prune lands
#     while the cli suite's fixtures are executing `node dist/main.js`, and the
#     module-not-found crash reads as a payload regression;
#   * per WORKTREE, for the same reason across checkouts — and with a worse
#     failure, since the surviving run may report green about the other tree's
#     payload;
#   * and a kernel `flock` over the provision itself, which stops two runs of the
#     same suite in the same tree (a re-run started before the first finished)
#     from interleaving two `npm install`s and stamping the resulting partial
#     node_modules as a successful install. The kernel drops it when the holder
#     dies, so a killed run leaves nothing behind to time out on or reclaim.
#
# That last case is the one the key CANNOT separate — same suite, same tree means
# the same directory — and the lock does not reach past provisioning into the
# minutes of testing that follow. So the provisioner additionally REFUSES to touch
# the sandbox while a fixture is executing out of it, checked twice: before the
# install (which rewrites node_modules and swaps the manifest) and again before
# the prune. Together those cover a re-run started by hand or by a CI retry; a
# genuinely simultaneous pair that both clear the check in the same instant is not
# covered, and would need the lock's lifetime moved to the consumer (acquire in
# ops_provision, release in teardown_file).
emulate -L zsh
setopt pipe_fail no_unset

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h:h}"
TEMPLATE="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript"
PAYLOAD="$TEMPLATE/ops-api"

# die [code] <message> — exit with a TYPED status, so a caller can tell an
# environment fault from a deliberate refusal without grepping prose:
#
#   1  provisioning failed on OUR side — npm install, tsc, a write, the lock wait
#   2  the INPUTS are wrong — bad usage, a missing tool, a missing or malformed
#      template file (a corrupt shipped fragment is a template defect, not a
#      provisioning failure, so it belongs here rather than in 1)
#   3  the sandbox is in use by a running fixture — the deliberate refusal
#
# tests/acceptance/rest/ops-api-node.bats pins 3 for the refusal; the #243 runner
# can use the same split rather than matching on wording.
die() {
  local code=1
  [[ "$1" == <-> ]] && { code="$1"; shift }
  print -u2 -- "node-ops-sandbox: $*"
  exit "$code"
}

SUITE="default"
while (( $# )); do
  case "$1" in
    --suite)
      [[ -n "${2:-}" ]] || die 2 "--suite requires a value"
      SUITE="$2"
      shift 2
      ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
# The caller passes a bats filename. Key on the last TWO path components, not the
# basename: the two acceptance suites are both called `ops-api-node.bats` and
# differ only in their directory, so `${SUITE:t:r}` alone collapses them to one
# name — and the per-file split this whole script is built around would silently
# not exist. `ops_port` keys on `dirname/basename` for exactly this reason; these
# two derivations must agree.
SUITE="${${SUITE:h}:t}-${SUITE:t:r}"
SUITE="${SUITE//[^A-Za-z0-9._-]/_}"
[[ -n "$SUITE" ]] || die 2 "--suite resolved to an empty name"

CACHE="${ACCEPTANCE_CACHE:-${TMPDIR:-/tmp}/claude-acceptance-cache}"

# The cache is shared across every checkout on the machine, and this repo works
# in `.claude/worktrees/`, so several trees of the same repo are the norm. Two
# worktrees provisioning "the same" suite would otherwise prune and recompile one
# directory in turn: one run crashes with module-not-found, or — worse — reports
# green about the OTHER tree's payload, which is precisely the stale-copy result
# the prune step exists to prevent. So the repo root is part of the key.
TREE_KEY="$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)" \
  || die "could not derive a cache key for $REPO_ROOT"
SANDBOX="$CACHE/node-ops-api-$SUITE-$TREE_KEY"
LOCK="$CACHE/.node-ops-api-$SUITE-$TREE_KEY.lock"

mkdir -p "$CACHE" || die "could not create $CACHE"

# ---- provisioning lock ------------------------------------------------------
# `zsystem flock` — an advisory KERNEL lock on a plain file — rather than a
# hand-rolled `mkdir` lock. The difference is the failure mode, not the happy
# path: a mkdir lock has to be released by the process that took it, so a run
# killed with SIGKILL leaves it behind and every later run must either wait out a
# timeout or "reclaim" it. Reclaiming is check-then-act on a shared resource, and
# no amount of re-reading makes that atomic: two waiters can both decide a lock is
# stale, and the loser then deletes the winner's freshly acquired lock — handing
# two provisions the sandbox at once, which is exactly the interleaved-npm-install
# corruption the lock exists to prevent. The kernel releases a flock when the
# holding process dies, however it dies, so staleness cannot arise and there is
# nothing to reclaim.
#
# The lock spans the WHOLE provision (install -> stamp -> prune -> compile),
# because the prune is as destructive to a concurrent run as a half-finished
# install is. It does NOT span the test run that follows — the sandbox key above
# is what makes that safe, by giving every (suite, worktree) pair its own
# directory. The lock's remaining job is the narrower one: two runs of the SAME
# suite in the SAME tree (a re-run started before the first finished).
#
# No signal traps and no release: the fd closes when this process exits, by any
# route, and the kernel drops the lock with it.
zmodload zsh/system 2>/dev/null \
  || die 2 "zsh/system is unavailable, so the provisioning lock cannot be taken"
: > "$LOCK" 2>/dev/null \
  || die "could not create the lock file $LOCK (is the cache writable?)"
# -t 300: the same bound the previous implementation had, but reached only under
# genuine contention — a dead holder's lock is already gone.
#
# flock's status is READ, not collapsed: it returns 2 for the timeout and 1 for
# anything else (a failed open, a locking syscall error). Reporting those as "the
# timeout" would send the reader hunting for a concurrent provision that does not
# exist.
typeset -i flock_rc=0
zsystem flock -t 300 -f LOCK_FD "$LOCK" || flock_rc=$?
if (( flock_rc == 2 )); then
  die "timed out after 300s waiting for $LOCK — another provision of this suite is still running in this worktree"
elif (( flock_rc != 0 )); then
  die "could not lock $LOCK (zsystem flock rc $flock_rc)"
fi

# ---- in-use check -----------------------------------------------------------
# The sandbox key separates suites and worktrees, but NOT a re-run of this same
# suite in this same tree — and the lock is released when this script exits, long
# before that run's TESTS finish. Mutating the tree under a live fixture is what
# produces the module-not-found crash that reads as a payload regression.
#
# `ops_start`/`ops_run_expect_exit` launch the fixture with the ABSOLUTE script
# path for exactly this reason: `pgrep -f` matches argv, and a relative
# `dist/main.js` would make this guard silently never fire.
#
# The pattern is an ERE, so every character that is not plainly safe is replaced
# by `.` — a `+`, `(` or `[` anywhere in $TMPDIR would otherwise make the pattern
# uncompilable and turn the refusal back into dead code, which is the failure this
# guard has already had once. `.` is a wildcard, so the match only ever widens
# within this one sandbox path, never across sandboxes.
#
# Named for what it RETURNS. `sandbox_in_use() { ! pgrep … }` succeeds when the
# sandbox is idle, so `if sandbox_in_use; then die` — the reading the name invites
# — would silently invert the guard: refusing every legitimate provision and
# permitting every unsafe one. For a guard that has already shipped once unable to
# fire, that is not a risk worth the tidier-sounding name.
#
# pgrep's codes are read, not collapsed. `! pgrep …` treats 2/3 (usage or fatal)
# and 127 (not installed) as "idle" exactly like 1 (no match), so on a CI image
# without procps — the #243 tier this harness targets — the guard would fail OPEN
# and nothing would say so.
sandbox_is_free() {
  local pat="${SANDBOX//[^A-Za-z0-9\/._-]/.}/dist/main.js" rc=0
  pgrep -f "$pat" > /dev/null 2>&1 || rc=$?
  (( rc == 0 )) && return 1        # matched — a fixture is running
  (( rc == 1 )) && return 0        # no match — genuinely idle
  die 2 "pgrep failed (rc $rc) — cannot prove $SANDBOX is idle, refusing to touch it"
}
# Fail loudly on a missing tool rather than letting the caller skip: a skipped
# acceptance check that reads as green is worse than an absent one. `pgrep` is in
# the list, and this loop runs BEFORE the first in-use check below, because that
# check is the one whose failure mode is silent — the others die on their own.
for tool in node npm curl jq pgrep; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "'$tool' is required but not on PATH"
done

# Checked HERE as well as before the prune: the npm install below can run for ~30s
# and rewrites node_modules in place, and the package.json swap replaces the
# manifest the payload's /info version fallback reads — both as destructive to a
# concurrent run as the prune is.
sandbox_is_free || die 3 "$SANDBOX is in use by a running fixture — wait for that run to finish (or kill it) before re-provisioning"

for f in "$PAYLOAD/opsApi.ts" "$PAYLOAD/package.json.deps" "$TEMPLATE/tsconfig.json"; do
  [[ -f "$f" ]] || die 2 "template file missing: $f"
done

mkdir -p "$SANDBOX/src/ops" || die "could not create $SANDBOX"

# ---- package.json ----------------------------------------------------------
# Built from the SHIPPED fragment, so the cases prove the fragment is installable
# and complete — not merely that some hand-written manifest works. The `//`
# comment key is dropped (npm tolerates it; jq output is cleaner without), and the
# name/version are the acceptance data: version 1.4.2 is what
# tc-happy-version-falls-back-to-package-json asserts /info reports when
# $BUILD_VERSION is unset.
#
# typescript is added HERE rather than installed separately, and that is not a
# style choice: `npm install typescript` REWRITES package.json to record the new
# dependency, so the next run's fragment comparison below would never match and
# every run would reinstall. It is the harness's own tool — the shipped fragment
# ships only what a service needs at runtime, which is why it is added here and
# not there.
# Validated separately from the write: `jq … > file || die "not valid JSON"` blames
# the shipped fragment for a full or read-only cache directory, and leaves a
# truncated package.json.next behind.
jq -e . "$PAYLOAD/package.json.deps" > /dev/null \
  || die 2 "package.json.deps is not valid JSON"
jq '. + {name: "ops-acceptance", version: "1.4.2", private: true}
    | del(."//")
    | .devDependencies.typescript = "^7.0.0"' \
  "$PAYLOAD/package.json.deps" > "$SANDBOX/package.json.next" \
  || die "could not write $SANDBOX/package.json.next (is the cache full or read-only?)"

# ---- tsconfig --------------------------------------------------------------
# The shipped strict config, plus rootDir. The template omits rootDir because its
# own acceptance bar is `tsc --noEmit`; EMITTING from it needs one under
# TypeScript 7 (TS5011), and that is a harness concern, not a payload change.
jq -e . "$TEMPLATE/tsconfig.json" > /dev/null \
  || die 2 "tsconfig.json is not valid JSON"
jq '.compilerOptions.rootDir = "src"' "$TEMPLATE/tsconfig.json" \
  > "$SANDBOX/tsconfig.json" \
  || die "could not write $SANDBOX/tsconfig.json (is the cache full or read-only?)"

# ---- dependencies (incremental) --------------------------------------------
# Reinstalling on every run would add ~30s per suite for no signal: the fragment
# is what determines the tree, so compare against the copy the last install used.
# The cache key is a STAMP written only after a SUCCESSFUL install, never the
# manifest itself. Keying on package.json would record "installed" the moment the
# manifest is generated, so an install that then failed (a registry flake) or was
# interrupted (Ctrl-C during the ~30s first run) would be cached as a success:
# every later run skips the install and either dies on a missing tsc or — worse —
# compiles against a partial tree and reports green about a fragment it never
# actually installed. Only recovery would be deleting the cache by hand.
# The COMPILER is part of the predicate, not just the directory: macOS's periodic
# $TMPDIR reaper deletes files under /var/folders/** while leaving directories, and
# the default cache lives exactly there — so node_modules/ and the stamp can both
# survive while .bin/tsc is gone. Without this the install is skipped and the run
# dies with "the payload does not compile", blaming opsApi.ts for a cache
# eviction, on every re-run, because the stamp still matches.
needs_install=1
if [[ -f "$SANDBOX/.deps-installed" && -x "$SANDBOX/node_modules/.bin/tsc" ]] \
   && cmp -s "$SANDBOX/package.json.next" "$SANDBOX/.deps-installed"; then
  needs_install=0
fi
mv "$SANDBOX/package.json.next" "$SANDBOX/package.json" \
  || die "could not install package.json into $SANDBOX"

if (( needs_install )); then
  print -u2 -- "node-ops-sandbox: installing dependencies into $SANDBOX (first run or fragment changed)"
  # The stamp is cleared FIRST, so an install that dies partway cannot leave a
  # stale success behind.
  rm -f "$SANDBOX/.deps-installed"
  ( cd "$SANDBOX" && npm install --no-audit --no-fund --silent ) >&2 \
    || die "npm install failed"
  cp "$SANDBOX/package.json" "$SANDBOX/.deps-installed" \
    || die "could not write the dependency stamp"
fi

# ---- payload + fixture, then build -----------------------------------------
# PRUNED, then recopied: these cases must exercise the working tree's payload and
# nothing else. Overwriting alone would leave a previous run's file behind after a
# rename or deletion in the template, and tsc would keep compiling it — the suite
# then reports green against a source the template no longer ships, which is the
# stale-copy failure this whole step exists to prevent. node_modules and the
# dependency stamp deliberately survive; they are what keeps the install
# incremental.
# The second of the two checks (the first is above, before the install). Only the
# first is exercised by the acceptance case; this one is the same call.
sandbox_is_free || die 3 "$SANDBOX is in use by a running fixture — wait for that run to finish (or kill it) before re-provisioning"
rm -rf "$SANDBOX/src" "$SANDBOX/dist" || die "could not clean the sandbox payload"
mkdir -p "$SANDBOX/src/ops" || die "could not recreate $SANDBOX/src/ops"
cp "$PAYLOAD/opsApi.ts" "$SANDBOX/src/ops/opsApi.ts" || die "could not copy opsApi.ts"
cp "$SCRIPT_DIR/ops-fixture-service.ts" "$SANDBOX/src/main.ts" || die "could not copy the fixture"

[[ -x "$SANDBOX/node_modules/.bin/tsc" ]] \
  || die 2 "$SANDBOX/node_modules/.bin/tsc is missing — the sandbox toolchain is incomplete; delete $SANDBOX and re-run"
( cd "$SANDBOX" && ./node_modules/.bin/tsc --project tsconfig.json ) >&2 \
  || die "tsc failed — the payload does not compile under the shipped strict config, OR the dependency cache was partially evicted; delete $SANDBOX and re-run before blaming the payload"

print -r -- "$SANDBOX"
