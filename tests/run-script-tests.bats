#!/usr/bin/env bats
#
# Behavioral tests for tests/run-script-tests.zsh — specifically the IaC
# toolchain cache-mount wiring #1199 added to its Docker path.
#
# WHY. Every failure mode in that wiring is SILENT. Drop the `-e
# IAC_TOOLS_CACHE=/iac-tools`, misspell the mount target, or lose the `:A`
# absolutisation, and the container simply re-downloads ~100 MB of toolchain on
# every run while the suite stays green — the "never reds, just quietly wrong"
# class this whole epic is about. Docker is the natural seam: the script `exec`s
# it, so a recording stub on PATH captures the argv without Docker being
# installed at all.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # NEUTRALISE the ambient cache variables. Stubbing $HOME is not enough: the
  # script prefers IAC_TOOLS_CACHE, then XDG_CACHE_HOME, and only then $HOME —
  # and `tests/run-script-tests.zsh` runs the container with
  # `-e IAC_TOOLS_CACHE=/iac-tools` over an ENTRYPOINT of `bats`. So in the
  # Docker mode tests/README.md documents as the DEFAULT, every test in this
  # file would see IAC_TOOLS_CACHE=/iac-tools and three of them would compare
  # against a path the script cannot produce — green natively, red in Docker.
  # The tests that want these variables pass them explicitly to run_local_script.
  unset IAC_TOOLS_CACHE XDG_CACHE_HOME
  # ...and the git environment, because these tests are ABOUT git resolution.
  # `git rev-parse` honours an inherited GIT_DIR/GIT_WORK_TREE (git exports both
  # inside hooks and `git rebase --exec`, two plausible ways this suite gets run),
  # which would make the script answer the ambient repository instead of the
  # fixture's. GIT_CONFIG_GLOBAL defeats the HOME stub outright.
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  # `pwd -P`: the script derives its own repo root with zsh's `${0:A:h:h}`,
  # which resolves symlinks. A logical pwd here would compare the two spellings
  # and fail on any checkout reached through a symlinked path.
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SCRIPT="$REPO_ROOT/tests/run-script-tests.zsh"
  STUB="$BATS_TEST_TMPDIR/stub"
  CALLS="$BATS_TEST_TMPDIR/calls.txt"
  mkdir -p "$STUB"
  : > "$CALLS"
  export CALLS
  # a HOME of its own, so the default cache root never resolves to the
  # developer's real ~/.cache and the test cannot be satisfied by a cache that
  # was already there
  HOME_STUB="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME_STUB"
}

# `exec docker …` replaces the shell, so the stub's own exit status is the
# script's. It records argv and succeeds.
stub_docker() {
  cat > "$STUB/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$CALLS"
exit 0
EOF
  chmod +x "$STUB/docker"
}

run_local_script() {
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" "$@" zsh "$SCRIPT"
}

# The script absolutises the cache root with zsh's `:A`, which resolves
# symlinks — and on macOS $BATS_TEST_TMPDIR lives under /var, a symlink to
# /private/var. Expected values must be resolved the same way, or these
# assertions would pass on Linux and fail on macOS.
resolved() {
  (cd "$1" && pwd -P)
}

# The `docker run` line specifically — never the whole recording. `$CALLS` holds
# the build line too, so a `contains` over the concatenation is satisfied by a
# flag sitting on `docker build`, which is not where any of these flags belong.
docker_run_line() {
  sed -n 2p "$CALLS"
}

# HERMETIC git for the fixtures. The script invocations already run with
# HOME="$HOME_STUB"; the fixture builders must too, or they inherit the
# developer's global/system gitconfig — `commit.gpgsign=true`, a global
# `core.hooksPath`, an `init.templateDir` — and red these tests for reasons that
# have nothing to do with the runner.
_git() {
  env HOME="$HOME_STUB" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"
}

# A throwaway git repo carrying a copy of the script at the same repo-relative
# path, so `${0:A:h:h}` makes it the repo root (#1360). Built rather than
# asserted against the ambient checkout because the two shapes this must cover —
# plain clone and linked worktree — cannot both be the shape the suite happens to
# be running from. Committed, so `git worktree add` can check the script out too.
mk_repo() {
  local root="$1"
  mkdir -p "$root/tests"
  cp "$SCRIPT" "$root/tests/run-script-tests.zsh"
  _git -c init.defaultBranch=main init -q "$root"
  _git -C "$root" add tests/run-script-tests.zsh
  _git -C "$root" commit -qm seed
}

