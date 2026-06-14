# Disposable image for running the shell-script behavioral tests (bats) in
# isolation from the host — the "don't mess up the local dev machine" guarantee
# from #263. Contains exactly the toolchain the scripts under test need.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats jq shellcheck zsh python3 git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["bats"]
CMD ["tests"]
