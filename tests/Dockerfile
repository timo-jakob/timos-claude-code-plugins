# Disposable image for running the shell-script behavioral tests (bats) in
# isolation from the host — the "don't mess up the local dev machine" guarantee
# from #263. Contains exactly the toolchain the scripts under test need.
FROM debian:stable-slim

# python3-venv + python3-pip: Debian splits `venv` and `pip` OUT of `python3`, so
# neither is present in this base image — and `verify-python-state.sh` (exercised
# by tests/detect-stack.bats's two `verify-python-state:` cases) creates a venv,
# which fails with "ensurepip is not available … install the python3-venv
# package". They are installed rather than stubbed: a stubbed toolchain stops the
# test proving the thing it exists to prove. The `--local` host lane is
# unaffected — Homebrew's python3 ships both.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats jq shellcheck zsh python3 python3-venv python3-pip git ca-certificates \
      nodejs yamllint curl \
 && rm -rf /var/lib/apt/lists/*
# mikefarah yq, NOT Debian's `yq` apt package (which is kislyuk's python-yq, a
# different query language): the suite and the shipped kubernetes-ci template
# both use `-o=json` and rely on YAML 1.2 semantics, neither of which python-yq
# provides. This image is the "don't mess up the local dev machine" run, so it
# is the one leg with no preinstalled mikefarah yq to fall back on.
# The suite reads the repo's git store through a bind mount the runner adds
# (#1360). The container is uid 0 while those files carry the host's ownership on
# any backend that does not remap it (Colima, Rancher Desktop, rootful Docker on
# Linux) — and git then refuses the repo with `detected dubious ownership`, the
# same untyped container-only fatal #1360 exists to remove, which the runner's
# host-side pre-flight cannot see. Docker Desktop for Mac does remap, so this is
# insurance for backends this repo does not test on, in a disposable test image
# where a blanket setting costs nothing.
RUN git config --system --add safe.directory '*'
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
