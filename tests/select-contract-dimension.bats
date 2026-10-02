#!/usr/bin/env bats
#
# select-contract-dimension.zsh (#2009): the pure selector that decides whether
# a claude-plugin DELTA round needs the `contract` dimension. Most cases build a
# real delta in a temp repo and hand the selector the two inputs the way
# `review-dispatch.zsh plan` builds them — the name-status list as
# [{status, path}], agents and SKILL.md files at whole-file context, every other
# path at -U0 — so each trigger is exercised on genuine git output. The input
# shapes git never produces (a malformed list, a list that disagrees with the
# patch, a SKILL.md hunk without whole-file context) are written by hand.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SEL="$REPO_ROOT/development/skills/resolve-issue/scripts/select-contract-dimension.zsh"
  R="$BATS_TEST_TMPDIR/repo"
  IN="$BATS_TEST_TMPDIR/in"
  mkdir -p "$R" "$IN"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  mkdir -p "$R/tests" "$R/dev/skills/x" "$R/dev/agents" "$R/dev/scripts" "$R/.claude-plugin"
  printf '#!/usr/bin/env bats\nload assertions\n' > "$R/tests/a.bats"
  printf '# Notes\n\nbody\n' > "$R/tests/notes.md"
  # a SKILL.md whose body runs well past its frontmatter
  { printf -- '---\nname: x\ndescription: does x\n---\n\n# X\n\n'
    for i in $(seq 1 40); do printf 'body line %s\n' "$i"; done; } > "$R/dev/skills/x/SKILL.md"
  printf -- '---\nname: rev\ndescription: reviews\nmodel: opus\ntools: Read\n---\n\nYou review.\n' > "$R/dev/agents/rev.md"
  printf '#!/usr/bin/env zsh\ncase "$1" in\n  --old) shift ;;\n  *) print hi ;;\nesac\nprint done\n' > "$R/dev/scripts/tool.zsh"
  printf '#!/usr/bin/env bash\ncase "$1" in\n  run) echo run ;;\nesac\necho done\n' > "$R/dev/scripts/t.bash"
  printf '# Dev\n\n## Install\n\ntext one\n\n## Use\n\ntext two\n' > "$R/dev/README.md"
  printf 'See dev/ref.md for details.\n' > "$R/dev/index.md"
  printf 'ref body\n' > "$R/dev/ref.md"
  printf '# Architecture\n\nprose\n' > "$R/ARCHITECTURE.md"
  printf '{"plugins":[]}\n' > "$R/.claude-plugin/marketplace.json"
  printf 'a\000b\000c' > "$R/dev/blob.bin"
  git -C "$R" add -A
  git -C "$R" commit -qm base
}

# Build the two inputs from HEAD vs the working tree, exactly as `plan` does.
build() {
  git -C "$R" add -A
  git -C "$R" -c core.quotePath=false diff --cached --name-status -M HEAD \
    | jq -Rnc '[ inputs | split("\t") | {status: .[0][0:1], path: .[-1]} ]' > "$IN/files.json"
  git -C "$R" -c core.quotePath=false diff --cached -M -U0 HEAD \
    -- . ':(exclude,glob)**/agents/*.md' ':(exclude,glob)**/skills/*/SKILL.md' > "$IN/patch.diff"
  git -C "$R" -c core.quotePath=false diff --cached -M --unified=10000 HEAD \
    -- ':(glob)**/agents/*.md' ':(glob)**/skills/*/SKILL.md' >> "$IN/patch.diff"
}

judge() {  # build, then run the selector on the built inputs
  build
  run --separate-stderr zsh "$SEL" --files "$IN/files.json" --patch "$IN/patch.diff"
}

# expect <run|skip> <compact triggers JSON>
expect() {
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .contract)" = "$1" ]
  [ "$(echo "$output" | jq -c .triggers)" = "$2" ]
}

# ---- each trigger --------------------------------------------------------------

@test "architecture: ARCHITECTURE.md in the delta runs contract" {
  printf '# Architecture\n\nprose, revised\n' > "$R/ARCHITECTURE.md"
  judge
  expect run '["architecture"]'
}

@test "claude-plugin-manifest: a .claude-plugin/ path runs contract" {
  printf '{"plugins":[{"name":"dev"}]}\n' > "$R/.claude-plugin/marketplace.json"
  judge
  expect run '["claude-plugin-manifest"]'
}

@test "frontmatter: a changed name: line in a SKILL.md runs contract" {
  sed -i.bak 's/^name: x$/name: y/' "$R/dev/skills/x/SKILL.md" && rm "$R/dev/skills/x/SKILL.md.bak"
  judge
  expect run '["frontmatter"]'
}

@test "frontmatter: a non-name key (a changed model: line) in an agent runs contract" {
  sed -i.bak 's/^model: opus$/model: sonnet/' "$R/dev/agents/rev.md" && rm "$R/dev/agents/rev.md.bak"
  judge
  expect run '["frontmatter"]'
}

