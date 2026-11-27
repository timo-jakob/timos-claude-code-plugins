#!/usr/bin/env bats
#
# The styleguide step of /development:bootstrap (#3016): a React repo mounts a
# user-supplied UI styleguide repository as the `styleguide/` submodule, pinned to
# its highest vX.Y.Z tag, bound in CLAUDE.md, and bumped by one Dependabot
# `gitsubmodule` entry. The script styleguide-submodule.zsh runs here for real,
# against local fixture remotes (no network); the render and SKILL.md halves are
# pinned clause by clause.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BS="$REPO_ROOT/development/skills/bootstrap"
  SCRIPT="$BS/scripts/styleguide-submodule.zsh"
  RENDER="$BS/scripts/render.zsh"
  TEMPLATES="$BS/templates"
  SKILL="$BS/SKILL.md"
  TMPL="$TEMPLATES/common/CLAUDE.md.tmpl"
  W="$BATS_TEST_TMPDIR"
  # an isolated git: no signing, a fixed identity, and the file protocol a
  # local submodule remote needs (git refuses it by default since 2.38.1)
  printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$W/gitconfig"
  export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
}

# A styleguide remote at $1 carrying one commit per tag in $2..., then a commit
# past the last tag on main (the branch head a fallback would pick).
make_remote() {
  local dir="$1" t
  shift
  git init -q "$dir"
  for t in "$@"; do
    printf '%s\n' "$t" > "$dir/STYLEGUIDE.md"
    printf 'checklist %s\n' "$t" > "$dir/CHECKLIST.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "release $t"
    git -C "$dir" tag "$t"
  done
  printf 'unreleased\n' > "$dir/STYLEGUIDE.md"
  git -C "$dir" commit -qam "unreleased work"
}

# A React app repo at $1 with one commit (and $2 as its CLAUDE.md, when given).
make_app() {
  git init -q "$1"
  printf '{"name":"app","dependencies":{"react":"19.0.0"}}\n' > "$1/package.json"
  [ -z "${2-}" ] || printf '%s' "$2" > "$1/CLAUDE.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

# Every file under $1 but .git, with its content, as one comparable listing.
tree_state() {
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s\n' "$f"
    cat "$f"
  done)
}

tagged_commit() { git -C "$1" rev-parse "refs/tags/$2^{commit}"; }

# --- the add -------------------------------------------------------------------

@test "styleguide: pins the highest vX.Y.Z tag, writes .gitmodules without a branch line, stages and never commits" {
  make_remote "$W/sg" v0.1.0 v0.9.0 v0.10.0 v1.0.0-rc.1 nightly
  make_app "$W/app"
  local head_before
  head_before="$(git -C "$W/app" rev-parse HEAD)"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: added $W/sg at v0.10.0" ]
  # checked out at v0.10.0's commit: not v0.9.0, not the rc, not nightly, not main
  [ "$(git -C "$W/app/styleguide" rev-parse HEAD)" = "$(tagged_commit "$W/sg" v0.10.0)" ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.styleguide.path)" = styleguide ]
  [ "$(git -C "$W/app" config -f .gitmodules submodule.styleguide.url)" = "$W/sg" ]
  run git -C "$W/app" config -f .gitmodules --get-regexp 'branch'
  [ "$status" -eq 1 ]
  [ "$(grep -c '^\[submodule "styleguide"\]$' "$W/app/.gitmodules")" -eq 1 ]
  # staged — the gitlink at the tag's commit — and no commit made
  run git -C "$W/app" diff --cached --name-only
  [ "$output" = $'.gitmodules\nstyleguide' ]
  [ "$(git -C "$W/app" ls-files -s styleguide | awk '{print $1, $2}')" = "160000 $(tagged_commit "$W/sg" v0.10.0)" ]
  [ "$(git -C "$W/app" rev-parse HEAD)" = "$head_before" ]
}

@test "styleguide: an annotated release tag pins its commit, not the tag object" {
  make_remote "$W/sg" v0.1.0
  git -C "$W/sg" tag -a v0.2.0 -m "annotated" HEAD
  make_app "$W/app"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: added $W/sg at v0.2.0" ]
  [ "$(git -C "$W/app/styleguide" rev-parse HEAD)" = "$(tagged_commit "$W/sg" v0.2.0)" ]
}