# The worktree shape, built once and reused: two tests need it, and duplicating
# the three-step preamble is how the two drift apart.
mk_worktree() {
  local root="$1" wt="$2"
  mk_repo "$root"
  _git -C "$root" worktree add -q -b wt-branch "$wt"
}

# Counts the git mounts on the recorded `docker run` line — the dedup guard's
# only observable effect, and the assertion that a lost guard would trip.
git_mount_count() {
  grep -o -- "-v [^ ]*/\.git[^ ]*" <<<"$1" | wc -l | tr -d ' '
}

# The script resolves the cache root the same way regardless, so these tests only
# ever read the git mounts off the recorded `docker run` line.
run_script_in() {
  local root="$1"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" zsh "$root/tests/run-script-tests.zsh"
}

@test "the docker run bind-mounts the git dir read-only in a PLAIN CLONE (#1360)" {
  stub_docker
  local root="$BATS_TEST_TMPDIR/clone"
  mk_repo "$root"
  run_script_in "$root"
  [ "$status" -eq 0 ]
  run docker_run_line
  # In a plain clone --git-dir and --git-common-dir ARE the same path, and
  # `docker run` rejects a duplicate mount destination outright — so the single
  # mount below IS both mounts. Asserted at its host-absolute path, which is what
  # lets git's own `gitdir:`/`commondir` pointers resolve verbatim.
  local gd
  gd="$(resolved "$root")/.git"
  contains "$output" "-v ${gd}:${gd}:ro"
  # EXACTLY ONE, which is what pins the de-duplication guard. Dropping it emits
  # `-v X:X:ro` twice — the `contains` above still passes, the recording stub
  # still exits 0, and every real plain-clone run dies with `Duplicate mount
  # point`. A positive-only assertion cannot see that.
  [ "$(git_mount_count "$output")" -eq 1 ]
  # ...and NOT the `:r` history-modifier spelling. zsh applies `:r` to an
  # unbraced `$name:`, so `"$git_dir:ro"` silently mounted `…/o` — a mount that
  # exists, carries no `:ro`, and makes every git call in the container fail.
  lacks "$output" "$(resolved "$root")/o"
}

@test "the docker run bind-mounts BOTH git dirs read-only in a WORKTREE (#1360)" {
  stub_docker
  local root="$BATS_TEST_TMPDIR/main" wt="$BATS_TEST_TMPDIR/wt"
  mk_worktree "$root" "$wt"
  run_script_in "$wt"
  [ "$status" -eq 0 ]
  run docker_run_line
  # The repo root alone is what USED to be mounted, and in a worktree its `.git`
  # is a FILE naming a host path the container cannot see — which is why the four
  # tests/build-golden-798-target.bats tests fataled with "not a git repository".
  contains "$output" "-v $(resolved "$wt"):/work"
  # The per-worktree gitdir carries HEAD, index and a `commondir` pointer...
  local gd gc
  gd="$(resolved "$root/.git/worktrees/wt")"
  gc="$(resolved "$root")/.git"
  contains "$output" "-v ${gd}:${gd}:ro"
  # ...and objects, refs and packed-refs live in the MAIN .git, which is where
  # `git show <sha>:<path>` reads from. Mounting only the first is not enough.
  contains "$output" "-v ${gc}:${gc}:ro"
  [ "$gd" != "$gc" ]
}

@test "every git mount carries :ro in the two-mount shape (#1360)" {
  stub_docker
  local root="$BATS_TEST_TMPDIR/main" wt="$BATS_TEST_TMPDIR/wt"
  mk_worktree "$root" "$wt"
  run_script_in "$wt"
  [ "$status" -eq 0 ]
  local line ro_mounts
  line="$(docker_run_line)"
  # Every mount whose SOURCE is a git dir must end `:ro`. Counted rather than
  # spot-checked: a third git mount added later without `:ro` must red here.
  ro_mounts="$(grep -o -- "-v [^ ]*/\.git[^ ]*:ro" <<<"$line" | wc -l | tr -d ' ')"
  [ "$(git_mount_count "$line")" -eq 2 ]
  [ "$ro_mounts" -eq 2 ]
}

