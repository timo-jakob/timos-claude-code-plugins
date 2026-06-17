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