@test "frontmatter: a changed closing fence line counts as frontmatter" {
  # the closing `---` itself rewritten to carry a trailing key line before it
  printf -- '---\nname: rev\ndescription: reviews\nmodel: opus\ntools: Read\ncolor: red\n---\n\nYou review.\n' > "$R/dev/agents/rev.md"
  judge
  expect run '["frontmatter"]'
}

@test "script-interface: a changed case-arm label runs contract" {
  sed -i.bak 's/  --old) shift ;;/  --new) shift ;;/' "$R/dev/scripts/tool.zsh" && rm "$R/dev/scripts/tool.zsh.bak"
  judge
  expect run '["script-interface"]'
}

@test "script-interface: a changed getopts line runs contract" {
  printf 'while getopts "ab:" opt; do :; done\n' >> "$R/dev/scripts/tool.zsh"
  judge
  expect run '["script-interface"]'
}

@test "script-interface: a changed zparseopts line runs contract" {
  printf 'zparseopts -D -E -- -verbose=v\n' >> "$R/dev/scripts/tool.zsh"
  judge
  expect run '["script-interface"]'
}

@test "script-interface: a changed line holding mixed-case Usage runs contract" {
  printf 'print -u2 "Usage: tool [--new]"\n' >> "$R/dev/scripts/tool.zsh"
  judge
  expect run '["script-interface"]'
}

@test "script-interface: a case-arm label in a *.bash file runs contract" {
  sed -i.bak 's/  run) echo run ;;/  walk) echo walk ;;/' "$R/dev/scripts/t.bash" && rm "$R/dev/scripts/t.bash.bak"
  judge
  expect run '["script-interface"]'
}

@test "script-interface: a body line that is no arm, getopts, zparseopts or usage skips" {
  sed -i.bak 's/^print done$/print finished/' "$R/dev/scripts/tool.zsh" && rm "$R/dev/scripts/tool.zsh.bak"
  judge
  expect skip '[]'
}

@test "path-change: an added shipped file runs contract" {
  printf 'new\n' > "$R/dev/new.txt"
  judge
  expect run '["path-change"]'
}

@test "path-change: a deleted shipped file runs contract" {
  rm "$R/dev/ref.md"
  judge
  expect run '["path-change"]'
}

@test "path-change: a renamed shipped file runs contract" {
  git -C "$R" mv dev/index.md dev/contents.md
  judge
  expect run '["path-change"]'
  [ "$(jq -r '.[0].status' "$IN/files.json")" = "R" ]
}

@test "heading: a reworded heading in a shipped .md runs contract" {
  sed -i.bak 's/^## Install$/## Installing/' "$R/dev/README.md" && rm "$R/dev/README.md.bak"
  judge
  expect run '["heading"]'
}

@test "heading: a removed heading in a shipped .md runs contract" {
  sed -i.bak '/^## Use$/d' "$R/dev/README.md" && rm "$R/dev/README.md.bak"
  judge
  expect run '["heading"]'
}

@test "triggers are listed in the fixed order, each once" {
  printf '# Architecture v2\n\nprose\n' > "$R/ARCHITECTURE.md"   # architecture + heading
  printf '{"plugins":[1]}\n' > "$R/.claude-plugin/marketplace.json"
  sed -i.bak 's/^model: opus$/model: haiku/' "$R/dev/agents/rev.md" && rm "$R/dev/agents/rev.md.bak"
  sed -i.bak 's/  --old) shift ;;/  --new) shift ;;/' "$R/dev/scripts/tool.zsh" && rm "$R/dev/scripts/tool.zsh.bak"
  printf 'x\n' > "$R/dev/added.txt"
  sed -i.bak 's/^## Install$/## Setup/' "$R/dev/README.md" && rm "$R/dev/README.md.bak"
  judge
  expect run '["architecture","claude-plugin-manifest","frontmatter","script-interface","path-change","heading"]'
}

# ---- skips -----------------------------------------------------------------------

@test "a bats-only delta skips contract" {
  printf 'load more\n' >> "$R/tests/a.bats"
  printf 'new\n' > "$R/tests/b.bats"   # an ADDED test file is not shipped
  judge
  expect skip '[]'
}

@test "a prose-only SKILL.md body edit wholly after the closing --- skips contract" {
  sed -i.bak 's/^body line 30$/body line thirty/' "$R/dev/skills/x/SKILL.md" && rm "$R/dev/skills/x/SKILL.md.bak"
  judge
  expect skip '[]'
}

@test "a content edit (M) to a file another shipped file references by path skips contract" {
  printf 'ref body, revised\n' > "$R/dev/ref.md"
  judge
  expect skip '[]'
}

@test "a body-only edit to a shipped .md skips contract" {
  sed -i.bak 's/^text one$/text one, revised/' "$R/dev/README.md" && rm "$R/dev/README.md.bak"
  judge
  expect skip '[]'
}

@test "a purely added heading in a shipped .md skips contract" {
  printf '\n## Extra\n\nmore\n' >> "$R/dev/README.md"
  judge
  expect skip '[]'
}

@test "a heading change in a .md under tests/ skips contract" {
  sed -i.bak 's/^# Notes$/# Test notes/' "$R/tests/notes.md" && rm "$R/tests/notes.md.bak"
  judge
  expect skip '[]'
}

