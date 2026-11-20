#!/usr/bin/env bats
#
# The product-document lookup (#3203, task 2 of #3195):
# product/scripts/resolve-product-doc.zsh tells a product skill where a product
# document lives — the repo's own file, else the first submodule declared in
# `.gitmodules` that carries it at the same relative path.
#
# Every fixture is invented and built locally in setup(): plain directories and
# a hand-written `.gitmodules`. No network, no real submodule, no `git init`.
# The suite also pins define-personas' stop rule and the ARCHITECTURE.md
# statement of the lookup, each scoped to its own section.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these; the script's `git config -f`
  # must never see a real repository's state
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/product/scripts/resolve-product-doc.zsh"
  SKILL="$REPO_ROOT/product/skills/define-personas/SKILL.md"
  R="$BATS_TEST_TMPDIR/product repo"
  mkdir -p "$R"
  DOC="docs/personas.md"
}

# declare_subs <name>... — a hand-written .gitmodules declaring each submodule,
# in argument order, with the path equal to the name
declare_subs() {
  local s
  : > "$R/.gitmodules"
  for s in "$@"; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/%s.git\n' "$s" "$s" "$s" \
      >> "$R/.gitmodules"
  done
}

# declare_named_sub <name> <path> — a hand-written .gitmodules declaring one
# submodule whose name differs from its path; the lookup must use the path
declare_named_sub() {
  printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/%s.git\n' "$1" "$2" "$1" \
    > "$R/.gitmodules"
}

# populate <dir> — an initialised-looking submodule: a non-empty directory
populate() {
  mkdir -p "$R/$1"
  printf 'Acme Ledger readme\n' > "$R/$1/README.md"
}

# place <dir> — put the document under <dir> ("." is the repo itself)
place() {
  mkdir -p "$R/$1/docs"
  printf '# Personas\n\nNadia, a bookkeeper at a dental practice.\n' > "$R/$1/$DOC"
}

@test "own file wins over a linked one" {
  declare_subs product-docs
  populate product-docs
  place product-docs
  place .
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$R" && pwd -P)/$DOC"$'\t'"own" ]
}

@test "falls back to the first submodule that has the file, in .gitmodules order" {
  declare_subs handbook product-docs
  populate handbook
  populate product-docs
  place product-docs
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$R/product-docs" && pwd -P)/$DOC"$'\t'"linked:product-docs" ]
}

@test "the first declared submodule wins when two carry the file" {
  declare_subs zeta-docs alpha-docs
  place zeta-docs
  place alpha-docs
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  ends_with "$output" $'\t'"linked:zeta-docs"
}

@test "not found anywhere is exit 3 naming the path" {
  declare_subs handbook
  populate handbook
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$stderr" = "product-doc: not found: $DOC" ]
}

@test "a repo with no .gitmodules is own or not found" {
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 3 ]
  place .
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  ends_with "$output" $'\t'"own"
}

@test "declared submodule directory is empty: exit 4 naming it and the init line" {
  declare_subs product-docs
  mkdir -p "$R/product-docs"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  contains "$stderr" "not initialised: product-docs"
  contains "$stderr" "git submodule update --init -- product-docs"
}

@test "a declared submodule with no directory at all is exit 4 too" {
  declare_subs product-docs
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  contains "$stderr" "not initialised: product-docs"
}

@test "an uninitialised submodule before a hit is exit 4, never the later hit" {
  declare_subs handbook product-docs
  mkdir -p "$R/handbook"
  place product-docs
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  contains "$stderr" "not initialised: handbook"
}

@test "a hit before an uninitialised submodule wins" {
  declare_subs product-docs handbook
  place product-docs
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  ends_with "$output" $'\t'"linked:product-docs"
}

@test "own file wins over an uninitialised submodule" {
  declare_subs product-docs
  place .
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  ends_with "$output" $'\t'"own"
}

@test "a submodule whose name differs from its path is looked up and reported by its path" {
  declare_named_sub docs-repo "vendor/product docs"
  mkdir -p "$R/docs-repo/docs"
  printf '# Personas\n' > "$R/docs-repo/$DOC"
  place "vendor/product docs"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$R/vendor/product docs" && pwd -P)/$DOC"$'\t'"linked:vendor/product docs" ]
}

@test "an uninitialised submodule whose name differs from its path is exit 4 naming the path" {
  declare_named_sub docs-repo "vendor/product docs"
  mkdir -p "$R/vendor/product docs" "$R/docs-repo/docs"
  printf '# Personas\n' > "$R/docs-repo/$DOC"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  contains "$stderr" "submodule not initialised: vendor/product docs"
  contains "$stderr" "git submodule update --init -- 'vendor/product docs'"
}

@test "works with spaces in the repo path, the submodule path and the document path" {
  declare_subs "shared product docs"
  place "shared product docs"
  mkdir -p "$R/shared product docs/road map"
  printf 'Q3: invoice export\n' > "$R/shared product docs/road map/next steps.md"
  run --separate-stderr zsh "$S" --repo "$R" "road map/next steps.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$R/shared product docs" && pwd -P)/road map/next steps.md"$'\t'"linked:shared product docs" ]
  rm -rf "$R/shared product docs"
  mkdir -p "$R/shared product docs"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  contains "$stderr" "git submodule update --init -- 'shared product docs'"
}

@test "defaults --repo to the current directory" {
  place .
  cd "$R"
  run --separate-stderr zsh "$S" "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = "$(pwd -P)/$DOC"$'\t'"own" ]
}

