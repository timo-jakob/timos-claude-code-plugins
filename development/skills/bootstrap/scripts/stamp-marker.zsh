#!/usr/bin/env zsh
# Stamp a provenance marker on a freshly-rendered bootstrap file.
#
# The marker captures three things needed by the maintenance pipeline's
# template-drift detector (#213):
#   1. Which bootstrap template the file was rendered from (relative path).
#   2. The `development` plugin version at render time.
#   3. The sha256 of the template file at render time.
#
# The detector reads the marker on subsequent maintenance runs and compares
# the recorded sha256 against the current template's sha256. Equal = no
# drift. Different = template evolved since render; surface as a finding.
#
# Usage:
#   stamp-marker.zsh --repo <repo-path> \
#                    --target <target-relpath> \
#                    --template <template-relpath>
#
#   --repo:     absolute path to the target repo
#   --target:   relative path of the rendered file inside <repo-path>
#               e.g. .github/dependabot.yml
#   --template: relative path of the source template inside templates/
#               e.g. common/.github/dependabot.yml.tmpl
#
# Idempotent: if the target already carries a marker line, the script
# exits 0 without modification. Bootstrap can therefore call it
# unconditionally on every rendered tracked file.
#
# Only YAML/Dockerfile/zsh/python-comment files are supported (anything
# whose comment leader is `#`). Templates that render to JSON or other
# comment-hostile formats are out of scope for v1 of #213.

set -euo pipefail

repo=""
target=""
template=""

while (( $# > 0 )); do
  case "$1" in
    --repo)     repo="$2";     shift 2 ;;
    --target)   target="$2";   shift 2 ;;
    --template) template="$2"; shift 2 ;;
    *) print -u2 "stamp-marker.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$repo" || -z "$target" || -z "$template" ]]; then
  print -u2 "stamp-marker.zsh: --repo, --target, and --template are required"
  exit 2
fi

script_dir="${0:A:h}"
skill_dir="${script_dir:h}"
skills_dir="${skill_dir:h}"
plugin_dir="${skills_dir:h}"

plugin_json="${plugin_dir}/.claude-plugin/plugin.json"
templates_root="${skill_dir}/templates"

target_abs="${repo}/${target}"
template_abs="${templates_root}/${template}"

if [[ ! -f "$target_abs" ]]; then
  print -u2 "stamp-marker.zsh: target not found: $target_abs"
  exit 1
fi
if [[ ! -f "$template_abs" ]]; then
  print -u2 "stamp-marker.zsh: template not found: $template_abs"
  exit 1
fi
if [[ ! -f "$plugin_json" ]]; then
  print -u2 "stamp-marker.zsh: plugin.json not found: $plugin_json"
  exit 1
fi

# Idempotency — bail if a marker is already present in the first 10 lines.
if head -10 "$target_abs" | grep -q "^# claude-bootstrap: rendered from "; then
  exit 0
fi

plugin_version=$(jq -r '.version' < "$plugin_json")
template_hash=$(shasum -a 256 "$template_abs" | awk '{print $1}')

marker_line_1="# claude-bootstrap: rendered from ${template} @ v${plugin_version} sha256:${template_hash}"
marker_line_2="# (do not edit this line; the maintenance pipeline uses it for drift detection — see #213)"

tmp=$(mktemp "${TMPDIR:-/tmp}/stamp-marker.XXXXXXXX")
{
  print -- "$marker_line_1"
  print -- "$marker_line_2"
  cat "$target_abs"
} > "$tmp"
mv "$tmp" "$target_abs"