@test "styleguide: the semver order is numeric per field (v1.10.0 beats v1.2.0 and v0.99.99)" {
  make_remote "$W/sg" v1.2.0 v1.10.0 v0.99.99
  make_app "$W/app"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  ends_with "$output" " at v1.10.0"
}

# --- CLAUDE.md -----------------------------------------------------------------

@test "styleguide: an existing CLAUDE.md gets the section appended once, its prior bytes an unchanged prefix" {
  make_remote "$W/sg" v0.1.0
  local prior=$'# Our agent rules\n\nKeep PRs small.'
  make_app "$W/app" "$prior"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  local f="$W/app/CLAUDE.md" n
  n="$(printf '%s' "$prior" | wc -c | tr -d ' ')"
  [ "$(head -c "$n" "$f")" = "$prior" ]
  [ "$(grep -cx '## Read the styleguide before UI changes' "$f")" -eq 1 ]
  contains "$(cat "$f")" 'styleguide/STYLEGUIDE.md'
  contains "$(cat "$f")" 'styleguide/CHECKLIST.md'
  # only the section is appended: no block markers, no other template section
  lacks "$(cat "$f")" 'STYLEGUIDE-START'
  lacks "$(cat "$f")" '## Who decides what'
  # a second run is byte-identical
  cp "$f" "$W/after-first"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: present" ]
  cmp -s "$f" "$W/after-first"
}

@test "styleguide: the appended section is the template's section, byte for byte" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app" $'# Ours\n'
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  local want got
  want="$(awk '$0 == "## Read the styleguide before UI changes" {on=1} on && /^<!-- --- STYLEGUIDE-END/ {exit} on {print}' "$TMPL")"
  got="$(awk '$0 == "## Read the styleguide before UI changes" {on=1} on {print}' "$W/app/CLAUDE.md")"
  [ -n "$want" ]
  [ "$got" = "$want" ]
}

@test "styleguide: with no CLAUDE.md the script writes none (the render carries the section)" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  [ ! -e "$W/app/CLAUDE.md" ]
}

# --- present: the re-run --------------------------------------------------------

@test "styleguide: a re-run with the submodule contacts no remote, ignores --url and changes no byte" {
  make_remote "$W/sg" v0.1.0 v0.2.0
  make_app "$W/app" $'# Ours\n'
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  git -C "$W/app" add -A
  git -C "$W/app" commit -qm "bootstrap"
  # a newer release exists now; the pin must not follow it
  git -C "$W/sg" tag v0.3.0
  cp "$W/app/.gitmodules" "$W/gm" && cp "$W/app/CLAUDE.md" "$W/cm"
  local pin
  pin="$(git -C "$W/app/styleguide" rev-parse HEAD)"
  # a logging git proves no ls-remote / fetch / clone ran
  local real
  real="$(command -v git)"
  mkdir -p "$W/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$W" "$real" > "$W/bin/git"
  chmod +x "$W/bin/git"
  PATH="$W/bin:$PATH" run zsh "$SCRIPT" --repo "$W/app" --url "$W/no-such-remote"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: present" ]
  [ -f "$W/git.log" ]
  run grep -E 'ls-remote|fetch|clone|submodule (add|update)' "$W/git.log"
  [ "$status" -eq 1 ]
  cmp -s "$W/app/.gitmodules" "$W/gm"
  cmp -s "$W/app/CLAUDE.md" "$W/cm"
  [ "$(git -C "$W/app/styleguide" rev-parse HEAD)" = "$pin" ]
  [ -z "$(git -C "$W/app" status --porcelain)" ]
}

@test "styleguide: present fills a missing CLAUDE.md section and nothing else" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app" $'# Ours\n'
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 0 ]
  printf '# Ours\n' > "$W/app/CLAUDE.md"
  run zsh "$SCRIPT" --repo "$W/app"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: present" ]
  [ "$(grep -cx '## Read the styleguide before UI changes' "$W/app/CLAUDE.md")" -eq 1 ]
}

