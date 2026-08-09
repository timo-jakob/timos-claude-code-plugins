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
