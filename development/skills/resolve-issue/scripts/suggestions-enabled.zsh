#!/usr/bin/env zsh
# suggestions-enabled.zsh — read the `enable_suggestions` setting and print
# `on` or `off`.
#
# Why: resolve-issue's suggestion-promotion phase (reference/promotion.md)
# stops a converged interactive run to ask which waived suggestions to promote.
# A human who wants the run to carry straight on to the PR sets
# `enable_suggestions` to a falsy value in the `env` block of their Claude Code
# settings, exactly as `switch_fable_to_opus` is set. The conductor runs this
# script at the promotion gate instead of judging the variable itself, so the
# truthiness rule has one statement and one test suite.
#
# Truthiness is the MIRROR of `switch_fable_to_opus`, because the default here
# is ON: `0`, `false`, `no`, `off` (any case) are OFF; unset, "", and every
# other value — including a typo — are ON. A mistyped value therefore keeps
# today's behaviour (the prompt is offered) rather than silently waiving
# suggestions the human meant to see.
#
# Usage: suggestions-enabled.zsh
# Output: exactly one line, `on` or `off`. Exit 0 always — there is no input
# to get wrong, and a failure to decide must never block convergence.

emulate -L zsh
setopt no_unset

case "${(L)${enable_suggestions:-}}" in
  0|false|no|off) print -r -- off ;;
  *) print -r -- on ;;
esac
