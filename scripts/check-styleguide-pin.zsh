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
# fixture must produce every id in EXPECTED_RULES at error severity. A dead pin
# produces none of them and the check exits non-zero, loudly.
#
# Exits 0 when the pin resolves and enforces every rule in the roster, 1 on any
# conformance failure, 2 on usage/tooling errors (missing jq/node/fixture).
#
# Invoked by .github/workflows/styleguide-pin.yml on every PR that touches the
# shim, the ruleset, the fixtures or this script — plus a weekly cron, because a
# pin can rot from outside this repo. Also runnable locally — no arguments, but
# it needs node + network (it fetches the pin).
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
SHIM="$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
FIXTURES="$REPO_ROOT/tests/fixtures/api-styleguide"

# Pinned EXACTLY, like the acceptance lane and unlike the shipped workflow's
# floating `@6`: a spectral minor can retire or rename an inherited spectral:oas
# rule, which would move this check's goalposts without a commit here.
SPECTRAL="@stoplight/spectral-cli@6.16.3"

# The v2 normative set. FIFTEEN IDS, twelve conventions — a convention can need
# more than one id: operation-operationId and -unique are one expressed as two,
# and cursor pagination is one expressed as three. docs/reference/api-styleguide.md
# is the authoritative convention text and owns that count; it is repeated here
# only to make the roster below readable.
#
# The first eight are #689's v1 set; the seven below them are #944's pagination
# and header conventions, which entered the published artifact with
# styleguide-v2.0.0. They were parked in tests/check-styleguide-pin.bats's
# PENDING_PIN_RULES for the release window between #944's two PRs — added to the
# ruleset by PR-A, unverifiable through a pin that did not yet carry them, and
# moved here by PR-B the moment the shim's pin advanced. That list is now empty
# and the window is closed.
EXPECTED_RULES=(
  operation-operationId
  operation-operationId-unique
  info-description
  operation-description
  operation-tags
  org-deprecated-operation-has-sunset
  org-resource-naming
  org-problem-json-errors
  # newly minted in styleguide-v2.0.0 (#944)
  org-pagination-cursor-params
  org-pagination-no-offset-params
  org-pagination-envelope
  org-idempotency-key-on-post-patch
  org-retry-after-on-throttled
  org-deprecation-sunset-headers
  org-no-bespoke-correlation-headers
)

die() { print -u2 -- "check-styleguide-pin: $1"; exit "${2:-2}"; }

for tool in jq node npx curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not on PATH"
done
[[ -f "$SHIM" ]] || die "shim not found: $SHIM"
# BOTH fixtures, not just the non-conforming one: step 3's over-fire guard is
# vacuous without its fixture, and would otherwise report success while
# asserting nothing.
for fixture in nonconforming conforming; do
  [[ -f "$FIXTURES/$fixture/openapi.yaml" ]] || die "fixture not found: $FIXTURES/$fixture/openapi.yaml"
done

# --- 1. the pin itself ------------------------------------------------------
# Extracted from the shim rather than hardcoded, so this check can never pass
# against a version the shim does not actually ship.
#
# Comment lines are stripped first, and the result must be EXACTLY ONE url: a
# retired pin left behind in a `# was: …` comment would otherwise be the one
# validated here, so the CDN probe below would report on a URL the shim no longer
# ships. Two live pins is likewise a defect worth failing on.
# The `|| true` matters under `set -o pipefail`: a no-match grep exits 1, which
# would kill the script at this assignment and never reach the guard below —
# a red run with an empty log instead of the diagnostic.
pins=("${(@f)$(grep -vE '^[[:space:]]*#' "$SHIM" | grep -oE 'https://cdn\.jsdelivr\.net/gh/[^ ]+/ruleset\.yaml' || true)}")
pins=("${(@)pins:#}")   # drop the empty element a no-match split leaves behind
(( ${#pins} == 1 )) || die "expected exactly 1 jsDelivr pin in $SHIM, found ${#pins} — is it still the exact-pin shim?" 1
PIN_URL="${pins[1]}"

# Anchored on the FULL semver shape. `*@styleguide-v[0-9]*` would accept
# `@styleguide-v1` — a floating major tag that jsDelivr serves happily and that
# someone WILL move on the next release, which is precisely the pin the shim's
# own header forbids.
[[ "$PIN_URL" =~ '@styleguide-v[0-9]+\.[0-9]+\.[0-9]+/' ]] \
  || die "pin is not an exact styleguide-vX.Y.Z tag: $PIN_URL" 1
print "pin: $PIN_URL"

# A distinct, well-labelled failure for the CDN case — otherwise a jsDelivr
# outage would surface as a roster of mysteriously-absent rules. The body is never
# read, so it is discarded rather than written to a fixed /tmp path.
http_code="$(curl -fsS -o /dev/null -w '%{http_code}' "$PIN_URL" 2>/dev/null || true)"
[[ "$http_code" == "200" ]] || die "pin did not resolve (HTTP ${http_code:-000}) — $PIN_URL" 1
print "pin resolves: HTTP 200"

# --- 2. what the pin ENFORCES, through the shim -----------------------------
# --ruleset is the SHIM, not the local ruleset: that is the whole point.
#
# spectral exits 1 when it finds anything, so its status is not a usable signal
# and is swallowed — but its STDERR is kept, because an npx/registry failure and
# a genuinely-empty lint are indistinguishable from stdout alone, and the former
# should not be reported as a conformance failure.
# `foo.XXXXXX`, never `-t foo`: the -t form without X's is BSD-only. GNU
# coreutils rejects it ("too few X's"), busybox with "Invalid argument" — so the
# BSD spelling exits 1 on Linux, which is the platform this script's own workflow
# runs on. It would have redded every CI run while passing on macOS.
SPECTRAL_ERR="$(mktemp "${TMPDIR:-/tmp}/styleguide-pin-err.XXXXXX")" \
  || die "could not create a temp file for spectral's stderr"
trap 'rm -f "$SPECTRAL_ERR"' EXIT INT TERM

lint_json() {
  npx --yes "$SPECTRAL" lint --ruleset "$SHIM" --format json "$1" 2>"$SPECTRAL_ERR" || true
}

# Exit 2, not 1: spectral could not RUN, which is a tooling fault, not a verdict
# about the pin. Keeps the header's documented 1-vs-2 split honest.
require_json() {
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$1" && return 0
  print -u2 -- "check-styleguide-pin: spectral produced no parseable JSON for the $2 fixture."
  print -u2 -- "  spectral stderr: $(tail -n 5 "$SPECTRAL_ERR" 2>/dev/null || print '<none>')"
  exit 2
}

nonconforming_json="$(lint_json "$FIXTURES/nonconforming/openapi.yaml")"
require_json "$nonconforming_json" "non-conforming"

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
# Guarded like step 2 rather than defaulting to `[]`: that default turned a
# crashed spectral (or a deleted fixture) into "0 errors" and a green exit,
# silently disabling this assertion.
conforming_json="$(lint_json "$FIXTURES/conforming/openapi.yaml")"
require_json "$conforming_json" "conforming"
errors="$(jq -r '[.[] | select(.severity == 0)] | length' <<<"$conforming_json")"
[[ "$errors" == "0" ]] || die "the conforming fixture produced $errors error finding(s) through the pin" 1
print "conforming fixture: 0 error findings through the pin"

print "OK — the shipped shim resolves $PIN_URL and enforces the normative set."
