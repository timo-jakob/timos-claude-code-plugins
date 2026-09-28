#!/usr/bin/env bats
#
# The composition repo-type scaffold and its promotion machinery (issue #1745,
# child 2 of epic #687):
#
#   * development-composition/scripts/scaffold-composition.zsh — the exact
#     skeleton it writes, and its typed branch on validate-workspace.zsh's exit;
#   * templates/.github/workflows/promote-to-prod.yml — the triggers, read with
#     yq (a grep cannot tell a trigger from a comment), and actionlint;
#   * templates/scripts/promote.zsh — EXECUTED against a stubbed `docker`, the
#     one command it resolves digests with. The stub answers only the documented
#     invocation and logs every call, so a case can prove the lookup's shape and
#     that no lookup happened at all;
#   * templates/renovate.json (#1746) — its shape, and its regex EXECUTED by
#     python3 against sample `image:` lines, so the default gate proves the match
#     without Docker (the real Renovate dry-run is acceptance-only);
#   * bootstrap's §3m, pinned where it routes a run to the scaffold.
#
# The acceptance cases for the story's test_cases[] live in
# tests/acceptance/cli/composition-scaffold.bats and (#1746)
# composition-renovate.bats; this is the always-on gate.
#
# yq, actionlint and python3 are called unguarded and are declared dependencies in
# .github/workflows/script-tests.yml and tests/Dockerfile: an absent one should
# fail these red rather than skip the only coverage the templates have.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN="$REPO_ROOT/development-composition"
  SCAFFOLD="$PLUGIN/scripts/scaffold-composition.zsh"
  TEMPLATES="$PLUGIN/templates"
  WF_TMPL="$TEMPLATES/.github/workflows/promote-to-prod.yml"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"

  REPO="$BATS_TEST_TMPDIR/orders-composition"
  mkdir -p "$REPO"

  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  export STUB_LOG="$BATS_TEST_TMPDIR/docker.log"
  export STUB_DIGESTS="$BATS_TEST_TMPDIR/digests"
  : >"$STUB_DIGESTS"
  # `docker buildx imagetools inspect <ref> --format {{.Manifest.Digest}}` → the
  # digest mapped to <ref> in $STUB_DIGESTS. Any other argv is refused, so a
  # changed invocation reds here rather than only against a real registry.
  cat >"$STUB_BIN/docker" <<'EOF'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
[ "$1 $2 $3 $5 $6" = "buildx imagetools inspect --format {{.Manifest.Digest}}" ] && [ $# -eq 6 ] \
  || { echo "stub: unexpected docker invocation: $*" >&2; exit 64; }
d="$(awk -v r="$4" '$1 == r { print $2 }' "$STUB_DIGESTS")"
[ -n "$d" ] || { echo "stub: manifest unknown for $4" >&2; exit 1; }
echo "$d"
EOF
  chmod +x "$STUB_BIN/docker"

  SHA="3f9c2e1d4b5a69788796a5b4c3d2e1f00112233a"
  D_UI="sha256:$(printf 'a%.0s' {1..64})"
  D_API="sha256:$(printf 'b%.0s' {1..64})"
  D_OTHER="sha256:$(printf 'c%.0s' {1..64})"

  MEMBER_UI="name=orders-ui,repo=acme/orders-ui,role=web-ui,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-ui:2.3.1"
  MEMBER_API="name=orders-api,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-api:1.5.0"
}

scaffold() {
  zsh "$SCAFFOLD" --repo "$REPO" "$@"
}

# the orders-composition repo, scaffolded, with both tags mapped to a digest
scaffolded_repo() {
  scaffold --member "$MEMBER_UI" --member "$MEMBER_API" >/dev/null
  printf '%s %s\n' "ghcr.io/acme/orders-ui:2.3.1" "$D_UI" "ghcr.io/acme/orders-api:1.5.0" "$D_API" >"$STUB_DIGESTS"
}

