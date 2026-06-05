#!/usr/bin/env zsh
# gather-github-security.zsh — fetch GitHub Code Scanning alerts (CodeQL,
# Scorecard, and any other SARIF-uploading scanner) for the current repo.
#
# Replaces the Snyk REST API gather (which required a paid plan; see
# timos-claude-code-plugins#87). Code Scanning is free for public repos,
# uses the existing `gh` auth, and includes CodeQL by default on every
# bootstrapped repo.
#
# Output (stdout, JSON):
#   { "code_scanning_alerts": [ ...flat alert array... ] }
#
# Each alert entry:
#   {
#     "number":     int,
#     "rule_id":    string,
#     "severity":   "critical"|"high"|"medium"|"low"|"warning"|"note"|null,
#     "state":      "open" (we filter to open-only),
#     "tool":       string (e.g. "CodeQL", "Scorecard"),
#     "file":       string (most_recent_instance.location.path),
#     "line":       int    (most_recent_instance.location.start_line),
#     "message":    string (most_recent_instance.message.text),
#     "html_url":   string
#   }
#
# Stderr: one explanatory line summarizing what happened. The caller
# surfaces this via the gather payload's notes[].
#
# Exit codes:
#   0 → success; the array may be empty if there are genuinely no open
#       alerts, but the API path worked end-to-end.
#   1 → API path failed (gh not authenticated, code-scanning disabled,
#       etc.).
#   2 → usage error (bad/missing repo_path argument).

set -euo pipefail

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { print -u2 -- "usage: $0 <repo_path>"; exit 2; }
cd "$repo"

# `command gh` skips any zsh function/alias shadow (mirrors PR α's fix
# for curl; see #151).
command -v gh >/dev/null 2>&1 \
  || { print -u2 -- "gh CLI not on PATH; can't fetch Code Scanning alerts."; exit 1; }
command gh auth status >/dev/null 2>&1 \
  || { print -u2 -- "gh not authenticated; run 'gh auth login'."; exit 1; }

REPO_FULL=$(command gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
[[ -n "$REPO_FULL" ]] \
  || { print -u2 -- "could not resolve current repo's GitHub nameWithOwner."; exit 1; }

# Fetch all open Code Scanning alerts. --paginate handles result sets
# larger than one page.
raw=$(mktemp); trap 'rm -f "$raw"' EXIT

# code-scanning/alerts returns 404 when Code Scanning isn't enabled on
# the repo. Treat that as "no alerts available" rather than a hard
# failure — many private repos don't enable it.
if ! command gh api "repos/$REPO_FULL/code-scanning/alerts?state=open" --paginate \
       > "$raw" 2>/dev/null; then
  print -- '{"code_scanning_alerts": []}'
  print -u2 -- "Code Scanning fetch failed for $REPO_FULL — either Code Scanning isn't enabled, or gh lacks security-events scope. Enable via GitHub repo Settings → Code security."
  exit 1
fi

# Pagination may produce multiple JSON arrays concatenated; jq -s
# (slurp + flatten with add) handles either shape.
count=$(jq -s 'add // [] | length' "$raw" 2>/dev/null || echo 0)
mapped=$(jq -s '
  add // [] |
  map({
    number:    .number,
    rule_id:   .rule.id,
    severity:  .rule.security_severity_level,
    state:     .state,
    tool:      .tool.name,
    file:      .most_recent_instance.location.path,
    line:      .most_recent_instance.location.start_line,
    message:   .most_recent_instance.message.text,
    html_url:  .html_url
  })
' "$raw" 2>/dev/null || echo '[]')

jq -n --argjson alerts "$mapped" '{ code_scanning_alerts: $alerts }'
print -u2 -- "Code Scanning fetched $count open alerts from $REPO_FULL (free, GitHub-native; replaces the deprecated Snyk REST API gather)."
