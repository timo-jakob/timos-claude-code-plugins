#!/usr/bin/env bash
# detect-stack.sh — emits JSON describing the current repository's state.
# Used by /development:bootstrap to drive its setup flow.
#
# Output keys:
#   git_initialized       bool
#   has_github_remote     bool
#   github_repo           string  (owner/repo or "")
#   default_branch        string  ("" if not detectable)
#   visibility            "public" | "private" | "unknown"
#   languages             []string  subset of [swift, typescript, python, go]
#   has_dockerfile        bool
#   existing_artifacts    object   path -> true for files we would otherwise generate
#
# All paths are evaluated relative to the current working directory.

set -euo pipefail

cwd="$(pwd)"

json_bool() { [[ "$1" == "true" ]] && printf "true" || printf "false"; }
json_str()  { printf '"%s"' "${1//\"/\\\"}"; }

# --- git ---------------------------------------------------------------------
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_initialized="true"
else
  git_initialized="false"
fi

# --- github remote -----------------------------------------------------------
has_github_remote="false"
github_repo=""
default_branch=""
visibility="unknown"

if [[ "$git_initialized" == "true" ]]; then
  origin_url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin_url" =~ github\.com[:/]+([^/]+/[^/.]+) ]]; then
    has_github_remote="true"
    github_repo="${BASH_REMATCH[1]}"
  fi

  if command -v gh >/dev/null 2>&1 && [[ "$has_github_remote" == "true" ]]; then
    gh_json="$(gh repo view "$github_repo" --json visibility,defaultBranchRef 2>/dev/null || true)"
    if [[ -n "$gh_json" ]]; then
      vis_raw="$(printf '%s' "$gh_json" | sed -n 's/.*"visibility":"\([^"]*\)".*/\1/p')"
      case "$vis_raw" in
        PUBLIC)  visibility="public" ;;
        PRIVATE) visibility="private" ;;
        *)       visibility="unknown" ;;
      esac
      default_branch="$(printf '%s' "$gh_json" | sed -n 's/.*"defaultBranchRef":{"name":"\([^"]*\)".*/\1/p')"
    fi
  fi
fi

# --- languages ---------------------------------------------------------------
detect_lang() {
  local lang="$1"; shift
  for marker in "$@"; do
    while IFS= read -r -d '' _; do
      printf '%s\n' "$lang"
      return
    done < <(find "$cwd" \
      -path '*/node_modules' -prune -o \
      -path '*/.git' -prune -o \
      -path '*/vendor' -prune -o \
      -path '*/.build' -prune -o \
      -path '*/dist' -prune -o \
      -name "$marker" -print0 2>/dev/null)
  done
}

langs=()
[[ -n "$(detect_lang swift      Package.swift  '*.xcodeproj'   '*.xcworkspace')" ]] && langs+=("swift")
[[ -n "$(detect_lang typescript package.json   tsconfig.json)" ]] && langs+=("typescript")
[[ -n "$(detect_lang python     pyproject.toml requirements.txt setup.py)" ]] && langs+=("python")
[[ -n "$(detect_lang go         go.mod)" ]] && langs+=("go")

languages_json="["
for i in "${!langs[@]}"; do
  [[ "$i" -gt 0 ]] && languages_json+=","
  languages_json+="$(json_str "${langs[$i]}")"
done
languages_json+="]"

# --- dockerfile --------------------------------------------------------------
has_dockerfile="false"
if [[ -f "$cwd/Dockerfile" ]] || \
   [[ -f "$cwd/docker/Dockerfile" ]] || \
   find "$cwd" -maxdepth 3 -name 'Dockerfile' -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
  has_dockerfile="true"
fi

# --- existing artifacts ------------------------------------------------------
# Files we would generate. We mark which already exist so the skill can skip/diff.
candidate_paths=(
  ".pre-commit-config.yaml"
  ".github/dependabot.yml"
  ".github/ISSUE_TEMPLATE/bug.yml"
  ".github/ISSUE_TEMPLATE/feature.yml"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/workflows/quality-public.yml"
  ".github/workflows/quality-private.yml"
  ".github/workflows/codeql.yml"
  "sonar-project.properties"
  ".snyk"
  "trivy.yaml"
  "infra/sonarqube/docker-compose.yml"
  "CONTRIBUTING.md"
  "SETUP.md"
  "CLAUDE.md"
  ".gitignore"
  "LICENSE"
)

artifacts_json="{"
first=1
for p in "${candidate_paths[@]}"; do
  if [[ -e "$cwd/$p" ]]; then
    [[ $first -eq 1 ]] && first=0 || artifacts_json+=","
    artifacts_json+="$(json_str "$p"):true"
  fi
done
artifacts_json+="}"

# --- emit --------------------------------------------------------------------
cat <<EOF
{
  "git_initialized": $(json_bool "$git_initialized"),
  "has_github_remote": $(json_bool "$has_github_remote"),
  "github_repo": $(json_str "$github_repo"),
  "default_branch": $(json_str "$default_branch"),
  "visibility": $(json_str "$visibility"),
  "languages": $languages_json,
  "has_dockerfile": $(json_bool "$has_dockerfile"),
  "existing_artifacts": $artifacts_json
}
EOF