@test "styleguide: a .gitmodules declaring the submodule under another name still reads as present" {
  make_app "$W/app"
  printf '[submodule "ui"]\n\tpath = styleguide\n\turl = %s\n' "$W/no-such-remote" > "$W/app/.gitmodules"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/no-such-remote"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: present" ]
}

# --- skipped --------------------------------------------------------------------

@test "styleguide: no URL skips the step in one line naming --styleguide-repo, writing nothing" {
  make_app "$W/app" $'# Ours\n'
  local before
  before="$(tree_state "$W/app")"
  run zsh "$SCRIPT" --repo "$W/app"
  [ "$status" -eq 0 ]
  [ "$output" = "styleguide: skipped — no repository supplied; pass --styleguide-repo <url>" ]
  [ "$(tree_state "$W/app")" = "$before" ]
  [ ! -e "$W/app/styleguide" ]
  [ ! -e "$W/app/.gitmodules" ]
}

@test "styleguide: a blank --url is no URL" {
  make_app "$W/app"
  run zsh "$SCRIPT" --repo "$W/app" --url "  "
  [ "$status" -eq 0 ]
  contains "$output" "styleguide: skipped"
}

# --- failures, each undone as a unit ---------------------------------------------

# Run the script expecting exit 1 and the reason $2, and nothing changed.
assert_fails_cleanly() {
  local url="$1" reason="$2" before porcelain
  before="$(tree_state "$W/app")"
  porcelain="$(git -C "$W/app" status --porcelain)"
  run zsh "$SCRIPT" --repo "$W/app" --url "$url"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "styleguide: failed — $url: $reason" ] || { echo "output: $output"; return 1; }
  [ "$(tree_state "$W/app")" = "$before" ] || { echo "the tree changed"; return 1; }
  [ "$(git -C "$W/app" status --porcelain)" = "$porcelain" ] || { echo "git status changed"; return 1; }
  [ ! -d "$W/app/.git/modules/styleguide" ] || { echo "a modules dir was left"; return 1; }
  run git -C "$W/app" config --get-regexp '^submodule\.'
  [ "$status" -eq 1 ] || { echo "a submodule config entry was left: $output"; return 1; }
}

@test "styleguide: an unreachable URL fails as a unit, naming the URL and the reason" {
  make_app "$W/app" $'# Ours\n'
  assert_fails_cleanly "$W/no-such-remote" "unreachable"
  [ ! -e "$W/app/styleguide" ]
}

@test "styleguide: a remote with no vX.Y.Z tag fails, and never checks out the branch head" {
  make_remote "$W/sg" nightly v1.0.0-rc.1 v1.0 1.0.0
  make_app "$W/app" $'# Ours\n'
  assert_fails_cleanly "$W/sg" "no vX.Y.Z tag"
  [ ! -e "$W/app/styleguide" ]
}

@test "styleguide: a tracked styleguide/ that is not a submodule fails and stays untouched" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app"
  mkdir "$W/app/styleguide"
  printf 'our own notes\n' > "$W/app/styleguide/notes.md"
  git -C "$W/app" add -A
  git -C "$W/app" commit -qm notes
  assert_fails_cleanly "$W/sg" "styleguide/ exists and is not a submodule"
  [ "$(cat "$W/app/styleguide/notes.md")" = "our own notes" ]
  [ ! -e "$W/app/.gitmodules" ]
}

@test "styleguide: an untracked styleguide/ file is not a submodule either" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app"
  printf 'x\n' > "$W/app/styleguide"
  assert_fails_cleanly "$W/sg" "styleguide/ exists and is not a submodule"
}

