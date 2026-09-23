#!/usr/bin/env bats
#
# Tests for resolve-tools.zsh (#1651) — the quality toolchain as a DECLARATION in
# .maintenance.yml's `tools:` block rather than a consequence of visibility. The
# contract pinned here: per-category resolution (recorded → chosen → default),
# the ordered validation procedure whose FIRST failing step wins with one exact
# stderr message, the two rejected combinations (public + sonarqube, since
# SonarQube runs on a self-hosted runner; private + codeql, since CodeQL on a
# private repository needs GitHub Advanced Security, #1670), and --record's
# byte-preserving merge.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/resolve-tools.zsh"
  TEMPLATE="$REPO_ROOT/development/skills/bootstrap/templates/common/.maintenance.yml.tmpl"
  cd "$BATS_TEST_TMPDIR"
  M="$BATS_TEST_TMPDIR/.maintenance.yml"
}

# expected stdout for a resolution, in the script's fixed key order
lines() { # <sa> <sa_src> <v> <v_src> <cs> <cs_src> <runner>
  printf 'static_analysis=%s\nstatic_analysis_source=%s\nvulnerabilities=%s\nvulnerabilities_source=%s\ncode_scanning=%s\ncode_scanning_source=%s\nself_hosted_runner=%s' "$@"
}

STEP4='resolve-tools: tools.static_analysis: sonarqube is not supported on a public repository — SonarQube runs on a self-hosted runner, and a public repository must never have one (fork pull requests could run code on it). Declare static_analysis: sonarcloud, or make the repository private.'

STEP4_CODEQL='resolve-tools: tools.code_scanning: codeql is not supported on a private repository — CodeQL on a private repository needs GitHub Advanced Security. Declare code_scanning: none, or make the repository public.'

# --- defaults -------------------------------------------------------------------

@test "resolve-tools: public, nothing declared -> sonarcloud/snyk/codeql, all default, GitHub-hosted" {
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarcloud default snyk default codeql default false)" ]
  [ -z "$stderr" ]
}

@test "resolve-tools: private, nothing declared -> sonarqube/trivy/none, all default, self-hosted" {
  run --separate-stderr zsh "$S" --visibility private
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube default trivy default none default true)" ]
}

@test "resolve-tools: an empty tools: key and a null one both record nothing" {
  local body
  for body in 'tools:' 'tools: null' 'tools: ~' 'tools: ""' 'tools: {}' $'tools:\n  code_scanning: ""'; do
    printf 'primary: java\n%s\n' "$body" > "$M"
    run --separate-stderr zsh "$S" --visibility public
    [ "$status" -eq 0 ]
    [ "$output" = "$(lines sonarcloud default snyk default codeql default false)" ]
  done
}

@test "resolve-tools: --maintenance-file is read instead of ./.maintenance.yml" {
  printf 'tools:\n  code_scanning: none\n' > "$BATS_TEST_TMPDIR/other.yml"
  printf 'tools:\n  code_scanning: codeql\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --maintenance-file "$BATS_TEST_TMPDIR/other.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube default trivy default none recorded true)" ]
}

# --- source precedence ------------------------------------------------------------

@test "resolve-tools: a recorded value wins over a contradicting flag (source recorded)" {
  printf 'tools:\n  static_analysis: sonarqube\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --static-analysis sonarcloud
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube recorded trivy default none default true)" ]
}

@test "resolve-tools: a flag with no recorded value applies (source chosen), per category" {
  printf 'tools:\n  static_analysis: sonarqube\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube recorded trivy chosen none chosen true)" ]
}

@test "resolve-tools: self_hosted_runner follows static_analysis alone" {
  # sonarcloud on a private repo is GitHub-hosted even with trivy and no codeql
  run --separate-stderr zsh "$S" --visibility private --static-analysis sonarcloud
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarcloud chosen trivy default none default false)" ]
}

# --- step 1 -------------------------------------------------------------------------

@test "resolve-tools: step 1 — a missing --visibility exits 1 with the exact message, stdout empty" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: --visibility is required — allowed: public | private" ]
}

@test "resolve-tools: step 1 — --visibility internal is not supported" {
  run --separate-stderr zsh "$S" --visibility internal
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: --visibility: internal is not supported — allowed: public | private" ]
}

