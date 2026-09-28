#!/usr/bin/env bats
#
# Acceptance cases for the composition scaffold's Renovate config (#1746,
# child 3 of epic #687) — the `cli`-tooled test_cases[] of its story-spec, one
# test per `tc-*` id:
#
#   tc-happy-renovate-custom-manager   #1893
#   tc-corner-renovate-bump-pr         #932
#   tc-corner-digest-pinned-member     #1894
#   tc-corner-no-newer-tag             #1895
#   tc-corner-quoted-image-value       #1896
#   tc-corner-existing-renovate-json   #1897
#   tc-error-docker-absent             #1898
#
# (tc-happy-scaffold-skeleton, #929, is shared with #1745 and lives in
# composition-scaffold.bats beside it.)
#
# The use case: timo-platform-builder maintains orders-composition, which pins
# its members in .claude-workspace.yaml. When orders-api publishes 1.5.1,
# Renovate proposes the bump with no hand-written config — the scaffolded
# renovate.json is the whole of it.
#
# What runs for real: scaffold-composition.zsh into an empty repo, then — for
# the three dry-run cases — the PINNED renovate/renovate image with
# `--platform=local --dry-run=full` over that repo, against a PINNED local
# registry:3 this file fills through the registry HTTP API. Those three need
# Docker and pull ~1 GB, which is why this lives here and never in the default
# gate (tests/composition-scaffold.bats covers the regex without Docker). Without
# a usable Docker they SKIP with one exact reason; tc-error-docker-absent proves
# that skip, with docker hidden from PATH, by running this file's dry-run cases
# in a nested bats.
#
# Every dry-run verdict is read from Renovate's JSON log (LOG_FORMAT=json): the
# `packageFiles with updates` record's regex-manager deps and their `updates`,
# never a free-text log line.

bats_require_minimum_version 1.5.0
load ../../assertions

# The pins. This repo's own Renovate is deliberately NOT asked to bump them
# (#1746's scope): a bump here is a reviewed change to what the check proves.
readonly RENOVATE_IMAGE="renovate/renovate:44.115.13@sha256:0c04185c9e7ea5284da22ea0b2a2c88dcd3687badd8feb6c71691659b380df9b"
readonly REGISTRY_IMAGE="registry:3.1.2@sha256:c87f33837722a100572e95d7dc4bf539fc42cf68202b13c3bc03c0ff54c3a649"

readonly DOCKER_SKIP="docker not available: the Renovate dry-run needs a local registry and the pinned renovate/renovate image"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCAFFOLD="$REPO_ROOT/development-composition/scripts/scaffold-composition.zsh"
  REPO="$BATS_TEST_TMPDIR/orders-composition"
  mkdir -p "$REPO"

  UI="name=orders-ui,repo=acme/orders-ui,role=web-ui,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-ui:2.3.1"
  API="name=orders-api,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-api:1.5.0"
  REGISTRY_NAME=""
}

teardown() {
  if [ -n "$REGISTRY_NAME" ]; then docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true; fi
}

# A dry-run case's first line: skip, with the one agreed reason, unless both the
# docker CLI and a daemon answering it are present.
require_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "$DOCKER_SKIP"
  fi
}

# Every match the scaffolded matchStrings[0] makes over file $1, one
# `depName currentValue [currentDigest]` line each — a copy of
# tests/composition-scaffold.bats's probe (python3 `re`, the whole file, `(?<`
# spelled `(?P<`), kept here so this suite stands alone. The dry-run cases, not
# this probe, are what prove Renovate's own RE2 engine agrees.
renovate_matches() {
  python3 -c '
import json, re, sys
pattern = json.load(open(sys.argv[1]))["customManagers"][0]["matchStrings"][0]
for m in re.finditer(pattern.replace("(?<", "(?P<"), open(sys.argv[2]).read()):
    print(" ".join(g for g in (m["depName"], m["currentValue"], m["currentDigest"]) if g))' "$REPO/renovate.json" "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# Start the pinned registry, published on a free loopback port only.
start_registry() {
  REGISTRY_NAME="composition-renovate-$$-$BATS_TEST_NUMBER"
  docker run -d --rm --name "$REGISTRY_NAME" -p 127.0.0.1::5000 "$REGISTRY_IMAGE" >/dev/null
  # sed -n reads to EOF: an early-exit reader here could SIGPIPE docker (#1797)
  REGISTRY_URL="http://127.0.0.1:$(docker port "$REGISTRY_NAME" 5000/tcp | sed -n '1s/.*://p')"
  local i
  for i in $(seq 50); do
    curl -sf "$REGISTRY_URL/v2/" >/dev/null && return 0
    sleep 0.2
  done
  echo "registry never answered at $REGISTRY_URL" >&2
  return 1
}

# Push acme/orders-api:<tag> — a layerless OCI image whose config names the tag,
# so every tag gets its own digest — and print the manifest digest the registry
# stored it under. Fails, printing nothing, unless the registry answered with a
# sha256 digest: the pipelines below would otherwise hide a failed PUT.
push_tag() {
  local tag="$1" cfg digest loc sep mf stored
  cfg="{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{\"Labels\":{\"org.opencontainers.image.version\":\"$tag\"}},\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[]}}"
  digest="sha256:$(printf '%s' "$cfg" | sha256_of)"
  loc="$(curl -sf -X POST -D - -o /dev/null "$REGISTRY_URL/v2/acme/orders-api/blobs/uploads/" \
         | tr -d '\r' | awk -F': ' 'tolower($1) == "location" { print $2 }')"
  [ -n "$loc" ] || return 1
  case "$loc" in http*) ;; *) loc="$REGISTRY_URL$loc" ;; esac
  sep='?'; case "$loc" in *\?*) sep='&' ;; esac
  curl -sf -X PUT -H 'Content-Type: application/octet-stream' --data-binary "$cfg" \
    -o /dev/null "$loc${sep}digest=$digest" || return 1
  mf="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"$digest\",\"size\":${#cfg}},\"layers\":[]}"
  stored="$(curl -sf -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary "$mf" \
    -D - -o /dev/null "$REGISTRY_URL/v2/acme/orders-api/manifests/$tag" \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }')"
  [[ "$stored" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "push_tag $tag: no digest stored" >&2; return 1; }
  printf '%s\n' "$stored"
}

