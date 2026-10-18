#!/usr/bin/env bats
#
# sole-go-skipped-templates.zsh — the file-level half of folding the source-only
# CI checks into the Go gate (#2128, #2617): the one place the set of templates
# a sole-Go render skips is written down. SKILL.md Step 3 subtracts it,
# detect-stack.sh holds it out of missing_artifacts, and the render tests
# enumerate their rows through it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKIPPED="$REPO_ROOT/development/skills/bootstrap/scripts/sole-go-skipped-templates.zsh"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
}

# the five common workflows every sole-Go render skips, as the selector prints them
always_skipped() {
  printf '%s\n' common/.github/workflows/contracts-lint.yml.tmpl common/.github/workflows/contracts-semver.yml.tmpl \
    common/.github/workflows/docs.yml.tmpl common/.github/workflows/gitleaks.yml \
    common/.github/workflows/no-cluster-deploy.yml.tmpl
}

@test "#2617: a sole-Go repo with no Dockerfile and no swift skips the five folded workflows and both quality files" {
  local vis want
  for vis in public private; do
    run --separate-stderr zsh "$SKIPPED" --primary go --languages go --visibility "$vis" --docker false
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    want="$({ always_skipped; printf '%s\n' "$vis/.github/workflows/quality-$vis-noop.yml.tmpl" \
      "$vis/.github/workflows/quality-$vis.yml.tmpl"; } | LC_ALL=C sort)"
    [ "$output" = "$want" ] || { printf '%s got:\n%s\nwant:\n%s\n' "$vis" "$output" "$want"; return 1; }
  done
}

@test "#2617: a Dockerfile, or swift among the languages, keeps both quality files" {
  local args
  for args in "go true" "go_swift false" "go_swift true"; do
    read -r langs docker <<< "$args"
    run --separate-stderr zsh "$SKIPPED" --primary go --languages "${langs//_/ }" --visibility private --docker "$docker"
    [ "$status" -eq 0 ]
    [ "$output" = "$(always_skipped)" ] || { echo "[$args] got: $output"; return 1; }
  done
}

@test "#2617: every relpath the selector prints is a real template" {
  local vis rel
  for vis in public private; do
    while IFS= read -r rel; do
      [ -f "$TEMPLATES/$rel" ] || { echo "no template: $rel"; return 1; }
    done < <(zsh "$SKIPPED" --primary go --languages go --visibility "$vis" --docker false)
  done
}

@test "#2617: a repo that is not sole-Go gets an empty set" {
  local args
  for args in "go go_python" "go go_javascript" "go go_java" "python python" "swift swift" "kubernetes _"; do
    read -r primary langs <<< "$args"
    langs="${langs//_/ }"
    run --separate-stderr zsh "$SKIPPED" --primary "$primary" --languages "${langs# }" --visibility public --docker false
    [ "$status" -eq 0 ] || { echo "[$args] exited $status"; return 1; }
    [ -z "$output" ] || { echo "[$args] printed: $output"; return 1; }
  done
}

