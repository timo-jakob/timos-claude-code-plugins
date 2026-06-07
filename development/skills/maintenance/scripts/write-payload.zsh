#!/usr/bin/env zsh
# Write a maintenance dispatch payload from stdin to a temp file and
# print its absolute path on stdout.
#
# Used by the orchestrator (development/skills/maintenance) to hand a
# JSON payload to a language dispatcher without passing the payload
# inline as a Skill-tool argument. See ARCHITECTURE.md § "JSON schema
# (v2)" for the file-handover contract.
#
# Usage:
#   write-payload.zsh < payload.json
#   echo "$payload_json" | write-payload.zsh
#
# Output (stdout):
#   /var/folders/.../claude-maintenance-payload.XXXXXXXX
#
# The caller (orchestrator) owns the temp file's lifecycle and removes
# it after the dispatch returns. On a hard crash, the file is left in
# $TMPDIR for the OS to reap.

set -euo pipefail

# 0600 on the temp file — payload may contain Snyk findings,
# code-scanning alerts, or other repo-sensitive data.
umask 077

payload_file=$(mktemp "${TMPDIR:-/tmp}/claude-maintenance-payload.XXXXXXXX")

cat > "$payload_file"

# Refuse to return a path to an empty payload — would just fail
# downstream validation; better to fail loud here.
if [[ ! -s "$payload_file" ]]; then
  rm -f "$payload_file"
  print -u2 "write-payload.zsh: empty stdin; refusing to write empty payload"
  exit 1
fi

print -r -- "$payload_file"
