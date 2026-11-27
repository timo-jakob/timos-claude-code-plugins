#!/usr/bin/env bats
#
# Acceptance cases for "include the platform UI styleguide in web UI repos"
# (#3016) — the `cli`-tooled test_cases[] of its story-spec, one test per `tc-*`
# id:
#
#   tc-happy-add-pins-latest-tag                  #3359
#   tc-corner-semver-order-ignores-prerelease     #3360
#   tc-happy-claude-md-section-once               #3361
#   tc-happy-dependabot-gitsubmodule-entry        #3362
#   tc-happy-react-variants-ignore-styleguide     #3363
#   tc-corner-rerun-is-noop                       #3364
#   tc-corner-no-url-skips-naming-flag            #3365
#   tc-corner-web-ui-without-react-not-triggered  #3366
#   tc-corner-swiftui-app-not-triggered           #3367
#   tc-error-unreachable-url                      #3368
#   tc-error-no-release-tag                       #3369
#   tc-error-styleguide-dir-not-a-submodule       #3370
#
# The use case: timo-platform-builder bootstraps a create-vite `react-ts` app in a
# private platform repo with `--styleguide-repo <url>` and gets the shared UI
# styleguide mounted, pinned and bound in CLAUDE.md without wiring it by hand.
# The styleguide remote is a local fixture shaped like the real one — tags
# v0.1.0 and v0.1.1, STYLEGUIDE.md, CHECKLIST.md, tokens/ and node:test suites —
# so no network is touched. What runs for real: styleguide-submodule.zsh,
# render.zsh and detect-stack.sh. The default gate's
# tests/bootstrap-styleguide-submodule.bats covers the same criteria clause by
# clause.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BS="$REPO_ROOT/development/skills/bootstrap"
  STEP="$BS/scripts/styleguide-submodule.zsh"
  RENDER="$BS/scripts/render.zsh"
  DETECT="$BS/scripts/detect-stack.sh"
  TEMPLATES="$BS/templates"
  RX="$TEMPLATES/languages/javascript/react"
  W="$BATS_TEST_TMPDIR"
  printf '[user]\n\tname = Platform Builder\n\temail = builder@example.invalid\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$W/gitconfig"
  export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
}

# The styleguide remote: one release commit per tag given, then unreleased work on main.
styleguide_remote() {
  local dir="$W/timos-platform-styleguide" t
  git init -q "$dir"
  mkdir -p "$dir/tokens" "$dir/tests"
  for t in "$@"; do
    printf '# Platform UI styleguide %s\n\nMaterial Design 3 usage rules, WCAG 2.2 AA.\n' "$t" > "$dir/STYLEGUIDE.md"
    printf -- '- [ ] contrast meets WCAG 2.2 AA (%s)\n' "$t" > "$dir/CHECKLIST.md"
    printf ':root { --platform-space-2: 8px; }\n' > "$dir/tokens/tokens.css"
    printf '{"space":{"2":"8px"}}\n' > "$dir/tokens/tokens.json"
    printf 'import test from "node:test";\ntest("tokens", () => {});\n' > "$dir/tests/tokens.test.mjs"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "release $t"
    git -C "$dir" tag "$t"
  done
  printf '# unreleased\n' > "$dir/STYLEGUIDE.md"
  git -C "$dir" commit -qam "unreleased work"
  printf "%s\n" "$dir"
}

# A create-vite react-ts app, committed; $1 is an optional CLAUDE.md.
react_app() {
  local app="$W/dashboard-frontend"
  git init -q "$app"
  printf '{"name":"dashboard-frontend","private":true,"dependencies":{"react":"19.1.0","react-dom":"19.1.0"}}\n' > "$app/package.json"
  printf 'import { defineConfig } from "vite";\nexport default defineConfig({});\n' > "$app/vite.config.ts"
  [ -z "${1-}" ] || printf '%s' "$1" > "$app/CLAUDE.md"
  git -C "$app" add -A
  git -C "$app" commit -qm "create-vite react-ts"
  printf '%s\n' "$app"
}

worktree_state() {
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s\n' "$f"
    [ -f "$f" ] && cat "$f"
  done)
}