@test "the image declares the python venv toolchain, and so does the CI Linux leg (#1360)" {
  # The roster invariant the workflow comment asserts in prose ("Declared here so
  # the two rosters agree"). Dropping either side re-reds detect-stack.bats's two
  # `verify-python-state:` cases with pip's own "ensurepip is not available" — in
  # the Docker lane only, where no CI check would see it.
  local dockerfile="$REPO_ROOT/tests/Dockerfile" wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  [ -f "$dockerfile" ]
  [ -f "$wf" ]
  # The apt install block of each, not the whole file: a package named only in a
  # comment is not declared. COMMENT-STRIPPED and bounded on both sides — the
  # workflow's `apt-get install` is followed by a ~40-line comment block, so an
  # unbounded `,/^$/` slice would be mostly prose and the invariant above would
  # be satisfiable by a comment, which is exactly what it denies.
  local docker_apt ci_apt
  docker_apt="$(sed -n '/apt-get install/,/rm -rf/p' "$dockerfile" | grep -v '^[[:space:]]*#')"
  ci_apt="$(sed -n '/sudo apt-get install/,/yamllint$/p' "$wf" | grep -v '^[[:space:]]*#')"
  # each slice is short — a runaway slice would make the needles below vacuous
  [ "$(wc -l <<<"$docker_apt" | tr -d ' ')" -lt 10 ]
  [ "$(wc -l <<<"$ci_apt" | tr -d ' ')" -lt 10 ]
  # ...and a negative control that reds if the CI range ever runs past its step
  lacks "$ci_apt" 'brew install'
  contains "$docker_apt" 'python3-venv'
  contains "$docker_apt" 'python3-pip'
  contains "$ci_apt" 'python3-venv'
  contains "$ci_apt" 'python3-pip'
}

@test "the image marks the mounted git store safe.directory, and installs git (#1360)" {
  # The other half of the bind-mount fix. The container is uid 0 while the mounted
  # files carry host ownership on any backend that does not remap it, and git then
  # refuses with `detected dubious ownership` — the untyped, container-only fatal
  # this story exists to remove, which the host-side pre-flight cannot see. Both
  # CI legs are native, so no check would catch its removal.
  # COMMENT-BLIND and VALUE-PINNING. This Dockerfile's habit is a multi-line
  # rationale block above each instruction, so deleting the RUN and leaving its
  # comment behind is the likely regression — and a needle that stops before the
  # argument passes just as happily on `--add safe.directory /some/other/path`,
  # which protects nothing.
  local dockerfile="$REPO_ROOT/tests/Dockerfile"
  run bash -c "grep -v '^[[:space:]]*#' '$dockerfile' | grep -F \"git config --system --add safe.directory '*'\""
  [ "$status" -eq 0 ]
  # ...and the mount is useless without git itself
  run bash -c "sed -n '/apt-get install/,/rm -rf/p' '$dockerfile' | grep -v '^[[:space:]]*#' | grep -F ' git '"
  [ "$status" -eq 0 ]
}

@test "no flag and no environment variable can make a git mount writable (#1360)" {
  # Its own @test, so a failure localises: the counting above is behavioural, this
  # is the structural claim that no toggle EXISTS. The mount array is built by
  # exactly these two lines and each spells `:ro` literally, so a relaxation
  # switch would have to appear here to exist at all.
  # Unanchored: the `+=` sits after a `||` continuation, so a line-start anchor
  # would see one assignment and pass while the second mount went unchecked.
  local adds
  adds="$(grep -cE 'git_mounts(=|\+=)\(' "$SCRIPT")"
  [ "$adds" -eq 2 ]
  run grep -E 'git_mounts(=|\+=)\(' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c ':ro"' <<<"$output")" -eq 2 ]

  # ...and the BEHAVIOURAL companion, stated as an EQUALITY rather than against
  # invented variable names: every git mount on the argv carries `:ro`, whatever
  # else is in the environment. A future toggle of any name that dropped `:ro`
  # from one mount breaks the equality; counting to a fixed 2 would not say that.
  stub_docker
  local root="$BATS_TEST_TMPDIR/main" wt="$BATS_TEST_TMPDIR/wt" line ro
  mk_worktree "$root" "$wt"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" \
    GIT_MOUNT_RW=1 GIT_MOUNTS_RO=0 DOCKER_MOUNT_MODE=rw \
    zsh "$wt/tests/run-script-tests.zsh"
  [ "$status" -eq 0 ]
  line="$(docker_run_line)"
  ro="$(grep -o -- "-v [^ ]*/\.git[^ ]*:ro" <<<"$line" | wc -l | tr -d ' ')"
  [ "$(git_mount_count "$line")" -eq "$ro" ]
  [ "$ro" -eq 2 ]
}

