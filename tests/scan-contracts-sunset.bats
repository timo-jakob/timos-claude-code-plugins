#!/usr/bin/env bats
#
# Behavioral tests for scan-contracts-sunset.zsh (#708) — the sunset-enforcement
# primitive. It reports, per live major, whether that major carries a
# MAJOR-level x-sunset and whether the date has passed. `--today` pins the
# comparison so these tests never depend on the real clock.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO_ROOT/development/skills/maintenance/scripts/scan-contracts-sunset.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
}

# mkmajor <vN> <version> [sunset-key] [sunset-date]
#   sunset-key: "root" | "info" | "" (none)
mkmajor() {
  local dir="$1" ver="$2" key="${3:-}" date="${4:-}"
  mkdir -p "$WORK/contracts/$dir"
  {
    printf 'openapi: 3.1.0\n'
    if [[ "$key" == "root" ]]; then printf 'x-sunset: "%s"\n' "$date"; fi
    printf 'info:\n  title: T\n  version: "%s"\n' "$ver"
    if [[ "$key" == "info" ]]; then printf '  x-sunset: "%s"\n' "$date"; fi
  } > "$WORK/contracts/$dir/openapi.yaml"
  return 0
}

@test "#708 scan: no contracts/ directory -> []" {
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "#708 scan: a major with no x-sunset is omitted entirely" {
  mkmajor v1 "1.0.0"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "#708 scan: a PAST root-level x-sunset -> expired true" {
  mkmajor v1 "1.0.0" root "2026-01-01"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].major' <<<"$output")" = "v1" ]
  [ "$(jq -r '.[0].spec' <<<"$output")" = "contracts/v1/openapi.yaml" ]
  [ "$(jq -r '.[0].sunset' <<<"$output")" = "2026-01-01" ]
  run ! jq -e '.[0].expired != true' <<<"$output"   # strict: boolean true
}

@test "#708 scan: a FUTURE sunset -> expired false (declared via info.x-sunset)" {
  mkmajor v1 "1.0.0" info "2027-12-31"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].sunset' <<<"$output")" = "2027-12-31" ]
  run ! jq -e '.[0].expired != false' <<<"$output"  # strict: boolean false
}

@test "#708 scan: the sunset date itself is not yet expired (boundary)" {
  mkmajor v1 "1.0.0" root "2026-07-20"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  run ! jq -e '.[0].expired != false' <<<"$output"  # strict: boolean false
}

@test "#708 scan: an RFC 3339 timestamp compares on its date part" {
  mkmajor v1 "1.0.0" root "2026-01-01T23:59:59Z"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  run ! jq -e '.[0].expired != true' <<<"$output"   # strict: boolean true
}

@test "#708 scan: mixed majors — only the sunset-carrying ones appear, numerically ordered" {
  mkmajor v1 "1.0.0" root "2026-01-01"   # expired
  mkmajor v2 "2.0.0" info "2027-12-31"   # future
  mkmajor v3 "3.0.0"                     # no sunset -> omitted
  mkmajor v10 "10.0.0" root "2025-01-01" # expired, must sort AFTER v2
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].major] | join(",")' <<<"$output")" = "v1,v2,v10" ]
  [ "$(jq -r '[.[] | select(.expired == true) | .major] | join(",")' <<<"$output")" = "v1,v10" ]
  # every entry's expired must be a real boolean, not a string
  [ "$(jq -r '[.[] | .expired | type] | unique | join(",")' <<<"$output")" = "boolean" ]
}

@test "#708 scan: --today makes the verdict deterministic (same repo, different day)" {
  mkmajor v1 "1.0.0" root "2026-06-01"
  run zsh "$SCAN" --repo "$WORK" --today 2026-01-01
  run ! jq -e '.[0].expired != false' <<<"$output"  # strict: boolean false
  run zsh "$SCAN" --repo "$WORK" --today 2026-12-01
  run ! jq -e '.[0].expired != true' <<<"$output"   # strict: boolean true
}

@test "#708 scan: a non-canonical vN filename is not a major" {
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\n' > "$WORK/contracts/v1/api-spec.yaml"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "#708 scan: an unknown flag is a usage error (exit 2)" {
  run zsh "$SCAN" --nope
  [ "$status" -eq 2 ]
}

@test "#708 scan: root x-sunset WINS over info x-sunset when both are present" {
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n  x-sunset: "2099-12-31"\n' \
    > "$WORK/contracts/v1/openapi.yaml"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].sunset' <<<"$output")" = "2020-01-01" ]
  run ! jq -e '.[0].expired != true' <<<"$output"
}

@test "#708 scan: a non-canonical major DIRECTORY (contracts/beta) is not a major" {
  mkdir -p "$WORK/contracts/beta" "$WORK/contracts/v1"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "0"\n' > "$WORK/contracts/beta/openapi.yaml"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<<"$output")" = "1" ]
  [ "$(jq -r '.[0].major' <<<"$output")" = "v1" ]
}

@test "#708 scan: two spec spellings in one major dir yield ONE entry (unique key downstream)" {
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yml"
  run zsh "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<<"$output")" = "1" ]
}

@test "#708 scan: a missing --repo directory is a usage error (exit 2), not an empty verdict" {
  run zsh "$SCAN" --repo "$BATS_TEST_TMPDIR/nope" --today 2026-07-20
  [ "$status" -eq 2 ]
}

@test "#708 scan: a malformed --today is rejected (exit 2) rather than silently miscomparing" {
  mkmajor v1 "1.0.0" root "2026-01-01"
  run zsh "$SCAN" --repo "$WORK" --today "not-a-date"
  [ "$status" -eq 2 ]
}

@test "#708 scan: a missing yq exits 3 (typed tool error), never a silent empty verdict" {
  mkmajor v1 "1.0.0" root "2020-01-01"
  local stub="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$stub"
  # a PATH carrying jq but NOT yq; zsh is invoked by absolute path so the
  # stripped PATH can't make the interpreter itself unfindable. --today is
  # supplied so the (also-absent) `date` is never needed — the tool check
  # must fire first.
  ln -sf "$(command -v jq)" "$stub/jq"
  run env PATH="$stub" "$(command -v zsh)" "$SCAN" --repo "$WORK" --today 2026-07-20
  [ "$status" -eq 3 ]
}
