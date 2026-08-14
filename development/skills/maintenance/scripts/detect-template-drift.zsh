#!/usr/bin/env zsh
# Detect drift between rendered bootstrap files and the current templates.
#
# For each tracked rendered path that exists in the target repo, read the
# `# claude-bootstrap: rendered from ... sha256:<H>` marker (#213) and
# compare the recorded sha256 against the current template's sha256.
# Equal → no drift. Different → emit a drifted finding. Missing marker →
# emit an unknown_provenance finding (file was rendered before this
# feature shipped, or hand-created from scratch).
#
# Output: JSON array on stdout. Empty array means no findings. Exits 0
# on completion regardless of findings count.
#
# Usage:
#   detect-template-drift.zsh <repo-path>
#
# The set of tracked rendered files is hardcoded below (v1 scope:
# workflows + config files only; scaffold files like CLAUDE.md are
# excluded because users are expected to edit them).

set -euo pipefail

# Return 0 iff semver $1 is strictly greater than $2 (used to pick changelog
# entries newer than a rendered file's marker version).
vgt() {
  [[ "$1" == "$2" ]] && return 1
  local top
  top=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
  [[ "$top" == "$1" ]]
}

if (( $# != 1 )); then
  print -u2 "detect-template-drift.zsh: expected exactly one argument (repo path)"
  exit 2
fi

repo="${1:A}"
if [[ ! -d "$repo" ]]; then
  print -u2 "detect-template-drift.zsh: not a directory: $repo"
  exit 2
fi

script_dir="${0:A:h}"
skill_dir="${script_dir:h}"
skills_dir="${skill_dir:h}"
plugin_dir="${skills_dir:h}"

plugin_json="${plugin_dir}/.claude-plugin/plugin.json"
templates_root="${plugin_dir}/skills/bootstrap/templates"

# Curated map of notable template changes, so a drifted file can NAME the fixes a
# re-bootstrap would deliver (#400). Overridable for tests via TEMPLATE_CHANGELOG.
changelog="${TEMPLATE_CHANGELOG:-${skill_dir}/reference/template-changelog.json}"

current_plugin_version=$(jq -r '.version' < "$plugin_json")

# Tracked rendered files for v1. Scaffold files (CLAUDE.md,
# CONTRIBUTING.md, SETUP.md) are intentionally excluded — users
# customize those, drift is expected and meaningless to report.
typeset -a tracked=(
  ".github/workflows/api-stability.yml"
  # the §3l IaC path's one rendered workflow (#1154): stamped by bootstrap's
  # Step 3.6, so it must be read here too — otherwise the marker is written and
  # never consumed, and a consumer repo whose kubernetes-ci.yml has fallen
  # behind the template is reported drift-free forever
  ".github/workflows/kubernetes-ci.yml"
  # the application-repo direct-to-cluster gate (#1206) — BOTH halves. The
  # workflow is the runner; the CHECKER holds the matched command set, so it is
  # the half that actually goes stale: widen the IN set upstream and a consumer
  # on the old checker keeps reporting green against it. Tracking only the
  # workflow would leave exactly the drift this entry exists to name invisible,
  # because the workflow (branch + pinned yq) almost never changes. Both are
  # stamped at Step 3.6; stamp-marker.zsh inserts after a shebang and preserves
  # the file mode (#783), so a zsh script is stampable.
  ".github/workflows/no-cluster-deploy.yml"
  "scripts/check-no-cluster-deploy.zsh"
  ".github/workflows/codeql.yml"
  ".github/workflows/codeql-noop.yml"
  ".github/workflows/quality-public.yml"
  ".github/workflows/quality-public-noop.yml"
  ".github/workflows/quality-private.yml"
  ".github/workflows/quality-private-noop.yml"
  ".github/workflows/scorecard.yml"
  ".github/workflows/release.yml"
  ".github/workflows/template-drift-watch.yml"
  ".github/dependabot.yml"
  "trivy.yaml"
)

typeset -a findings=()

for target_rel in "${tracked[@]}"; do
  target_abs="${repo}/${target_rel}"
  if [[ ! -f "$target_abs" ]]; then
    continue
  fi

  marker_line=$(head -10 "$target_abs" | grep "^# claude-bootstrap: rendered from " | head -1 || true)

  if [[ -z "$marker_line" ]]; then
    findings+=( "$(jq -nc \
      --arg file "$target_rel" \
      --arg severity "unknown_provenance" \
      --arg message "No claude-bootstrap marker found — file was rendered before #213 shipped, or hand-created. Cannot verify drift without provenance." \
      '{_tool: "template_drift", file: $file, severity: $severity, message: $message}')" )
    continue
  fi

  # Marker shape:
  # # claude-bootstrap: rendered from <template-relpath> @ v<version> sha256:<hash>
  template_relpath=$(printf '%s\n' "$marker_line" | sed -nE 's|^# claude-bootstrap: rendered from (.+) @ v[^ ]+ sha256:[0-9a-f]+$|\1|p')
  marker_version=$(printf '%s\n' "$marker_line"  | sed -nE 's|^# claude-bootstrap: rendered from .+ @ v([^ ]+) sha256:[0-9a-f]+$|\1|p')
  marker_hash=$(printf '%s\n' "$marker_line"    | sed -nE 's|^# claude-bootstrap: rendered from .+ @ v[^ ]+ sha256:([0-9a-f]+)$|\1|p')

  if [[ -z "$template_relpath" || -z "$marker_version" || -z "$marker_hash" ]]; then
    findings+=( "$(jq -nc \
      --arg file "$target_rel" \
      --arg severity "malformed_marker" \
      --arg message "claude-bootstrap marker present but unparseable. Re-bootstrap to refresh." \
      --arg raw "$marker_line" \
      '{_tool: "template_drift", file: $file, severity: $severity, message: $message, raw_marker: $raw}')" )
    continue
  fi

  template_abs="${templates_root}/${template_relpath}"
  if [[ ! -f "$template_abs" ]]; then
    findings+=( "$(jq -nc \
      --arg file "$target_rel" \
      --arg template "$template_relpath" \
      --arg severity "template_missing" \
      --arg message "Marker references template '${template_relpath}' but no such template exists in the current development plugin. Was the template renamed or deleted upstream?" \
      '{_tool: "template_drift", file: $file, template_path: $template, severity: $severity, message: $message}')" )
    continue
  fi

  current_hash=$(shasum -a 256 "$template_abs" | awk '{print $1}')

  if [[ "$marker_hash" == "$current_hash" ]]; then
    # No drift.
    continue
  fi

  # Name the fixes a re-bootstrap would deliver (#400): collect changelog
  # entries for this template whose version is newer than the marker's.
  fixes_json='[]'
  blocking="false"
  if [[ -f "$changelog" ]]; then
    typeset -a kept=()
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      entry_version=$(printf '%s' "$entry" | jq -r '.version')
      if vgt "$entry_version" "$marker_version"; then
        kept+=( "$entry" )
      fi
    done < <(jq -c --arg t "$template_relpath" '(.[$t] // [])[]' "$changelog" 2>/dev/null)
    if (( ${#kept[@]} > 0 )); then
      fixes_json=$(printf '%s\n' "${kept[@]}" | jq -s 'sort_by(.version)')
      blocking=$(printf '%s' "$fixes_json" | jq 'any(.[]; .blocking == true)')
    fi
  fi

  if [[ "$fixes_json" != "[]" ]]; then
    fix_list=$(printf '%s' "$fixes_json" | jq -r 'map("#\(.issue) (\(.summary))") | join("; ")')
    message="Rendered from ${template_relpath} at development v${marker_version}; current is v${current_plugin_version}. Re-running /development:bootstrap would apply: ${fix_list}."
    [[ "$blocking" == "true" ]] && message="BLOCKING — ${message} One of these changes the behavior of a REQUIRED CI check; until you re-bootstrap, this repo keeps the old behavior."
  else
    message="Rendered from ${template_relpath} at development v${marker_version}; current development is v${current_plugin_version} and the template has changed (sha256 ${marker_hash} → ${current_hash}). Re-run /development:bootstrap to pick up upstream fixes."
  fi

  findings+=( "$(jq -nc \
    --arg file "$target_rel" \
    --arg template "$template_relpath" \
    --arg marker_version "$marker_version" \
    --arg current_version "$current_plugin_version" \
    --arg marker_hash "$marker_hash" \
    --arg current_hash "$current_hash" \
    --arg severity "drifted" \
    --argjson fixes "$fixes_json" \
    --argjson blocking "$blocking" \
    --arg message "$message" \
    '{_tool: "template_drift", file: $file, template_path: $template, marker_version: $marker_version, current_version: $current_version, marker_hash: $marker_hash, current_hash: $current_hash, severity: $severity, blocking: $blocking, fixes: $fixes, message: $message}')" )
done

# Emit as a JSON array. Empty array if no findings.
if (( ${#findings[@]} == 0 )); then
  print -- '[]'
else
  printf '%s\n' "${findings[@]}" | jq -s '.'
fi