@test "tc-happy-add-pins-latest-tag (#3359)" {
  local sg app
  sg="$(styleguide_remote v0.1.0)"
  app="$(react_app)"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: added $sg at v0.1.0" ]
  [ "$(git -C "$app/styleguide" rev-parse HEAD)" = "$(git -C "$sg" rev-parse 'v0.1.0^{commit}')" ]
  [ "$(git -C "$app" config -f .gitmodules submodule.styleguide.path)" = styleguide ]
  [ "$(git -C "$app" config -f .gitmodules submodule.styleguide.url)" = "$sg" ]
  run grep -c 'branch' "$app/.gitmodules"
  [ "$output" = 0 ]
  [ "$(git -C "$app" diff --cached --name-only | tr '\n' ' ')" = ".gitmodules styleguide " ]
  [ "$(git -C "$app" rev-list --count HEAD)" -eq 1 ]
}

@test "tc-corner-semver-order-ignores-prerelease (#3360)" {
  local sg app
  sg="$(styleguide_remote v0.1.0 v0.9.0 v0.10.0 v1.0.0-rc.1 nightly)"
  app="$(react_app)"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 0 ]
  ends_with "$output" " at v0.10.0"
  local head
  head="$(git -C "$app/styleguide" rev-parse HEAD)"
  [ "$head" = "$(git -C "$sg" rev-parse 'v0.10.0^{commit}')" ]
  [ "$head" != "$(git -C "$sg" rev-parse 'v0.9.0^{commit}')" ]
  [ "$head" != "$(git -C "$sg" rev-parse 'v1.0.0-rc.1^{commit}')" ]
  [ "$head" != "$(git -C "$sg" rev-parse main)" ]
}

@test "tc-happy-claude-md-section-once (#3361)" {
  local sg app prior=$'# dashboard-frontend\n\nUse the shared query client; never fetch in useEffect.\n'
  sg="$(styleguide_remote v0.1.0 v0.1.1)"
  app="$(react_app "$prior")"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 0 ]
  local f="$app/CLAUDE.md"
  head -c "$(printf '%s' "$prior" | wc -c)" "$f" | cmp -s - <(printf '%s' "$prior")
  [ "$(grep '^## ' "$f" | tail -n 1)" = "## Read the styleguide before UI changes" ]
  contains "$(cat "$f")" 'styleguide/STYLEGUIDE.md'
  contains "$(cat "$f")" 'styleguide/CHECKLIST.md'
  cp "$f" "$W/first"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 0 ]
  cmp -s "$f" "$W/first"
  [ "$(grep -cx '## Read the styleguide before UI changes' "$f")" -eq 1 ]
}

@test "tc-happy-dependabot-gitsubmodule-entry (#3362)" {
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$W/out" --languages javascript --styleguide true \
    common/.github/dependabot.yml.tmpl
  [ "$status" -eq 0 ]
  local d="$W/out/common/.github/dependabot.yml"
  [ "$(grep -cF 'package-ecosystem: "gitsubmodule"' "$d")" -eq 1 ]
  [ "$(yq -r '.updates[] | select(.["package-ecosystem"] == "gitsubmodule") | .directory' "$d")" = / ]
  [ "$(yq -r '.updates[] | select(.["package-ecosystem"] == "gitsubmodule") | .schedule.interval' "$d")" = weekly ]
  if command -v yamllint >/dev/null; then
    run yamllint -c "$REPO_ROOT/.yamllint" "$d"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  fi
}

@test "tc-happy-react-variants-ignore-styleguide (#3363)" {
  local v cfg
  for v in plain consumer; do
    cfg=languages/javascript/react
    [ "$v" = consumer ] && cfg="$cfg/contract-consumer"
    run zsh "$RENDER" --templates "$TEMPLATES" --out "$W/$v" --vite-config-file vite.config.ts \
      "$cfg/eslint.config.js" "$cfg/vitest.config.ts"
    [ "$status" -eq 0 ]
    grep -qF '{ ignores: ["styleguide/"] },' "$W/$v/$cfg/eslint.config.js"
    grep -qF '"styleguide/**"' "$W/$v/$cfg/vitest.config.ts"
  done
  # an existing .prettierignore keeps its lines; styleguide/ follows them
  printf 'dist/\ncoverage/\n' > "$W/.prettierignore"
  bash "$BS/scripts/merge-gitignore.sh" "$W/.prettierignore" "$RX/prettierignore" >> "$W/.prettierignore"
  [ "$(head -n 2 "$W/.prettierignore")" = $'dist/\ncoverage/' ]
  [ "$(grep -cx 'styleguide/' "$W/.prettierignore")" -eq 1 ]
}

