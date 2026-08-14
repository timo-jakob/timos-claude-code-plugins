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
# The kubernetes-ci real-tool harness (tests/kubernetes-ci-fixtures.bats, #1199)
# needs helm, kustomize, kubeconform, kube-linter, kyverno and yq — and they are
# deliberately NOT installed here. Two reasons, both about correctness rather
# than image size:
#   * the versions are PINNED, and four of the six (kubeconform, kube-linter,
#     kyverno, yq) are read from the workflow template
#     (development/skills/bootstrap/templates/iac/...), which is outside this
#     build context. An apt/brew build of kube-linter one minor ahead reports
#     three findings on the fixture that pins four, so "whatever the distro
#     ships" is not an option. (helm and kustomize are pinned in
#     tests/iac-tools.zsh — the template installs neither — so this reason does
#     not apply to them; the next one does.);
#   * baking them in would re-download ~100 MB on every image rebuild.
# tests/iac-tools.zsh fetches them into a cache keyed by os-arch, and
# run-script-tests.zsh mounts the host's cache root at /iac-tools
# (IAC_TOOLS_CACHE), so the container downloads once per platform, ever. What
# this image owes that path is the fetch toolchain — curl, tar (base), zsh,
# ca-certificates and yq — all installed above.
#
# nodejs: the development-javascript contract-consumer ships a pure-JS orval
# transformer (orval-deprecation-transformer.mjs, #707); its behavioral bats test
# executes it with node, so node is a declared test dependency, not incidental.
# yamllint: tests/bootstrap-iac-pipeline.bats (#1154) lints the kubernetes-ci
# workflow template with the repo's strict yamllint config, and
# tests/no-cluster-deploy.bats (#1206) lints the no-cluster-deploy workflow
# template the same way; both call it unguarded, so the documented local run
# needs it present. yq is installed
# above from upstream for the reason given there.

WORKDIR /work
ENTRYPOINT ["bats"]
CMD ["tests"]
