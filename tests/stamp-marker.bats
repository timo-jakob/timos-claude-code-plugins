#!/usr/bin/env bats
#
# Tests for stamp-marker.zsh (#213 provenance markers), added with the #783
# permission-preservation fix: the marker rewrite went through a mktemp temp
# file (mode 600) and a bare mv, silently replacing every stamped file's
# permissions — which stripped the exec bit from the first executable stamped
# file (scripts/docs-nav-to-chapters.zsh) and broke the pdf-epub gate on its
# first real run (ai-doc-organizer#120).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/stamp-marker.zsh"
  # A real template relpath (any template works; the marker records it + sha).
  TPL="common/scripts/docs-nav-to-chapters.zsh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
}

mode_of() { # portable octal mode (BSD stat on macOS, GNU stat in CI)
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

@test "stamp-marker: prepends the marker with template path, version, sha" {
  printf 'key: value\n' > "$R/f.yml"
  run zsh "$S" --repo "$R" --target f.yml --template "$TPL"
  [ "$status" -eq 0 ]
  head -1 "$R/f.yml" | grep -qE "^# claude-bootstrap: rendered from $TPL @ v[0-9.]+ sha256:[0-9a-f]{64}$"
  [ "$(tail -1 "$R/f.yml")" = "key: value" ]
}

@test "stamp-marker: #783 an executable target keeps its exec bit (755 stays 755)" {
  printf '#!/usr/bin/env zsh\necho hi\n' > "$R/tool.zsh"
  chmod 755 "$R/tool.zsh"
  run zsh "$S" --repo "$R" --target tool.zsh --template "$TPL"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$R/tool.zsh")" = "755" ]
}

@test "stamp-marker: #783 the marker goes BELOW a shebang, and the script still runs" {
  # Stamping above the `#!` line hides it from the kernel — bash then executes
  # a zsh script (`emulate: command not found`, the second pdf-epub failure on
  # ai-doc-organizer#120).
  printf '#!/usr/bin/env zsh\nprint -- "still-zsh"\n' > "$R/tool.zsh"
  chmod 755 "$R/tool.zsh"
  run zsh "$S" --repo "$R" --target tool.zsh --template "$TPL"
  [ "$status" -eq 0 ]
  [ "$(head -1 "$R/tool.zsh")" = "#!/usr/bin/env zsh" ]
  sed -n 2p "$R/tool.zsh" | grep -q "^# claude-bootstrap: rendered from "
  run "$R/tool.zsh"
  [ "$status" -eq 0 ]
  [ "$output" = "still-zsh" ]
}

@test "stamp-marker: #783 a plain target keeps its mode (644 stays 644)" {
  printf 'key: value\n' > "$R/f.yml"
  chmod 644 "$R/f.yml"
  run zsh "$S" --repo "$R" --target f.yml --template "$TPL"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$R/f.yml")" = "644" ]
}

@test "stamp-marker: second run is a no-op and the mode survives it" {
  printf '#!/usr/bin/env zsh\n' > "$R/tool.zsh"
  chmod 755 "$R/tool.zsh"
  zsh "$S" --repo "$R" --target tool.zsh --template "$TPL"
  before="$(cat "$R/tool.zsh")"
  run zsh "$S" --repo "$R" --target tool.zsh --template "$TPL"
  [ "$status" -eq 0 ]
  [ "$(cat "$R/tool.zsh")" = "$before" ]
  [ "$(mode_of "$R/tool.zsh")" = "755" ]
}

@test "stamp-marker: missing target / template -> exit 1; missing args -> exit 2" {
  run zsh "$S" --repo "$R" --target nope.yml --template "$TPL"
  [ "$status" -eq 1 ]
  printf 'x\n' > "$R/f.yml"
  run zsh "$S" --repo "$R" --target f.yml --template "common/does-not-exist.tmpl"
  [ "$status" -eq 1 ]
  run zsh "$S" --repo "$R"
  [ "$status" -eq 2 ]
}
