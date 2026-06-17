#!/usr/bin/env zsh
# gather-container-scan.zsh — harvest Snyk container CVEs for the current repo
# from the latest default-branch CI artifact (`snyk-container-scan`), produced
# by the `image` job's `snyk container test --json-file-output` (see #299).
#
# We harvest the CI artifact rather than running `snyk container test` locally:
# no local Docker build, no extra Snyk quota (public projects test unlimited),
# and free-plan-safe. It's the GitHub-native analogue of the Code Scanning
# gather that replaced the Snyk REST API (timos-claude-code-plugins#87).
#
# Output (stdout, JSON):
#   { "container_scan": [ ...normalized findings, deduped by id... ] }
#
# Each finding:
#   {
#     "id":                     "SNYK-DEBIAN12-GNUTLS28-16344297",  # .snyk ignore key
#     "cve":                    ["CVE-..."],
#     "title":                  string,
#     "severity":               "critical"|"high"|"medium"|"low",
#     "package":                string (e.g. "gnutls28/libgnutls30"),
#     "version":                string,
#     "fixable":                bool,
#     "fixed_in":               [string, ...],
#     "from_image":             string|null  (dep_chain[0]),
#     "dep_chain":              [string, ...],
#     "dockerfile_instruction": string|null,
#     "is_base_image_cve":      bool,  # false ⇒ installed by our own RUN layer (apt-pinnable)
#     "url":                    string
#   }
#
# Snyk emits one `.vulnerabilities[]` entry per vulnerable path, so the same
# `id` recurs; we dedup by `id` (the `.snyk` ignore is one entry per id).
#
# Stderr: one explanatory line; the caller surfaces it via the payload notes[].
#
# Exit codes:
#   0 → success (the array may be empty: no artifact, or a genuinely clean image)
#   1 → harvest path failed (gh missing/unauth, repo unresolvable)
#   2 → usage error
#
# Testable seam: `--from-file <path>` reads an *unzipped* `snyk container test
# --json` document straight from disk and runs the identical normalization,
# skipping all gh/network/unzip. tests/container-scan.bats uses this.

set -euo pipefail

# jq program: raw `snyk container test --json` (object with .vulnerabilities[])
# → normalized, deduped-by-id finding array.
NORMALIZE='
  (.vulnerabilities // [])
  | map({
      id:        .id,
      cve:       ((.identifiers.CVE // []) | unique),
      title:     .title,
      severity:  .severity,
      package:   .packageName,
      version:   .version,
      fixable:   ((.isUpgradable // false) or (.isPatchable // false)
                  or ((.nearestFixedInVersion // "") != "")
                  or (((.fixedIn // []) | length) > 0)),
      fixed_in:  (.fixedIn // []),
      from_image: ((.from // []) | (.[0] // null)),
      dep_chain: (.from // []),
      dockerfile_instruction: (.dockerfileInstruction // null),
      # Our own RUN apt-get layer ⇒ apt-pinnable (not a base-image CVE).
      # Everything else (no instruction, or a FROM) is base-image.
      is_base_image_cve: (((.dockerfileInstruction // "") | ascii_upcase
                           | startswith("RUN")) | not),
      url:       ("https://security.snyk.io/vuln/" + (.id // ""))
    })
  | group_by(.id) | map(.[0])
'

emit_from() {
  # $1 = path to a raw snyk container JSON document
  local raw="$1" mapped
  mapped=$(jq "$NORMALIZE" "$raw" 2>/dev/null || echo '[]')
  jq -n --argjson f "$mapped" '{ container_scan: $f }'
}

# --- testable seam: --from-file <path> ---------------------------------------
if [[ "${1:-}" == "--from-file" ]]; then
  src="${2:-}"
  [[ -n "$src" && -f "$src" ]] \
    || { print -u2 -- "usage: $0 --from-file <snyk-container.json>"; exit 2; }
  n=$(jq '(.vulnerabilities // []) | map(.id) | unique | length' "$src" 2>/dev/null || echo 0)
  emit_from "$src"
  print -u2 -- "container scan (from-file): normalized $n unique CVE(s) from $src."
  exit 0
fi

# --- live harvest path -------------------------------------------------------
repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] \
  || { print -u2 -- "usage: $0 <repo_path> | --from-file <path>"; exit 2; }
cd "$repo"

# `command gh` skips any zsh function/alias shadow (mirrors gather-github-security.zsh).
command -v gh >/dev/null 2>&1 || {
  print -- '{"container_scan": []}'
  print -u2 -- "gh CLI not on PATH; can't harvest the container-scan artifact."
  exit 1
}
command gh auth status >/dev/null 2>&1 || {
  print -- '{"container_scan": []}'
  print -u2 -- "gh not authenticated; run 'gh auth login'."
  exit 1
}

REPO_FULL=$(command gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
DEFAULT_BRANCH=$(command gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
[[ -n "$REPO_FULL" && -n "$DEFAULT_BRANCH" ]] || {
  print -- '{"container_scan": []}'
  print -u2 -- "could not resolve repo / default branch via gh."
  exit 1
}

# Newest default-branch *push* runs only. Provenance: never fork-PR runs (a
# fork PR could upload a spoofed "no vulns" artifact); push runs on the default
# branch are trusted. The artifact only exists on push/release (matches the
# workflow's upload gating).
runs=$(command gh run list --workflow quality-public.yml --branch "$DEFAULT_BRANCH" \
         --event push --json databaseId,createdAt --limit 10 2>/dev/null || echo '[]')

tmp=$(mktemp -d); trap 'rm -f "$tmp"/*(N) 2>/dev/null; rmdir "$tmp" 2>/dev/null' EXIT

# Walk newest→oldest; the most recent run with a live (non-expired) artifact
# wins. Older runs are tried only if the newest lacks one (e.g. retention).
chosen_created=""
found="false"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  run_id="${line%%|*}"
  created="${line#*|}"
  if command gh run download "$run_id" --name snyk-container-scan --dir "$tmp" >/dev/null 2>&1; then
    chosen_created="$created"
    found="true"
    break
  fi
done < <(print -r -- "$runs" | jq -r '.[] | "\(.databaseId)|\(.createdAt)"')

if [[ "$found" != "true" || ! -f "$tmp/snyk-container.json" ]]; then
  print -- '{"container_scan": []}'
  print -u2 -- "No snyk-container-scan artifact found on $REPO_FULL@$DEFAULT_BRANCH (no push run yet, or the artifact expired). Container CVEs not ingested this run."
  exit 0
fi

n=$(jq '(.vulnerabilities // []) | map(.id) | unique | length' "$tmp/snyk-container.json" 2>/dev/null || echo 0)
emit_from "$tmp/snyk-container.json"

# Staleness: the artifact is only as fresh as the last default-branch push.
note="container scan: ingested $n unique CVE(s) from the latest $DEFAULT_BRANCH push run."
if [[ -n "$chosen_created" ]] && command -v python3 >/dev/null 2>&1; then
  age_days=$(python3 - "$chosen_created" <<'PY' 2>/dev/null || true
import sys, datetime
try:
    t = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    print((now - t).days)
except Exception:
    pass
PY
)
  if [[ -n "$age_days" && "$age_days" -gt 14 ]]; then
    note="$note Findings are from a run ${age_days}d old — push to $DEFAULT_BRANCH to refresh."
  fi
fi
print -u2 -- "$note"