promote() {
  ( cd "$REPO" && PATH="$STUB_BIN:$PATH" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" \
      zsh scripts/promote.zsh --sha "$SHA" "$@" )
}

# A PATH holding only the named tools plus the base set every path needs — the
# composition-plugin-skeleton.bats convention, which also hides the host's
# /usr/bin so a tool the case removes cannot be found there.
stub_path_with() {
  local dir="$BATS_TEST_TMPDIR/only-bin" tool src
  rm -rf "$dir" || return 1
  mkdir -p "$dir" || return 1
  for tool in "$@" rm tr mktemp mkdir cp chmod mv awk; do
    src="$(command -v "$tool")"
    [ -n "$src" ] || return 1
    ln -sf "$src" "$dir/$tool" || return 1
  done
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# The scaffold
# ---------------------------------------------------------------------------

@test "the scaffold writes exactly the skeleton — no manifest, harness or validator workflow" {
  run scaffold --member "$MEMBER_UI" --member "$MEMBER_API"
  [ "$status" -eq 0 ]
  local files s="scaffold-composition.zsh"
  files="$(cd "$REPO" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
  [ "$files" = "./.claude-workspace.yaml ./.github/workflows/promote-to-prod.yml ./.maintenance.yml ./deploy/README.md ./e2e/README.md ./renovate.json ./scripts/promote.zsh " ]
  [ -x "$REPO/scripts/promote.zsh" ]
  # one line per file in write order, then the validator's own success line —
  # naming the manifest, not the temporary file it judged
  [ "$output" = "$s: wrote .claude-workspace.yaml"$'\n'"$s: wrote .github/workflows/promote-to-prod.yml"$'\n'"$s: wrote scripts/promote.zsh"$'\n'"$s: wrote deploy/README.md"$'\n'"$s: wrote e2e/README.md"$'\n'"$s: wrote .maintenance.yml"$'\n'"$s: wrote renovate.json"$'\n'"$s: claude-workspace/v1: $REPO/.claude-workspace.yaml is valid (2 members, 2 environments)" ]
  # mktemp's 0600 is not carried onto the manifest
  [ "$(ls -l "$REPO/.claude-workspace.yaml" | cut -c1-10)" = "-rw-r--r--" ]
}

@test "the scaffolded manifest carries every member field verbatim and staging -> production at deploy_target none" {
  scaffold --member "$MEMBER_UI" --member "$MEMBER_API" >/dev/null
  local m="$REPO/.claude-workspace.yaml"
  [ "$(yq -r '.members | map(.name + "|" + .repo + "|" + .role + "|" + .contract + "|" + .image) | join(" ")' "$m")" \
    = "orders-ui|acme/orders-ui|web-ui|contracts/v1/openapi.yaml|ghcr.io/acme/orders-ui:2.3.1 orders-api|acme/orders-api|rest-api|contracts/v1/openapi.yaml|ghcr.io/acme/orders-api:1.5.0" ]
  [ "$(yq -r '.environments | keys | join(" ")' "$m")" = "staging production" ]
  [ "$(yq -r '.environments.staging.github_environment' "$m")" = "staging" ]
  [ "$(yq -r '.environments.production.github_environment' "$m")" = "production" ]
  [ "$(yq -r '.environments.staging.promotes_from' "$m")" = "null" ]
  [ "$(yq -r '.environments.production.promotes_from' "$m")" = "staging" ]
  [ "$(yq -r '[.environments[].deploy_target] | unique | join(" ")' "$m")" = "none" ]
  [ "$(yq -r '.primary' "$REPO/.maintenance.yml")" = "composition" ]
}

@test "a member spec's keys land in the contract's field order, whatever order they were given" {
  scaffold --member "image=ghcr.io/acme/orders-api:1.5.0,contract=c.yaml,role=rest-api,repo=acme/orders-api,name=orders-api" >/dev/null
  [ "$(yq -r '.members[0] | keys | join(" ")' "$REPO/.claude-workspace.yaml")" = "name repo role contract image" ]
}

@test "both socket READMEs point at the renderer epics #719 and #720" {
  scaffold --member "$MEMBER_API" >/dev/null
  local f
  for f in deploy/README.md e2e/README.md; do
    contains "$(cat "$REPO/$f")" "issues/719"
    contains "$(cat "$REPO/$f")" "issues/720"
  done
}

@test "a member value starting with - is taken as a value, never as a jq option" {
  scaffold --member "name=orders-api,repo=acme/orders-api,role=-r,contract=-x,image=ghcr.io/acme/orders-api:1.5.0" >/dev/null
  [ "$(yq -r '.members[0] | .role + " " + .contract + " " + .image' "$REPO/.claude-workspace.yaml")" \
    = "-r -x ghcr.io/acme/orders-api:1.5.0" ]
}

@test "a member value YAML would misread is written quoted, not pasted" {
  # `role` of `yes` is a YAML 1.1 boolean and `#` starts a comment: both must
  # round-trip as the strings they were given
  scaffold --member "name=orders-api,repo=acme/orders-api,role=yes,contract=a #b,image=ghcr.io/acme/orders-api:1.5.0" >/dev/null
  [ "$(yq -r '.members[0].role | type' "$REPO/.claude-workspace.yaml")" = "!!str" ]
  [ "$(yq -r '.members[0].contract' "$REPO/.claude-workspace.yaml")" = "a #b" ]
}

@test "a refused manifest fails the scaffold with exit 1, quoting the named error, and writes nothing" {
  run scaffold --member "name=orders-api,repo=acme/orders-api,role=rest-api,contract=c.yaml,image=ghcr.io/acme/orders-api:latest"
  [ "$status" -eq 1 ]
  contains "$output" "violates claude-workspace/v1"
  contains "$output" "(new .claude-workspace.yaml; nothing was written)"
  contains "$output" "member 'orders-api'"
  contains "$output" "':latest'"
  # judged BEFORE anything is written, so a corrected re-run starts clean
  [ -z "$(ls -A "$REPO")" ]
  run scaffold --member "$MEMBER_API"
  [ "$status" -eq 0 ]
}

@test "a re-run keeps every existing file and still validates" {
  scaffold --member "$MEMBER_API" >/dev/null
  printf '# mine\n' >>"$REPO/deploy/README.md"
  run scaffold
  [ "$status" -eq 0 ]
  contains "$output" "kept .claude-workspace.yaml (exists)"
  contains "$output" "kept deploy/README.md (exists)"
  lacks "$output" "wrote"
  [ "$(tail -n 1 "$REPO/deploy/README.md")" = "# mine" ]
  contains "$output" "is valid"
}

@test "an existing manifest judged invalid fails the scaffold as the KEPT manifest, and writes no other file" {
  scaffold --member "$MEMBER_API" >/dev/null
  rm -rf "$REPO/.github" "$REPO/scripts"
  yq -i '.environments.production.promotes_from = "qa"' "$REPO/.claude-workspace.yaml"
  run scaffold
  [ "$status" -eq 1 ]
  contains "$output" "kept .claude-workspace.yaml"
  contains "$output" "environment 'production'"
  [ ! -e "$REPO/scripts/promote.zsh" ]
}

@test "a kept manifest without the staging -> production chain the workflow binds is refused, and writes no other file" {
  local edit
  # each shape is valid claude-workspace/v1, and each breaks one clause:
  # no staging/production at all; staging not the head of the chain; a
  # production gated by an Environment the workflow never binds
  for edit in \
    '.environments = {"dev": {"github_environment": "dev", "promotes_from": null, "deploy_target": "none"}}' \
    '.environments = {"dev": {"github_environment": "dev", "promotes_from": null, "deploy_target": "none"}} + .environments | .environments.staging.promotes_from = "dev"' \
    '.environments.production.github_environment = "prod-gated"' \
    '.environments.staging.github_environment = "stage"' \
    '.environments.production.promotes_from = null'; do
    rm -rf "$REPO" && mkdir -p "$REPO"
    scaffold --member "$MEMBER_API" >/dev/null
    rm -rf "$REPO/.github" "$REPO/scripts"
    yq -i "$edit" "$REPO/.claude-workspace.yaml"
    run scaffold
    [ "$status" -eq 1 ]
    contains "$output" "does not declare staging (github_environment: staging, promotes_from: null) and production (github_environment: production, promotes_from: staging)"
    [ ! -e "$REPO/scripts/promote.zsh" ]
  done
}

@test "a skeleton file that cannot be written is exit 3, saying the manifest was already judged and placed" {
  printf 'x\n' >"$REPO/deploy"      # a file where the deploy/ socket must go
  run scaffold --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not create deploy/"
  contains "$output" "the manifest was judged valid and is on disk"
  lacks "$output" "violates"
}

@test "a skeleton file that cannot be copied is exit 3, saying the manifest was already judged and placed" {
  mkdir -p "$REPO/deploy"
  ln -s "$BATS_TEST_TMPDIR/absent/x" "$REPO/deploy/README.md"   # dangling: -e false, cp fails, even as root
  run scaffold --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not write deploy/README.md"
  contains "$output" "the manifest was judged valid and is on disk"
}

@test "a repo the temporary manifest cannot be created in is exit 3" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory modes"
  chmod 0555 "$REPO"
  run scaffold --member "$MEMBER_API"
  chmod 0755 "$REPO"
  [ "$status" -eq 3 ]
  contains "$output" "could not create a temporary file"
}

@test "a manifest render that fails after the yq probe is exit 3 and leaves nothing behind" {
  local stub
  stub="$(stub_path_with jq zsh)"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "yq version 4.44.3"; exit 0; }\nexit 2\n' >"$stub/yq"
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not render the manifest"
  [ -z "$(ls -A "$REPO")" ]
}

@test "--member beside an existing manifest is refused rather than silently ignored" {
  scaffold --member "$MEMBER_API" >/dev/null
  run scaffold --member "$MEMBER_UI"
  [ "$status" -eq 2 ]
  contains "$output" "already exists"
  [ "$(yq -r '.members | length' "$REPO/.claude-workspace.yaml")" = "1" ]
}

