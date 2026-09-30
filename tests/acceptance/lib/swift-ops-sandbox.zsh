#!/usr/bin/env zsh
# swift-ops-sandbox.zsh — provision a runnable Swift service from the shipped ops-api
# AND resilience templates, so the acceptance cases (#1146) exercise the real surface.
#
# Prints the sandbox directory on stdout; everything else goes to stderr.
#
# The package it builds is the BOOTSTRAPPED LAYOUT, not a convenient one: ONE
# executable target holding `Ops/` and `Resilience/` exactly as SKILL.md places them
# (sources, READMEs, `.deps` fragments and the declaration file) and the fixture as
# `main.swift`, under `// swift-tools-version:6.1` with `.swiftLanguageMode(.v6)`.
# The manifest's package and product lines are lifted from the SHIPPED ops-api
# `Package.swift.deps`, so a case going green also proves the fragment is complete —
# and the resilience fragment contributes nothing, which is its own claim.
#
# The sandbox lives OUTSIDE the repository (under $ACCEPTANCE_CACHE): a SwiftPM
# `.build` has no business in a working copy, and resolve-issue's review loop hashes
# the working tree. It is keyed per test FILE and per WORKTREE — the same two keys,
# for the same two reasons, as node-ops-sandbox.zsh: provisioning prunes `Sources/`
# before recopying, and a shared directory would let one suite's prune land under
# another's running fixture, or report green about another tree's payload.
#
# It is INCREMENTAL: `.build` survives, so only the first run resolves and compiles
# the dependency graph. The payload is pruned and recopied every time — these cases
# must test the files as they stand in the working tree, never a stale copy.
#
# The toolchain is `$SWIFT` (default `swift`), so a host whose `swift` shim is broken
# can point it at a working one: `SWIFT="$(xcrun --find swift)"`.
#
# Exit codes (typed, so a runner can tell them apart without matching on wording):
#   1  provisioning failed on OUR side — resolution, compilation, a write
#   2  the INPUTS are wrong — bad usage, a missing tool, a missing template file
#   3  the sandbox is in use — by a running fixture, or by another provision still
#      holding the lock — the deliberate refusal
emulate -L zsh
setopt pipe_fail no_unset

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h:h}"
TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates/languages/swift"
OPS="$TEMPLATES/ops-api"
RES="$TEMPLATES/resilience"
SWIFT="${SWIFT:-swift}"

die() {
  local code=1
  [[ "$1" == <-> ]] && { code="$1"; shift }
  print -u2 -- "swift-ops-sandbox: $*"
  exit "$code"
}