@test "#2617: SKILL.md states the sole-Go subtraction and the leftovers report where Step 3 and Step 5 act on them" {
  local skill joined n
  skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  joined="$(tr -s '[:space:]' ' ' < "$skill")"
  local -a needles=(
    '**The sole-Go subtraction (#2617).** For a **sole-Go** repo (`is-sole-go.zsh` exits 0, #2615) the gate in `go-ci.yml` runs every source-only check (#2614), so Step 3 renders and copies **none** of the templates this prints — in §3a, §3b, §3h and §3i alike:'
    '"<skill-base-dir>/scripts/sole-go-skipped-templates.zsh" --primary <primary> \ --languages "<languages>" --visibility <public|private> --docker <true|false>'
    'Exit 2 is your own malformed call: fix it and re-run. Exit 1 means `is-sole-go.zsh` failed: stop and relay its message.'
    'and `swift` for the `test-and-coverage-swift` job and the noop'"'"'s `test-and-coverage`, which report the `test-and-coverage` check #2616 still requires for Go+Swift.'
    '`toolchain-templates.zsh` keeps its contract; subtract this set from what it prints.'
    'A re-run deletes no file (#2126 owns removal); Step 5 reports what is left over.'
    '**A sole-Go render stops unless Step 4b will narrow (#2617).** Before Step 3 renders a sole-Go repo, check that the recorded `gate:` in `.maintenance.yml` is absent or `make check` (read as `{{GATE_COMMAND}}`'"'"'s row reads it), and that the `.pre-commit-config.yaml` this run writes or keeps carries the `id: semgrep` hook'
    'If either fails, stop and render nothing, because the gate would not run the folded checks and Step 4b'"'"'s branch protection would require checks no workflow reports.'
    'Name the fix: restore `gate: make check`, or add the semgrep hook from that template, then re-run.'
    'This same run renders `go-ci.yml` and `scripts/go-gate.zsh`, so only an older repo can still reach Step 4b'"'"'s sole-Go fallbacks, and it still carries its old workflows.'
    'quoting the warning. A fresh render never gets here: §3b'"'"'s sole-Go render stop comes first.'
    'a **sole-Go** repo drops both unless a Dockerfile or `swift` keeps them (the sole-Go subtraction below) |'
    '**Not for a sole-Go repo**, whose gate runs gitleaks (§3b'"'"'s sole-Go subtraction, #2617).'
    'On a **sole-Go** repo only the checker renders: its gate runs it, so the workflow is skipped (§3b'"'"'s sole-Go subtraction, #2617).'
    'On a **sole-Go** repo drop `common/.github/workflows/docs.yml.tmpl` from that list'
    'On a **sole-Go** repo drop `contracts-lint.yml.tmpl` and `contracts-semver.yml.tmpl` from that list'
    'combination except a **sole-Go** repo, where `NOT_SOLE_GO` strips them and `trivy-fs` with them (#2617), keeping only a Go+Swift noop'"'"'s `test-and-coverage`;'
    '"<skill-base-dir>/scripts/sole-go-leftovers.zsh" --repo . --visibility <public|private> \ --docker <true|false>'
    'Quote its output verbatim under a **Leftover folded CI (removal: #2126)** heading. Omit the heading when the output is empty, as it always is for a repo that is not sole-Go.'
    'On exit 1, say under that heading that the leftover check could not run, quoting its stderr.'
  )
  for n in "${needles[@]}"; do
    contains "$joined" "$n" || { echo "missing: $n"; return 1; }
  done
  contains "$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh")" \
    '# A sole-Go repo renders less than this set: SKILL.md Step 3 subtracts what # sole-go-skipped-templates.zsh prints (#2617)'
}

@test "#2617: a missing or out-of-set flag is a usage error, exit 2" {
  local drop
  for drop in primary languages visibility docker; do
    local -a args=(--primary go --languages go --visibility public --docker false)
    local -a kept=() i
    for ((i = 0; i < ${#args[@]}; i += 2)); do
      [ "${args[i]}" = "--$drop" ] || kept+=("${args[i]}" "${args[i + 1]}")
    done
    run --separate-stderr zsh "$SKIPPED" "${kept[@]}"
    [ "$status" -eq 2 ] || { echo "without --$drop: $status"; return 1; }
    [ -z "$output" ]
    contains "$stderr" "--$drop is required"
  done
  run --separate-stderr zsh "$SKIPPED" --primary go --languages go --visibility internal --docker false
  [ "$status" -eq 2 ]
  contains "$stderr" "--visibility must be public or private"
  run --separate-stderr zsh "$SKIPPED" --primary go --languages go --visibility public --docker yes
  [ "$status" -eq 2 ]
  contains "$stderr" "--docker must be true or false"
  run --separate-stderr zsh "$SKIPPED" --primary go --languages go --visibility public --docker
  [ "$status" -eq 2 ]
  contains "$stderr" "--docker needs a value"
  run --separate-stderr zsh "$SKIPPED" --primary go --languages go --visibility public --docker false --bogus x
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --bogus"
}