@test "an unresolvable git dir is a typed error before docker is touched (#1360)" {
  # Never a bare `fatal: not a git repository` from inside the container — and
  # never after paying for an image build either.
  stub_docker
  local root="$BATS_TEST_TMPDIR/notgit"
  mkdir -p "$root/tests"
  cp "$SCRIPT" "$root/tests/run-script-tests.zsh"
  # GIT_CEILING_DIRECTORIES stops git walking UP into a real checkout — without
  # it this passes or fails depending on where BATS_TEST_TMPDIR happens to live.
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" \
    GIT_CEILING_DIRECTORIES="$(resolved "$BATS_TEST_TMPDIR")" zsh "$root/tests/run-script-tests.zsh"
  # the script's own `exit 1`, not a bare non-zero: `-ne 0` is equally satisfied
  # by an errexit abort before the guard, or by a later arg-parsing regression
  [ "$status" -eq 1 ]
  contains "$output" 'git could not resolve the git dir'
  # neither build nor run: the resolution happens before both
  run cat "$CALLS"
  [ "$output" = "" ]
}

@test "a git dir discovered OUTSIDE the repo root is a typed error, not a wrong mount (#1360)" {
  # `git rev-parse` discovers UPWARDS. Without the toplevel cross-check, a tests/
  # tree sitting inside some other checkout resolves that repository's store and
  # bind-mounts it into the container while /work is a different tree — silently
  # wrong, where the whole point of this pre-flight is a named failure.
  stub_docker
  local outer="$BATS_TEST_TMPDIR/outer" root="$BATS_TEST_TMPDIR/outer/vendored"
  mk_repo "$outer"
  mkdir -p "$root/tests"
  cp "$SCRIPT" "$root/tests/run-script-tests.zsh"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" zsh "$root/tests/run-script-tests.zsh"
  [ "$status" -eq 1 ]
  contains "$output" 'is not the root of a git checkout'
  run cat "$CALLS"
  [ "$output" = "" ]
}

@test "no inherited git environment variable can redirect the mount (#1360)" {
  # The one shape the toplevel cross-check alone does NOT catch: with
  # GIT_WORK_TREE pointing at this tree and GIT_DIR at another repository, the
  # toplevel answers correctly while the two git dirs name the OTHER store —
  # which would then be bind-mounted into the container. git exports both inside
  # hooks and `git rebase --exec`, so this is inherited, not typed by hand. The
  # script's `env -u …` scrub is the fix, and setup() deliberately unsets these,
  # so this test is the only place that scrub is exercised at all.
  stub_docker
  local mine="$BATS_TEST_TMPDIR/mine" other="$BATS_TEST_TMPDIR/other" line
  mk_repo "$mine"
  mk_repo "$other"
  : > "$CALLS"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" \
    GIT_DIR="$other/.git" GIT_WORK_TREE="$mine" \
    zsh "$mine/tests/run-script-tests.zsh"
  [ "$status" -eq 0 ]
  line="$(docker_run_line)"
  contains "$line" "-v $(resolved "$mine")/.git:"
  lacks "$line" "$(resolved "$other")/.git"

  # GIT_COMMON_DIR is honoured independently by `rev-parse --git-common-dir`, so
  # dropping just that `-u` would mount the other repo's object store while the
  # toplevel cross-check still passed — silently reintroducing the worktree fatal
  # this story removes.
  : > "$CALLS"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" GIT_COMMON_DIR="$other/.git" \
    zsh "$mine/tests/run-script-tests.zsh"
  [ "$status" -eq 0 ]
  line="$(docker_run_line)"
  contains "$line" "-v $(resolved "$mine")/.git:"
  lacks "$line" "$(resolved "$other")/.git"

  # GIT_WORK_TREE ALONE, so this arm can actually fail: unscrubbed it makes
  # `--show-toplevel` answer `$other`, which trips the toplevel cross-check and
  # exits 1. With GIT_DIR also set (the arm above) the cross-check passes either
  # way, so that arm pins GIT_DIR only.
  : > "$CALLS"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" GIT_WORK_TREE="$other" \
    zsh "$mine/tests/run-script-tests.zsh"
  [ "$status" -eq 0 ]
  contains "$(docker_run_line)" "-v $(resolved "$mine")/.git:"

  # GIT_INDEX_FILE has no effect on this argv at all, so it can only be pinned
  # structurally — otherwise it could be dropped from the scrub set silently.
  run grep -F -- 'env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a git that answers the wrong number of paths is a typed error (#1360)" {
  # The `expected 3` branch: the script asks for three paths, so a `git` shim or
  # wrapper that answers fewer must be named rather than silently indexed into. A
  # recording stub is the seam — $STUB is first on PATH, so the script's own
  # `git` call resolves to it.
  stub_docker
  printf '#!/bin/sh\nprintf "%%s\\n" /tmp/only-one\n' > "$STUB/git"
  chmod +x "$STUB/git"
  run_script_in "$REPO_ROOT"
  [ "$status" -eq 1 ]
  contains "$output" 'expected 3'
  run cat "$CALLS"
  [ "$output" = "" ]
}