# Scaffold the fixture constellation with the given --member specs.
scaffold_fixture() {
  local m args=()
  for m in "$@"; do args+=(--member "$m"); done
  zsh "$SCAFFOLD" --repo "$REPO" "${args[@]}" >/dev/null
}

# Scaffold, then run the pinned Renovate over the fixture — see run_renovate.
dry_run() {
  scaffold_fixture "$@" || return 1
  run_renovate
}

# Run the pinned Renovate over the fixture inside the registry's network
# namespace, where localhost:5000 IS the registry. The plain-http hostRules
# entry is this fixture's, passed as global config — never part of the
# scaffolded renovate.json.
run_renovate() {
  chmod -R a+rwX "$REPO"      # the renovate image runs as a non-root user
  docker run --rm --network "container:$REGISTRY_NAME" \
    -v "$REPO:/usr/src/app" -w /usr/src/app \
    -e LOG_FORMAT=json -e LOG_LEVEL=debug \
    -e RENOVATE_HOST_RULES='[{"matchHost":"localhost","insecureRegistry":true}]' \
    "$RENOVATE_IMAGE" --platform=local --dry-run=full >"$BATS_TEST_TMPDIR/renovate.log" 2>&1
}

# The regex manager's deps for .claude-workspace.yaml from Renovate's JSON update
# record, reduced to what the cases judge. `skipReason` and `warnings` ride
# along so a lookup that FAILED (an empty registry, an unreachable host) can
# never read as "nothing newer": the cases expect null and [].
manifest_deps() {
  jq -R 'fromjson? // empty' "$BATS_TEST_TMPDIR/renovate.log" | jq -s -c '
    [ .[] | select(.msg == "packageFiles with updates") | .config.regex[]?
      | select(.packageFile == ".claude-workspace.yaml") | .deps[]
      | {depName, currentValue, currentDigest, skipReason, warnings: (.warnings // []),
         updates: [.updates[] | {newValue, newDigest}]} ]'
}

api_member() { # <image>
  printf 'name=orders-api,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=%s\n' "$1"
}

@test "tc-happy-renovate-custom-manager (#1893): the scaffold writes a regex customManager that matches both member lines" {
  run zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API"
  [ "$status" -eq 0 ]
  contains "$output" "scaffold-composition.zsh: wrote renovate.json"
  local r="$REPO/renovate.json"
  jq -e . "$r" >/dev/null
  # exact key sets: nothing that could switch Renovate off rides along
  [ "$(jq -c 'keys' "$r")" = '["$schema","customManagers"]' ]
  [ "$(jq -c '.customManagers[0] | keys' "$r")" \
    = '["customType","datasourceTemplate","description","managerFilePatterns","matchStrings"]' ]
  [ "$(jq -r '.customManagers[0] | [.customType, .datasourceTemplate] | join(" ")' "$r")" = "regex docker" ]
  [ "$(jq -c '.customManagers[0].managerFilePatterns' "$r")" = '["/(^|/)\\.claude-workspace\\.yaml$/"]' ]
  run renovate_matches "$REPO/.claude-workspace.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/acme/orders-ui 2.3.1"$'\n'"ghcr.io/acme/orders-api 1.5.0" ]
}