@test "resolve-tools: step 1 — a scalar tools: and a list tools: are each rejected by shape" {
  printf 'tools: sonarcloud\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools: must be a mapping of static_analysis, vulnerabilities, code_scanning — got a scalar" ]
  printf 'tools:\n  - sonarcloud\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools: must be a mapping of static_analysis, vulnerabilities, code_scanning — got a list" ]
}

@test "resolve-tools: step 1 — an unknown key under tools: is named" {
  printf 'tools:\n  static_analysis: sonarcloud\n  secrets: gitleaks\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: unknown key tools.secrets — allowed: static_analysis, vulnerabilities, code_scanning" ]
}

@test "resolve-tools: step ordering — an unknown key (step 1) wins over an unsupported value (step 2)" {
  printf 'tools:\n  code_scanning: semgrep\n  secrets: gitleaks\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: unknown key tools.secrets — allowed: static_analysis, vulnerabilities, code_scanning" ]
}

@test "resolve-tools: step 1 — visibility is checked before the tools: shape" {
  printf 'tools: sonarcloud\n' > "$M"
  run --separate-stderr zsh "$S" --visibility internal
  [ "$stderr" = "resolve-tools: --visibility: internal is not supported — allowed: public | private" ]
}

# --- step 2 -------------------------------------------------------------------------

@test "resolve-tools: step 2 — an unsupported recorded or flag value names its category and set" {
  printf 'tools:\n  code_scanning: semgrep\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools.code_scanning: semgrep is not supported — allowed: codeql | none" ]
  rm "$M"
  run --separate-stderr zsh "$S" --visibility private --vulnerabilities grype
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools.vulnerabilities: grype is not supported — allowed: snyk | trivy" ]
  # an empty flag is still a declared value, not "nothing chosen"
  run --separate-stderr zsh "$S" --visibility private --static-analysis ''
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-tools: tools.static_analysis:  is not supported — allowed: sonarcloud | sonarqube" ]
}

@test "resolve-tools: step 2 — a bad flag is rejected even where a recorded value would win" {
  printf 'tools:\n  vulnerabilities: trivy\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --vulnerabilities grype
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools.vulnerabilities: grype is not supported — allowed: snyk | trivy" ]
}

@test "resolve-tools: step 2 — a list or map as a category value is unsupported, not 'nothing recorded'" {
  local body
  for body in $'tools:\n  code_scanning:\n    - codeql' $'tools:\n  code_scanning:\n    engine: codeql'; do
    printf '%s\n' "$body" > "$M"
    run --separate-stderr zsh "$S" --visibility private
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    starts_with "$stderr" "resolve-tools: tools.code_scanning: "
    ends_with "$stderr" " is not supported — allowed: codeql | none"
  done
}

@test "resolve-tools: step ordering — an unsupported value fails step 2 before public+sonarqube fails step 4" {
  printf 'tools:\n  static_analysis: sonarqube\n  vulnerabilities: grype\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-tools: tools.vulnerabilities: grype is not supported — allowed: snyk | trivy" ]
}

# --- step 4 -------------------------------------------------------------------------

@test "resolve-tools: step 4 — public + sonarqube is rejected whether chosen or recorded" {
  run --separate-stderr zsh "$S" --visibility public --static-analysis sonarqube
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$STEP4" ]
  printf 'tools:\n  static_analysis: sonarqube\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --static-analysis sonarcloud
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$STEP4" ]
}

@test "resolve-tools: step 4 — private + codeql is rejected whether chosen or recorded (#1670)" {
  run --separate-stderr zsh "$S" --visibility private --code-scanning codeql
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$STEP4_CODEQL" ]
  contains "$stderr" "GitHub Advanced Security"
  printf 'tools:\n  code_scanning: codeql\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --code-scanning none
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$STEP4_CODEQL" ]
  # public + codeql still resolves, recorded or chosen
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarcloud default snyk default codeql recorded false)" ]
  rm "$M"
  run --separate-stderr zsh "$S" --visibility public --code-scanning codeql
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarcloud default snyk default codeql chosen false)" ]
}

@test "resolve-tools: step 4 — its rejections never record" {
  printf 'primary: java\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private --code-scanning codeql --record
  [ "$status" -eq 1 ]
  [ "$(cat "$M")" = "primary: java" ]
  run --separate-stderr zsh "$S" --visibility public --static-analysis sonarqube --record
  [ "$status" -eq 1 ]
  [ "$(cat "$M")" = "primary: java" ]
}