@test "a git dir that is not a directory is a typed error (#1360)" {
  # The shape this whole story is about — a linked worktree's `.git` is a FILE —
  # so a resolution that lands on one must be named, never handed to `docker -v`.
  stub_docker
  local afile="$BATS_TEST_TMPDIR/a-file"
  printf 'gitdir: /nowhere\n' > "$afile"
  # three lines, so the count and toplevel checks pass and the -d check is the
  # one that fires
  printf '#!/bin/sh\nprintf "%%s\\n%%s\\n%%s\\n" %s %s %s\n' "$afile" "$afile" "$REPO_ROOT" \
    > "$STUB/git"
  chmod +x "$STUB/git"
  run_script_in "$REPO_ROOT"
  [ "$status" -eq 1 ]
  contains "$output" 'is not a directory'
  run cat "$CALLS"
  [ "$output" = "" ]
}

@test "the docker run mounts the host cache root and names it via IAC_TOOLS_CACHE (#1199)" {
  stub_docker
  run_local_script
  [ "$status" -eq 0 ]
  # PER LINE, not over the whole recording: `contains "$output" …` against the
  # concatenation is satisfied by a flag appearing on EITHER invocation, so the
  # mount could sit on `docker build` and this would still pass. Splitting also
  # makes the build-before-run ordering an actual assertion rather than a claim
  # two independent `contains` calls cannot express.
  local build_line run_line
  build_line="$(sed -n 1p "$CALLS")"
  run_line="$(sed -n 2p "$CALLS")"
  starts_with "$build_line" 'docker build'
  starts_with "$run_line" 'docker run'
  # the repo itself, as before
  contains "$run_line" "-v $REPO_ROOT:/work"
  contains "$run_line" '-w /work'
  # ...and the toolchain cache, both halves. The mount alone is not enough: the
  # container resolves its leaf from IAC_TOOLS_CACHE, so without the -e it would
  # write into $HOME/.cache INSIDE the container and re-download every run while
  # the mount sat there unused.
  contains "$run_line" "-v $(resolved "$HOME_STUB/.cache/timos-claude-code-plugins/iac-tools"):/iac-tools"
  contains "$run_line" '-e IAC_TOOLS_CACHE=/iac-tools'
}

