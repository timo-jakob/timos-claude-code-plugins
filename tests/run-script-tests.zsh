#!/usr/bin/env zsh
setopt err_exit nounset pipefail

# run-script-tests.zsh — run the shell-script behavioral tests (bats).
#
# Default: build the disposable Docker image (tests/Dockerfile) and run the suite
# inside it, so the scripts under test — which touch the filesystem, run other
# tools, and exercise error paths — can't affect the host. This is the isolation
# #263 asked for.
#
# Flags:
#   --local   run `bats` directly on the host instead (requires bats on PATH).
#             CI uses this — the runner there is already disposable.
#
# Usage:
#   tests/run-script-tests.zsh            # Docker (isolated)
#   tests/run-script-tests.zsh --local    # host bats (CI / when you have bats)

emulate -L zsh
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
docker build -q -t claude-plugin-script-tests "$repo_root/tests" >/dev/null
print -u2 -- "==> running bats in the container ..."
exec docker run --rm -v "$repo_root:/work" -w /work claude-plugin-script-tests tests