@test "tc-corner-rerun-is-noop (#3364)" {
  local sg app
  sg="$(styleguide_remote v0.1.0)"
  app="$(react_app $'# app\n')"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 0 ]
  git -C "$app" add -A
  git -C "$app" commit -qm bootstrap
  local before pin
  before="$(worktree_state "$app")"
  pin="$(git -C "$app/styleguide" rev-parse HEAD)"
  # the remote is gone: any contact would fail
  rm -rf "$sg"
  run zsh "$STEP" --repo "$app" --url "$W/unreachable-styleguide"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: present" ]
  [ "$(worktree_state "$app")" = "$before" ]
  [ "$(git -C "$app/styleguide" rev-parse HEAD)" = "$pin" ]
}

@test "tc-corner-no-url-skips-naming-flag (#3365)" {
  local app
  app="$(react_app $'# app\n')"
  run zsh "$STEP" --repo "$app"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: skipped — no repository supplied; pass --styleguide-repo <url>" ]
  [ ! -e "$app/styleguide" ]
  [ ! -e "$app/.gitmodules" ]
  lacks "$(cat "$app/CLAUDE.md")" 'Read the styleguide'
}

@test "tc-corner-web-ui-without-react-not-triggered (#3366)" {
  mkdir -p "$W/flask" "$W/jslib"
  printf '[project]\nname = "ops-portal"\nversion = "0.1.0"\ndependencies = ["flask>=3", "jinja2>=3"]\n' > "$W/flask/pyproject.toml"
  printf '{"name":"date-utils","dependencies":{"date-fns":"4.1.0"}}\n' > "$W/jslib/package.json"
  local d
  for d in flask jslib; do
    [ "$(cd "$W/$d" && bash "$DETECT" 2>/dev/null | jq -c .is_react)" = false ] || { echo "$d"; false; }
  done
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$W/out" --languages "python javascript" \
    common/.github/dependabot.yml.tmpl common/CLAUDE.md.tmpl
  [ "$status" -eq 0 ]
  run grep -c gitsubmodule "$W/out/common/.github/dependabot.yml"
  [ "$output" = 0 ]
  lacks "$(cat "$W/out/common/CLAUDE.md")" '## Read the styleguide before UI changes'
}

@test "tc-corner-swiftui-app-not-triggered (#3367)" {
  mkdir -p "$W/swiftui"
  printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Gallery")\n' > "$W/swiftui/Package.swift"
  [ "$(cd "$W/swiftui" && bash "$DETECT" 2>/dev/null | jq -c .is_react)" = false ]
  run zsh "$RENDER" --templates "$TEMPLATES" --out "$W/out" --languages swift \
    common/.github/dependabot.yml.tmpl common/CLAUDE.md.tmpl
  [ "$status" -eq 0 ]
  run grep -c gitsubmodule "$W/out/common/.github/dependabot.yml"
  [ "$output" = 0 ]
  lacks "$(cat "$W/out/common/CLAUDE.md")" 'styleguide'
}

@test "tc-error-unreachable-url (#3368)" {
  local app before porcelain
  app="$(react_app $'# app\n')"
  before="$(worktree_state "$app")"
  porcelain="$(git -C "$app" status --porcelain)"
  run zsh "$STEP" --repo "$app" --url "$W/no-repository-here"
  [ "$status" -eq 1 ]
  [ "$output" = "styleguide: failed — $W/no-repository-here: unreachable" ]
  [ "$(worktree_state "$app")" = "$before" ]
  [ "$(git -C "$app" status --porcelain)" = "$porcelain" ]
}

@test "tc-error-no-release-tag (#3369)" {
  local sg app before
  sg="$(styleguide_remote nightly v1.0.0-rc.1)"
  app="$(react_app $'# app\n')"
  before="$(worktree_state "$app")"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 1 ]
  [ "$output" = "styleguide: failed — $sg: no vX.Y.Z tag" ]
  [ "$(worktree_state "$app")" = "$before" ]
  [ ! -e "$app/styleguide" ]
}

@test "tc-error-styleguide-dir-not-a-submodule (#3370)" {
  local sg app before
  sg="$(styleguide_remote v0.1.0)"
  app="$(react_app)"
  mkdir "$app/styleguide"
  printf 'our design notes\n' > "$app/styleguide/notes.md"
  git -C "$app" add -A
  git -C "$app" commit -qm notes
  before="$(worktree_state "$app")"
  run zsh "$STEP" --repo "$app" --url "$sg"
  [ "$status" -eq 1 ]
  [ "$output" = "styleguide: failed — $sg: styleguide/ exists and is not a submodule" ]
  [ "$(worktree_state "$app")" = "$before" ]
  [ ! -e "$app/.gitmodules" ]
}
