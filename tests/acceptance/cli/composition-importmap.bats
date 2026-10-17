#!/usr/bin/env bats
#
# Acceptance cases for the micro-frontend roles and the import-map renderer
# (#2660, epic #1122) — the `cli`-tooled test_cases[] of its story-spec, one test
# per `tc-*` id:
#
#   tc-happy-render-shell-two-remotes       #2661
#   tc-happy-validate-mfe-constellation     #2662
#   tc-corner-shell-only-empty-map          #2663
#   tc-corner-tag-bump-byte-identical       #2664
#   tc-corner-legacy-web-ui-unchanged       #2665
#   tc-error-two-shells                     #2666
#   tc-error-remote-without-shell           #2667
#   tc-error-mfe-name-not-path-segment      #2668
#   tc-error-render-invalid-writes-nothing  #2669
#   tc-error-render-missing-manifest        #2670
#   tc-error-render-usage                   #2671
#
# The use case: timo-platform-builder pins a shell and its remotes in the orders
# composition repo once, by image tag, and gets the per-environment import map
# the shell fetches without writing or maintaining it by hand. What runs for real:
# development-composition's validate-workspace.zsh and render-importmap.zsh over
# a fixture repo. The default gate's tests/composition-plugin-skeleton.bats
# covers the same criteria clause by clause.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  VALIDATE="$REPO_ROOT/development-composition/scripts/validate-workspace.zsh"
  RENDER="$REPO_ROOT/development-composition/scripts/render-importmap.zsh"
  REPO="$BATS_TEST_TMPDIR/orders-composition"
  mkdir -p "$REPO"
}

# The constellation as name|role|image lines, staging -> production.
constellation() {
  local m name role image
  {
    printf 'members:\n'
    for m in "$@"; do
      IFS='|' read -r name role image <<< "$m"
      printf '  - name: "%s"\n    repo: acme/%s\n    role: %s\n' "$name" "$name" "$role"
      printf '    contract: contracts/v1/openapi.yaml\n    image: %s\n' "$image"
    done
    printf 'environments:\n  staging:\n    github_environment: staging\n    promotes_from: null\n'
    printf '    deploy_target: none\n  production:\n    github_environment: production\n'
    printf '    promotes_from: staging\n    deploy_target: none\n'
  } > "$REPO/.claude-workspace.yaml"
}

SHELL_M='shell|mfe-shell|ghcr.io/acme/shell:1.4.0'
ORDERS_M='orders-ui|mfe-remote|ghcr.io/acme/orders-ui:2.3.1'
BILLING_M='billing-ui|mfe-remote|ghcr.io/acme/billing-ui:0.9.0'
API_M='orders-api|rest-api|ghcr.io/acme/orders-api:1.5.0'
EXPECTED='{"imports":{"orders-ui":"/ui/orders-ui/remote.js","billing-ui":"/ui/billing-ui/remote.js"}}'

@test "tc-happy-render-shell-two-remotes (#2661): each environment maps the two remotes, shell and API absent" {
  constellation "$SHELL_M" "$ORDERS_M" "$BILLING_M" "$API_M"
  run zsh "$RENDER" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$REPO/deploy/staging/importmap.json")" = "$EXPECTED" ]
  [ "$(jq -c . "$REPO/deploy/production/importmap.json")" = "$EXPECTED" ]
}

@test "tc-happy-validate-mfe-constellation (#2662): the shell, two remotes and an API validate" {
  constellation "$SHELL_M" "$ORDERS_M" "$BILLING_M" "$API_M"
  run zsh "$VALIDATE" --repo "$REPO"
  [ "$status" -eq 0 ]
  contains "$output" 'is valid (4 members, 2 environments)'
}

@test "tc-corner-shell-only-empty-map (#2663): a shell and an API with no remote render an empty map" {
  constellation "$SHELL_M" "$API_M"
  run zsh "$RENDER" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$REPO/deploy/staging/importmap.json")" = '{"imports":{}}' ]
  [ "$(jq -c . "$REPO/deploy/production/importmap.json")" = '{"imports":{}}' ]
}

