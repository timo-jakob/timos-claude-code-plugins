#!/usr/bin/env bats
#
# Acceptance cases for the composition repo-type scaffold and promote-to-prod
# (#1745, child 2 of epic #687) — the `cli`-tooled test_cases[] of its
# story-spec, one test per `tc-*` id:
#
#   tc-happy-scaffold-skeleton          #929  (shared with #1746 — see below)
#   tc-happy-promote-triggers           #1734
#   tc-happy-promote-staging-record     #1735
#   tc-corner-promote-prepinned-digest  #1751
#   tc-error-promote-no-renderer        #1736
#   tc-error-promote-undeclared-env     #1737
#
# The use case: timo-platform-builder stands up the orders-composition repo,
# pinning ghcr.io/acme/orders-ui:2.3.1 and ghcr.io/acme/orders-api:1.5.0, with
# `staging` (promotes from none) and `production` (promotes from staging), both
# at deploy_target: none. Merges promote staging and record what was promoted;
# production promotes only on a gated manual dispatch; no run claims a deploy.
#
# What runs for real: development-composition's scaffold-composition.zsh (and
# the validate-workspace.zsh it calls) into an empty repo, then the scaffolded
# scripts/promote.zsh — against a stubbed `docker`, the one command it resolves
# digests with, since no registry is reachable offline. The default gate's
# tests/composition-scaffold.bats covers the same criteria clause by clause.
#
# #929's shape also names renovate.json, which child 3 (#1746) scaffolds. Its
# case here asserts the skeleton THIS story owns; #1746 extends the expected set
# with renovate.json, and #929 closes with whichever of the two merges last.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCAFFOLD="$REPO_ROOT/development-composition/scripts/scaffold-composition.zsh"
  REPO="$BATS_TEST_TMPDIR/orders-composition"
  mkdir -p "$REPO"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export STUB_LOG="$BATS_TEST_TMPDIR/docker.log"
  export STUB_DIGESTS="$BATS_TEST_TMPDIR/digests"
  : >"$STUB_LOG"
  cat >"$STUB_BIN/docker" <<'EOF'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
[ "$1 $2 $3 $5 $6" = "buildx imagetools inspect --format {{.Manifest.Digest}}" ] && [ $# -eq 6 ] || exit 64
d="$(awk -v r="$4" '$1 == r { print $2 }' "$STUB_DIGESTS")"
[ -n "$d" ] || exit 1
echo "$d"
EOF
  chmod +x "$STUB_BIN/docker"

  SHA="7e1c0d9a8b7f6e5d4c3b2a1908f7e6d5c4b3a291"
  D_UI="sha256:1f0e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0"
  D_API="sha256:9a8b7c6d5e4f30211203f4e5d6c7b8a99a8b7c6d5e4f30211203f4e5d6c7b8a9"
  printf '%s %s\n' "ghcr.io/acme/orders-ui:2.3.1" "$D_UI" \
                   "ghcr.io/acme/orders-api:1.5.0" "$D_API" >"$STUB_DIGESTS"

  UI="name=orders-ui,repo=acme/orders-ui,role=web-ui,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-ui:2.3.1"
  API="name=orders-api,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-api:1.5.0"
}

promote() {
  ( cd "$REPO" && PATH="$STUB_BIN:$PATH" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" \
      zsh scripts/promote.zsh --sha "$SHA" "$@" )
}

@test "tc-happy-scaffold-skeleton (#929): the scaffold writes the skeleton, no manifest or harness, and validates" {
  run zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API"
  [ "$status" -eq 0 ]
  contains "$output" "is valid (2 members, 2 environments)"
  [ "$(cd "$REPO" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" \
    = "./.claude-workspace.yaml ./.github/workflows/promote-to-prod.yml ./.maintenance.yml ./deploy/README.md ./e2e/README.md ./scripts/promote.zsh " ]
  grep -qx 'primary: composition' "$REPO/.maintenance.yml"
  # zero compose/k8s manifests, zero Playwright files, no validator workflow
  [ -z "$(cd "$REPO" && find . \( -name 'docker-compose*' -o -name 'compose.y*ml' -o -name 'kustomization.y*ml' \
          -o -name 'playwright.config.*' -o -name '*.spec.ts' \) -print)" ]
  [ "$(ls "$REPO/.github/workflows")" = "promote-to-prod.yml" ]
}

@test "tc-happy-promote-triggers (#1734): push promotes staging, only a dispatch promotes production, actionlint clean" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$API" >/dev/null
  local wf="$REPO/.github/workflows/promote-to-prod.yml"
  [ "$(yq -r '.on.push.branches | join(" ")' "$wf")" = "main" ]
  [ "$(yq -r '.jobs["promote-staging"].if' "$wf")" = "github.event_name == 'push'" ]
  [ "$(yq -r '.jobs["promote-production"].if' "$wf")" = "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'" ]
  [ "$(yq -r '.jobs["promote-production"].environment' "$wf")" = "production" ]
  # nothing that runs on push promotes production
  [ "$(yq -r '[.jobs[] | select(.if == "github.event_name == '"'"'push'"'"'") | .steps[].run // "" | select(test("--env production"))] | length' "$wf")" = "0" ]
  run actionlint "$wf"
  [ "$status" -eq 0 ]
}

@test "tc-happy-promote-staging-record (#1735): staging records both members at their digests, says nothing deployed, exits 0" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API" >/dev/null
  run promote --env staging --mode push
  [ "$status" -eq 0 ]
  local r="$REPO/promotion-staging.json"
  [ "$(jq -r '.commit' "$r")" = "$SHA" ]
  [ "$(jq -r '.members[].image' "$r" | tr '\n' ' ')" \
    = "ghcr.io/acme/orders-ui:2.3.1@$D_UI ghcr.io/acme/orders-api:1.5.0@$D_API " ]
  local notice="nothing deployed — deploy_target: none, no renderer (#719/#720)"
  contains "$output" "$notice"
  contains "$(cat "$BATS_TEST_TMPDIR/summary.md")" "$notice"
}

@test "tc-corner-promote-prepinned-digest (#1751): a digest-pinned member keeps exactly one @sha256: suffix" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API" >/dev/null
  yq -i ".members[1].image = \"ghcr.io/acme/orders-api:1.5.0@$D_API\"" "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 0 ]
  local api
  api="$(jq -r '.members[] | select(.name == "orders-api") | .image' "$REPO/promotion-staging.json")"
  [ "$api" = "ghcr.io/acme/orders-api:1.5.0@$D_API" ]
  [ "$(grep -o '@sha256:' <<<"$api" | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -r '.members[] | select(.name == "orders-ui") | .image' "$REPO/promotion-staging.json")" \
    = "ghcr.io/acme/orders-ui:2.3.1@$D_UI" ]
}

@test "tc-error-promote-no-renderer (#1736): a production dispatch records, then fails naming #719/#720" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API" >/dev/null
  [ "$(ls -A "$REPO/deploy")" = "README.md" ]
  run promote --env production --mode dispatch
  [ "$status" -eq 1 ]
  [ -s "$REPO/promotion-production.json" ]
  contains "$output" "no deploy renderer present — deploy/ is filled by #719 (compose) / #720 (kubernetes)"
  lacks "$output" "nothing deployed —"
  [ "$(jq -r '.deployed' "$REPO/promotion-production.json")" = "false" ]
}

@test "tc-error-promote-undeclared-env (#1737): qa is refused, listing staging and production, before any lookup" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API" >/dev/null
  run promote --env qa --mode push
  [ "$status" -eq 1 ]
  contains "$output" "declared: staging, production"
  [ ! -s "$STUB_LOG" ]
}