@test "no arguments is a usage error" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage:"
}

@test "an absolute path, two paths, an unknown flag or a missing --repo value is a usage error" {
  run --separate-stderr zsh "$S" --repo "$R" "/etc/hosts"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo "$R" "$DOC" "docs/charter.md"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --colour "$DOC"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" "$DOC" --repo
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --repo "$R/no such dir" "$DOC"
  [ "$status" -eq 2 ]
  contains "$stderr" "not a directory"
}

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage:"
}

@test "a .gitmodules git cannot read is exit 1" {
  printf '[submodule "broken\n' > "$R/.gitmodules"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 1 ]
  contains "$stderr" "cannot read"
}

@test "git missing from PATH is exit 1" {
  declare_subs product-docs
  # Ubuntu CI keeps git in /usr/bin, so PATH is a stub dir holding only zsh
  local hide_bin="$BATS_TEST_TMPDIR/hide-bin"
  mkdir -p "$hide_bin"
  ln -s "$(command -v zsh)" "$hide_bin/zsh"
  run --separate-stderr env PATH="$hide_bin" zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "git is not on PATH"
}

@test "a .gitmodules with no path key is no submodules: not found is exit 3" {
  : > "$R/.gitmodules"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 3 ]
  [ "$stderr" = "product-doc: not found: $DOC" ]
}

@test "a file under a submodule mount is never own: exit 5 names the path inside it" {
  declare_subs docs
  populate docs
  printf '# Personas\n' > "$R/$DOC"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 5 ]
  [ "$output" = "" ]
  contains "$stderr" "product-doc: $DOC lies inside submodule docs"
  contains "$stderr" "in that repository it is personas.md; look it up there"
}

@test "a path under a submodule mount still walks the submodules: an uninitialised earlier one is exit 4" {
  declare_subs handbook docs
  populate docs
  printf '# Personas\n' > "$R/$DOC"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 4 ]
  contains "$stderr" "submodule not initialised: handbook"
}

@test "a path under a submodule mount still walks the submodules: an earlier holder is linked" {
  declare_subs handbook docs
  place handbook
  populate docs
  printf '# Personas\n' > "$R/$DOC"
  run --separate-stderr zsh "$S" --repo "$R" "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$R/handbook" && pwd -P)/$DOC"$'\t'"linked:handbook" ]
}

@test "define-personas looks the registry up and stops on a linked one without writing" {
  local step0
  step0="$(sed -n '/^## Step 0/,/^## Step 1/p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$step0" '"<skill-base-dir>/../../scripts/resolve-product-doc.zsh" --repo <target repo root> docs/personas.md'
  contains "$step0" "**exit 0, origin \`linked:<submodule path>\`**"
  contains "$step0" "**Stop without writing anything.** Tell the human: the product's persona registry lives in the linked repository at \`<submodule path>\`"
  contains "$step0" "**exit 3** (not found anywhere) → **create**"
  contains "$step0" "**exit 4** (a declared submodule is not initialised, and it could hold the registry) → **stop without writing anything**"
  contains "$step0" "Relay the lookup's stderr, which names the submodule and its \`git submodule update --init\` line, and ask the human to initialise it and run this skill again."
  contains "$step0" "Its stdout is \`<absolute path>\` TAB \`<origin>\`; branch on its exit:"
  contains "$step0" "**exit 0, origin \`own\`** → **update**; parse that file's \`personas/v1\` block into the registry-so-far"
  contains "$step0" "**exit 5** (\`docs/personas.md\` lies inside a declared submodule's mount, and no submodule holds it at that path) → **stop without writing anything**. Relay the lookup's stderr, which names the submodule and the registry's path inside it"
  contains "$step0" "**exit 1 or 2** → **stop without writing anything** and report the stderr."
}

@test "define-personas guardrails forbid shadowing a linked registry" {
  local guard
  guard="$(sed -n '/^## Guardrails/,$p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$guard" "**Never shadow a linked registry.** When the lookup finds the registry in a linked submodule, never create a second one in this repo: Step 0 stops without writing."
}

@test "ARCHITECTURE.md states the lookup rule in the product section" {
  local section
  section="$(sed -n '/^### The `product` plugin — outside the language\/topic model/,/^##/p' \
               "$REPO_ROOT/ARCHITECTURE.md" | tr -s '[:space:]' ' ')"
  contains "$section" "\`product/scripts/resolve-product-doc.zsh [--repo <dir>] <relative-path>\`, and never by a path of its own."
  contains "$section" "It prints \`<absolute path>\` TAB \`<origin>\`, where the origin is \`own\` or \`linked:<submodule path>\`, and exits 0 found, 2 usage, 3 not found, or 4 when a declared submodule that is not initialised (a missing or empty directory) comes before any hit, since that submodule might hold the file; its stderr then names the submodule and the \`git submodule update --init\` line."
  contains "$section" "the lookup exits 5 and its stderr names the submodule and the path inside it."
  contains "$section" "Exit 1 is an internal failure: git missing, or a \`.gitmodules\` git cannot read."
  contains "$section" "\`/product:define-personas\` stops without writing when the registry is \`linked:…\` or the lookup exits 5, and names where it lives."
  contains "$section" "The repo's own file wins. Otherwise the submodules declared in \`.gitmodules\` are tried in file order"
  contains "$section" "There is no configuration."
  contains "$section" "A path under a declared submodule's mount is never the repo's own; when no submodule holds it at the same relative path, the lookup exits 5"
}