SUITE="default"
while (( $# )); do
  case "$1" in
    --suite)
      [[ -n "${2:-}" ]] || die 2 "--suite requires a value"
      SUITE="$2"; shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
# The last TWO path components: both suites are called swift-resilience.bats and
# differ only in their directory. Only a path has two; a bare name keys as itself.
[[ -n "$SUITE" ]] || die 2 "--suite resolved to an empty name"
[[ "$SUITE" == */* ]] && SUITE="${${SUITE:h}:t}-${SUITE:t:r}"
SUITE="${SUITE//[^A-Za-z0-9._-]/_}"
[[ -n "$SUITE" ]] || die 2 "--suite resolved to an empty name"

for tool in "$SWIFT" pgrep; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "'$tool' is required but not on PATH (set \$SWIFT to a working toolchain)"
done

CACHE="${ACCEPTANCE_CACHE:-${TMPDIR:-/tmp}/claude-acceptance-cache}"
TREE_KEY="$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)" || die "could not derive a cache key"
SANDBOX="$CACHE/swift-ops-resilience-$SUITE-$TREE_KEY"
LOCK="$CACHE/.swift-ops-resilience-$SUITE-$TREE_KEY.lock"
BINARY="$SANDBOX/.build/debug/OpsFixture"
mkdir -p "$CACHE" || die "could not create $CACHE"

# A KERNEL lock over the whole provision, released by the kernel however this
# process dies — see node-ops-sandbox.zsh for why a mkdir lock is the wrong tool.
zmodload zsh/system 2>/dev/null || die 2 "zsh/system is unavailable, so the provisioning lock cannot be taken"
: > "$LOCK" 2>/dev/null || die "could not create the lock file $LOCK"
typeset -i flock_rc=0
zsystem flock -t 900 -f LOCK_FD "$LOCK" || flock_rc=$?
# 2 is the timeout: another provision of this suite holds the sandbox — contention,
# the in-use class, not a failure on our side.
(( flock_rc == 2 )) && die 3 "timed out after 900s waiting for $LOCK — another provision of this suite is still running"
(( flock_rc == 0 )) || die "could not lock $LOCK (zsystem flock rc $flock_rc)"

# Refuse to touch a sandbox a fixture is executing out of. This NARROWS the race with
# a concurrent run of the same suite in the same tree; it does not close the gap
# between that run's fixtures, which start outside the lock. pgrep's codes are READ,
# not collapsed: 2/3/127 would otherwise read as "idle" and fail the guard open.
sandbox_is_free() {
  local pat="${BINARY//[^A-Za-z0-9\/._-]/.}" rc=0
  pgrep -f "$pat" > /dev/null 2>&1 || rc=$?
  (( rc == 0 )) && return 1
  (( rc == 1 )) && return 0
  die 2 "pgrep failed (rc $rc) — cannot prove $SANDBOX is idle, refusing to touch it"
}
sandbox_is_free || die 3 "$SANDBOX is in use by a running fixture — wait for that run to finish (or kill it) before re-provisioning"

for f in "$OPS/OpsApi.swift" "$OPS/Package.swift.deps" "$OPS/README.md" \
         "$RES/DependencyCatalog.swift" "$RES/DependencyHealth.swift" "$RES/PricingAPIClient.swift" \
         "$RES/Package.swift.deps" "$RES/README.md" "$RES/resilience-dependencies.properties" \
         "$SCRIPT_DIR/swift-fixture-main.swift"; do
  [[ -f "$f" ]] || die 2 "template file missing: $f"
done

# ---- Package.swift, from the SHIPPED fragments -------------------------------
packages="$(grep -E '^[[:space:]]*\.package\(url:' "$OPS/Package.swift.deps")"
products="$(grep -E '^[[:space:]]*\.product\(name:' "$OPS/Package.swift.deps")"
[[ -n "$packages" && -n "$products" ]] || die 2 "the ops-api Package.swift.deps has no .package/.product lines"
# The resilience fragment must add NOTHING: it declares no third-party dependency.
# grep's status is READ, not folded into an `if`: 2 (unreadable) must not pass as 1.
typeset -i paste_rc=0
grep -qE '^[[:space:]]*\.(package|product)\(' "$RES/Package.swift.deps" || paste_rc=$?
(( paste_rc == 0 )) && die 2 "the resilience Package.swift.deps declares a paste line — this harness does not know where it goes"
(( paste_rc == 1 )) || die 2 "could not read $RES/Package.swift.deps (grep rc $paste_rc)"
mkdir -p "$SANDBOX" || die "could not create $SANDBOX"
{
  print -r -- '// swift-tools-version:6.1'
  print -r -- 'import PackageDescription'
  print -r -- ''
  print -r -- 'let package = Package('
  print -r -- '    name: "OpsFixture",'
  print -r -- '    platforms: [.macOS(.v13), .iOS(.v16)],'
  print -r -- '    dependencies: ['
  print -r -- "$packages"
  print -r -- '    ],'
  print -r -- '    targets: ['
  print -r -- '        .executableTarget('
  print -r -- '            name: "OpsFixture",'
  print -r -- '            dependencies: ['
  print -r -- "$products"
  print -r -- '            ],'
  print -r -- '            swiftSettings: [.swiftLanguageMode(.v6)]'
  print -r -- '        )'
  print -r -- '    ]'
  print -r -- ')'
} > "$SANDBOX/Package.swift.next" || die "could not write the manifest"
mv "$SANDBOX/Package.swift.next" "$SANDBOX/Package.swift" || die "could not install the manifest"

# ---- payload + fixture, pruned then recopied ---------------------------------
sandbox_is_free || die 3 "$SANDBOX is in use by a running fixture — wait for that run to finish (or kill it) before re-provisioning"
rm -rf "$SANDBOX/Sources" || die "could not clean the sandbox payload"
mkdir -p "$SANDBOX/Sources/OpsFixture/Ops" "$SANDBOX/Sources/OpsFixture/Resilience" \
  || die "could not recreate the source tree"
# Every file SKILL.md places, non-source ones included — a README or a .deps fragment
# inside a target directory is part of how SwiftPM sees the bootstrapped layout.
cp "$OPS/OpsApi.swift" "$OPS/Package.swift.deps" "$OPS/README.md" \
  "$SANDBOX/Sources/OpsFixture/Ops/" || die "could not copy the ops-api payload"
cp "$RES/DependencyCatalog.swift" "$RES/DependencyHealth.swift" "$RES/PricingAPIClient.swift" \
  "$RES/Package.swift.deps" "$RES/README.md" "$RES/resilience-dependencies.properties" \
  "$SANDBOX/Sources/OpsFixture/Resilience/" || die "could not copy the resilience payload"
cp "$SCRIPT_DIR/swift-fixture-main.swift" "$SANDBOX/Sources/OpsFixture/main.swift" \
  || die "could not copy the fixture"

print -u2 -- "swift-ops-sandbox: building $SANDBOX (the first run resolves and compiles the dependency graph)"
"$SWIFT" build --package-path "$SANDBOX" >&2 \
  || die "swift build failed — the payload does not compile in the bootstrapped layout under the Swift 6 language mode"
[[ -x "$BINARY" ]] || die "the build reported success but $BINARY is missing"

print -r -- "$SANDBOX"
