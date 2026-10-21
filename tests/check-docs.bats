#!/usr/bin/env bats
#
# #2640 — check-docs.zsh, the docs stage every language gate shares. These
# cases run the REAL checker from the bootstrap template, with the real
# chapter-order script, in a fixture repository whose python3 (and the venv it
# makes) and docker are logging stubs, so each exit code, the --caller prefix,
# the pinned pandoc image and the --out contract are exercised without a docs
# toolchain. tests/bootstrap-go-gate.bats owns the Go gate's use of it.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  CHECKER="$TEMPLATES/common/scripts/check-docs.zsh"
  ZSH="$(command -v zsh)"
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  R="$BATS_TEST_TMPDIR/repo"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$STUB" "$R/scripts/pandoc" "$R/docs" "$OUT"
  : > "$CALLS"
  export CALLS
  write_stubs
  cp "$CHECKER" "$TEMPLATES/common/scripts/docs-nav-to-chapters.zsh" "$R/scripts/"
  printf 'site_name: Dashboard Service\nrepo_name: "acme/dashboard-service" # the repository\n' > "$R/mkdocs.yml"
  printf 'nav:\n  - Home: index.md\n' >> "$R/mkdocs.yml"
  printf '# Dashboard Service\n' > "$R/docs/index.md"
  printf 'mkdocs-material==9.5.0\n' > "$R/requirements-docs.txt"
}

# python3 makes a venv whose pip and mkdocs log and answer as an env var says; docker stands in
# for the pandoc image: a run writes the manual it was asked for into the directory mounted at
# /out and prints $PANDOC_LOG for the PDF, and the probe reports its dangling link unless
# $PROBE_SILENT is set.
write_stubs() {
  cat > "$STUB/python3" <<'EOF'
#!/bin/sh
echo "python3 $*" >> "$CALLS"
if [ "$1 $2" = "-m venv" ]; then
  mkdir -p "$3/bin"
  printf '#!/bin/sh\necho "pip $*" >> "$CALLS"\nexit "${PIP_INSTALL_RC:-0}"\n' > "$3/bin/pip"
  printf '#!/bin/sh\necho "mkdocs $*" >> "$CALLS"\nexit "${MKDOCS_RC:-0}"\n' > "$3/bin/mkdocs"
  chmod +x "$3/bin/pip" "$3/bin/mkdocs"
fi
exit 0
EOF
  cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$CALLS"
case " $* " in
  *" --entrypoint "*)
    [ -n "${PROBE_SILENT:-}" ] || echo "LaTeX Warning: There were undefined references."
    exit "${PROBE_RC:-0}" ;;
esac
out="" target="" prev=""
for a in "$@"; do
  case "$prev" in
    -v) case "$a" in *:/out) out="${a%:/out}" ;; esac ;;
    -o) target="${a#/out/}" ;;
  esac
  prev="$a"
