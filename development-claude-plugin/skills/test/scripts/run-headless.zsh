#!/usr/bin/env zsh
setopt err_exit nounset pipefail

# run-headless.zsh — launch a single headless `claude` session against a target
# project directory with one or more LOCAL (uncommitted) plugins loaded, and
# capture its stream-json transcript to a file.
#
# This is the "system under test" layer of /development-claude-plugin:test. It
# is invoked by the fresh-context judge subagent (or, as a fallback, directly by
# the authoring session) so the undocumented "claude launches claude" nesting is
# isolated to exactly one place.
#
# Usage:
#   run-headless.zsh \
#     --cwd <dir> \
#     --out <file.jsonl> \
#     --plugins <dir1>[,<dir2>,...] \
#     --prompt "<task, e.g. /development:maintenance --dry-run --tool version_sync>" \
#     [--gh-repo <owner/repo>]     # give the child GitHub context (see note below)
#     [--permission-mode <mode>]   # default: bypassPermissions (see note below)
#
# NOTE on --gh-repo: the clone's `origin` is a local filesystem path, so the
# child's `gh` calls can't resolve a GitHub host and every gh-based gather
# (vendor PRs, code scanning, container scan) comes back empty. Passing
# --gh-repo exports GH_REPO for the child, which `gh` honors over git-remote
# detection — so READ-ONLY gathers resolve the real repo while git push/fetch
# stay isolated on the local-path origin. Because that same context would let a
# non-dry-run run MUTATE real shared PRs, only pass --gh-repo for dry-run /
# read-only tasks (the harness SKILL enforces this).
#
# Exit code mirrors the child `claude` process. The transcript (newline-delimited
# JSON, one event per line) is always written to --out, even on failure, so the
# caller can inspect partial progress.
#
# NOTE on permissions: a headless run cannot answer interactive prompts, so it
# must pre-authorize tools or it will hang. The default is bypassPermissions
# because the harness always runs against a throwaway clone with --dry-run; the
# blast radius is a disposable copy. Override with --permission-mode acceptEdits
# plus your own allow-listing if you want a tighter run.

emulate -L zsh

local cwd="" out="" plugins="" prompt="" permission_mode="bypassPermissions" gh_repo=""

while (( $# )); do
  case "$1" in
    --cwd)             cwd="$2";             shift 2 ;;
    --out)             out="$2";             shift 2 ;;
    --plugins)         plugins="$2";         shift 2 ;;
    --prompt)          prompt="$2";          shift 2 ;;
    --gh-repo)         gh_repo="$2";         shift 2 ;;
    --permission-mode) permission_mode="$2"; shift 2 ;;
    *) print -u2 "run-headless.zsh: unknown argument: $1"; exit 2 ;;
  esac
done

# --- validate --------------------------------------------------------------
local missing=()
[[ -n "$cwd"     ]] || missing+=(--cwd)
[[ -n "$out"     ]] || missing+=(--out)
[[ -n "$plugins" ]] || missing+=(--plugins)
[[ -n "$prompt"  ]] || missing+=(--prompt)
if (( ${#missing} )); then
  print -u2 "run-headless.zsh: missing required argument(s): ${(j:, :)missing}"
  exit 2
fi

[[ -d "$cwd" ]] || { print -u2 "run-headless.zsh: --cwd is not a directory: $cwd"; exit 2 }
command -v claude >/dev/null 2>&1 || {
  print -u2 "run-headless.zsh: 'claude' not on PATH. Install Claude Code first."
  exit 127
}

# --- assemble plugin-dir flags --------------------------------------------
# Split the comma-separated --plugins list into repeated --plugin-dir flags.
local -a plugin_flags=()
local d
for d in ${(s/,/)plugins}; do
  [[ -d "$d" ]] || { print -u2 "run-headless.zsh: plugin dir does not exist: $d"; exit 2 }
  plugin_flags+=(--plugin-dir "$d")
done

# --- run -------------------------------------------------------------------
print -u2 "run-headless.zsh: launching headless claude"
print -u2 "  cwd:        $cwd"
print -u2 "  plugins:    ${(j:, :)${(s/,/)plugins}}"
print -u2 "  permission: $permission_mode"
print -u2 "  gh-repo:    ${gh_repo:-<none — gh gathers will be empty>}"
print -u2 "  prompt:     $prompt"
print -u2 "  transcript: $out"

# `-p` with stream-json requires --verbose. Run from the target directory so
# the session's cwd is the project under test. err_exit is suspended around the
# call so we can capture and surface the child's exit code rather than aborting.
# GH_REPO (when set) is exported only for the child subshell so its gh-based
# gathers resolve the real repo; git push/fetch still use the local-path origin.
local rc=0
{
  cd "$cwd"
  [[ -n "$gh_repo" ]] && export GH_REPO="$gh_repo"
  claude \
    "${plugin_flags[@]}" \
    -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --permission-mode "$permission_mode" \
    > "$out"
} always {
  rc=$?
}

print -u2 "run-headless.zsh: child claude exited with code $rc"
exit $rc
