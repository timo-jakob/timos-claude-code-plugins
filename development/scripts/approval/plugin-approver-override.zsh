#!/usr/bin/env zsh
# plugin-approver-override.zsh — may the Claude Approver approve PRs on this
# claude-plugin repo in THIS session? A claude-plugin repo is human-only
# (#1684); CLAUDE_PLUGIN_APPROVER=1 is a per-session, environment-only opt-in
# that nothing records in the repo. Every flow must ask this script instead of
# reading the variable itself (#2131).
#
# "No Approver App" — not registered for the repo's owner, or not installed on
# the repo — is the SUPPORTED way to forbid AI approvals (an organisation that
# wants none simply does not install it). It is a decision, not a failure:
# exit 0, nothing on stderr, whether or not the variable is set.
#
# Usage: plugin-approver-override.zsh        (no arguments; run anywhere inside the repo)
#
# Checks run in this order, and the first one that fails decides:
#   1. CLAUDE_PLUGIN_APPROVER is exactly `1`        else env-unset
#   2. <repo root>/.claude-plugin/plugin.json or marketplace.json exists
#                                                    else not-plugin-repo
#   3. claude-apps-owner.zsh status claude-approver  else approver-not-registered,
#                                                    approver-key-missing or
#                                                    approver-registry-unusable
#   4. mint-approver-token.zsh --check-installed     else approver-not-installed
#                                                    or approver-lookup-failed
# With the variable unset nothing is probed: no gh, Keychain or GitHub call.
#
# Stdout: `override=on`, or `override=off` then `reason=<slug>`.
#
# Exit codes:
#   0 — override=on, or off for env-unset | not-plugin-repo |
#       approver-not-registered | approver-not-installed (stderr empty)
#   1 — off for a broken setup someone intended: approver-key-missing (the
#       owner probe's `fix:` line relayed), approver-registry-unusable (owner
#       probe exit 1 or 4) or approver-lookup-failed (--check-installed exit 2,
#       or any exit other than 0 and 3) — the probe's diagnostic is relayed on
#       stderr. Callers still take the human path.

setopt err_exit nounset pipefail

script_dir="${0:A:h}"
owner_helper="$script_dir/../../skills/bootstrap/scripts/claude-apps-owner.zsh"
mint="$script_dir/../../skills/maintenance/scripts/mint-approver-token.zsh"

off() {
  print -r -- "override=off"
  print -r -- "reason=$1"
  exit "${2:-0}"
}

[[ "${CLAUDE_PLUGIN_APPROVER:-}" == "1" ]] || off env-unset
root=$(git rev-parse --show-toplevel 2>/dev/null) || off not-plugin-repo
[[ -f "$root/.claude-plugin/plugin.json" || -f "$root/.claude-plugin/marketplace.json" ]] || off not-plugin-repo

diag_file=$(mktemp "${TMPDIR:-/tmp}/plugin-approver-override.XXXXXX")
trap 'rm -f "$diag_file"' EXIT

rc=0
report=$(zsh "$owner_helper" status claude-approver 2>"$diag_file") || rc=$?
case $rc in
  0) ;;
  3)
    if grep -q '^approver: key missing' <<<"$report"; then
      print -u2 -r -- "The Claude Approver is registered but its Keychain key is missing."
      grep '^fix: ' <<<"$report" >&2 || true
      off approver-key-missing 1
    fi
    off approver-not-registered
    ;;
  *)
    [[ -s "$diag_file" ]] && cat "$diag_file" >&2
    off approver-registry-unusable 1
    ;;
esac

rc=0
zsh "$mint" --check-installed >/dev/null 2>"$diag_file" || rc=$?
case $rc in
  0) print -r -- "override=on" ;;
  3) off approver-not-installed ;;
  *)
    [[ -s "$diag_file" ]] && cat "$diag_file" >&2
    off approver-lookup-failed 1
    ;;
esac