@test "a member spec missing a key is a usage error" {
  run scaffold --member "name=orders-api,repo=acme/orders-api,role=rest-api,image=ghcr.io/acme/orders-api:1.5.0"
  [ "$status" -eq 2 ]
  contains "$output" "missing key 'contract'"
  [ -z "$(ls -A "$REPO")" ]
}

@test "a member spec repeating a key is a usage error" {
  run scaffold --member "$MEMBER_API,name=again"
  [ "$status" -eq 2 ]
  contains "$output" "key 'name' given twice"
}

@test "a member spec naming an unknown key is a usage error" {
  run scaffold --member "$MEMBER_API,tier=gold"
  [ "$status" -eq 2 ]
  contains "$output" "unknown key 'tier'"
}

@test "a member spec pair without = is a usage error that writes nothing" {
  run scaffold --member "contract,name=orders-api,repo=acme/orders-api,role=rest-api,image=ghcr.io/acme/orders-api:1.5.0"
  [ "$status" -eq 2 ]
  contains "$output" "'contract' is not key=value"
  [ -z "$(ls -A "$REPO")" ]
}

@test "no --member and no manifest is a usage error" {
  run scaffold
  [ "$status" -eq 2 ]
  contains "$output" "at least one --member"
}

@test "an unknown argument is a usage error" {
  run scaffold --bogus
  [ "$status" -eq 2 ]
  contains "$output" "unknown argument: --bogus"
}

@test "a --repo that is not a directory is a usage error" {
  run zsh "$SCAFFOLD" --repo "$BATS_TEST_TMPDIR/nope" --member "$MEMBER_API"
  [ "$status" -eq 2 ]
  contains "$output" "is not a directory"
}

@test "a --repo that swallows the next flag is a usage error" {
  run zsh "$SCAFFOLD" --repo --member "$MEMBER_API"
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
}

@test "a missing yq or jq is exit 3 — an environment escalation — and writes nothing" {
  local stub
  stub="$(stub_path_with jq zsh)"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: yq"
  stub="$(stub_path_with yq zsh)"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: jq"
  [ -z "$(ls -A "$REPO")" ]
}

@test "a yq that is not mikefarah's is exit 3 and leaves no partial manifest" {
  # Debian/Ubuntu's python-yq rejects `-p=json`; its argparse exit 2 must not
  # read as this script's usage error, nor leave a comment-only manifest behind
  local stub
  stub="$(stub_path_with jq zsh)"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "yq 3.4.3"; exit 0; }\nexit 2\n' >"$stub/yq"
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"
  [ -z "$(ls -A "$REPO")" ]
}

@test "the validator's non-verdict exits are escalated as 3, never read as a bad manifest" {
  # a copy of the plugin whose validator is replaced, so each typed exit can be
  # reached without breaking a real tool
  local fake="$BATS_TEST_TMPDIR/plugin" code
  mkdir -p "$fake/scripts"
  cp -R "$TEMPLATES" "$fake/templates"
  cp "$SCAFFOLD" "$fake/scripts/"
  for code in 2 3 7; do
    rm -rf "$REPO" && mkdir -p "$REPO"
    printf '#!/bin/sh\necho "validator says %s" >&2\nexit %s\n' "$code" "$code" >"$fake/scripts/validate-workspace.zsh"
    run zsh "$fake/scripts/scaffold-composition.zsh" --repo "$REPO" --member "$MEMBER_API"
    [ "$status" -eq 3 ]
    contains "$output" "never judged"
    contains "$output" "validator says $code"
    lacks "$output" "violates"
    [ -z "$(ls -A "$REPO")" ]
  done
}

@test "the validator's exit 4 is relayed as 4, naming whose manifest could not be read" {
  local fake="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$fake/scripts"
  cp -R "$TEMPLATES" "$fake/templates"
  cp "$SCAFFOLD" "$fake/scripts/"
  printf '#!/bin/sh\necho "validator says 4" >&2\nexit 4\n' >"$fake/scripts/validate-workspace.zsh"
  run zsh "$fake/scripts/scaffold-composition.zsh" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 4 ]
  contains "$output" "could not read the manifest (new .claude-workspace.yaml)"
  contains "$output" "validator says 4"
}

@test "the validator's exit 4 on a KEPT manifest names it as kept" {
  local fake="$BATS_TEST_TMPDIR/plugin"
  scaffold --member "$MEMBER_API" >/dev/null
  mkdir -p "$fake/scripts"
  cp -R "$TEMPLATES" "$fake/templates"
  cp "$SCAFFOLD" "$fake/scripts/"
  printf '#!/bin/sh\necho "validator says 4" >&2\nexit 4\n' >"$fake/scripts/validate-workspace.zsh"
  run zsh "$fake/scripts/scaffold-composition.zsh" --repo "$REPO"
  [ "$status" -eq 4 ]
  contains "$output" "(kept .claude-workspace.yaml)"
}

# A stub PATH whose `$1` fails with exit 1 — optionally only when its first
# argument is `$2`, handing every other call to the real tool.
stub_failing() {
  local stub real
  stub="$(stub_path_with jq yq zsh)" || return 1
  real="$(command -v "$1")" || return 1
  rm -f "$stub/$1"
  printf '#!/bin/sh\n[ -z "%s" ] || [ "$1" = "%s" ] && { echo "stub %s failed" >&2; exit 1; }\nexec "%s" "$@"\n' \
    "${2:-}" "${2:-}" "$1" "$real" >"$stub/$1"
  /bin/chmod +x "$stub/$1"
  printf '%s\n' "$stub"
}

@test "a manifest whose mode cannot be set is exit 3" {
  local stub
  stub="$(stub_failing chmod 0644)"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not set the manifest's mode"
}

@test "a manifest that cannot be moved into place is exit 3 and leaves no temporary file" {
  local stub
  stub="$(stub_failing mv)"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not move the manifest into place"
  [ -z "$(ls -A "$REPO")" ]
}

@test "a promote script that cannot be made executable is exit 3, naming what is on disk" {
  local stub
  stub="$(stub_failing chmod +x)"
  run env PATH="$stub" /bin/zsh "$SCAFFOLD" --repo "$REPO" --member "$MEMBER_API"
  [ "$status" -eq 3 ]
  contains "$output" "could not make scripts/promote.zsh executable"
  contains "$output" "the manifest was judged valid and is on disk"
}

# ---------------------------------------------------------------------------
# The Renovate config (#1746)
# ---------------------------------------------------------------------------

# Every match the shipped matchStrings[0] makes over file $2, one line each:
# `depName currentValue [currentDigest]`. Run over the WHOLE file, as Renovate
# scans it, never line by line, with no global flags — Renovate compiles with
# `g` alone, so the pattern's line anchoring comes from its own scoped
# `(?m:…)` groups. python3's `re` stands in for Renovate's RE2 here because it
# reads those scoped groups on every supported runner (the node an Ubuntu apt
# installs predates them); its one spelling difference, `(?P<name>` for a named
# group, is translated. $1 is the renovate.json to read the pattern from.
renovate_matches() {
  python3 -c '
import json, re, sys
pattern = json.load(open(sys.argv[1]))["customManagers"][0]["matchStrings"][0]
for m in re.finditer(pattern.replace("(?<", "(?P<"), open(sys.argv[2]).read()):
    print(" ".join(g for g in (m["depName"], m["currentValue"], m["currentDigest"]) if g))' "$1" "$2"
}