@test "resolve-tools: exactly the 8 D4 combinations resolve (exit 0); the other 8 are rejected at step 4" {
  local vis sa v cs ok=0 rejected=0 runner
  for vis in public private; do
    for sa in sonarcloud sonarqube; do
      for v in snyk trivy; do
        for cs in codeql none; do
          run --separate-stderr zsh "$S" --visibility "$vis" \
            --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs"
          if [ "$vis/$sa" = public/sonarqube ]; then
            [ "$status" -eq 1 ]
            [ "$stderr" = "$STEP4" ]
            [ -z "$output" ]
            rejected=$((rejected + 1))
          elif [ "$vis/$cs" = private/codeql ]; then
            [ "$status" -eq 1 ]
            [ "$stderr" = "$STEP4_CODEQL" ]
            [ -z "$output" ]
            rejected=$((rejected + 1))
          else
            # every valid combination resolves — no default-only guard (#1670)
            [ "$status" -eq 0 ]
            [ -z "$stderr" ]
            if [ "$sa" = sonarqube ]; then runner=true; else runner=false; fi
            [ "$output" = "$(lines "$sa" chosen "$v" chosen "$cs" chosen "$runner")" ]
            ok=$((ok + 1))
          fi
        done
      done
    done
  done
  [ "$ok" -eq 8 ]
  [ "$rejected" -eq 8 ]
}

@test "resolve-tools: a recorded non-default toolchain resolves and --record completes it (no step 5)" {
  printf 'primary: java\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: none\n' > "$M"
  run --separate-stderr zsh "$S" --visibility private
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(lines sonarcloud recorded snyk recorded none recorded false)" ]
  printf 'primary: java\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --code-scanning none --record
  [ "$status" -eq 0 ]
  [ "$(yq -o=json -I=0 '.tools' "$M")" = '{"static_analysis":"sonarcloud","vulnerabilities":"snyk","code_scanning":"none"}' ]
  # the script no longer describes or implements a temporary guard
  run ! grep -qiE 'step 5|temporary guard|cannot be rendered yet' "$S"
}

# --- --record ---------------------------------------------------------------------------

@test "resolve-tools: --record appends the template's own block when tools: is absent" {
  printf 'primary: java\n# a comment\ngate: make lint\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility private --record
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube default trivy default none default true)" ]
  # every pre-existing byte is still there, in front
  [ "$(head -c "$(wc -c < "$BATS_TEST_TMPDIR/before")" "$M")" = "$(cat "$BATS_TEST_TMPDIR/before")" ]
  # the appended text is exactly the template's TOOLCHAIN block, markers and all,
  # so a merged repo and a freshly rendered one carry the same bytes
  expected="$(sed -n '/TOOLCHAIN-START/,/TOOLCHAIN-END/p' "$TEMPLATE" |
    sed -e 's/{{STATIC_ANALYSIS}}/sonarqube/' -e 's/{{VULNERABILITIES}}/trivy/' -e 's/{{CODE_SCANNING}}/none/')"
  [ "$(tail -n +4 "$M")" = "$expected" ]
  [ "$(yq -r '.tools.code_scanning' "$M")" = none ]
}

@test "resolve-tools: --record adds a newline first when the file lacks a trailing one" {
  printf 'primary: java' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$M")" = "primary: java" ]
  # exactly one newline was added: the block starts on line 2, no blank line between
  [ "$(sed -n 2p "$M")" = "# --- TOOLCHAIN-START ---" ]
  [ "$(yq -r '.primary' "$M")" = java ]
  [ "$(yq -r '.tools.static_analysis' "$M")" = sonarcloud ]
}

@test "resolve-tools: --record nests the three keys inside an empty or null tools: key" {
  printf 'primary: java\ntools:\nnext: 1\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'primary: java\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: codeql\nnext: 1')" ]
  printf 'primary: java\ntools: null  # set by hand\nnext: 1\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'primary: java\ntools: # set by hand\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: codeql\nnext: 1')" ]
  # `{}` is the canonical empty mapping: nested under a bare tools:, never refused as flow style
  printf 'primary: java\ntools: {}\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'primary: java\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: codeql')" ]
  # a bare tools: carrying only a comment has no value to drop: its line stays byte-for-byte
  printf 'primary: java\ntools:   # decided later\nnext: 1\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'primary: java\ntools:   # decided later\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: codeql\nnext: 1')" ]
}

