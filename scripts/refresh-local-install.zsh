#!/usr/bin/env zsh
# refresh-local-install.zsh — fully refresh this machine's Claude Code +
# the timos-claude-code-plugins marketplace so local state exactly matches
# the latest published marketplace.
#
# It does three things, in order:
#   1. Updates the Claude Code CLI (brew cask if brew-managed, else `claude
#      update`).
#   2. Hard-purges every on-disk cache for the timos marketplace — the
#      per-plugin cache, the marketplace git clone, the plugin data dir, and
#      the shared plugin-catalog-cache.json (regenerated on next launch).
#   3. Re-adds the marketplace and reinstalls EVERY plugin it publishes,
#      discovered from the freshly-cloned .claude-plugin/marketplace.json so
#      "all plugins" stays correct as plugins are added or removed.
#
# Only the timos marketplace is touched — other marketplaces (official,
# superpowers) are left alone.
#
# Destructive: it deletes files and reinstalls plugins. It prints the plan and
# prompts once before making any change; -y/--yes skips the prompt, --dry-run
# prints the plan and exits without touching anything.
#
# A Claude Code restart is required to apply the reinstalled plugins.
#
# Usage:
#   refresh-local-install.zsh            # plan, confirm, then refresh
#   refresh-local-install.zsh -y         # non-interactive (skip confirm)
#   refresh-local-install.zsh --dry-run  # print the plan, change nothing
#   refresh-local-install.zsh -h         # help
#
# Exits 0 on success, 1 on failure, 2 on usage errors (missing jq/claude, or
# a bad flag). Requires jq and the claude CLI on PATH.

setopt err_exit nounset pipefail
zmodload zsh/datetime   # strftime, for locale-formatted "last updated" dates

readonly MARKETPLACE="timos-claude-code-plugins"
readonly DEFAULT_REPO="timo-jakob/timos-claude-code-plugins"
readonly PLUGINS_DIR="${HOME}/.claude/plugins"
readonly KNOWN_MARKETPLACES="${PLUGINS_DIR}/known_marketplaces.json"
readonly MARKETPLACE_CLONE="${PLUGINS_DIR}/marketplaces/${MARKETPLACE}"

# Paths purged from disk to guarantee "completely removed" regardless of what
# the CLI's own cleanup leaves behind.
readonly -a PURGE_PATHS=(
  "${PLUGINS_DIR}/cache/${MARKETPLACE}"
  "${MARKETPLACE_CLONE}"
  "${PLUGINS_DIR}/data/development-${MARKETPLACE}"
  "${PLUGINS_DIR}/plugin-catalog-cache.json"
)

yes=0
dry_run=0

usage() {
  cat <<'EOF'
refresh-local-install.zsh — fully refresh this machine's Claude Code + the
timos-claude-code-plugins marketplace so local state matches the latest
published marketplace.

It updates the Claude Code CLI, hard-purges every on-disk cache for the timos
marketplace (per-plugin cache, marketplace git clone, plugin data dir, and the
shared plugin-catalog-cache.json), then re-adds the marketplace and reinstalls
every plugin it publishes. Only the timos marketplace is touched.

Destructive — it prints the plan and prompts once before any change. A Claude
Code restart is required afterwards to apply the reinstalled plugins.

Usage:
  refresh-local-install.zsh            # plan, confirm, then refresh
  refresh-local-install.zsh -y|--yes   # non-interactive (skip confirm)
  refresh-local-install.zsh --dry-run  # print the plan, change nothing
  refresh-local-install.zsh -h|--help  # this help

Exits 0 on success, 1 on failure, 2 on usage errors. Requires jq + the claude
CLI on PATH.
EOF
}

# --- arg parsing -----------------------------------------------------------
while (( $# )); do
  case "$1" in
    -y|--yes)     yes=1 ;;
    --dry-run)    dry_run=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) print -u2 -- "Unknown option: $1"; print -u2 -- "Try --help."; exit 2 ;;
  esac
  shift
done

# --- preconditions ---------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || { print -u2 -- "jq required, not on PATH."; exit 2; }
command -v claude >/dev/null 2>&1 \
  || { print -u2 -- "claude CLI required, not on PATH."; exit 2; }