@test "renovate.json is one regex customManager over .claude-workspace.yaml, docker datasource, no fileMatch or hostRules" {
  run scaffold --member "$MEMBER_UI" --member "$MEMBER_API"
  [ "$status" -eq 0 ]
  local r="$REPO/renovate.json"
  cmp -s "$r" "$TEMPLATES/renovate.json"
  jq -e . "$r" >/dev/null
  # the EXACT key sets, so a key that switches Renovate off (`enabled: false`,
  # a disabling packageRules entry) cannot ride along unnoticed
  [ "$(jq -c 'keys' "$r")" = '["$schema","customManagers"]' ]
  [ "$(jq -c '.customManagers[0] | keys' "$r")" \
    = '["customType","datasourceTemplate","description","managerFilePatterns","matchStrings"]' ]
  [ "$(jq -c '.customManagers | length' "$r")" = "1" ]
  [ "$(jq -r '.customManagers[0] | [.customType, .datasourceTemplate, (.matchStrings | length | tostring)] | join(" ")' "$r")" \
    = "regex docker 1" ]
  [ "$(jq -c '.customManagers[0].managerFilePatterns' "$r")" = '["/(^|/)\\.claude-workspace\\.yaml$/"]' ]
  # Renovate 44 scopes with managerFilePatterns; fileMatch is the retired key.
  # The plain-http rule for a local registry belongs to a test fixture only.
  [ "$(jq -r '[.. | objects | keys[]] | map(select(. == "fileMatch" or . == "hostRules")) | length' "$r")" = "0" ]
}

@test "renovate.json's managerFilePatterns selects the manifest at any depth, and nothing named like it" {
  local pat
  pat="$(jq -r '.customManagers[0].managerFilePatterns[0]' "$TEMPLATES/renovate.json")"
  run python3 -c '
import re, sys
pattern = re.compile(sys.argv[1][1:-1])
for p in sys.argv[2:]:
    print(p, "true" if pattern.search(p) else "false")' "$pat" \
    .claude-workspace.yaml envs/eu/.claude-workspace.yaml \
    x.claude-workspace.yaml .claude-workspace.yaml.bak .claude-workspace.yml
  [ "$status" -eq 0 ]
  [ "$output" = ".claude-workspace.yaml true"$'\n'"envs/eu/.claude-workspace.yaml true"$'\n'"x.claude-workspace.yaml false"$'\n'".claude-workspace.yaml.bak false"$'\n'".claude-workspace.yml false" ]
}

@test "the regex matches the scaffolded image: lines, capturing depName and currentValue" {
  scaffold --member "$MEMBER_UI" --member "$MEMBER_API" >/dev/null
  run renovate_matches "$REPO/renovate.json" "$REPO/.claude-workspace.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/acme/orders-ui 2.3.1"$'\n'"ghcr.io/acme/orders-api 1.5.0" ]
}

@test "the regex matches every image: line form — plain, host:port, digest, quoted, trailing comment, adjacent" {
  local m="$BATS_TEST_TMPDIR/forms.yaml" d="sha256:$(printf 'b%.0s' {1..64})"
  cat >"$m" <<EOF
members:
  - name: plain
    image: ghcr.io/acme/orders-ui:2.3.1
  - name: port
    image: localhost:5000/acme/orders-api:1.5.0
  - name: digest
    image: localhost:5000/acme/orders-api:1.5.0@$d
  - name: double-quoted
    image: "localhost:5000/acme/orders-api:1.5.0"
  - name: single-quoted
    image: 'ghcr.io/acme/orders-ui:2.3.1'
  - name: commented
    image: localhost:5000/acme/orders-api:1.5.0  # pinned by hand
  - name: quoted-digest-commented
    image: "ghcr.io/acme/orders-api:1.5.0@$d" # both
  - name: image-last
    image: ghcr.io/acme/orders-ui:2.3.1
  - image: ghcr.io/acme/orders-api:1.5.1
    name: image-first-right-after
EOF
  run renovate_matches "$TEMPLATES/renovate.json" "$m"
  [ "$status" -eq 0 ]
  # neither quote nor comment is ever captured; the port is part of depName;
  # and an image: line directly after another is read too — a match never
  # consumes the newline the next line's anchor needs
  [ "$output" = "ghcr.io/acme/orders-ui 2.3.1"$'\n'"localhost:5000/acme/orders-api 1.5.0"$'\n'"localhost:5000/acme/orders-api 1.5.0 $d"$'\n'"localhost:5000/acme/orders-api 1.5.0"$'\n'"ghcr.io/acme/orders-ui 2.3.1"$'\n'"localhost:5000/acme/orders-api 1.5.0"$'\n'"ghcr.io/acme/orders-api 1.5.0 $d"$'\n'"ghcr.io/acme/orders-ui 2.3.1"$'\n'"ghcr.io/acme/orders-api 1.5.1" ]
}

@test "the regex reads CRLF manifests, capturing no carriage return" {
  local m="$BATS_TEST_TMPDIR/crlf.yaml"
  printf 'members:\r\n  - name: orders-api\r\n    image: ghcr.io/acme/orders-api:1.5.0\r\n' >"$m"
  run renovate_matches "$TEMPLATES/renovate.json" "$m"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/acme/orders-api 1.5.0" ]
}

@test "the regex never reads a registry port as a tag, a commented-out pin, or a key that only ends in image" {
  local m="$BATS_TEST_TMPDIR/near-misses.yaml"
  cat >"$m" <<'EOF'
members:
  - name: untagged
    image: localhost:5000/acme/orders-api
  - name: other-key
    base_image: ghcr.io/acme/base:1.0.0
  - name: hyphenated-key
    base-image: ghcr.io/acme/base:1.0.0
  - name: commented-out
    # image: ghcr.io/acme/old:1.0.0
  - name: in-a-value
    note: "image: ghcr.io/acme/old:1.0.0"
  - name: short-digest
    image: ghcr.io/acme/orders-api:1.0.0@sha256:abc
EOF
  run renovate_matches "$TEMPLATES/renovate.json" "$m"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the regex uses nothing RE2 refuses — no lookaround, no backreference" {
  # Renovate compiles matchStrings with RE2, which python3's re above is more
  # permissive than: a lookahead would pass every python3 case and be refused by
  # Renovate itself, which only the Docker-backed acceptance dry-run would see.
  local re
  re="$(jq -r '.customManagers[0].matchStrings[0]' "$TEMPLATES/renovate.json")"
  [ -n "$re" ]
  run grep -E '\(\?(=|!|<=|<!)|\\[1-9]|\\k<' <<<"$re"
  [ "$status" -eq 1 ]
}