@test "resolve-tools: --record fills only the missing keys of a partial block, at its indentation" {
  printf 'primary: java\ntools:\n    code_scanning: codeql   # keep me\n    # inner comment\n\n# outer comment\nnext: 2\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'primary: java\ntools:\n    code_scanning: codeql   # keep me\n    static_analysis: sonarcloud\n    vulnerabilities: snyk\n    # inner comment\n\n# outer comment\nnext: 2')" ]
}

@test "resolve-tools: --record fills a key that is present with no value instead of duplicating it" {
  printf 'tools:\n  static_analysis:   # decide later\n  vulnerabilities: snyk\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'tools:\n  static_analysis: sonarcloud # decide later\n  vulnerabilities: snyk\n  code_scanning: codeql')" ]
  [ "$(grep -c static_analysis "$M")" -eq 1 ]
  # the key as YAML reads it: a space before the colon, or quotes, name the same key
  printf 'tools:\n  code_scanning :\n  "vulnerabilities": ~\n  static_analysis: sonarcloud\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(grep -c code_scanning "$M")" -eq 1 ]
  [ "$(grep -c vulnerabilities "$M")" -eq 1 ]
  [ "$(yq -o=json -I=0 '.tools' "$M")" = '{"code_scanning":"codeql","vulnerabilities":"snyk","static_analysis":"sonarcloud"}' ]
  printf "tools:\n  'code_scanning':\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n" > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(grep -c code_scanning "$M")" -eq 1 ]
  [ "$(yq -o=json -I=0 '.tools' "$M")" = '{"code_scanning":"codeql","static_analysis":"sonarcloud","vulnerabilities":"snyk"}' ]
}

@test "resolve-tools: --record scans past a blank line and a column-0 comment inside the block" {
  # both are legal inside a block mapping; ending the scan at either would miss the
  # null code_scanning below them and add a duplicate key
  printf 'tools:\n  static_analysis: sonarcloud\n\n# chosen by the platform team\n  code_scanning:\nnext: 1\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = "$(printf 'tools:\n  static_analysis: sonarcloud\n\n# chosen by the platform team\n  code_scanning: codeql\n  vulnerabilities: snyk\nnext: 1')" ]
}

@test "resolve-tools: --record writes the --maintenance-file it is given, not the cwd's" {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  printf 'primary: java\n' > "$BATS_TEST_TMPDIR/repo/.maintenance.yml"
  printf 'sentinel: 1\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --maintenance-file "$BATS_TEST_TMPDIR/repo/.maintenance.yml" --record
  [ "$status" -eq 0 ]
  [ "$(yq -r '.tools.static_analysis' "$BATS_TEST_TMPDIR/repo/.maintenance.yml")" = sonarcloud ]
  [ "$(cat "$M")" = "sentinel: 1" ]
}

@test "resolve-tools: a failed write-back exits 1 and keeps the merged text in the temp file it names" {
  [ "$(id -u)" -ne 0 ] || skip "root can write a read-only file"
  printf 'primary: java\ntools:\n  code_scanning: codeql\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  chmod 0444 "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "the merged text is in"
  local kept="${stderr##*the merged text is in }"
  [ "$(yq -r '.tools.static_analysis' "$kept")" = sonarcloud ]
  cmp "$M" "$BATS_TEST_TMPDIR/before"
}

@test "resolve-tools: --record writes through the file — same mode, same inode, no temp file left" {
  printf 'primary: java\ntools:\n  code_scanning: codeql\n' > "$M"
  chmod 0644 "$M"
  local inode
  inode="$(ls -i "$M" | awk '{print $1}')"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$M" 2>/dev/null || stat -f %Lp "$M")" = 644 ]
  [ "$(ls -i "$M" | awk '{print $1}')" = "$inode" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.resolve-tools.*')" ]
}

