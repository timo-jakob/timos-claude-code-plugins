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

# --- resolve the marketplace's GitHub source before we wipe the registry ---
repo="$DEFAULT_REPO"
if [[ -f "$KNOWN_MARKETPLACES" ]]; then
  found=$(jq -r --arg m "$MARKETPLACE" \
    '.[$m].source.repo // empty' "$KNOWN_MARKETPLACES" 2>/dev/null || true)
  [[ -n "$found" ]] && repo="$found"
fi

# --- decide how Claude Code itself gets updated ----------------------------
# A Homebrew cask resolves to a .../Caskroom/... path; upgrade it via brew so
# we don't fight brew's own management. Anything else uses `claude update`.
claude_path="${commands[claude]}"
resolved="${claude_path:A}"
if [[ "$resolved" == *"/Caskroom/"* ]]; then
  cli_update_desc="brew upgrade --cask claude-code"
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
  brew upgrade --cask claude-code || print -u2 -- "  (brew upgrade reported no change or failed; continuing)"
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

print -- ":: Reinstalling ${#plugin_names} plugin(s)..."
failed=0
for name in "${plugin_names[@]}"; do
  print -- "  installing ${name}@${MARKETPLACE}"
  if ! claude plugin install "${name}@${MARKETPLACE}"; then
    print -u2 -- "  ✗ failed to install ${name}"
    failed=$((failed + 1))
  fi
done

print -- ""
if (( failed )); then
  print -u2 -- "Done with ${failed} plugin install failure(s)."
  exit 1
fi

print -- "Done. Restart Claude Code to apply the reinstalled plugins."