@test "styleguide: a failure after the add undoes the gitlink, .gitmodules, CLAUDE.md and the clone" {
  make_remote "$W/sg" v0.1.0
  # an existing .gitmodules with another submodule must come back byte for byte
  make_app "$W/app" $'# Ours\n'
  printf '[submodule "docs"]\n\tpath = docs\n\turl = https://example.invalid/docs.git\n' > "$W/app/.gitmodules"
  git -C "$W/app" add .gitmodules
  git -C "$W/app" commit -qm gm
  # the tag fetch inside the submodule fails: a git wrapper refuses it
  local real
  real="$(command -v git)"
  mkdir -p "$W/bin"
  printf '#!/bin/sh\ncase "$*" in *"fetch"*"refs/tags/"*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real" > "$W/bin/git"
  chmod +x "$W/bin/git"
  PATH="$W/bin:$PATH" assert_fails_cleanly "$W/sg" "cannot fetch v0.1.0"
  [ ! -e "$W/app/styleguide" ]
  [ "$(grep -c 'submodule' "$W/app/.gitmodules")" -eq 1 ]
}

@test "styleguide: a CLAUDE.md that cannot be written undoes the whole add" {
  [ "$(id -u)" != 0 ] || skip "root writes a read-only file"
  make_remote "$W/sg" v0.1.0
  make_app "$W/app" $'# Ours\n'
  chmod a-w "$W/app/CLAUDE.md"
  assert_fails_cleanly "$W/sg" "cannot write CLAUDE.md"
  chmod u+w "$W/app/CLAUDE.md"
  [ ! -e "$W/app/styleguide" ]
}

# --- usage ----------------------------------------------------------------------

@test "styleguide: usage errors exit 2 and write nothing" {
  make_app "$W/app"
  run zsh "$SCRIPT"
  [ "$status" -eq 2 ]
  run zsh "$SCRIPT" --repo "$W/app" --bogus x
  [ "$status" -eq 2 ]
  run zsh "$SCRIPT" --repo "$W/app" --url
  [ "$status" -eq 2 ]
  mkdir -p "$W/plain"
  run zsh "$SCRIPT" --repo "$W/plain" --url "$W/sg"
  [ "$status" -eq 2 ]
  contains "$output" "not a git work tree"
  mkdir -p "$W/app/sub"
  run zsh "$SCRIPT" --repo "$W/app/sub" --url "$W/sg"
  [ "$status" -eq 2 ]
  contains "$output" "not the root of its work tree"
  run zsh "$SCRIPT" --repo "$W/app" --template "$W/no-such.tmpl"
  [ "$status" -eq 2 ]
  [ ! -e "$W/app/.gitmodules" ]
}

@test "styleguide: a stale styleguide git directory fails before any write" {
  make_remote "$W/sg" v0.1.0
  make_app "$W/app"
  mkdir -p "$W/app/.git/modules/styleguide"
  run zsh "$SCRIPT" --repo "$W/app" --url "$W/sg"
  [ "$status" -eq 1 ]
  contains "$output" "a stale submodule git directory exists"
  [ ! -e "$W/app/styleguide" ]
  [ -d "$W/app/.git/modules/styleguide" ]
}

# --- the render: the Dependabot entry and the CLAUDE.md section -------------------

render_common() {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$W/out" --project-name app --project-slug o/app \
    --languages javascript "$@" common/.github/dependabot.yml.tmpl common/CLAUDE.md.tmpl
}

@test "render: --styleguide true yields exactly one gitsubmodule entry (directory /, weekly) and the section" {
  run render_common --styleguide true
  [ "$status" -eq 0 ]
  local d="$W/out/common/.github/dependabot.yml"
  [ "$(yq -r '[.updates[] | select(.["package-ecosystem"] == "gitsubmodule")] | length' "$d")" -eq 1 ]
  [ "$(yq -r '.updates[] | select(.["package-ecosystem"] == "gitsubmodule") | .directory' "$d")" = / ]
  [ "$(yq -r '.updates[] | select(.["package-ecosystem"] == "gitsubmodule") | .schedule.interval' "$d")" = weekly ]
  [ "$(grep -cx '## Read the styleguide before UI changes' "$W/out/common/CLAUDE.md")" -eq 1 ]
  # the decision-rights section still closes the file, untouched by the block
  [ "$(grep '^## ' "$W/out/common/CLAUDE.md" | tail -n 1)" = "## Who decides what" ]
}

