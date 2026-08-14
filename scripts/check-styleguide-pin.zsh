#!/usr/bin/env zsh
# check-styleguide-pin.zsh — prove the SHIPPED Spectral shim still resolves the
# published org styleguide, THROUGH THE PIN (issue #689, AC 8).
#
# Every other styleguide test lints against the local styleguide/spectral/
# ruleset.yaml. That proves the rules are right; it proves nothing about what a
# bootstrapped repo actually gets, because a bootstrapped repo never sees this
# repo's working tree — it extends an exact pinned jsDelivr URL. This check is
# the only thing standing between a broken pin and every downstream repo's CI.
#
# THE FAILURE MODE THIS EXISTS FOR: a pin that 404s must FAIL, never report a
# clean run. Spectral loading no rules yields "0 problems" — a green check that
# enforces nothing. So conformance is asserted POSITIVELY: the non-conforming
# fixture must produce all eight org rule ids at error severity. A dead pin
# produces none of them and the check exits non-zero, loudly.
#
# Exits 0 when the pin resolves and enforces all eight rules, 1 on any
# conformance failure, 2 on usage/tooling errors (missing jq/node/fixture).
#
# Invoked by .github/workflows/styleguide-pin.yml on every PR. Also runnable
# locally — no arguments, but it needs node + network (it fetches the pin).
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
SHIM="$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
FIXTURES="$REPO_ROOT/tests/fixtures/api-styleguide"

# Pinned EXACTLY, like the acceptance lane and unlike the shipped workflow's
# floating `@6`: a spectral minor can retire or rename an inherited spectral:oas
# rule, which would move this check's goalposts without a commit here.
SPECTRAL="@stoplight/spectral-cli@6.16.3"

# The v1 normative set (#689 decision 1). Eight IDS, seven conventions —
# operation-operationId and -unique are one convention with two ids.
EXPECTED_RULES=(
  operation-operationId
  operation-operationId-unique
  info-description
  operation-description
  operation-tags
  org-deprecated-operation-has-sunset
  org-resource-naming
  org-problem-json-errors
)

die() { print -u2 -- "check-styleguide-pin: $1"; exit "${2:-2}"; }

for tool in jq node npx curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not on PATH"
done
[[ -f "$SHIM" ]] || die "shim not found: $SHIM"
[[ -f "$FIXTURES/nonconforming/openapi.yaml" ]] || die "fixture not found: $FIXTURES/nonconforming/openapi.yaml"

# --- 1. the pin itself ------------------------------------------------------
# Extracted from the shim rather than hardcoded, so this check can never pass
# against a version the shim does not actually ship.
PIN_URL="$(grep -oE 'https://cdn\.jsdelivr\.net/gh/[^ ]+/ruleset\.yaml' "$SHIM" | head -n1)"
[[ -n "$PIN_URL" ]] || die "no jsDelivr pin found in $SHIM — is it still the exact-pin shim?" 1

case "$PIN_URL" in
  *@styleguide-v[0-9]*) ;;
  *) die "pin is not an exact styleguide-vX.Y.Z tag: $PIN_URL" 1 ;;
esac
print "pin: $PIN_URL"

# A distinct, well-labelled failure for the CDN case — otherwise a jsDelivr
# outage would surface as eight mysteriously-absent rules.
http_code="$(curl -fsS -o /tmp/styleguide-pin.yaml -w '%{http_code}' "$PIN_URL" 2>/dev/null || true)"
[[ "$http_code" == "200" ]] || die "pin did not resolve (HTTP ${http_code:-000}) — $PIN_URL" 1
print "pin resolves: HTTP 200"

# --- 2. what the pin ENFORCES, through the shim -----------------------------
# --ruleset is the SHIM, not the local ruleset: that is the whole point.
lint_json() {
  npx --yes "$SPECTRAL" lint --ruleset "$SHIM" --format json "$1" 2>/dev/null || true
}

nonconforming_json="$(lint_json "$FIXTURES/nonconforming/openapi.yaml")"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$nonconforming_json" \
  || die "spectral produced no parseable JSON for the non-conforming fixture" 1

fired=("${(@f)$(jq -r '[.[] | select(.severity == 0) | .code] | unique | .[]' <<<"$nonconforming_json")}")

missing=()
for rule in "${EXPECTED_RULES[@]}"; do
  (( ${fired[(Ie)$rule]} )) || missing+=("$rule")
done

if (( ${#missing} )); then
  print -u2 -- "check-styleguide-pin: the pinned ruleset did not enforce ${#missing} of ${#EXPECTED_RULES} org rules."
  print -u2 -- "  missing at error severity: ${missing[*]}"
  print -u2 -- "  fired: ${fired[*]:-<none>}"
  print -u2 -- "  A pin that resolves but enforces nothing is the exact silent failure this check exists to catch."
  exit 1
fi
print "enforced through the pin: all ${#EXPECTED_RULES} org rules at error severity"

# --- 3. the pin must not over-fire ------------------------------------------
# Without this, a ruleset that flagged EVERYTHING would satisfy the check above.
conforming_json="$(lint_json "$FIXTURES/conforming/openapi.yaml")"
errors="$(jq -r '[.[] | select(.severity == 0)] | length' <<<"${conforming_json:-[]}" 2>/dev/null || echo bad)"
[[ "$errors" == "0" ]] || die "the conforming fixture produced $errors error finding(s) through the pin" 1
print "conforming fixture: 0 error findings through the pin"

print "OK — the shipped shim resolves $PIN_URL and enforces the v1 normative set."