@test "the CI workflow caches and installs the same toolchain the script resolves (#1199)" {
  # The CI half of the same wiring the tests above cover for Docker, and
  # its failure modes are just as silent: a cache `path` that no longer matches
  # the script's default cache root, or a key that stops hashing a file a pin
  # lives in, means a permanent cache MISS — ~100 MB re-fetched from the two
  # release hosts on both matrix legs of every PR, with the suite still green.
  local wf="$REPO_ROOT/.github/workflows/script-tests.yml" suffix
  [ -f "$wf" ]

  # The cache root, cross-checked between the two files that must agree rather
  # than asserted against a third restatement of it here. If either side is
  # renamed, exactly one of the two assertions below fails.
  # The WHOLE relative root, `.cache` included — not a two-segment tail. That
  # segment is exactly the one that can drift: renaming the script's default to
  # `$HOME/.cache-x/timos-claude-code-plugins/iac-tools` leaves any suffix-only
  # needle satisfied while `actions/cache`'s `path:` silently stops matching,
  # which is the permanent-cache-miss regression this test exists to prevent.
  suffix='.cache}/timos-claude-code-plugins/iac-tools'
  # COMMENT-BLIND: the script's header documents the same default in prose, so a
  # plain grep would be satisfied by the comment alone — the code could be
  # renamed, the comment left stale, and this test would stay green.
  run bash -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/tests/iac-tools.zsh' | grep -F '$suffix'"
  [ "$status" -eq 0 ]
  contains "$output" 'XDG_CACHE_HOME'

  # ...and the workflow's path asserted EXACTLY, so neither side can be renamed
  # without exactly one of these two failing
  run yq -r '.jobs.bats.steps[] | select(.uses == "actions/cache@v4") | .with.path' "$wf"
  [ "$status" -eq 0 ]
  [ "$output" = "~/.cache/timos-claude-code-plugins/iac-tools" ]

  # the key must hash BOTH files a pin can live in — the script (helm/kustomize)
  # and the workflow template (the other four)
  run yq -r '.jobs.bats.steps[] | select(.uses == "actions/cache@v4") | .with.key' "$wf"
  [ "$status" -eq 0 ]
  contains "$output" 'tests/iac-tools.zsh'
  contains "$output" 'development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl'
  # ...and both of those must actually exist, or hashFiles() silently contributes
  # nothing and the key degenerates to a constant
  [ -f "$REPO_ROOT/tests/iac-tools.zsh" ]
  [ -f "$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl" ]

  # ...and the install step still runs the resolver. Selected BY NAME, not by
  # joining every run: block — a join is satisfied by the path appearing
  # anywhere, a shell comment in an unrelated step included.
  run yq -r '.jobs.bats.steps[] | select(.name == "Install the pinned IaC toolchain") | .run' "$wf"
  [ "$status" -eq 0 ]
  # EXACT, not `contains`. A substring match is equally satisfied by
  # `zsh tests/iac-tools.zsh --bin-dir /tmp/whatever`, which installs somewhere
  # actions/cache neither restores nor saves — the permanent-miss regression
  # this whole test exists to prevent, with every other assertion still green.
  [ "$output" = "zsh tests/iac-tools.zsh" ]

  # ...and no env override can move the resolution either. The script resolves
  # IAC_TOOLS_CACHE > XDG_CACHE_HOME > $HOME/.cache, so an `env:` at any level
  # setting either of the first two would relocate the install away from the
  # cached path while the exact-path assertion above still passed.
  run yq -r '.env // "none"' "$wf"
  [ "$output" = "none" ]
  run yq -r '.jobs.bats.env // "none"' "$wf"
  [ "$output" = "none" ]
  run yq -r '.jobs.bats.steps[] | select(.name == "Install the pinned IaC toolchain") | .env // "none"' "$wf"
  [ "$output" = "none" ]

  # and it PRE-warms: the whole point of the named step is that a network
  # failure reads as "the toolchain could not be downloaded" rather than as a
  # mysterious red inside the suite, which only holds if it precedes the run.
  # Both selected BY NAME. Matching the gate step on its `run:` content instead
  # returns TWO indices — the dependency step's comment mentions run-gate.zsh —
  # which is the same match-a-comment flaw the cross-check above avoids.
  local install_ix gate_ix cache_ix
  install_ix="$(yq -r '.jobs.bats.steps | to_entries[] | select(.value.name == "Install the pinned IaC toolchain") | .key' "$wf")"
  gate_ix="$(yq -r '.jobs.bats.steps | to_entries[] | select(.value.name == "Run shell-script behavioral tests") | .key' "$wf")"
  cache_ix="$(yq -r '.jobs.bats.steps | to_entries[] | select(.value.uses == "actions/cache@v4") | .key' "$wf")"
  [ -n "$install_ix" ]
  [ -n "$gate_ix" ]
  [ -n "$cache_ix" ]
  # restore BEFORE the install, or the cache restores nothing it could have
  # saved and the install re-fetches every run — silently
  [ "$cache_ix" -lt "$install_ix" ]
  [ "$install_ix" -lt "$gate_ix" ]
  # and that step is the one that actually drives the gate
  run yq -r '.jobs.bats.steps[] | select(.name == "Run shell-script behavioral tests") | .run' "$wf"
  contains "$output" 'run-gate.zsh'
}