# A skip is one line in place of renovate.json's, and nothing else changes: the
# rest of the skeleton is written and the validator's verdict still closes the
# output. $1 is the exact skip line expected.
assert_skipped_run() {
  local s="scaffold-composition.zsh"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$s: wrote .claude-workspace.yaml"$'\n'"$s: wrote .github/workflows/promote-to-prod.yml"$'\n'"$s: wrote scripts/promote.zsh"$'\n'"$s: wrote deploy/README.md"$'\n'"$s: wrote e2e/README.md"$'\n'"$s: wrote .maintenance.yml"$'\n'"$1"$'\n'"$s: claude-workspace/v1: $REPO/.claude-workspace.yaml is valid (1 members, 2 environments)" ] || return 1
  [ ! -e "$REPO/renovate.json" ] || return 1
  [ -x "$REPO/scripts/promote.zsh" ]
}

@test "renovate.json is skipped, never written, beside a Renovate config under another name" {
  local other
  for other in renovate.json5 .github/renovate.json .github/renovate.json5 .gitlab/renovate.json \
               .gitlab/renovate.json5 .renovaterc .renovaterc.json .renovaterc.json5; do
    rm -rf "$REPO" && mkdir -p "$(dirname "$REPO/$other")"
    printf '{ "extends": ["config:recommended"] }\n' >"$REPO/$other"
    run scaffold --member "$MEMBER_API"
    assert_skipped_run "scaffold-composition.zsh: skipped renovate.json (Renovate is configured in $other — add the image customManager from $TEMPLATES/renovate.json there)"
    [ "$(cat "$REPO/$other")" = '{ "extends": ["config:recommended"] }' ]
  done
}

@test "renovate.json is skipped beside a package.json that carries a renovate key, and only then" {
  printf '{ "name": "x", "renovate": { "extends": ["config:recommended"] } }\n' >"$REPO/package.json"
  run scaffold --member "$MEMBER_API"
  assert_skipped_run "scaffold-composition.zsh: skipped renovate.json (Renovate is configured in package.json — add the image customManager from $TEMPLATES/renovate.json there)"
  # a package.json WITHOUT the key configures nothing, so the file is written
  rm -rf "$REPO" && mkdir -p "$REPO"
  printf '{ "name": "x" }\n' >"$REPO/package.json"
  run scaffold --member "$MEMBER_API"
  [ "$status" -eq 0 ]
  contains "$output" "wrote renovate.json"
}

@test "renovate.json is skipped, never written, in a repo that runs Dependabot" {
  local dep
  for dep in .github/dependabot.yml .github/dependabot.yaml; do
    rm -rf "$REPO" && mkdir -p "$REPO/.github"
    printf 'version: 2\nupdates: []\n' >"$REPO/$dep"
    run scaffold --member "$MEMBER_API"
    assert_skipped_run "scaffold-composition.zsh: skipped renovate.json (Dependabot is configured in $dep — one dependency bot per repo; Dependabot cannot read .claude-workspace.yaml)"
  done
}

@test "a repo with both a Renovate config and Dependabot reports the Renovate config, once" {
  mkdir -p "$REPO/.github"
  printf '{}\n' >"$REPO/.github/renovate.json"
  printf 'version: 2\nupdates: []\n' >"$REPO/.github/dependabot.yml"
  run scaffold --member "$MEMBER_API"
  assert_skipped_run "scaffold-composition.zsh: skipped renovate.json (Renovate is configured in .github/renovate.json — add the image customManager from $TEMPLATES/renovate.json there)"
  [ "$(grep -c 'skipped renovate.json' <<<"$output")" = "1" ]
}

@test "an existing renovate.json is kept, never skipped, beside Dependabot or another Renovate config" {
  # kept wins over both skip reasons: the file is on disk, so §3m's report sees
  # `kept`, never `skipped` (beside Dependabot it says to remove Dependabot
  # before enabling Renovate)
  local other
  for other in .github/dependabot.yml .renovaterc; do
    rm -rf "$REPO" && mkdir -p "$REPO/.github"
    printf '{ "extends": ["config:recommended"] }\n' >"$REPO/renovate.json"
    case "$other" in
      .renovaterc) printf '{ "extends": ["config:recommended"] }\n' >"$REPO/$other" ;;
      *) printf 'version: 2\nupdates: []\n' >"$REPO/$other" ;;
    esac
    cp "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
    run scaffold --member "$MEMBER_API"
    [ "$status" -eq 0 ]
    contains "$output" "scaffold-composition.zsh: kept renovate.json (exists)"
    lacks "$output" "skipped renovate.json"
    cmp -s "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
  done
}

@test "an existing renovate.json is kept byte-identical, reported as kept, and the scaffold exits 0" {
  printf '{ "extends": ["config:recommended"] }\n' >"$REPO/renovate.json"
  cp "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
  run scaffold --member "$MEMBER_UI" --member "$MEMBER_API"
  [ "$status" -eq 0 ]
  contains "$output" "scaffold-composition.zsh: kept renovate.json (exists)"
  lacks "$output" "wrote renovate.json"
  cmp -s "$REPO/renovate.json" "$BATS_TEST_TMPDIR/before.json"
}

# ---------------------------------------------------------------------------
# The workflow
# ---------------------------------------------------------------------------

@test "push to main promotes staging; only workflow_dispatch on main promotes production, bound to its Environment" {
  [ "$(yq -r '.on.push.branches | join(" ")' "$WF_TMPL")" = "main" ]
  [ "$(yq -r '.on | keys | join(" ")' "$WF_TMPL")" = "push workflow_dispatch" ]
  [ "$(yq -r '.jobs | keys | join(" ")' "$WF_TMPL")" = "promote-staging promote-production" ]

  [ "$(yq -r '.jobs["promote-staging"].if' "$WF_TMPL")" = "github.event_name == 'push'" ]
  [ "$(yq -r '.jobs["promote-staging"].environment' "$WF_TMPL")" = "staging" ]
  [ "$(yq -r '.jobs["promote-production"].if' "$WF_TMPL")" \
    = "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'" ]
  [ "$(yq -r '.jobs["promote-production"].environment' "$WF_TMPL")" = "production" ]

  # each job promotes only its own environment, in its own mode
  [ "$(yq -r '.jobs["promote-staging"].steps[].run | select(. != null) | select(test("promote.zsh"))' "$WF_TMPL")" \
    = 'zsh scripts/promote.zsh --env staging --mode push --sha "$GITHUB_SHA"' ]
  [ "$(yq -r '.jobs["promote-production"].steps[].run | select(. != null) | select(test("promote.zsh"))' "$WF_TMPL")" \
    = 'zsh scripts/promote.zsh --env production --mode dispatch --sha "$GITHUB_SHA"' ]
}