done
[ -n "${PANDOC_NO_OUTPUT:-}" ] || echo manual > "$out/$target"
[ "$target" = manual.pdf ] && printf '%s\n' "${PANDOC_LOG:-}"
exit "${PANDOC_RC:-0}"
EOF
  chmod +x "$STUB"/*
}

# The checker as a gate would run it, from the repository root, stubs first on PATH, with
# VAR=value stub verdicts before the checker's own arguments.
docs() {
  local -a envs=()
  while [ $# -gt 0 ]; do
    case "$1" in *=*) envs+=("$1"); shift ;; *) break ;; esac
  done
  (cd "$R" && env PATH="$STUB:$PATH" "${envs[@]}" "$ZSH" scripts/check-docs.zsh "$@")
}

@test "#2640: exit 0 builds the site strictly and both manuals into --out, with the pinned pandoc image" {
  local out_abs
  out_abs="$(cd "$OUT" && pwd -P)"
  run --separate-stderr docs --caller python-gate --out "$OUT"
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ -z "$output" ]
  grep -qx 'pip install --quiet -r requirements-docs.txt' "$CALLS"
  grep -qx "mkdocs build --strict --site-dir $out_abs/site" "$CALLS"
  grep -qx "docker run --rm -v $R:/data -v $out_abs:/out -w /data pandoc/extra:3.5 --pdf-engine=xelatex --toc -V fontsize=11pt --metadata title=Dashboard Service --metadata author=acme/dashboard-service --lua-filter=scripts/pandoc/break-long-tokens.lua --include-in-header=scripts/pandoc/manual-header.tex -o /out/manual.pdf docs/index.md" "$CALLS"
  grep -qx "docker run --rm -v $R:/data -v $out_abs:/out -w /data pandoc/extra:3.5 --toc --metadata title=Dashboard Service --metadata author=acme/dashboard-service -o /out/manual.epub docs/index.md" "$CALLS"
  grep -q '^docker run --rm --entrypoint sh pandoc/extra:3.5 -c ' "$CALLS"
  # the manuals and the pandoc log land in --out, and --out itself is left in place
  [ -s "$OUT/manual.pdf" ] && [ -s "$OUT/manual.epub" ] && [ -f "$OUT/pandoc-pdf.log" ]
  [ -d "$OUT" ]
}

@test "#2640: a strict mkdocs warning is exit 1 under the caller's prefix, and without --caller under check-docs" {
  run --separate-stderr docs MKDOCS_RC=1 --caller java-gate --out "$OUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'java-gate: FAIL docs — mkdocs build --strict' ]
  run --separate-stderr docs MKDOCS_RC=1 --out "$OUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'check-docs: FAIL docs — mkdocs build --strict' ]
}

@test "#2640: a failed install, a missing glyph, an unresolved reference, a missing manual and a blind or failed probe are each exit 1" {
  run --separate-stderr docs PIP_INSTALL_RC=1 --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — installing requirements-docs.txt'
  run --separate-stderr docs PANDOC_LOG='[WARNING] Missing character: There is no ≥ in font lmroman10-regular' --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'Missing character: There is no ≥'
  contains "$stderr" 'swift-gate: FAIL docs — xelatex dropped the characters above from manual.pdf'
  run --separate-stderr docs PANDOC_LOG='LaTeX Warning: There were undefined references.' --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — manual.pdf has unresolved references'
  run --separate-stderr docs PROBE_SILENT=1 --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — pandoc no longer reports undefined references'
  run --separate-stderr docs PROBE_RC=125 --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — the pandoc probe container failed'
  rm -f "$OUT"/manual.*
  run --separate-stderr docs PANDOC_NO_OUTPUT=1 --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — a manual was not produced'
  run --separate-stderr docs PANDOC_RC=1 --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: FAIL docs — pandoc manual.pdf'
}

@test "#2640: a failed chapter-order derivation is exit 1" {
  printf '#!/usr/bin/env zsh\nexit 1\n' > "$R/scripts/docs-nav-to-chapters.zsh"
  run --separate-stderr docs --caller swift-gate --out "$OUT"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'swift-gate: FAIL docs — deriving the chapter order' ]
}

@test "#2640: a missing python3 or docker is exit 1 naming the tool" {
  local t bare
  for t in python3 docker; do
    bare="$BATS_TEST_TMPDIR/bare-$t"
    mkdir -p "$bare"
    ln -s "$ZSH" "$bare/zsh"
    [ "$t" = python3 ] || ln -s "$STUB/python3" "$bare/python3"
    run --separate-stderr bash -c 'cd "$1" && PATH="$2" "$3" scripts/check-docs.zsh --caller javascript-gate --out "$4"' _ "$R" "$bare" "$ZSH" "$OUT"
    [ "$status" -eq 1 ]
    [ "$stderr" = "javascript-gate: FAIL docs — $t is not installed" ]
  done
  [ ! -s "$CALLS" ]
}

@test "#2640: a missing, empty or non-directory --out, an empty --caller and an unknown argument are each exit 2, and nothing runs" {
  run --separate-stderr docs --caller python-gate
  [ "$status" -eq 2 ]
  [ "$stderr" = 'python-gate: --out is required' ]
  run --separate-stderr docs --caller python-gate --out ''
  [ "$status" -eq 2 ]
  [ "$stderr" = 'python-gate: --out needs a value' ]
  run --separate-stderr docs --caller python-gate --out
  [ "$status" -eq 2 ]
  [ "$stderr" = 'python-gate: --out needs a value' ]
  # the checker never creates the directory it was given
  run --separate-stderr docs --caller python-gate --out "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 2 ]
  [ "$stderr" = "python-gate: --out $BATS_TEST_TMPDIR/absent is not an existing directory" ]
  [ ! -e "$BATS_TEST_TMPDIR/absent" ]
  : > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr docs --caller python-gate --out "$BATS_TEST_TMPDIR/a-file"
  [ "$status" -eq 2 ]
  run --separate-stderr docs --caller '' --out "$OUT"
  [ "$status" -eq 2 ]
  [ "$stderr" = 'check-docs: --caller needs a value' ]
  run --separate-stderr docs --out "$OUT" --site x
  [ "$status" -eq 2 ]
  [ "$stderr" = 'check-docs: unknown argument: --site' ]
  [ ! -s "$CALLS" ]
}

@test "#2640: -h and --help print the header comment and exit 0" {
  local flag
  for flag in -h --help; do
    run --separate-stderr docs "$flag"
    [ "$status" -eq 0 ]
    contains "$output" 'check-docs.zsh — build this repository'"'"'s docs the way docs.yml does'
    contains "$output" 'Exit codes: 0 built; 1 failed, the reason on stderr; 2 an unknown or malformed argument,'
    lacks "$output" 'emulate -L zsh'
  done
}

@test "#2640: the checker hard-codes no gate's name" {
  run ! grep -q 'go-gate' "$CHECKER"
}