@test "resolve-tools: --record over a complete block writes nothing — a re-run is byte-identical" {
  printf 'primary: java\ntools:\n  static_analysis: sonarcloud\n  vulnerabilities: snyk\n  code_scanning: codeql\n\n\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  cmp "$M" "$BATS_TEST_TMPDIR/before"
  # "no write at all", not "rewrote the same bytes": a COMPLETE flow-style mapping would
  # hit the flow-style refusal if --record reached the merge at all
  printf 'tools: {static_analysis: sonarcloud, vulnerabilities: snyk, code_scanning: codeql}\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  cmp "$M" "$BATS_TEST_TMPDIR/before"
  # and a file --record just completed is itself stable on the next run
  printf 'primary: java\n' > "$M"
  run zsh "$S" --visibility public --record
  cp "$M" "$BATS_TEST_TMPDIR/after-first"
  run zsh "$S" --visibility public --record
  [ "$status" -eq 0 ]
  cmp "$M" "$BATS_TEST_TMPDIR/after-first"
}

@test "resolve-tools: --record refuses a missing file and a flow-style partial mapping" {
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "--record needs an existing"
  printf 'tools: {code_scanning: codeql}\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "flow-style tools: mapping"
  [ "$(cat "$M")" = "tools: {code_scanning: codeql}" ]
}

@test "resolve-tools: --record refuses, byte-unchanged, a tools key it cannot find as a line" {
  # a quoted key: yq sees tools, the column-0 line scan does not — appending would duplicate it
  printf '"tools":\n  code_scanning: codeql\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "cannot find the top-level tools: line"
  cmp "$M" "$BATS_TEST_TMPDIR/before"
  # an empty value on the line AFTER tools: — merging above it would stop the file parsing
  printf 'primary: java\ntools:\n  {}\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "would not read back; left it unchanged"
  cmp "$M" "$BATS_TEST_TMPDIR/before"
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.resolve-tools.*')" ]
  # the append path is checked the same way: a column-0 block after a flow-style top level
  printf '{primary: java}\n' > "$M"
  cp "$M" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$S" --visibility public --record
  [ "$status" -eq 1 ]
  contains "$stderr" "would not read back; left it unchanged"
  cmp "$M" "$BATS_TEST_TMPDIR/before"
}

# --- yq -----------------------------------------------------------------------------------

@test "resolve-tools: yq is needed only to read a file, and only mikefarah's will do" {
  # PATH replaced wholesale (a host /usr/bin may carry its own yq): zsh, and later a stub yq
  local bin="$BATS_TEST_TMPDIR/bin" msg
  mkdir -p "$bin"
  ln -s "$(command -v zsh)" "$bin/zsh"
  run --separate-stderr env PATH="$bin" "$bin/zsh" "$S" --visibility private
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines sonarqube default trivy default none default true)" ]
  msg="resolve-tools: yq (mikefarah, v4) is required to read ./.maintenance.yml — install it with: brew install yq"
  printf 'primary: java\n' > "$M"
  run --separate-stderr env PATH="$bin" "$bin/zsh" "$S" --visibility private
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$msg" ]
  # python-yq answers `type` in jq's vocabulary; refused by name, not read as a malformed file
  printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$bin/yq"
  chmod +x "$bin/yq"
  run --separate-stderr env PATH="$bin" "$bin/zsh" "$S" --visibility private
  [ "$status" -eq 1 ]
  [ "$stderr" = "$msg" ]
}

# --- usage ------------------------------------------------------------------------------

@test "resolve-tools: an unknown argument, a flag with no value, and --help are usage (exit 2)" {
  run --separate-stderr zsh "$S" --visibility public --frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown argument: --frobnicate"
  contains "$stderr" "usage: resolve-tools.zsh"
  run --separate-stderr zsh "$S" --visibility
  [ "$status" -eq 2 ]
  contains "$stderr" "--visibility needs a value"
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: resolve-tools.zsh"
}

@test "resolve-tools: an unparseable .maintenance.yml fails closed" {
  printf 'tools: [unclosed\n' > "$M"
  run --separate-stderr zsh "$S" --visibility public
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "cannot parse"
}

# --- SKILL.md wording (#1651) --------------------------------------------------------------

@test "resolve-tools: SKILL.md drops 'Do not mix.' for the two rules it protected, and asks Q3a" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  run ! grep -q 'Do not mix\.' "$skill"
  grep -q 'Never render a workflow whose required contexts no job reports' "$skill"
  grep -q 'Never put a self-hosted runner on a public repository' "$skill"
  grep -q '^| \*\*Q3a: Toolchain\*\* |' "$skill"
  grep -q 'This selects the default toolchain' "$skill"
}
