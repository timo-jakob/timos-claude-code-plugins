#!/usr/bin/env bats
#
# The bootstrap templates' executable bits (#1632). Since #1604 render.zsh
# mirrors a template's mode onto its output in both directions, so a script
# template committed 100644 ships non-executable into every bootstrapped repo
# (check-ops-conformance.zsh did: the resilience READMEs run it by path and hit
# permission denied). The invariant is swept over every tracked template rather
# than a named list, so a new script template added without the bit fails here
# the day it lands. The mode checked is the one git RECORDS — what a clone gets —
# never the working-tree bit, which is a local accident.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every bootstrap template with a shebang is committed 100755, and every 100755 template has a shebang (#1632)" {
  local line meta mode file first seen=0 shebangs=0 bad=()
  while IFS= read -r line; do
    # `<mode> <sha> <stage>\t<path>` — split on the tab so a path may hold spaces
    meta=${line%%$'\t'*}
    file=${line#*$'\t'}
    mode=${meta%% *}
    seen=$((seen + 1))
    first=$(head -c2 "$REPO_ROOT/$file")
    if [ "$first" = '#!' ]; then
      shebangs=$((shebangs + 1))
      [ "$mode" = 100755 ] || bad+=("shebang but $mode: $file")
    elif [ "$mode" = 100755 ]; then
      bad+=("100755 but no shebang: $file")
    fi
  done < <(git -C "$REPO_ROOT" ls-files -s -- development/skills/bootstrap/templates)
  # a mis-pathed sweep must fail, not pass vacuously
  [ "$seen" -gt 0 ]
  [ "$shebangs" -gt 0 ]
  if [ "${#bad[@]}" -gt 0 ]; then
    printf '%s\n' "${bad[@]}"
    return 1
  fi
}
