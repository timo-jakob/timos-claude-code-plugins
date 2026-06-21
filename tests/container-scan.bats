#!/usr/bin/env bats
# container-scan.bats — gather-container-scan.zsh normalization, exercised
# through the `--from-file` seam (no gh / network / unzip).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-container-scan.zsh"
  FIX="$REPO_ROOT/tests/fixtures/container-scan"
}

# Emit normalized JSON on stdout only (stderr note suppressed) so $output is
# pure JSON regardless of the bats version's stderr handling.
emit() { "$GATHER" --from-file "$FIX/$1" 2>/dev/null; }

@test "normalizes and dedups by id (3 paths -> 2 unique CVEs)" {
  run emit two-cves.json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.container_scan | length')" -eq 2 ]
}

@test "unfixable base-image CVE is flagged fixable=false, is_base_image_cve=true" {
  run emit two-cves.json
  f="$(printf '%s' "$output" | jq -c '.container_scan[] | select(.id=="SNYK-DEBIAN12-SQLITE3-1000001")')"
  [ "$(printf '%s' "$f" | jq '.fixable')" = "false" ]
  [ "$(printf '%s' "$f" | jq '.is_base_image_cve')" = "true" ]
  [ "$(printf '%s' "$f" | jq -r '.severity')" = "high" ]
  [ "$(printf '%s' "$f" | jq -r '.cve[0]')" = "CVE-2025-1111" ]
  [ "$(printf '%s' "$f" | jq -r '.url')" = "https://security.snyk.io/vuln/SNYK-DEBIAN12-SQLITE3-1000001" ]
}

@test "fixable apt CVE on our RUN layer is fixable=true, is_base_image_cve=false" {
  run emit two-cves.json
  f="$(printf '%s' "$output" | jq -c '.container_scan[] | select(.id=="SNYK-DEBIAN12-CURL-2000002")')"
  [ "$(printf '%s' "$f" | jq '.fixable')" = "true" ]
  [ "$(printf '%s' "$f" | jq '.is_base_image_cve')" = "false" ]
  [ "$(printf '%s' "$f" | jq -r '.fixed_in[0]')" = "7.88.1-10+deb12u5" ]
}

@test "clean image yields an empty array and exit 0" {
  run emit empty.json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.container_scan | length')" -eq 0 ]
}

@test "missing --from-file argument is a usage error (exit 2)" {
  run "$GATHER" --from-file
  [ "$status" -eq 2 ]
}

# --- reliability note (#388): the count is point-in-time; a 0 is a false-zero
#     risk, not a clean bill. Exercised through the --reliability-note seam.

@test "reliability note: count 0 is framed as 'not a live scan', not clean" {
  run "$GATHER" --reliability-note 0 "2020-01-01T00:00:00Z" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT a live scan"* ]]
  [[ "$output" == *"not a clean image"* ]]
  [[ "$output" == *"#388"* ]]
}

@test "reliability note: a stale (>7d) scan escalates with a refresh hint" {
  run "$GATHER" --reliability-note 0 "2020-01-01T00:00:00Z" main
  [[ "$output" == *"push to main to refresh"* ]]
}

@test "reliability note: count >0 reports the count + point-in-time caveat" {
  run "$GATHER" --reliability-note 3 "2020-01-01T00:00:00Z" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ingested 3 unique CVE(s)"* ]]
  [[ "$output" == *"Point-in-time"* ]]
}

@test "reliability note: a fresh scan carries the caveat but no refresh hint" {
  fresh="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')"
  run "$GATHER" --reliability-note 2 "$fresh" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"Point-in-time"* ]]
  [[ "$output" != *"refresh before relying"* ]]
}
