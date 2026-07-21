# Disposable image for running the shell-script behavioral tests (bats) in
# isolation from the host — the "don't mess up the local dev machine" guarantee
# from #263. Contains exactly the toolchain the scripts under test need.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats jq shellcheck zsh python3 git ca-certificates nodejs \
 && rm -rf /var/lib/apt/lists/*
# nodejs: the development-javascript contract-consumer ships a pure-JS orval
# transformer (orval-deprecation-transformer.mjs, #707); its behavioral bats test
# executes it with node, so node is a declared test dependency, not incidental.

WORKDIR /work
ENTRYPOINT ["bats"]
CMD ["tests"]