# --- snapshot what is installed NOW, so the summary can report old -> new ---
# The authoritative installed version is the version dir on disk under
# cache/<marketplace>/<plugin>/<version>. The `n` glob qualifier sorts
# numerically, so 1.148.1 wins over 1.9.0 (a lexical sort gets that backwards).
installed_version() {
  local -a dirs=("${PLUGINS_DIR}/cache/${MARKETPLACE}/$1"/*(/Nn))
  (( ${#dirs} )) && print -- "${dirs[-1]:t}" || print -- "(not installed)"
}

# Just the version field of `claude --version` ("2.1.220 (Claude Code)").
cli_version() {
  local raw
  raw="$(claude --version 2>/dev/null || true)"
  print -- "${${raw%% *}:-(unknown)}"
}

typeset -A version_before
for d in "${PLUGINS_DIR}/cache/${MARKETPLACE}"/*(/Nn); do
  version_before[${d:t}]="$(installed_version "${d:t}")"
done
cli_version_before="$(cli_version)"

# --- resolve the marketplace's GitHub source before we wipe the registry ---
repo="$DEFAULT_REPO"
if [[ -f "$KNOWN_MARKETPLACES" ]]; then
  found=$(jq -r --arg m "$MARKETPLACE" \
    '.[$m].source.repo // empty' "$KNOWN_MARKETPLACES" 2>/dev/null || true)
  [[ -n "$found" ]] && repo="$found"
fi

# --- decide how Claude Code itself gets updated ----------------------------
# A Homebrew cask resolves to a .../Caskroom/<cask>/<ver>/... path; upgrade it
# via brew so we don't fight brew's own management. The cask name is derived
# from the path (the segment right after /Caskroom/) rather than hardcoded, so
# both `claude-code` and the rolling `claude-code@latest` cask are handled.
# Anything else uses `claude update`.
claude_path="${commands[claude]}"
resolved="${claude_path:A}"
if [[ "$resolved" == *"/Caskroom/"* ]]; then
  cli_cask="${resolved#*/Caskroom/}"
  cli_cask="${cli_cask%%/*}"
  cli_update_desc="brew upgrade --cask ${cli_cask}"
  cli_update_kind="brew"
else
  cli_update_desc="claude update"
  cli_update_kind="claude"
fi

# --- plan ------------------------------------------------------------------
print -- "Refresh plan for marketplace '${MARKETPLACE}' (source: ${repo}):"
print -- ""
print -- "  1. Update Claude Code:   ${cli_update_desc}"
print -- "  2. Remove marketplace:   claude plugin marketplace remove ${MARKETPLACE}"
print -- "  3. Purge from disk:"
for p in "${PURGE_PATHS[@]}"; do
  print -- "       rm -rf ${p/#$HOME/~}"
done
print -- "  4. Re-add marketplace:   claude plugin marketplace add ${repo}"
print -- "  5. Reinstall every plugin listed in the re-cloned marketplace.json"
print -- ""

if (( dry_run )); then
  print -- "--dry-run: nothing changed."
  exit 0
fi

if (( ! yes )); then
  print -n -- "Proceed? This deletes the paths above and reinstalls. [y/N] "
  read -r reply
  if [[ "$reply" != [yY]* ]]; then
    print -- "Aborted."
    exit 0
  fi
fi

# --- 1. update the CLI -----------------------------------------------------
print -- ":: Updating Claude Code (${cli_update_desc})..."
if [[ "$cli_update_kind" == "brew" ]]; then
  brew upgrade --cask "$cli_cask" || print -u2 -- "  (brew upgrade reported no change or failed; continuing)"
else
  claude update || print -u2 -- "  (claude update reported no change or failed; continuing)"
fi

# --- 2. remove the marketplace via the CLI (registry + plugin uninstall) ----
# Best-effort: it may refuse or be a no-op if already gone. The rm -rf below is
# the real guarantee.
print -- ":: Removing marketplace '${MARKETPLACE}' from the registry..."
claude plugin marketplace remove "$MARKETPLACE" \
  || print -u2 -- "  (marketplace remove was a no-op or failed; continuing to disk purge)"

# --- 3. purge every cache path from disk -----------------------------------
print -- ":: Purging caches from disk..."
for p in "${PURGE_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    rm -rf -- "$p"
    print -- "  removed ${p/#$HOME/~}"
  fi
done

# --- 4. re-add the marketplace (re-clones a fresh copy) --------------------
print -- ":: Re-adding marketplace from ${repo}..."
claude plugin marketplace add "$repo"

# --- 5. reinstall every published plugin -----------------------------------
readonly FRESH_MANIFEST="${MARKETPLACE_CLONE}/.claude-plugin/marketplace.json"
[[ -f "$FRESH_MANIFEST" ]] \
  || { print -u2 -- "Re-cloned marketplace manifest missing: $FRESH_MANIFEST"; exit 1; }

plugin_names=("${(@f)$(jq -r '.plugins[].name' "$FRESH_MANIFEST")}")
(( ${#plugin_names} )) \
  || { print -u2 -- "No plugins found in $FRESH_MANIFEST"; exit 1; }

# Index-aligned with plugin_names; a non-string (git/URL) source yields an empty
# entry, which the summary reports as an unknown last-updated date.
plugin_sources=("${(@f)$(jq -r \
  '.plugins[] | if (.source | type) == "string" then .source else "" end' \
  "$FRESH_MANIFEST")}")

print -- ":: Reinstalling ${#plugin_names} plugin(s)..."
failed=0
for name in "${plugin_names[@]}"; do
  print -- "  installing ${name}@${MARKETPLACE}"
  if ! claude plugin install "${name}@${MARKETPLACE}"; then
    print -u2 -- "  ✗ failed to install ${name}"
    failed=$((failed + 1))
  fi
done

# --- summary: report the installed versions --------------------------------
# Versions come from the disk cache (cache/<marketplace>/<plugin>/<version>),
# not from what the manifest claims — so a plugin whose install failed shows
# "(not installed)". Each line reports "<was> -> <now>" when this run changed
# the version, and the bare version when it did not.
#
# "last updated" is the date of the newest commit touching that plugin's
# directory in the marketplace repo. `claude plugin marketplace add` makes a
# SHALLOW clone (a single commit), in which every plugin would report that one
# commit's date — so deepen it first, best-effort.
if [[ -f "${MARKETPLACE_CLONE}/.git/shallow" ]] && command -v git >/dev/null 2>&1; then
  print -- ":: Fetching marketplace history (for last-updated dates)..."
  git -C "$MARKETPLACE_CLONE" fetch --unshallow --quiet 2>/dev/null \
    || print -u2 -- "  (could not deepen the clone; last-updated dates unavailable)"
fi

# Date + time of the last commit touching <source> in the marketplace clone,
# formatted with %x %X so it follows the system's locale settings (LC_TIME/LANG)
# and rendered in local time — the time matters because a plugin can be updated
# several times in one day.
plugin_updated_at() {
  local src="${1#./}" epoch
  if [[ -z "$src" ]] || [[ -f "${MARKETPLACE_CLONE}/.git/shallow" ]] \
     || ! command -v git >/dev/null 2>&1; then
    print -- "unknown"
    return
  fi
  epoch="$(git -C "$MARKETPLACE_CLONE" log -1 --format=%ct -- "$src" 2>/dev/null || true)"
  [[ -n "$epoch" ]] && strftime '%x %X' "$epoch" || print -- "unknown"
}

# Build the version cells first, so both columns can be width-aligned.
typeset -a version_cells
name_width=0
version_width=0
for i in {1..${#plugin_names}}; do
  name="${plugin_names[i]}"
  now="$(installed_version "$name")"
  was="${version_before[$name]:-}"
  if [[ -n "$was" && "$was" != "$now" ]]; then
    version_cells[i]="${was} -> ${now}"
  else
    version_cells[i]="$now"
  fi
  (( ${#name} > name_width )) && name_width=${#name}
  (( ${#version_cells[i]} > version_width )) && version_width=${#version_cells[i]}
done

cli_version_now="$(cli_version)"
if [[ "$cli_version_before" != "$cli_version_now" ]]; then
  cli_cell="${cli_version_before} -> ${cli_version_now}"
else
  cli_cell="$cli_version_now"
fi

print -- ""
print -- "Installed versions:"
printf '  %-*s  %s\n' "$name_width" "Claude Code CLI" "$cli_cell"
for i in {1..${#plugin_names}}; do
  printf '  %-*s  %-*s  (last updated: %s)\n' \
    "$name_width" "${plugin_names[i]}" \
    "$version_width" "${version_cells[i]}" \
    "$(plugin_updated_at "${plugin_sources[i]:-}")"
done
print -- ""

if (( failed )); then
  print -u2 -- "Done with ${failed} plugin install failure(s)."
  exit 1
fi

print -- "Done. Restart Claude Code to apply the reinstalled plugins."