# ---- undecidable (fail-closed) -------------------------------------------------

@test "undecidable: --files names a missing file" {
  build
  run --separate-stderr zsh "$SEL" --files "$IN/nope.json" --patch "$IN/patch.diff"
  expect run '["undecidable"]'
}

@test "undecidable: --patch names an unreadable file" {
  build
  chmod 000 "$IN/patch.diff"
  if [ -r "$IN/patch.diff" ]; then skip "running as a user who can read mode-000 files"; fi
  run --separate-stderr zsh "$SEL" --files "$IN/files.json" --patch "$IN/patch.diff"
  chmod 644 "$IN/patch.diff"
  expect run '["undecidable"]'
}

@test "undecidable: --files is not an array of {status, path} with a known status" {
  : > "$IN/p.diff"
  for bad in '{}' '"x"' '[{"status":"M"}]' '[{"status":"X","path":"dev/a"}]' \
             '[{"status":"R100","path":"dev/a"}]' '[{"status":"M","path":""}]' '[] []' 'not json'; do
    printf '%s\n' "$bad" > "$IN/f.json"
    run --separate-stderr zsh "$SEL" --files "$IN/f.json" --patch "$IN/p.diff"
    expect run '["undecidable"]'
  done
}

@test "undecidable: a Binary files line for a shipped file" {
  printf 'a\000z\000c' > "$R/dev/blob.bin"
  judge
  expect run '["undecidable"]'
  grep -q '^Binary files ' "$IN/patch.diff"
}

@test "undecidable: a shipped file with status T" {
  printf '[{"status":"T","path":"dev/ref.md"}]\n' > "$IN/f.json"
  : > "$IN/p.diff"
  run --separate-stderr zsh "$SEL" --files "$IN/f.json" --patch "$IN/p.diff"
  expect run '["undecidable"]'
}

@test "undecidable: a shipped M file with no diff --git section (list and patch disagree)" {
  printf '[{"status":"M","path":"dev/ref.md"}]\n' > "$IN/f.json"
  : > "$IN/p.diff"
  run --separate-stderr zsh "$SEL" --files "$IN/f.json" --patch "$IN/p.diff"
  expect run '["undecidable"]'
}

@test "undecidable: a mode-only change on a script" {
  chmod +x "$R/dev/scripts/tool.zsh"
  judge
  expect run '["undecidable"]'
}

@test "undecidable: a mode-only change on an agent" {
  chmod +x "$R/dev/agents/rev.md"
  judge
  expect run '["undecidable"]'
}

@test "undecidable: a mode-only change on a SKILL.md" {
  chmod +x "$R/dev/skills/x/SKILL.md"
  judge
  expect run '["undecidable"]'
}

@test "a mode-only change on any other shipped file is not undecidable" {
  chmod +x "$R/dev/ref.md"
  judge
  expect skip '[]'
}

@test "undecidable: a SKILL.md with an opening --- and no closing ---" {
  mkdir -p "$R/dev/skills/open"
  printf -- '---\nname: open\n\nbody one\nbody two\n' > "$R/dev/skills/open/SKILL.md"
  git -C "$R" add -A && git -C "$R" commit -qm open
  sed -i.bak 's/^body two$/body 2/' "$R/dev/skills/open/SKILL.md" && rm "$R/dev/skills/open/SKILL.md.bak"
  judge
  expect run '["undecidable"]'
}

@test "undecidable: an agent or SKILL.md section with a -U0 hunk instead of whole-file context" {
  sed -i.bak 's/^body line 30$/body line thirty/' "$R/dev/skills/x/SKILL.md" && rm "$R/dev/skills/x/SKILL.md.bak"
  sed -i.bak 's/^You review.$/You review it./' "$R/dev/agents/rev.md" && rm "$R/dev/agents/rev.md.bak"
  build
  # the same delta, every path at -U0 — the agent/SKILL.md fences are invisible
  git -C "$R" diff --cached -M -U0 HEAD > "$IN/u0.diff"
  run --separate-stderr zsh "$SEL" --files "$IN/files.json" --patch "$IN/u0.diff"
  expect run '["undecidable"]'
  # the control: the whole-file build of that delta skips
  run --separate-stderr zsh "$SEL" --files "$IN/files.json" --patch "$IN/patch.diff"
  expect skip '[]'
}

# ---- interface -------------------------------------------------------------------

@test "a usage error exits 2: no flags, an unknown flag, a flag without a value, a stray argument" {
  run --separate-stderr zsh "$SEL"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SEL" --files a.json
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SEL" --files a.json --patch p.diff --base x
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SEL" --files --patch p.diff
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$SEL" --files a.json --patch p.diff extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the selector is pure: it never calls git" {
  sed -i.bak 's/  --old) shift ;;/  --new) shift ;;/' "$R/dev/scripts/tool.zsh" && rm "$R/dev/scripts/tool.zsh.bak"
  build
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch "%s/git-called"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr zsh "$SEL" --files "$IN/files.json" --patch "$IN/patch.diff"
  expect run '["script-interface"]'
  [ ! -e "$BATS_TEST_TMPDIR/git-called" ]
}
