#!/usr/bin/env bats
#
# Acceptance cases for "link a docs repository — the pinned submodule and the
# binding lines in CLAUDE.md" (#3355) — the `cli`-tooled test_cases[] of its
# story-spec, one test per `tc-*` id:
#
#   tc-happy-apply-pins-highest-tag              #3387
#   tc-happy-check-linked-and-gap                #3388
#   tc-happy-apply-section-appends-once          #3389
#   tc-corner-rerun-byte-identical               #3390
#   tc-corner-same-url-without-key-keeps-pin     #3391
#   tc-corner-tag-order-and-bare-form            #3392
#   tc-corner-paths-with-spaces                  #3393
#   tc-corner-crlf-claude-md                     #3394
#   tc-error-no-version-tag                      #3395
#   tc-error-unreachable-url                     #3396
#   tc-error-foreign-mount                       #3397
#   tc-error-not-a-work-tree-and-usage           #3398
#
# The use case: timo-platform-builder bootstraps a service repo with
# `--docs-repo <url>` pointing at the private docs repository that holds the
# target architecture, tagged v1.2.0 and v1.10.0, and gets it linked at
# `linked-docs/`, pinned to v1.10.0 and bound in CLAUDE.md. The docs repository
# is a local bare repo reached by an absolute path, so no network is touched.
# What runs for real: link-reference-docs.zsh and the shipped template. The
# default gate's tests/bootstrap-link-reference-docs.bats covers the same
# criteria clause by clause.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BS="$REPO_ROOT/development/skills/bootstrap"
  LINK="$BS/scripts/link-reference-docs.zsh"
  TMPL="$BS/templates/common/claude-md-linked-reference-docs.md.tmpl"
  W="$BATS_TEST_TMPDIR"
  printf '[user]\n\tname = Platform Builder\n\temail = builder@example.invalid\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$W/gitconfig"
  export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
  DOCS="$W/timos-platform-docs.git"
}

# The docs repository: one release commit per tag given, then unreleased work on main.
docs_repo() {
  local work="$W/docs-work" t
  git init -q "$work"
  mkdir -p "$work/docs/architecture"
  for t in "$@"; do
    printf '# Target architecture %s\n\nTA-1: services talk gRPC inside, REST outside.\n' "$t" \
      > "$work/docs/architecture/target-architecture.md"
    git -C "$work" add -A
    git -C "$work" commit -qm "release $t"
    git -C "$work" tag "$t"
  done
  printf 'draft\n' > "$work/docs/architecture/target-architecture.md"
  git -C "$work" commit -qam "draft"
  git clone -q --bare "$work" "$DOCS"
}

# A service repo with one commit and a CLAUDE.md.
service_repo() {
  git init -q "$1"
  printf '# order-service\n' > "$1/README.md"
  printf '# CLAUDE.md\n\nRepo-wide rules for order-service.\n' > "$1/CLAUDE.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

pin() { git -C "$1" ls-files -s "$2" | awk '{print $2}'; }
tag_commit() { git -C "$DOCS" rev-parse "refs/tags/$1^{commit}"; }
state() {
  local f
  for f in "$1/.gitmodules" "$1/.git/index" "$1/.git/config"; do
    if [ -f "$f" ]; then cksum < "$f"; else printf 'absent\n'; fi
  done
  git -C "$1" status --porcelain
}

@test "tc-happy-apply-pins-highest-tag (#3387): the link is pinned to v1.10.0, marked, staged, uncommitted" {
  docs_repo v1.2.0 v1.10.0
  service_repo "$W/order-service"
  local head
  head="$(git -C "$W/order-service" rev-parse HEAD)"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(pin "$W/order-service" linked-docs)" = "$(tag_commit v1.10.0)" ]
  [ "$(git -C "$W/order-service" config -f .gitmodules submodule.linked-docs.reference-docs)" = true ]
  run git -C "$W/order-service" config -f .gitmodules --get-regexp 'branch'
  [ "$status" -eq 1 ]
  run git -C "$W/order-service" diff --cached --name-only
  [ "$output" = $'.gitmodules\nlinked-docs' ]
  [ "$(git -C "$W/order-service" rev-parse HEAD)" = "$head" ]
}

@test "tc-happy-check-linked-and-gap (#3388): gap before, linked after, no byte changed, no remote read" {
  docs_repo v1.2.0 v1.10.0
  service_repo "$W/order-service"
  local before
  before="$(state "$W/order-service")"
  run zsh "$LINK" check --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  [ "$(state "$W/order-service")" = "$before" ]
  run zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  before="$(state "$W/order-service")"
  mv "$DOCS" "$W/moved-away.git"
  run zsh "$LINK" check --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(state "$W/order-service")" = "$before" ]
}

@test "tc-happy-apply-section-appends-once (#3389): gap, applied once after one blank line, then present" {
  service_repo "$W/order-service"
  local cm="$W/order-service/CLAUDE.md"
  cp "$cm" "$W/before.md"
  run zsh "$LINK" check-section --claude-md "$cm"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  run zsh "$LINK" apply-section --claude-md "$cm" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = applied ]
  { cat "$W/before.md"; printf '\n'; cat "$TMPL"; } > "$W/want.md"
  cmp "$cm" "$W/want.md"
  [ "$(grep -c '^## Linked reference documents$' "$cm")" -eq 1 ]
  run zsh "$LINK" apply-section --claude-md "$cm" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
  cmp "$cm" "$W/want.md"
}

