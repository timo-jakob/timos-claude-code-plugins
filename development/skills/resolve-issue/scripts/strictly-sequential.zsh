#!/usr/bin/env zsh
# strictly-sequential.zsh — read the `epic_strictly_sequential` setting and
# print `on` or `off`.
#
# Why: an epic run normally resolves its provably-disjoint children in parallel
# worktree sub-agents and runs each review round's gate as a detached process
# beside the panel. A human who starts an epic unattended (overnight, say) and
# would rather trade throughput for a run with no re-work and nothing out of
# sight sets `epic_strictly_sequential` in the `env` block of their Claude Code
# settings, exactly as `switch_fable_to_opus` is set. The conductor runs this
# script once at the start of the Epic flow instead of judging the variable
# itself, so the truthiness rule has one statement and one test suite.
#
# Truthiness is the SAME as `switch_fable_to_opus`, because the default here is
# OFF: `1`, `true`, `yes`, `on` (any case) are ON; unset, "", and every other
# value — including a typo — are OFF. The conductor announces the mode it read
# at the start of the run, so a typo is visible rather than silent.
#
# Usage: strictly-sequential.zsh
# Output: exactly one line, `on` or `off`. Exit 0 always — there is no input
# to get wrong, and a failure to decide must never block an epic.

emulate -L zsh
setopt no_unset

case "${(L)${epic_strictly_sequential:-}}" in
  1|true|yes|on) print -r -- on ;;
  *) print -r -- off ;;
esac
