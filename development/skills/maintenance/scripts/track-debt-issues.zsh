#!/usr/bin/env zsh
# Track maintenance scanner findings as GitHub debt issues (#58).
#
# Idempotent per (repo, tool):
#   - Tool with findings AND no open tracking issue  → create
#   - Tool with findings AND existing open issue     → edit body
#   - Tool with zero findings AND existing open issue → close with comment
#   - Tool with zero findings AND no existing issue   → no-op
#
# One issue per scanner tool. Within each body, findings are grouped by
# the tool's natural sub-category (CodeQL/Scorecard for code_scanning,
# BUG/VULNERABILITY/CODE_SMELL/SECURITY_HOTSPOT for sonarcloud, severity
# for semgrep, none for ruff).
#
# Body is capped at BODY_CAP findings (top by severity then file). The
# remainder is summarized with a "+ N more" footer linking to the tool's
# source if available.
#
# PR-based tools (dependabot, snyk_prs) are intentionally excluded —
# their findings are already first-class PRs.
#
# Usage:
#   track-debt-issues.zsh --findings <path> [--repo <repo-path>] [--run-ref <s>]
#
#   --findings: path to a JSON file with `findings_by_tool` at top level
#               (the maintenance Phase 4 payload, or the per-language
#                findings-<lang>.json before payload construction)
#   --repo:     target repo path (defaults to $(pwd))
#   --run-ref:  human-readable reference to the originating run, stamped into
#               each issue body for traceability (#384). Defaults to the run
#               date + current branch.

set -euo pipefail

BODY_CAP=50
MANAGED_MARKER="<!-- managed by /development:maintenance — do not edit body manually; it will be overwritten on the next maintenance run -->"

findings_path=""
repo_path="$(pwd)"
run_ref=""

while (( $# > 0 )); do
  case "$1" in
    --findings) findings_path="$2"; shift 2 ;;
    --repo)     repo_path="$2";     shift 2 ;;
    --run-ref)  run_ref="$2";       shift 2 ;;
    *) print -u2 "track-debt-issues.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$findings_path" ]]; then
  print -u2 "track-debt-issues.zsh: --findings is required"
  exit 2
fi
if [[ ! -f "$findings_path" ]]; then
  print -u2 "track-debt-issues.zsh: findings file not found: $findings_path"
  exit 1
fi

# Move to the repo so `gh` operates on the right one.
cd "$repo_path"

# Scanner tools to track. PR-based tools (dependabot, snyk_prs)
# excluded — their findings are already PRs. container_scan is
# scanner-class (Snyk base-image CVEs harvested from CI), so it gets a
# tracking issue like the others (#299).
typeset -a tracked_tools=( ruff semgrep code_scanning_alerts sonarcloud container_scan )

ensure_label() {
  local name=$1 color=$2 desc=$3
  if ! gh label list --json name --jq '.[].name' --limit 200 | grep -qx "$name"; then
    gh label create "$name" --color "$color" --description "$desc" >/dev/null
  fi
}

ensure_label "maintenance" "5319e7" "Tracked by /development:maintenance"
for t in "${tracked_tools[@]}"; do
  ensure_label "tool:${t}" "ededed" "Maintenance tracking issue for ${t}"
done

today=$(date +%Y-%m-%d)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || print -- "?")
# Run reference stamped into every issue body so a finding is traceable to the
# run that filed it (#384). Defaults to date + branch when the orchestrator
# doesn't pass an explicit --run-ref.
[[ -z "$run_ref" ]] && run_ref="${today} (branch \`${branch}\`)"

