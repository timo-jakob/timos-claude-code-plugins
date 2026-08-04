# Disposable image for running the shell-script behavioral tests (bats) in
# isolation from the host — the "don't mess up the local dev machine" guarantee
# from #263. Contains exactly the toolchain the scripts under test need.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats jq shellcheck zsh python3 git ca-certificates nodejs yamllint curl \
 && rm -rf /var/lib/apt/lists/*
# mikefarah yq, NOT Debian's `yq` apt package (which is kislyuk's python-yq, a
# different query language): the suite and the shipped kubernetes-ci template
# both use `-o=json` and rely on YAML 1.2 semantics, neither of which python-yq
# provides. This image is the "don't mess up the local dev machine" run, so it
# is the one leg with no preinstalled mikefarah yq to fall back on.
ARG YQ_VERSION=4.44.3
RUN curl -sSfLo /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
 && chmod +x /usr/local/bin/yq
# nodejs: the development-javascript contract-consumer ships a pure-JS orval
# transformer (orval-deprecation-transformer.mjs, #707); its behavioral bats test
# executes it with node, so node is a declared test dependency, not incidental.
# yamllint: tests/bootstrap-iac-pipeline.bats (#1154) lints the kubernetes-ci
# workflow template with the repo's strict yamllint config; it is called
# unguarded, so the documented local run needs it present. yq is installed
# above from upstream for the reason given there.

WORKDIR /work
ENTRYPOINT ["bats"]
CMD ["tests"]
