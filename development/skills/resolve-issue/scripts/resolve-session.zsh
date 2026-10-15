#!/usr/bin/env zsh
# resolve-session.zsh — read the `resolve_session` setting and print the
# session mode resolve-issue runs in, with where it came from (#2575).
#
# Why: resolve-issue decides whether a human is present by inference — a human
# invoking the skill is interactive; an epic-driven child or the maintenance
# pipeline is autonomous — and every "ask the human" branch keys on that. A
# maintainer who starts a long run and leaves has no way to say "nobody is
# here", so the run stops at the first prompt and waits. `resolve_session`, set
# in the `env` block of their Claude Code settings exactly as
# `enable_suggestions` is, says it explicitly. §0a's human-present
# determination runs this script instead of judging the variable itself, so the
# parsing rule has one statement and one test suite.
#
# A script cannot see whether a human is present: that is the conductor's
# judgement, from how the run was started. So the caller passes the inference
# it makes today with --inferred, and this script only decides whether the
# setting overrides it.
#
# Usage: resolve-session.zsh --inferred attended|unattended
#
# Output: exactly one line on stdout, `<mode> <source>`:
#   resolve_session `attended` / `unattended` (any case, surrounding whitespace
#   trimmed)        -> `<that mode> env`
#   unset or empty  -> `<the --inferred mode> inferred`
#   any other value -> `<the --inferred mode> inferred`, plus ONE stderr line
#                      naming the ignored value, so a typo is visible in the
#                      run's narration instead of silently reverting to the
#                      inference
#
# Exit codes:
#   0  a mode was printed (every case above)
#   2  usage — --inferred missing, or its value is not attended / unattended,
#      an unknown flag, or a stray argument. Nothing is printed on stdout.
#   There is no other exit code.

emulate -L zsh
setopt no_unset extended_glob   # extended_glob: the `##` trim patterns below

local usage="usage: resolve-session.zsh --inferred attended|unattended"
local inferred=""

while (( $# > 0 )); do
  case "$1" in
    --inferred)
      (( $# >= 2 )) || { print -u2 -- "resolve-session: --inferred requires a value"; print -u2 -- "$usage"; exit 2; }
      inferred="$2"; shift 2 ;;
    -h|--help) print -r -- "$usage"; exit 0 ;;
    -*) print -u2 -- "resolve-session: unknown flag: $1"; print -u2 -- "$usage"; exit 2 ;;
    *) print -u2 -- "resolve-session: unexpected argument: $1"; print -u2 -- "$usage"; exit 2 ;;
  esac
done

case "$inferred" in
  attended|unattended) ;;
  "") print -u2 -- "resolve-session: --inferred is required"; print -u2 -- "$usage"; exit 2 ;;
  *) print -u2 -- "resolve-session: --inferred must be attended or unattended, got: $inferred"
     print -u2 -- "$usage"; exit 2 ;;
esac

# Lowercase, then trim surrounding whitespace (spaces, tabs, newlines).
local raw="${resolve_session:-}"
local value="${(L)raw}"
value="${value##[[:space:]]##}"
value="${value%%[[:space:]]##}"

case "$value" in
  attended|unattended) print -r -- "$value env" ;;
  "") print -r -- "$inferred inferred" ;;
  *)
    print -u2 -r -- "resolve-session: ignoring unrecognised resolve_session value '$raw'; using the inferred mode ($inferred)"
    print -r -- "$inferred inferred" ;;
esac
exit 0