@test "each job uploads its own environment's record, even when the hand-off fails" {
  local job env
  for job in promote-staging promote-production; do
    env="${job#promote-}"
    [ "$(yq -r ".jobs[\"$job\"].steps[] | select(.uses != null and (.uses | test(\"upload-artifact\"))) | [.if, .with.name, .with.path] | join(\" \")" "$WF_TMPL")" \
      = "\${{ !cancelled() }} promotion-$env promotion-$env.json" ]
  done
}

@test "promotions are serialised per environment, per job, and never cancelled half-way" {
  local job
  [ "$(yq -r 'has("concurrency")' "$WF_TMPL")" = "false" ]
  for job in promote-staging promote-production; do
    [ "$(yq -r ".jobs[\"$job\"].concurrency | .group + \" \" + (.[\"cancel-in-progress\"] | tostring)" "$WF_TMPL")" \
      = "$job false" ]
  done
}

@test "each job installs zsh and logs in to ghcr.io with packages: read before it promotes" {
  local job j
  for job in promote-staging promote-production; do
    j=".jobs[\"$job\"]"
    [ "$(yq -r "$j.permissions.packages" "$WF_TMPL")" = "read" ]
    # every step, in order: checkout, install, log in, promote, upload
    [ "$(yq -r "[$j.steps[] | (.uses // .name) | sub(\"@.*\"; \"\")] | join(\"|\")" "$WF_TMPL")" \
      = "actions/checkout|install zsh and yq|log in to ghcr.io|promote ${job#promote-}|actions/upload-artifact" ]
    contains "$(yq -r "$j.steps[1].run" "$WF_TMPL")" 'mikefarah/yq/releases/download/v${YQ_VERSION}'
    [ "$(yq -r "$j.steps[1].env.YQ_VERSION" "$WF_TMPL")" = "4.44.3" ]
    contains "$(yq -r "$j.steps[] | select(.name == \"install zsh and yq\") | .run" "$WF_TMPL")" \
      "apt-get install -y --no-install-recommends zsh"
    contains "$(yq -r "$j.steps[] | select(.name == \"log in to ghcr.io\") | .run" "$WF_TMPL")" "docker login ghcr.io"
  done
}

@test "every action is pinned to a full commit SHA with its tag comment" {
  local refs
  refs="$(grep -E '^\s*- uses:|^\s*uses:' "$WF_TMPL")"
  [ -n "$refs" ]
  run grep -vE 'uses: [a-z0-9_.-]+/[a-z0-9_.-]+@[0-9a-f]{40} # v[0-9]+$' <<<"$refs"
  [ "$status" -eq 1 ]
}

@test "the workflow passes actionlint and strict yamllint" {
  run actionlint "$WF_TMPL"
  [ "$status" -eq 0 ]
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$WF_TMPL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The promote script
# ---------------------------------------------------------------------------

@test "staging in push mode records every member at its digest plus the commit, says nothing deployed, exits 0" {
  scaffolded_repo
  run promote --env staging --mode push
  [ "$status" -eq 0 ]
  local r="$REPO/promotion-staging.json"
  [ "$(jq -r '[.environment, .commit, .trigger, .deploy_target, (.deployed | tostring)] | join(" ")' "$r")" \
    = "staging $SHA push none false" ]
  [ "$(jq -r '.members | map(.name + "=" + .image) | join(" ")' "$r")" \
    = "orders-ui=ghcr.io/acme/orders-ui:2.3.1@$D_UI orders-api=ghcr.io/acme/orders-api:1.5.0@$D_API" ]
  local notice="nothing deployed — deploy_target: none, no renderer (#719/#720)"
  contains "$output" "$notice"
  # the job summary is the record as a table, then the notice
  [ "$(cat "$BATS_TEST_TMPDIR/summary.md")" = "### Promotion record — \`staging\` @ \`$SHA\`"$'\n\n'"| member | image |"$'\n'"| --- | --- |"$'\n'"| orders-ui | \`ghcr.io/acme/orders-ui:2.3.1@$D_UI\` |"$'\n'"| orders-api | \`ghcr.io/acme/orders-api:1.5.0@$D_API\` |"$'\n\n'"**$notice**" ]
  # the digest is read with exactly the documented invocation, once per member
  [ "$(cat "$STUB_LOG")" = "buildx imagetools inspect ghcr.io/acme/orders-ui:2.3.1 --format {{.Manifest.Digest}}"$'\n'"buildx imagetools inspect ghcr.io/acme/orders-api:1.5.0 --format {{.Manifest.Digest}}" ]
}

@test "a push-mode promotion with no GITHUB_STEP_SUMMARY still succeeds and writes no summary" {
  scaffolded_repo
  run env -u GITHUB_STEP_SUMMARY PATH="$STUB_BIN:$PATH" zsh -c "cd '$REPO' && zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 0 ]
  contains "$output" "nothing deployed —"
  # the record, and nothing else, is added to the repository
  [ "$(cd "$REPO" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" = "./.claude-workspace.yaml ./.github/workflows/promote-to-prod.yml ./.maintenance.yml ./deploy/README.md ./e2e/README.md ./promotion-staging.json ./renovate.json ./scripts/promote.zsh " ]
}

@test "production in dispatch mode writes its record, then fails naming #719/#720" {
  scaffolded_repo
  run promote --env production --mode dispatch
  [ "$status" -eq 1 ]
  [ "$(jq -r '[.environment, .trigger, (.deployed | tostring)] | join(" ")' "$REPO/promotion-production.json")" \
    = "production dispatch false" ]
  contains "$output" "no deploy renderer present"
  contains "$output" "#719"
  contains "$output" "#720"
  contains "$(cat "$BATS_TEST_TMPDIR/summary.md")" "no deploy renderer present"
  lacks "$output" "nothing deployed —"
}

@test "a deploy_target other than none is refused after the record is written, in push mode too" {
  scaffolded_repo
  yq -i '.environments.staging.deploy_target = "compose"' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "deploy_target 'compose' has no renderer"
  contains "$(cat "$BATS_TEST_TMPDIR/summary.md")" "deploy_target 'compose' has no renderer"
  [ "$(jq -r '.deploy_target + " " + (.deployed | tostring)' "$REPO/promotion-staging.json")" = "compose false" ]
  lacks "$output" "nothing deployed —"
}

@test "a member pinned by digest is recorded with exactly one @sha256: suffix" {
  scaffold --member "$MEMBER_UI" --member "name=orders-api,repo=acme/orders-api,role=rest-api,contract=c.yaml,image=ghcr.io/acme/orders-api:1.5.0@$D_API" >/dev/null
  printf '%s %s\n' "ghcr.io/acme/orders-ui:2.3.1" "$D_UI" "ghcr.io/acme/orders-api:1.5.0" "$D_API" >"$STUB_DIGESTS"
  run promote --env staging --mode push
  [ "$status" -eq 0 ]
  local img
  img="$(jq -r '.members[] | select(.name == "orders-api") | .image' "$REPO/promotion-staging.json")"
  [ "$img" = "ghcr.io/acme/orders-api:1.5.0@$D_API" ]
  [ "$(grep -o '@sha256:' <<<"$img" | wc -l | tr -d ' ')" = "1" ]
  # the TAG was resolved, never the pinned ref
  lacks "$(cat "$STUB_LOG")" "@sha256"
}

@test "a pinned digest its tag no longer resolves to is refused, naming both" {
  scaffold --member "name=orders-api,repo=acme/orders-api,role=rest-api,contract=c.yaml,image=ghcr.io/acme/orders-api:1.5.0@$D_API" >/dev/null
  printf '%s %s\n' "ghcr.io/acme/orders-api:1.5.0" "$D_OTHER" >"$STUB_DIGESTS"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api'"
  contains "$output" "$D_API"
  contains "$output" "$D_OTHER"
  [ ! -e "$REPO/promotion-staging.json" ]
}

@test "an undeclared environment is refused, listing the declared ones, before any digest lookup" {
  scaffolded_repo
  run promote --env qa --mode push
  [ "$status" -eq 1 ]
  contains "$output" "environment 'qa' is not declared"
  contains "$output" "declared: staging, production"
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$REPO/promotion-qa.json" ]
}

@test "an untagged member is refused before any digest lookup" {
  scaffolded_repo
  yq -i '.members[1].image = "localhost:5000/acme/orders-api"' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api'"
  contains "$output" "carries no tag"
  [ ! -s "$STUB_LOG" ]
}

@test "a manifest with no members is refused before any lookup and writes no record" {
  scaffolded_repo
  yq -i '.members = []' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "declares no members"
  [ ! -s "$STUB_LOG" ]
  [ ! -e "$REPO/promotion-staging.json" ]
}

@test "a manifest that is not YAML is refused with exit 1 before any lookup" {
  scaffolded_repo
  printf 'members: [unclosed\n' >"$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "could not parse"
  [ ! -s "$STUB_LOG" ]
}

@test "a manifest of more than one YAML document is refused with exit 1" {
  scaffolded_repo
  printf -- '---\nmembers: []\n' >>"$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "exactly one YAML document"
}

@test "a members value that is not a list is refused with exit 1 before any lookup" {
  scaffolded_repo
  yq -i '.members = "orders-api"' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "declares no members list"
  [ ! -s "$STUB_LOG" ]
}

@test "a member that is not a mapping with a string image is refused with exit 1" {
  scaffolded_repo
  yq -i '.members[1].image = {"ref": "ghcr.io/acme/orders-api:1.5.0"}' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "every member must be a mapping with a string name and image"
  [ ! -s "$STUB_LOG" ]
}

@test "a member on any floating tag is refused before any lookup" {
  local tag
  for tag in latest stable edge main master; do
    rm -rf "$REPO" && mkdir -p "$REPO" && : >"$STUB_LOG"
    scaffolded_repo
    yq -i ".members[1].image = \"ghcr.io/acme/orders-api:$tag\"" "$REPO/.claude-workspace.yaml"
    run promote --env staging --mode push
    [ "$status" -eq 1 ]
    contains "$output" "floating tag ':$tag'"
    [ ! -s "$STUB_LOG" ]
  done
}

@test "a member with a non-string name is refused with exit 1" {
  scaffolded_repo
  yq -i '.members[1].name = 7' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 1 ]
  contains "$output" "every member must be a mapping with a string name and image"
  [ ! -s "$STUB_LOG" ]
}

@test "a malformed image — interior space, no name, a digest that is not one — is refused before any lookup" {
  local img
  for img in "ghcr.io/acme/orders-api:1.5 .0" "ghcr.io/acme/:1.5.0" "ghcr.io/acme/orders-api:1.5.0@sha256:ABC" "ghcr.io/acme/orders-api:1.5.0@"; do
    rm -rf "$REPO" && mkdir -p "$REPO" && : >"$STUB_LOG"
    scaffolded_repo
    yq -i ".members[1].image = \"$img\"" "$REPO/.claude-workspace.yaml"
    run promote --env staging --mode push
    [ "$status" -eq 1 ]
    contains "$output" "is not image:tag with an optional @sha256:<64 hex> digest"
    [ ! -s "$STUB_LOG" ]
  done
}

@test "a padded image is read trimmed, as the contract reads it" {
  scaffolded_repo
  yq -i '.members[1].image = "  ghcr.io/acme/orders-api:1.5.0  "' "$REPO/.claude-workspace.yaml"
  run promote --env staging --mode push
  [ "$status" -eq 0 ]
  [ "$(jq -r '.members[1].image' "$REPO/promotion-staging.json")" = "ghcr.io/acme/orders-api:1.5.0@$D_API" ]
}

@test "a record that cannot be written is exit 3" {
  scaffolded_repo
  mkdir "$REPO/promotion-staging.json"      # a directory where the record goes — fails even as root
  run promote --env staging --mode push
  [ "$status" -eq 3 ]
  contains "$output" "could not write"
}

@test "a non-writable --out-dir is exit 3" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory modes"
  scaffolded_repo
  mkdir -p "$BATS_TEST_TMPDIR/ro" && chmod 0555 "$BATS_TEST_TMPDIR/ro"
  run promote --env staging --mode push --out-dir "$BATS_TEST_TMPDIR/ro"
  chmod 0755 "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 3 ]
  contains "$output" "is not writable"
}

@test "a missing manifest is refused with exit 1" {
  scaffolded_repo
  run promote --env staging --mode push --manifest absent.yaml
  [ "$status" -eq 1 ]
  contains "$output" "manifest not found or not readable: absent.yaml"
}

@test "a digest that cannot be resolved is exit 3, quoting docker's error, and writes no record" {
  scaffolded_repo
  printf '%s %s\n' "ghcr.io/acme/orders-ui:2.3.1" "$D_UI" >"$STUB_DIGESTS"
  run promote --env staging --mode push
  [ "$status" -eq 3 ]
  contains "$output" "member 'orders-api': could not resolve"
  contains "$output" "stub: manifest unknown for ghcr.io/acme/orders-api:1.5.0"
  [ ! -e "$REPO/promotion-staging.json" ]
}

@test "a resolved value that is not exactly a sha256 digest is exit 3" {
  scaffolded_repo
  printf '%s %s\n' "ghcr.io/acme/orders-ui:2.3.1" "$D_UI" "ghcr.io/acme/orders-api:1.5.0" "${D_API}junk" >"$STUB_DIGESTS"
  run promote --env staging --mode push
  [ "$status" -eq 3 ]
  contains "$output" "not a sha256 digest"
  [ ! -e "$REPO/promotion-staging.json" ]
}

@test "a missing docker is exit 3" {
  scaffolded_repo
  local stub
  stub="$(stub_path_with yq jq zsh)"
  run env PATH="$stub" /bin/zsh -c "cd '$REPO' && /bin/zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: docker"
}

@test "a missing jq is exit 3 for promote" {
  scaffolded_repo
  local stub
  stub="$(stub_path_with yq zsh)"
  ln -s "$STUB_BIN/docker" "$stub/docker"
  run env PATH="$stub" /bin/zsh -c "cd '$REPO' && /bin/zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: jq"
}

@test "promote accepts an older mikefarah yq and refuses a v3 one as not mikefarah's" {
  scaffolded_repo
  local stub real
  real="$(command -v yq)"
  stub="$(stub_path_with jq zsh)"
  ln -s "$STUB_BIN/docker" "$stub/docker"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "yq version 4.20.2"; exit 0; }\nexec "%s" "$@"\n' "$real" >"$stub/yq"
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh -c "cd '$REPO' && /bin/zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 0 ]
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "yq version 3.4.3"; exit 0; }\nexec "%s" "$@"\n' "$real" >"$stub/yq"
  run env PATH="$stub" /bin/zsh -c "cd '$REPO' && /bin/zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"
}

@test "an environment that is not a mapping with a deploy_target is refused before any lookup" {
  local edit
  for edit in '.environments.staging = "production"' '.environments.staging = null' \
              'del(.environments.staging.deploy_target)' '.environments.staging.deploy_target = 7'; do
    rm -rf "$REPO" && mkdir -p "$REPO" && : >"$STUB_LOG"
    scaffolded_repo
    yq -i "$edit" "$REPO/.claude-workspace.yaml"
    run promote --env staging --mode push
    [ "$status" -eq 1 ]
    contains "$output" "environment 'staging' is not declared, as a mapping with a deploy_target"
    [ ! -s "$STUB_LOG" ]
    [ ! -e "$REPO/promotion-staging.json" ]
  done
}

@test "a yq that is not mikefarah's is exit 3 for promote, not an unparsable manifest" {
  scaffolded_repo
  local stub
  stub="$(stub_path_with jq zsh)"
  ln -s "$STUB_BIN/docker" "$stub/docker"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "yq 3.4.3"; exit 0; }\nexit 2\n' >"$stub/yq"
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh -c "cd '$REPO' && /bin/zsh scripts/promote.zsh --sha $SHA --env staging --mode push"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"
}