@test "the cache root directory is created on the host before the mount (#1199)" {
  # docker would otherwise materialise the mount source itself, as root and
  # empty, which is how a permissions problem gets discovered days later
  stub_docker
  [ ! -d "$HOME_STUB/.cache/timos-claude-code-plugins/iac-tools" ]
  run_local_script
  [ "$status" -eq 0 ]
  [ -d "$HOME_STUB/.cache/timos-claude-code-plugins/iac-tools" ]
}

@test "IAC_TOOLS_CACHE overrides XDG_CACHE_HOME, which overrides HOME (#1199)" {
  stub_docker
  run_local_script XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg"
  [ "$status" -eq 0 ]
  run docker_run_line
  contains "$output" "-v $(resolved "$BATS_TEST_TMPDIR/xdg/timos-claude-code-plugins/iac-tools"):/iac-tools"

  : > "$CALLS"
  run_local_script XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg" IAC_TOOLS_CACHE="$BATS_TEST_TMPDIR/explicit"
  [ "$status" -eq 0 ]
  run docker_run_line
  contains "$output" "-v $(resolved "$BATS_TEST_TMPDIR/explicit"):/iac-tools"
  lacks "$output" "/xdg/timos-claude-code-plugins"
}

@test "a relative IAC_TOOLS_CACHE is made absolute before it reaches docker (#1199)" {
  # `docker run -v` rejects a relative mount source outright, so without the :A
  # the run dies with Docker's own error rather than anything naming the variable
  stub_docker
  mkdir -p "$BATS_TEST_TMPDIR/relcache"
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" IAC_TOOLS_CACHE=relcache \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$SCRIPT'"
  [ "$status" -eq 0 ]
  run docker_run_line
  lacks "$output" "-v relcache:/iac-tools"
  # `-v ` prefixed, like every other mount assertion in this file: a bare
  # `:/iac-tools` needle is satisfied by ANY mount source, so if `resolved` ever
  # returned empty the assertion would degenerate into an always-true substring
  contains "$output" "-v $(resolved "$BATS_TEST_TMPDIR/relcache"):/iac-tools"
}

@test "a failed image build stops before the run rather than using a stale image (#1199)" {
  # the concrete reason the errexit ordering mattered: a stale image is exactly
  # the state that produces a confusing red inside the harness's setup_file
  cat > "$STUB/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$CALLS"
case "$1" in build) exit 1 ;; esac
exit 0
EOF
  chmod +x "$STUB/docker"
  run_local_script
  [ "$status" -ne 0 ]
  contains "$output" 'test image build failed'
  run cat "$CALLS"
  contains "$output" 'docker build'
  lacks "$output" 'docker run'
}

@test "an absent docker is a typed 127, not a confusing failure (#1199)" {
  # $STUB holds no docker, and PATH is ONLY $STUB — so `command -v docker` fails
  # while zsh itself still resolves
  local bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  ln -s "$(command -v zsh)" "$bare/zsh"
  # `run -127`, not a bare `run`: bats then asserts the exact status itself and
  # does not emit its BW01 "command not found" warning into the TAP stream for
  # an exit code this test is deliberately provoking
  run -127 env PATH="$bare" HOME="$HOME_STUB" zsh "$SCRIPT"
  contains "$output" 'docker not on PATH'
}

@test "--local needs bats and never touches docker (#1199)" {
  local bare="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$bare"
  ln -s "$(command -v zsh)" "$bare/zsh"
  # docker IS on PATH and IS recording — that is what makes the emptiness
  # assertion below mean something. With docker absent (an earlier version of
  # this test) `$CALLS` is empty no matter what the script does, so the claim
  # "it did not build an image" was true by construction rather than by
  # observation.
  stub_docker
  run -127 env PATH="$STUB:$bare" HOME="$HOME_STUB" zsh "$SCRIPT" --local
  contains "$output" 'bats not on PATH'
  run cat "$CALLS"
  [ "$output" = "" ]
}

@test "--local execs bats over the repo's tests directory (#1199)" {
  # the mode CI actually runs in, and previously covered only by its 127 branch:
  # a regression dropping the argument would run bats over the cwd instead
  cat > "$STUB/bats" <<'EOF'
#!/bin/sh
printf 'bats %s\n' "$*" >> "$CALLS"
exit 0
EOF
  chmod +x "$STUB/bats"
  stub_docker
  run env PATH="$STUB:$PATH" HOME="$HOME_STUB" zsh "$SCRIPT" --local
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  [ "$output" = "bats $REPO_ROOT/tests" ]
}