@test "tc-corner-rerun-byte-identical (#3390): a second apply keeps the pin even after a newer tag" {
  docs_repo v1.2.0 v1.10.0
  service_repo "$W/order-service"
  run zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  local before head
  before="$(state "$W/order-service")"
  head="$(git -C "$W/order-service/linked-docs" rev-parse HEAD)"
  git -C "$W/docs-work" tag v1.11.0
  git -C "$W/docs-work" push -q "$DOCS" v1.11.0
  run zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(state "$W/order-service")" = "$before" ]
  [ "$(git -C "$W/order-service/linked-docs" rev-parse HEAD)" = "$head" ]
}

@test "tc-corner-same-url-without-key-keeps-pin (#3391): the key is added, the v1.2.0 pin kept, no remote read" {
  docs_repo v1.2.0 v1.10.0
  service_repo "$W/order-service"
  git -C "$W/order-service" submodule --quiet add --name linked-docs -- "$DOCS" linked-docs
  git -C "$W/order-service/linked-docs" -c advice.detachedHead=false checkout -q v1.2.0
  git -C "$W/order-service" add linked-docs .gitmodules
  git -C "$W/order-service" commit -qm "link docs by hand"
  run zsh "$LINK" check --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 1 ]
  [ "$output" = gap ]
  local v12
  v12="$(tag_commit v1.2.0)"
  mv "$DOCS" "$W/moved-away.git"
  run zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  [ "$(git -C "$W/order-service" config -f .gitmodules submodule.linked-docs.reference-docs)" = true ]
  run git -C "$W/order-service" diff --cached --name-only
  [ "$output" = .gitmodules ]
  [ "$(pin "$W/order-service" linked-docs)" = "$v12" ]
}

@test "tc-corner-tag-order-and-bare-form (#3392): v1.10.0 among v1.9.0, 1.2.0, v2.0.0-rc.1 and nightly; 1.10.0 when bare" {
  docs_repo v1.9.0 v1.10.0 1.2.0 v2.0.0-rc.1 nightly
  service_repo "$W/order-service"
  run zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$(pin "$W/order-service" linked-docs)" = "$(tag_commit v1.10.0)" ]
  rm -rf "$W/docs-work" "$DOCS"
  docs_repo 1.2.0 1.10.0
  service_repo "$W/billing-service"
  run zsh "$LINK" apply --repo-dir "$W/billing-service" --url "$DOCS"
  [ "$status" -eq 0 ]
  [ "$(pin "$W/billing-service" linked-docs)" = "$(tag_commit 1.10.0)" ]
}

