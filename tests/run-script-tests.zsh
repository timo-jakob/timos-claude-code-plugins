#!/usr/bin/env zsh
# `emulate -L zsh` FIRST, then `setopt`. emulate resets every option in its
# emulation set — errexit and nounset included, even without -R — so the
# original order (setopt on line 2, emulate further down) silently discarded
# both, and this script had been running with neither. Verify with:
#   zsh -c 'setopt errexit nounset; emulate -L zsh; setopt' | grep -c errexit
# which prints 0 — errexit is gone by the time the script body runs.
# FOUR other scripts still have the identical defect — gather-claude-plugin-
# findings.zsh, gather-spring-findings.zsh, run-headless.zsh, and the shipped
# template derive-release-scope.zsh. They are pre-existing and untouched by
# #1199, so they are tracked in #1223 rather than widening that story's diff.
emulate -L zsh
setopt err_exit nounset pipefail

# run-script-tests.zsh — run the shell-script behavioral tests (bats).
#
# Default: build the disposable Docker image (tests/Dockerfile) and run the suite
# inside it, so the scripts under test — which touch the filesystem, run other
# tools, and exercise error paths — can't affect the host. This is the isolation
# #263 asked for.
#
# Flags:
#   --local   run `bats` directly on the host instead (requires bats on PATH) —
#             the same host-bats mode CI runs in, the runner there being
#             disposable already. CI does NOT invoke this script: its entry point
#             is `run-gate.zsh --tests-dir tests` (see tests/README.md).
#
# Usage:
#   tests/run-script-tests.zsh            # Docker (isolated)
#   tests/run-script-tests.zsh --local    # host bats

local repo_root="${0:A:h:h}"
local mode="docker"
[[ "${1:-}" == "--local" ]] && mode="local"

if [[ "$mode" == "local" ]]; then
  command -v bats >/dev/null 2>&1 \
    || { print -u2 -- "bats not on PATH — install it (brew install bats-core) or drop --local to use Docker."; exit 127 }
  exec bats "$repo_root/tests"
fi

command -v docker >/dev/null 2>&1 \
  || { print -u2 -- "docker not on PATH — install Docker or pass --local to use host bats."; exit 127 }

print -u2 -- "==> building test image (tests/Dockerfile) ..."
# Explicitly guarded rather than left to errexit: for as long as the option was
# being discarded (above), a failed build fell straight through to `docker run`
# against whatever STALE image the last successful build left behind — and a
# stale image is precisely the state that produces a confusing red inside the
# harness's setup_file instead of "your image failed to build".
docker build -q -t claude-plugin-script-tests "$repo_root/tests" >/dev/null \
  || { print -u2 -- "test image build failed (tests/Dockerfile)"; exit 1 }

# The pinned IaC toolchain (#1199) is NOT baked into the image. Four of the six
# pins (kubeconform, kube-linter, kyverno, yq) are read from the workflow
# template, which lives outside this build context; helm and kustomize are pinned
# in tests/iac-tools.zsh, because the template installs neither. And baking any
# of them in would re-download ~100 MB on every image rebuild — the reason that
# covers all six. Mount the host's cache root instead. It is safe to share because iac-tools.zsh keys its leaf directory by
# os-arch — the host's darwin binaries and the container's linux ones sit side by
# side — so each platform downloads once, ever, rather than once per run.
# typed for the same reason as iac-tools.zsh's copy: the expansion dereferences
# $HOME under `nounset`, so with none of the three set this would die with a raw
# "HOME: parameter not set" — after the image was already built, and naming
# nothing about the cache. Every other failure in this script is typed.
if [[ -z "${IAC_TOOLS_CACHE:-}" && -z "${XDG_CACHE_HOME:-}" && -z "${HOME:-}" ]]; then
  print -u2 -- "no cache root — set IAC_TOOLS_CACHE, XDG_CACHE_HOME or HOME"
  exit 1
fi
local cache_root="${IAC_TOOLS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/timos-claude-code-plugins/iac-tools}"
# ABSOLUTE: `docker run -v` rejects a relative mount source outright, so a
# relative IAC_TOOLS_CACHE would fail the run with Docker's own error rather
# than anything naming this variable.
cache_root="${cache_root:A}"
mkdir -p "$cache_root" \
  || { print -u2 -- "cannot create the IaC toolchain cache at $cache_root"; exit 1 }

print -u2 -- "==> running bats in the container ..."
exec docker run --rm -v "$repo_root:/work" -v "$cache_root:/iac-tools" \
  -e IAC_TOOLS_CACHE=/iac-tools -w /work claude-plugin-script-tests tests