@test "--manifest and --out-dir are honoured" {
  scaffolded_repo
  mv "$REPO/.claude-workspace.yaml" "$BATS_TEST_TMPDIR/elsewhere.yaml"
  mkdir -p "$BATS_TEST_TMPDIR/out"
  run promote --env staging --mode push --manifest "$BATS_TEST_TMPDIR/elsewhere.yaml" --out-dir "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/out/promotion-staging.json" ]
  [ ! -e "$REPO/promotion-staging.json" ]
}

@test "the commit defaults to GITHUB_SHA, then to HEAD" {
  scaffolded_repo
  run env GITHUB_SHA="$SHA" GITHUB_STEP_SUMMARY=/dev/null PATH="$STUB_BIN:$PATH" \
    zsh -c "cd '$REPO' && zsh scripts/promote.zsh --env staging --mode push"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.commit' "$REPO/promotion-staging.json")" = "$SHA" ]

  git -C "$REPO" init -q
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  run env -u GITHUB_SHA GITHUB_STEP_SUMMARY=/dev/null PATH="$STUB_BIN:$PATH" \
    zsh -c "cd '$REPO' && zsh scripts/promote.zsh --env staging --mode push"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.commit' "$REPO/promotion-staging.json")" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "no --sha, no GITHUB_SHA and no git checkout is a usage error" {
  scaffolded_repo
  run env -u GITHUB_SHA GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" PATH="$STUB_BIN:$PATH" \
    zsh -c "cd '$REPO' && zsh scripts/promote.zsh --env staging --mode push"
  [ "$status" -eq 2 ]
  contains "$output" "no commit to record"
}