@test "render: without --styleguide (or with false) there is no gitsubmodule entry and no section" {
  local v
  for v in "" false; do
    rm -rf "$W/out"
    if [ -z "$v" ]; then run render_common; else run render_common --styleguide "$v"; fi
    [ "$status" -eq 0 ]
    run grep -c 'gitsubmodule' "$W/out/common/.github/dependabot.yml"
    [ "$output" = 0 ]
    run grep -c 'styleguide' "$W/out/common/CLAUDE.md"
    [ "$output" = 0 ]
  done
}

@test "render: the styleguide dependabot.yml passes yamllint" {
  command -v yamllint >/dev/null || skip "yamllint not installed"
  run render_common --styleguide true
  [ "$status" -eq 0 ]
  run yamllint -c "$REPO_ROOT/.yamllint" "$W/out/common/.github/dependabot.yml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# --- detection: who gets the step ------------------------------------------------

@test "detect: Flask + Jinja (web-ui), a plain JS library and a bare Package.swift app report is_react false" {
  local DETECT="$BS/scripts/detect-stack.sh" d
  mkdir -p "$W/flask" "$W/jslib" "$W/swiftui"
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["flask>=3", "jinja2>=3"]\n' > "$W/flask/pyproject.toml"
  printf '{"name":"lib","dependencies":{"lodash":"4.17.21"}}\n' > "$W/jslib/package.json"
  printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App")\n' > "$W/swiftui/Package.swift"
  (cd "$W/flask" && bash "$DETECT" 2>/dev/null) > "$W/flask.json"
  [ "$(jq -c '[.interfaces[].interface] | index("web-ui") != null' "$W/flask.json")" = true ]
  for d in flask jslib swiftui; do
    [ "$(cd "$W/$d" && bash "$DETECT" 2>/dev/null | jq -c .is_react)" = false ] || { echo "$d"; false; }
  done
}

# --- SKILL.md ---------------------------------------------------------------------

skill_flat() { tr '\n' ' ' < "$SKILL" | tr -s ' '; }
styleguide_step() { awk '/^### 3k\.5a\. /{on=1} on && /^### 3k\.6\. /{exit} on' "$SKILL" | tr '\n' ' ' | tr -s ' '; }

@test "skill: the styleguide step sits right after §3k.5, before §3k.6" {
  local a b c
  a="$(grep -n '^### 3k\.5\. ' "$SKILL" | cut -d: -f1)"
  b="$(grep -n '^### 3k\.5a\. Styleguide submodule' "$SKILL" | cut -d: -f1)"
  c="$(grep -n '^### 3k\.6\. ' "$SKILL" | cut -d: -f1)"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
}

@test "skill: the step's trigger is is_react true, and web-ui alone does not trigger it" {
  local s
  s="$(styleguide_step)"
  contains "$s" 'Run this step exactly when the React overlay (§3k.5) applies'
  contains "$s" '`detect-stack.sh` reports `is_react: true`'
  contains "$s" 'A `web-ui` entry in `interfaces` alone does not trigger it'
  contains "$s" 'a repo where `is_react` is `null` get no submodule, no `CLAUDE.md` section and no `gitsubmodule` entry, and are never asked for the URL'
}

@test "skill: the flag, the one question and the no-URL skip line" {
  local f
  f="$(skill_flat)"
  contains "$f" '- `--styleguide-repo <url>` — the shared UI styleguide repository'
  contains "$f" '| **Q8: Styleguide repository** | Only when the styleguide step (§3k.5a) would run'
  contains "$f" '**and** no `--styleguide-repo` was passed **and** `.gitmodules` declares no `styleguide` submodule'
  contains "$(styleguide_step)" '**exit 0, `styleguide: skipped — no repository supplied; pass --styleguide-repo <url>`**'
  # the script prints exactly that line
  grep -qF 'print -r -- "styleguide: skipped — no repository supplied; pass --styleguide-repo <url>"' "$SCRIPT"
}

@test "skill: the step stages, fails as a unit and continues, and relays its line in Step 5" {
  local s
  s="$(styleguide_step)"
  contains "$s" 'are **staged, never committed**: they land in bootstrap'"'"'s one commit (4d)'
  contains "$s" 'The step fails **as a unit**'
  contains "$s" 'It never falls back to the default branch head'
  contains "$s" '**continue the rest of bootstrap**'
  contains "$(skill_flat)" '**The report relays the styleguide step'"'"'s line** (§3k.5a, #3016)'
}

@test "skill: the Renovate repo gets no Dependabot entry and one not-configured line" {
  local s line='styleguide: submodule bumps are not configured — this repo keeps its own Renovate config'
  s="$(styleguide_step)"
  contains "$s" '**A repo that keeps its own Renovate config** renders no `.github/dependabot.yml` (§3a): add no Dependabot entry, leave the Renovate config alone'
  contains "$s" "\`$line\`"
  contains "$(skill_flat)" "the line \`$line\`."
}

@test "skill: §3a renders dependabot.yml and CLAUDE.md with --styleguide, and the block table teaches the tag" {
  local f
  f="$(skill_flat)"
  contains "$f" 'Render it with `--styleguide true` exactly when `.gitmodules` declares the `styleguide` submodule once §3k.5a has run'
  contains "$f" 'Render it through `render.zsh` with the same `--styleguide` value as `.github/dependabot.yml`'
  contains "$f" '| `STYLEGUIDE` | `--styleguide true`'
  contains "$f" 'Merge `react/prettierignore` into `.prettierignore` the same way'
}

@test "render.zsh: STYLEGUIDE is a taught tag, and --styleguide refuses any value but true or false" {
  grep -qF 'STYLEGUIDE) [[ "$styleguide" == "true" ]] ;;' "$RENDER"
  printf 'a\n# --- STYLEGUIDE-START ---\nb\n# --- STYLEGUIDE-END ---\n' > "$W/t.tmpl"
  local bad
  for bad in yes TRUE ""; do
    run zsh "$RENDER" --templates "$W" --out "$W/o" --styleguide "$bad" t.tmpl
    [ "$status" -eq 2 ] || { echo "'$bad' -> $status"; false; }
    contains "$output" "--styleguide must be true or false"
  done
  [ ! -e "$W/o/t" ]
}

@test "plugin: no styleguide repository URL is hard-coded under development/" {
  run git -C "$REPO_ROOT" grep -nIE 'timos-platform-styleguide|platform-styleguide' -- development
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "skill: the flag's, Q8's and the step's rule sentences are pinned whole" {
  local f s
  f="$(skill_flat)"
  s="$(styleguide_step)"
  contains "$f" 'The plugin names no styleguide of its own, so the URL is always yours.'
  contains "$f" 'Without the flag, bootstrap asks for it once (Q8), and only when the step would run and no `styleguide` submodule exists yet; with no URL the step is skipped.'
  contains "$f" 'Ignored when `.gitmodules` already declares the submodule.'
  contains "$f" 'Never on a re-run that has the submodule, and never on a repo the overlay does not apply to.'
  contains "$f" 'Which styleguide repository should it mount as its `styleguide/` submodule?'
  contains "$f" '| A URL becomes the step'"'"'s `--url`.'
  contains "$f" 'An existing `CLAUDE.md` gets that section from §3k.5a'"'"'s script instead, appended once.'
  contains "$f" 'A `skipped` or `failed` line is an outstanding item; an `added` or `present` line is reported once and is not a TODO.'
  contains "$s" '`--styleguide-repo <url>`, else Q8'"'"'s one question, asked in Step 2 only when the step would run and `.gitmodules` declares no `styleguide` submodule.'
  contains "$s" '**exit 0, `styleguide: added <url> at <tag>`** — `styleguide/` is a new submodule checked out at the commit of the remote'"'"'s highest `vX.Y.Z` tag in semver order (`v0.10.0` beats `v0.9.0`; pre-release and other tags are ignored).'
  contains "$s" '`.gitmodules` carries `[submodule "styleguide"]` with `path = styleguide` and `url = <url>` and no `branch` line.'
  contains "$s" 'The script contacts no remote, ignores `--url` and leaves the pin where it is; it only fills a missing `CLAUDE.md` section.'
  contains "$s" '**exit 1, `styleguide: failed — <url>: <reason>`** — the URL is unreachable, the remote has no `vX.Y.Z` tag, `styleguide/` exists and is not a submodule, or a git step failed.'
}
