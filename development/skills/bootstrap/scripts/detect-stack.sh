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
#   python_version        string   ("3.13", "3.12", ...; "" if not Python)
#   has_pytest_cov        bool     (true if pytest-cov is in dev deps already)
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

  # Fall back to the locally-checked-out branch when gh didn't tell us
  # (no remote, no auth, or repo view failed). Without this fallback the
  # orchestrator has no value to substitute for {{DEFAULT_BRANCH}}.
  if [[ -z "$default_branch" ]]; then
    default_branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || echo "")"
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

# --- python version + pytest-cov --------------------------------------------
# Both only meaningful when Python is in the detected language set. We still
# emit defaults ("3.12" / false) when Python isn't detected so the
# orchestrator doesn't have to special-case the JSON shape.
python_version=""
has_pytest_cov="false"

python_in_langs="false"
for l in ${langs[@]+"${langs[@]}"}; do
  [[ "$l" == "python" ]] && python_in_langs="true"
done

if [[ "$python_in_langs" == "true" ]]; then
  pyproject="$cwd/pyproject.toml"

  # Parse `requires-python` and strip operators (>=, ~=, ^, <, >). Prefer
  # python3's tomllib (stdlib 3.11+); fall back to grep so the script
  # doesn't hard-require a recent Python on the host.
  if [[ -f "$pyproject" ]] && command -v python3 >/dev/null 2>&1; then
    python_version="$(python3 - <<EOF 2>/dev/null || true
import re, sys
try:
    import tomllib
    with open("$pyproject", "rb") as f:
        data = tomllib.load(f)
    rp = data.get("project", {}).get("requires-python", "")
    m = re.search(r"\d+\.\d+", rp)
    print(m.group(0) if m else "")
except Exception:
    pass
EOF
)"
  fi

  # Fallback: grep for "requires-python" if Python's tomllib path didn't
  # yield anything (older python3 on host, malformed file, etc.).
  if [[ -z "$python_version" && -f "$pyproject" ]]; then
    python_version="$(grep -E '^[[:space:]]*requires-python' "$pyproject" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  fi

  # Sensible default — current stable interpreter at time of writing.
  [[ -z "$python_version" ]] && python_version="3.12"

  # pytest-cov detection: search pyproject dev extras + requirements files.
  if [[ -f "$pyproject" ]] && command -v python3 >/dev/null 2>&1; then
    if python3 - <<EOF >/dev/null 2>&1
import sys
try:
    import tomllib
    with open("$pyproject", "rb") as f:
        data = tomllib.load(f)
    deps = data.get("project", {}).get("optional-dependencies", {}).get("dev", [])
    for d in deps:
        if d.lower().startswith("pytest-cov"):
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
EOF
    then
      has_pytest_cov="true"
    fi
  fi

  # Also scan requirements*.txt files (a common pattern for projects that
  # split runtime + dev deps across multiple manifest files).
  if [[ "$has_pytest_cov" == "false" ]]; then
    for rf in "$cwd"/requirements*.txt; do
      [[ -f "$rf" ]] || continue
      if grep -qiE '^[[:space:]]*pytest-cov' "$rf" 2>/dev/null; then
        has_pytest_cov="true"
        break
      fi
    done
  fi
fi

# --- dockerfile --------------------------------------------------------------
has_dockerfile="false"
if [[ -f "$cwd/Dockerfile" ]] || \
   [[ -f "$cwd/docker/Dockerfile" ]] || \
   find "$cwd" -maxdepth 3 -name 'Dockerfile' -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
  has_dockerfile="true"
fi

# --- existing artifacts ------------------------------------------------------
# Files we would generate. We mark which already exist so the skill can
# skip/diff. The candidate list is derived dynamically from the templates
# directory so new templates auto-include without touching this script.
#
# Mapping rules:
#   templates/<scope>/foo              → foo
#   templates/<scope>/foo.tmpl         → foo
#   templates/<scope>/.github/x.yml    → .github/x.yml
# Language fragments (templates/languages/<lang>/*) follow the same shape
# but are only candidates for languages actually detected above.
# The merged .gitignore and conditional LICENSE are added explicitly.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
templates_dir="$(cd -- "$script_dir/../templates" &>/dev/null && pwd)"

# A "gitignore" fragment inside templates/languages/<lang>/ is merged into the
# project's single top-level .gitignore — not a stand-alone file. Skip it from
# the candidate list (the merged .gitignore is added explicitly below).
collect_from() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r tmpl_path; do
    rel="${tmpl_path#$dir/}"          # strip prefix
    rel="${rel%.tmpl}"                # strip .tmpl suffix if present
    [[ "$rel" == "gitignore" ]] && continue   # fragment, not a target file
    candidate_paths+=("$rel")
  done < <(find "$dir" -type f 2>/dev/null)
}

candidate_paths=()
collect_from "$templates_dir/common"
collect_from "$templates_dir/public"
collect_from "$templates_dir/private"

# Language-specific fragments (only for detected languages).
# `${langs[@]+...}` guards against the array being empty under `set -u`.
for lang in ${langs[@]+"${langs[@]}"}; do
  collect_from "$templates_dir/languages/$lang"
done

# Always-check files that don't map 1:1 to a template:
#   .gitignore (merged from language fragments above)
#   LICENSE (asked of user if missing)
candidate_paths+=(".gitignore" "LICENSE")

# Dedupe (some files like sonar-project.properties exist in both public/ and
# private/ scope — we'd otherwise list it twice).
candidate_paths=($(printf '%s\n' "${candidate_paths[@]}" | awk '!seen[$0]++'))

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
  "python_version": $(json_str "$python_version"),
  "has_pytest_cov": $(json_bool "$has_pytest_cov"),
  "existing_artifacts": $artifacts_json
}
EOF