@test "a --sha that is not exactly 40 hex characters is a usage error" {
  scaffolded_repo
  run promote --env staging --mode push --sha abc123
  [ "$status" -eq 2 ]
  contains "$output" "40-character"
  run promote --env staging --mode push --sha "${SHA}0"
  [ "$status" -eq 2 ]
}

@test "the promote script's argument errors are exit 2" {
  scaffolded_repo
  run promote --env staging --mode merge
  [ "$status" -eq 2 ]
  contains "$output" "--mode must be push or dispatch"
  run promote --mode push
  [ "$status" -eq 2 ]
  contains "$output" "--env is required"
  run promote --env --mode push
  [ "$status" -eq 2 ]
  contains "$output" "--env needs a value"
  run promote --env staging --mode push --bogus
  [ "$status" -eq 2 ]
  contains "$output" "unknown argument: --bogus"
  run promote --env staging --mode push --out-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  contains "$output" "is not a directory"
}

# ---------------------------------------------------------------------------
# Bootstrap's §3m
# ---------------------------------------------------------------------------

# §3m, END-ANCHORED on the next heading of any level so a deleted section cannot
# borrow needles from the rest of the file
section_3m() {
  sed -n '/^### 3m\. Composition repos/,/^##/{/^### 3m\./!{/^##/q;};p;}' "$SKILL" | tr -s '[:space:]' ' '
}

@test "bootstrap §3m runs the composition scaffold and branches on every validator exit" {
  local s
  s="$(section_3m)"
  [ -n "$s" ]
  contains "$s" 'zsh "<development-composition-root>/scripts/scaffold-composition.zsh" --repo .'
  contains "$s" '| `0` | the scaffold is complete and valid — continue |'
  contains "$s" '| `1` | **fail the run**, quoting the named error'
  contains "$s" '| `4` | **fail the run** — the validator could not read the manifest'
  contains "$s" '| `2` | your own malformed invocation: fix the command and re-run **once**'
  contains "$s" '| `3` | the environment failed — escalate it'
  contains "$s" '| any other | treat as `3` |'
  # #1746: the Renovate config is in the promised file set, and an install
  # too old to write it is refused rather than run
  contains "$s" '`.maintenance.yml` (`primary: composition`) and `renovate.json` (a regex custom manager'
  contains "$s" 'no `templates/renovate.json` (older than #1746'
  contains "$s" 'the seven files the scaffold writes'
  # …and the plan and report never promise or enable what the scaffold skipped
  contains "$s" '**Promise `renovate.json` only where the scaffold will write it.**'
  contains "$s" '**when the scaffold printed `wrote renovate.json` or `kept renovate.json`**'
  contains "$s" 'never tell the user to enable Renovate while a Dependabot config stays'
  # …in EVERY case, a kept renovate.json beside Dependabot included — not only
  # inside the skipped-file branch
  contains "$s" '**Whatever the scaffold printed for `renovate.json`** — a kept one beside `.github/dependabot.y(a)ml` included — never tell the user'
  contains "$s" "never report a scaffold as complete without the exit \`0\` that judged it"
  contains "$s" "Entry is the user's request, never detection"
  contains "$s" "**When it already exists, do not ask**"
  contains "$s" "never point the user at \`branch-protection.sh\` here"
  # and Step 1 sends a composition run there before detection
  contains "$(sed -n '/^## Step 1: Detect Repo State/,/^Run the stack detection/p' "$SKILL" | tr -s '[:space:]' ' ')" "read §3m first"
}