@test "tc-corner-renovate-bump-pr (#932): Renovate proposes 1.5.0 -> 1.5.1 for .claude-workspace.yaml" {
  require_docker
  start_registry
  push_tag 1.5.0 >/dev/null
  push_tag 1.5.1 >/dev/null
  scaffold_fixture "$(api_member localhost:5000/acme/orders-api:1.5.0)" \
    "name=orders-api-canary,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=localhost:5000/acme/orders-api:1.5.0"
  # the canary is hand-edited to the quoted, trailing-comment form, so Renovate's
  # own RE2 engine — not only the python3 probe — reads that form
  yq -i '.members[1].image style="double" | .members[1].image line_comment="pinned by hand"' \
    "$REPO/.claude-workspace.yaml"
  grep -qx '    image: "localhost:5000/acme/orders-api:1.5.0" # pinned by hand' "$REPO/.claude-workspace.yaml"
  run run_renovate
  [ "$status" -eq 0 ]
  local bump='{"depName":"localhost:5000/acme/orders-api","currentValue":"1.5.0","currentDigest":null,"skipReason":null,"warnings":[],"updates":[{"newValue":"1.5.1","newDigest":null}]}'
  [ "$(manifest_deps)" = "[$bump,$bump]" ]
}

@test "tc-corner-digest-pinned-member (#1894): a digest-pinned member is bumped to 1.5.1 with 1.5.1's digest" {
  require_docker
  start_registry
  local d150 d151
  d150="$(push_tag 1.5.0)"
  d151="$(push_tag 1.5.1)"
  matches "$d150" '^sha256:[0-9a-f]{64}$'
  matches "$d151" '^sha256:[0-9a-f]{64}$'
  [ "$d150" != "$d151" ]
  run dry_run "$(api_member "localhost:5000/acme/orders-api:1.5.0@$d150")"
  [ "$status" -eq 0 ]
  [ "$(manifest_deps)" \
    = "[{\"depName\":\"localhost:5000/acme/orders-api\",\"currentValue\":\"1.5.0\",\"currentDigest\":\"$d150\",\"skipReason\":null,\"warnings\":[],\"updates\":[{\"newValue\":\"1.5.1\",\"newDigest\":\"$d151\"}]}]" ]
}

@test "tc-corner-no-newer-tag (#1895): with only 1.5.0 published the dependency is detected and nothing is proposed" {
  require_docker
  start_registry
  push_tag 1.5.0 >/dev/null
  run dry_run "$(api_member localhost:5000/acme/orders-api:1.5.0)"
  [ "$status" -eq 0 ]
  # detected, looked up without a warning or skip — so an empty proposal is a
  # verdict about the registry, not a silent non-match or a failed lookup
  [ "$(manifest_deps)" \
    = '[{"depName":"localhost:5000/acme/orders-api","currentValue":"1.5.0","currentDigest":null,"skipReason":null,"warnings":[],"updates":[]}]' ]
}

@test "tc-corner-quoted-image-value (#1896): a quoted value and a trailing comment are matched, neither captured" {
  zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API" >/dev/null
  local m="$BATS_TEST_TMPDIR/hand-edited.yaml"
  cat >"$m" <<'EOF'
members:
  - name: orders-api
    image: "localhost:5000/acme/orders-api:1.5.0"
  - name: orders-api-canary
    image: localhost:5000/acme/orders-api:1.5.0  # pinned by hand
EOF
  run renovate_matches "$m"
  [ "$status" -eq 0 ]
  [ "$output" = "localhost:5000/acme/orders-api 1.5.0"$'\n'"localhost:5000/acme/orders-api 1.5.0" ]
}

@test "tc-corner-existing-renovate-json (#1897): an existing renovate.json is kept byte-identical and the scaffold exits 0" {
  printf '{\n  "extends": ["config:recommended"],\n  "timezone": "Europe/Berlin"\n}\n' >"$REPO/renovate.json"
  cp "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
  run zsh "$SCAFFOLD" --repo "$REPO" --member "$UI" --member "$API"
  [ "$status" -eq 0 ]
  contains "$output" "scaffold-composition.zsh: kept renovate.json (exists)"
  cmp "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "tc-error-docker-absent (#1898): with docker off PATH every dry-run case skips with the agreed reason, none passes" {
  # A PATH holding every executable the host's PATH does, except `docker` —
  # so the nested bats, zsh, jq, yq and python3 all still resolve.
  local shadow="$BATS_TEST_TMPDIR/no-docker-bin" dir f name
  mkdir -p "$shadow"
  local IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      name="${f##*/}"
      [ "$name" = docker ] && continue
      [ -x "$f" ] && [ ! -e "$shadow/$name" ] && ln -s "$f" "$shadow/$name"
    done
  done
  unset IFS
  [ ! -e "$shadow/docker" ]
  run env PATH="$shadow" bats --filter 'tc-corner-(renovate-bump-pr|digest-pinned-member|no-newer-tag)' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
  contains "$output" "1..3"
  [ "$(grep -c "^ok [0-9]* tc-corner-.* # skip $DOCKER_SKIP\$" <<<"$output")" = "3" ]
  # an `ok` without the skip would be a pass reported with no dry-run behind it
  [ "$(grep '^ok ' <<<"$output" | grep -vc ' # skip ')" = "0" ]
}