@test "tc-corner-tag-bump-byte-identical (#2664): bumping orders-ui 2.3.1 -> 2.4.0 re-renders identical bytes" {
  constellation "$SHELL_M" "$ORDERS_M" "$BILLING_M" "$API_M"
  zsh "$RENDER" --repo "$REPO" >/dev/null
  cp -R "$REPO/deploy" "$BATS_TEST_TMPDIR/before"
  constellation "$SHELL_M" 'orders-ui|mfe-remote|ghcr.io/acme/orders-ui:2.4.0' "$BILLING_M" "$API_M"
  zsh "$RENDER" --repo "$REPO" >/dev/null
  cmp "$BATS_TEST_TMPDIR/before/staging/importmap.json" "$REPO/deploy/staging/importmap.json"
  cmp "$BATS_TEST_TMPDIR/before/production/importmap.json" "$REPO/deploy/production/importmap.json"
  run grep -rE '2\.3\.1|2\.4\.0' "$REPO/deploy"
  [ "$status" -eq 1 ]
}

@test "tc-corner-legacy-web-ui-unchanged (#2665): a web-ui + rest-api manifest with no mfe roles still validates" {
  constellation 'orders-ui|web-ui|ghcr.io/acme/orders-ui:2.3.1' "$API_M"
  run zsh "$VALIDATE" --repo "$REPO"
  [ "$status" -eq 0 ]
  contains "$output" 'is valid (2 members, 2 environments)'
}

@test "tc-error-two-shells (#2666): a second mfe-shell is refused in one stderr line naming shell-b" {
  constellation "$SHELL_M" 'shell-b|mfe-shell|ghcr.io/acme/shell-b:1.0.0'
  run --separate-stderr zsh "$VALIDATE" --repo "$REPO"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  contains "$stderr" "'shell-b'"
}

@test "tc-error-remote-without-shell (#2667): an mfe-remote with no mfe-shell is refused, naming orders-ui" {
  constellation "$ORDERS_M" "$API_M"
  run --separate-stderr zsh "$VALIDATE" --repo "$REPO"
  [ "$status" -eq 1 ]
  contains "$stderr" "'orders-ui'"
}

@test "tc-error-mfe-name-not-path-segment (#2668): Orders_UI and orders/ui are refused, naming the member" {
  local bad
  for bad in Orders_UI orders/ui; do
    constellation "$SHELL_M" "$bad|mfe-remote|ghcr.io/acme/orders-ui:2.3.1"
    run --separate-stderr zsh "$VALIDATE" --repo "$REPO"
    [ "$status" -eq 1 ]
    contains "$stderr" "'$bad'"
  done
}

@test "tc-error-render-invalid-writes-nothing (#2669): two shells exit 1 with the validator's line, no map written" {
  local expected
  constellation "$SHELL_M" 'shell-b|mfe-shell|ghcr.io/acme/shell-b:1.0.0'
  expected="$(zsh "$VALIDATE" --repo "$REPO" 2>&1 >/dev/null || true)"
  run --separate-stderr zsh "$RENDER" --repo "$REPO"
  [ "$status" -eq 1 ]
  [ "$stderr" = "$expected" ]
  [ ! -e "$REPO/deploy" ]
}

@test "tc-error-render-missing-manifest (#2670): an empty repo exits 4 with manifest not found" {
  run --separate-stderr zsh "$RENDER" --repo "$REPO"
  [ "$status" -eq 4 ]
  contains "$stderr" 'manifest not found'
}

@test "tc-error-render-usage (#2671): an empty --manifest exits 2 naming the flag" {
  run --separate-stderr zsh "$RENDER" --manifest ''
  [ "$status" -eq 2 ]
  contains "$stderr" '--manifest needs a value'
}