@test "tc-corner-paths-with-spaces (#3393): a repo at 'my service' and a mount 'linked docs'" {
  docs_repo v1.2.0 v1.10.0
  service_repo "$W/my service"
  run zsh "$LINK" apply --repo-dir "$W/my service" --url "$DOCS" --path "linked docs"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
  run git -C "$W/my service" config -f .gitmodules 'submodule.linked docs.reference-docs'
  [ "$output" = true ]
  run zsh "$LINK" check --repo-dir "$W/my service" --url "$DOCS" --path "linked docs"
  [ "$status" -eq 0 ]
  [ "$output" = linked ]
}

@test "tc-corner-crlf-claude-md (#3394): a CRLF file gets a CRLF section; a missing final newline is added" {
  printf '# CLAUDE.md\r\n\r\nRules.\r\n' > "$W/crlf.md"
  cp "$W/crlf.md" "$W/crlf.before"
  run zsh "$LINK" apply-section --claude-md "$W/crlf.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = applied ]
  { cat "$W/crlf.before"; printf '\r\n'; sed 's/$/\r/' "$TMPL"; } > "$W/crlf.want"
  cmp "$W/crlf.md" "$W/crlf.want"
  printf '# CLAUDE.md\n\nRules.' > "$W/nonl.md"
  run zsh "$LINK" apply-section --claude-md "$W/nonl.md" --template "$TMPL"
  [ "$status" -eq 0 ]
  [ "$output" = applied ]
  { printf '# CLAUDE.md\n\nRules.\n\n'; cat "$TMPL"; } > "$W/nonl.want"
  cmp "$W/nonl.md" "$W/nonl.want"
}

@test "tc-error-no-version-tag (#3395): nightly and v2.0.0-rc.1 only -> exit 4, says to tag, nothing written" {
  docs_repo nightly v2.0.0-rc.1
  service_repo "$W/order-service"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  contains "$stderr" "tag a release"
  [ ! -e "$W/order-service/.gitmodules" ]
  [ ! -e "$W/order-service/linked-docs" ]
  [ -z "$(git -C "$W/order-service" status --porcelain)" ]
}

@test "tc-error-unreachable-url (#3396): a missing path, stdin closed -> exit 3 naming the URL, nothing written" {
  service_repo "$W/order-service"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service" --url "$W/no-such-docs.git" </dev/null
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  contains "$stderr" "$W/no-such-docs.git"
  [ ! -e "$W/order-service/.gitmodules" ]
  [ -z "$(git -C "$W/order-service" status --porcelain)" ]
}

@test "tc-error-foreign-mount (#3397): a plain directory or another URL's submodule -> exit 5, untouched" {
  docs_repo v1.2.0
  service_repo "$W/order-service"
  mkdir "$W/order-service/linked-docs"
  printf 'notes\n' > "$W/order-service/linked-docs/notes.md"
  local before
  before="$(state "$W/order-service")"
  run --separate-stderr zsh "$LINK" check --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 5 ]
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 5 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(state "$W/order-service")" = "$before" ]
  [ "$(cat "$W/order-service/linked-docs/notes.md")" = notes ]
  service_repo "$W/billing-service"
  git -C "$W/billing-service" submodule --quiet add --name linked-docs -- "$DOCS" linked-docs
  before="$(state "$W/billing-service")"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/billing-service" --url "$W/other-docs.git"
  [ "$status" -eq 5 ]
  [ "$(state "$W/billing-service")" = "$before" ]
}

@test "tc-error-not-a-work-tree-and-usage (#3398): exit 6 outside a repo; exit 2 with the usage for malformed calls" {
  docs_repo v1.2.0
  service_repo "$W/order-service"
  mkdir -p "$W/plain"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/plain" --url "$DOCS"
  [ "$status" -eq 6 ]
  run --separate-stderr zsh "$LINK" frobnicate --repo-dir "$W/order-service" --url "$DOCS"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: link-reference-docs.zsh"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: link-reference-docs.zsh"
  run --separate-stderr zsh "$LINK" apply --repo-dir "$W/order-service" --url ../docs
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: link-reference-docs.zsh"
  run --separate-stderr zsh "$LINK" apply-section --claude-md "$W/order-service/CLAUDE.md" --template "$W/no-such.tmpl"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: link-reference-docs.zsh"
  [ ! -e "$W/order-service/.gitmodules" ]
}