# Render the body for a single tool. Reads from $findings_path,
# selects findings_by_tool[$tool], groups by the tool's natural
# sub-category, caps total at BODY_CAP. Output goes to stdout.
#
# Each tool has its own jq filter that knows its native shape (field
# names, group-by key, message location). A single-extractor abstraction
# was attempted first and got messy — per-tool filters are clearer.
render_body() {
  local tool=$1 total=$2

  print -- "$MANAGED_MARKER"
  print -- "<!-- maintenance-tracking: tool=${tool} updated=${today} branch=${branch} total=${total} -->"
  print --
  print -- "## Summary"
  print --
  print -- "**${total}** open ${tool} finding(s) as of ${today} (last touched on \`${branch}\`)."
  print --
  if (( total > BODY_CAP )); then
    print -- "Body shows the top ${BODY_CAP}. ${total} total — see the source tool's UI for the full list."
    print --
  fi
  print -- "## Findings"
  print --

  # Per-tool jq filter. Each one:
  #   - Selects findings_by_tool[$tool]
  #   - Groups by the natural sub-category for that tool
  #   - Per group, renders a "### <header> (<count>)" + checklist
  #   - Caps per-group items at (BODY_CAP / num_groups) so one giant
  #     group can't eat the whole cap
  local filter
  case "$tool" in
    code_scanning_alerts)
      # Group by `.tool` (CodeQL / Scorecard / etc.).
      filter='
        .findings_by_tool.code_scanning_alerts // []
        | group_by(.tool // "other")
        | sort_by(.[0].tool // "")
        | (length) as $ngroups
        | ($cap / (if $ngroups == 0 then 1 else $ngroups end) | floor) as $per
        | .[]
        | (.[0].tool // "Other") as $header
        | length as $n
        | "### \($header) (\($n))",
          "",
          ([ .[0:$per][]
            | "- [ ] **\(.rule_id // "?")** — \(.file // "?")"
              + (if (.line // 0) > 0 then ":\(.line)" else "" end)
              + (if (.message // "") != "" then " — \(.message | gsub("\n"; " ") | gsub("\\s+"; " "))" else "" end)
              + (if (.html_url // "") != "" then " ([source](\(.html_url)))" else "" end)
          ] | join("\n")),
          (if $n > $per then "\n+ \($n - $per) more in this category — see the source tool." else "" end),
          ""
      '
      ;;
    sonarcloud)
      # Group by `.type` (BUG / VULNERABILITY / CODE_SMELL / SECURITY_HOTSPOT).
      filter='
        .findings_by_tool.sonarcloud // []
        | group_by(.type // "OTHER")
        | sort_by(.[0].type // "")
        | (length) as $ngroups
        | ($cap / (if $ngroups == 0 then 1 else $ngroups end) | floor) as $per
        | .[]
        | (.[0].type // "Other") as $header
        | length as $n
        | "### \($header) (\($n))",
          "",
          ([ .[0:$per][]
            | "- [ ] **\(.rule // .key // "?")** — \(.component // "?")"
              + (if (.line // 0) > 0 then ":\(.line)" else "" end)
              + (if (.message // "") != "" then " — \(.message | gsub("\n"; " ") | gsub("\\s+"; " "))" else "" end)
          ] | join("\n")),
          (if $n > $per then "\n+ \($n - $per) more in this category — see SonarCloud." else "" end),
          ""
      '
      ;;
    semgrep)
      # Group by severity (extra.severity or severity).
      filter='
        .findings_by_tool.semgrep // []
        | group_by((.extra.severity // .severity // "INFO") | ascii_upcase)
        | sort_by((.[0].extra.severity // .[0].severity // "INFO") | ascii_upcase)
        | (length) as $ngroups
        | ($cap / (if $ngroups == 0 then 1 else $ngroups end) | floor) as $per
        | .[]
        | ((.[0].extra.severity // .[0].severity // "INFO") | ascii_upcase) as $header
        | length as $n
        | "### \($header) (\($n))",
          "",
          ([ .[0:$per][]
            | "- [ ] **\(.check_id // .rule_id // "?")** — \(.path // .file // "?")"
              + (if (.start.line // 0) > 0 then ":\(.start.line)" else "" end)
              + (if (.extra.message // .message // "") != "" then " — \((.extra.message // .message) | gsub("\n"; " ") | gsub("\\s+"; " "))" else "" end)
          ] | join("\n")),
          (if $n > $per then "\n+ \($n - $per) more in this category — re-run \`semgrep\` locally for the full list." else "" end),
          ""
      '
      ;;
    container_scan)
      # Group by severity (critical / high / medium / low).
      filter='
        .findings_by_tool.container_scan // []
        | group_by(.severity // "unknown")
        | sort_by(.[0].severity // "")
        | (length) as $ngroups
        | ($cap / (if $ngroups == 0 then 1 else $ngroups end) | floor) as $per
        | .[]
        | ((.[0].severity // "unknown") | ascii_upcase) as $header
        | length as $n
        | "### \($header) (\($n))",
          "",
          ([ .[0:$per][]
            | "- [ ] **\(.id // "?")** — \(.package // "?")"
              + (if (.version // "") != "" then " \(.version)" else "" end)
              + (if .fixable then " — fix in \((.fixed_in // []) | join(", "))" else " — no upstream fix yet" end)
              + (if (.url // "") != "" then " ([source](\(.url)))" else "" end)
          ] | join("\n")),
          (if $n > $per then "\n+ \($n - $per) more in this severity — see Snyk." else "" end),
          ""
      '
      ;;
    ruff|*)
      # No sub-grouping — single flat list.
      filter='
        .findings_by_tool.ruff // []
        | [.]
        | .[]
        | length as $n
        | "### Lints (\($n))",
          "",
          ([ .[0:$cap][]
            | "- [ ] **\(.code // .rule // "?")** — \(.filename // .file // "?")"
              + (if (.location.row // 0) > 0 then ":\(.location.row)" else "" end)
              + (if (.message // "") != "" then " — \(.message | gsub("\n"; " ") | gsub("\\s+"; " "))" else "" end)
          ] | join("\n")),
          (if $n > $cap then "\n+ \($n - $cap) more — re-run \`ruff check\` for the full list." else "" end),
          ""
      '
      ;;
  esac

  jq -r --argjson cap "$BODY_CAP" "$filter" < "$findings_path"

  print -- "---"
  print -- "_Last maintenance run: ${run_ref}._"
  print -- "_This issue is auto-managed by \`/development:maintenance\` (#58, #384). It will be updated on every run and auto-closed when ${tool} reaches zero findings._"
}

# For each tracked tool, search for an existing open issue, then act
# based on finding count.
for tool in "${tracked_tools[@]}"; do
  count=$(jq -r --arg t "$tool" '(.findings_by_tool[$t] // []) | length' < "$findings_path")
  count=${count:-0}

  existing_json=$(gh issue list \
    --label maintenance \
    --label "tool:${tool}" \
    --state open \
    --json number,title \
    --limit 5 2>/dev/null || print -- "[]")
  existing_n=$(print -- "$existing_json" | jq -r '.[0].number // empty')

  if (( count == 0 )); then
    if [[ -n "$existing_n" ]]; then
      gh issue close "$existing_n" --comment "All \`${tool}\` findings resolved as of ${today} — maintenance run from \`${branch}\`. Re-opens automatically on the next run that finds anything." >/dev/null
      print -- "closed:    #${existing_n} (${tool} → 0 findings)"
    else
      print -- "no-op:     ${tool} has zero findings, no existing issue"
    fi
    continue
  fi

  body=$(render_body "$tool" "$count")
  title="[maintenance] ${tool} debt (${count} finding$([[ $count -ne 1 ]] && print -- s))"

  if [[ -n "$existing_n" ]]; then
    body_file=$(mktemp "${TMPDIR:-/tmp}/debt-body.XXXXXXXX")
    print -r -- "$body" > "$body_file"
    gh issue edit "$existing_n" --title "$title" --body-file "$body_file" >/dev/null
    rm -f "$body_file"
    print -- "updated:   #${existing_n} (${tool} → ${count} findings)"
  else
    body_file=$(mktemp "${TMPDIR:-/tmp}/debt-body.XXXXXXXX")
    print -r -- "$body" > "$body_file"
    new_url=$(gh issue create \
      --title "$title" \
      --label maintenance \
      --label "tool:${tool}" \
      --body-file "$body_file")
    rm -f "$body_file"
    print -- "created:   ${new_url} (${tool} → ${count} findings)"
  fi
done
