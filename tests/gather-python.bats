#!/usr/bin/env bats
#
# Behavioral tests for parse-python-coverage.py — the AST line->function region
# mapper — and the gather-python-findings.sh coverage.regions contract (#467,
# Python slice of the region-coverage epic #462).
#
# Hermetic: the parser tests feed a source file + a coverage.json fixture (no
# pytest run); the gather contract test uses the withheld path (no venv/pytest),
# so CI never needs the Python toolchain.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-python-coverage.py"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-python-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
}

@test "parse-python-coverage: maps lines to enclosing functions via AST" {
  mkdir -p "$WORK/src"
  cat > "$WORK/src/mod.py" <<'PY'
def covered(x):
    if x > 0:
        return x
    return -x

def uncovered(x):
    return x * 2
PY
  cat > "$WORK/cov.json" <<'JSON'
{"files": {"src/mod.py": {"executed_lines": [1, 2, 3, 4], "missing_lines": [6, 7]}}}
JSON
  out=$(cd "$WORK" && python3 "$PARSE" cov.json)
  [ "$(jq '.regions | length' <<<"$out")" = "2" ]
  [ "$(jq '[.regions[] | select(.name=="covered")][0] | .start_line==1 and .end_line==4 and .pct==100' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name=="uncovered")][0] | .start_line==6 and .end_line>=.start_line and .pct==0' <<<"$out")" = "true" ]
}

@test "parse-python-coverage: nested function -> both regions, inner span inside outer" {
  mkdir -p "$WORK/src"
  cat > "$WORK/src/nest.py" <<'PY'
def outer():
    def inner():
        return 1
    return inner()
PY
  cat > "$WORK/cov.json" <<'JSON'
{"files": {"src/nest.py": {"executed_lines": [1, 2, 3, 4], "missing_lines": []}}}
JSON
  out=$(cd "$WORK" && python3 "$PARSE" cov.json)
  [ "$(jq '.regions | length' <<<"$out")" = "2" ]
  # inner is contained within outer (smaller span) -> the dispatcher picks innermost
  [ "$(jq '[.regions[] | select(.name=="inner")][0] | .start_line>=2 and .end_line<=4' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name=="outer")][0].start_line==1' <<<"$out")" = "true" ]
}

@test "parse-python-coverage: unreadable/missing source -> no regions for it" {
  cat > "$WORK/cov.json" <<'JSON'
{"files": {"src/ghost.py": {"executed_lines": [1], "missing_lines": []}}}
JSON
  out=$(cd "$WORK" && python3 "$PARSE" cov.json)
  [ "$(jq '.regions | length' <<<"$out")" = "0" ]
}

@test "parse-python-coverage: no args -> regions []" {
  out=$(python3 "$PARSE")
  [ "$(jq -r '.regions | length' <<<"$out")" = "0" ]
}

@test "gather-python: coverage carries a regions array (empty when withheld) (#467)" {
  # No venv/pytest in this hermetic dir -> coverage is withheld -> regions [].
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > "$WORK/pyproject.toml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
}
