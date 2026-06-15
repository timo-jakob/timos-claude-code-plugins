#!/usr/bin/env bash
# cleanup.sh — Prune merged remote-tracking branches and delete merged local branches.
# Safe to run after merging a feature branch into main.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}==> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
error() {
	echo -e "${RED}✗ $*${NC}" >&2
	exit 1
}

# ── Verify we are inside a git repository ────────────────────────────────────
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || error "Not inside a git repository."

MAIN_BRANCH="main"

# ── Switch to main ────────────────────────────────────────────────────────────
CURRENT=$(git branch --show-current)
if [ "$CURRENT" != "$MAIN_BRANCH" ]; then
	log "Switching from '$CURRENT' to '$MAIN_BRANCH'..."
	git checkout "$MAIN_BRANCH"
else
	log "Already on '$MAIN_BRANCH'."
fi

# ── Pull latest main ──────────────────────────────────────────────────────────
log "Pulling latest '$MAIN_BRANCH'..."
git pull origin "$MAIN_BRANCH"

# ── Snapshot upstreams BEFORE prune, so we can detect squash-merges later ─────
# A squash-merged branch is not an ancestor of main (its tip SHA differs from
# the squash commit), so `git branch --merged` misses it. We use a different
# signal: the branch had an upstream before pruning, and that upstream is gone
# afterward — strong evidence the PR merged and GitHub auto-deleted the remote.
BEFORE_UPSTREAMS=$(mktemp)
trap 'rm -f "$BEFORE_UPSTREAMS"' EXIT
git for-each-ref --format='%(refname:short)|%(upstream:short)' refs/heads |
	grep -v '|$' >"$BEFORE_UPSTREAMS"

# ── Prune remote-tracking branches ───────────────────────────────────────────
log "Pruning stale remote-tracking branches..."
PRUNED=$(git fetch --prune 2>&1)
if echo "$PRUNED" | grep -q "pruned"; then
	echo "$PRUNED" | grep "pruned" | sed 's/^/  /'
	success "Remote-tracking branches pruned."
else
	success "No stale remote-tracking branches found."
fi

PROTECTED_RE='^(main|master|develop|staging|release/.+)$'

# ── Delete local branches already merged into main (true merge commits) ──────
log "Finding local branches merged into '$MAIN_BRANCH'..."

MERGED=$(git branch --merged "$MAIN_BRANCH" | grep -vE "^\*|^  (main|master|develop|staging|release/.+)$" || true)

if [ -z "$MERGED" ]; then
	success "No merged local branches to delete."
else
	echo "  Branches to delete:"
	echo "$MERGED" | sed 's/^/    /'
	echo "$MERGED" | xargs git branch -d
	success "Deleted merged local branches."
fi

# ── Delete squash-merged branches (upstream existed before, gone after) ──────
log "Finding squash-merged local branches (upstream removed after prune)..."

SQUASH_MERGED=""
while IFS='|' read -r branch upstream; do
	[ -z "$branch" ] && continue
	[[ "$branch" =~ $PROTECTED_RE ]] && continue
	# Already deleted by the --merged path? Skip.
	git show-ref --verify --quiet "refs/heads/$branch" || continue
	# Upstream ref still present? Then the remote branch wasn't pruned, so
	# we have no signal that it was merged. Leave it alone.
	if ! git rev-parse --verify --quiet "refs/remotes/$upstream" >/dev/null 2>&1; then
		SQUASH_MERGED="$SQUASH_MERGED$branch"$'\n'
	fi
done <"$BEFORE_UPSTREAMS"

SQUASH_MERGED=$(printf '%s' "$SQUASH_MERGED" | sed '/^$/d')

if [ -z "$SQUASH_MERGED" ]; then
	success "No squash-merged local branches to delete."
else
	echo "  Branches to delete (squash-merged, upstream gone):"
	echo "$SQUASH_MERGED" | sed 's/^/    /'
	# -D (force) is required: the branch tip is not an ancestor of main, so
	# safe -d would refuse. Reflog preserves SHAs for ~90 days if needed.
	echo "$SQUASH_MERGED" | xargs git branch -D
	success "Deleted squash-merged local branches."
fi

echo ""
success "Cleanup complete."
