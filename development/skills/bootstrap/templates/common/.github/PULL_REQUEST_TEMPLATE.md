## Type

<!-- One of:
       feat | fix | refactor | chore(deps) | chore(deps-major) |
       chore(runtime) | security | docs | test | ci | build | chore |
       revert | hotfix
     Add a trailing `!` (e.g. `feat!`) for breaking changes.

     When the Claude Approver is enabled (--claude-approver true at
     bootstrap), this drives the per-type criteria in
     .claude/approver-policy.md. -->

## Summary

<!-- 1-3 bullet points describing what changed and why. -->

## Linked issue

<!-- Closes #123 — or remove this section if not applicable.

     For feat: PRs evaluated by the Claude Approver, the linked issue's
     body is read as the user-story context to match against the
     implementation. -->

## Risk

<!-- What could go wrong? Edge cases not exercised? Anything load-bearing
     untested? Known limitations of the change?

     The Claude Approver reads this when building the PR's risk register.
     A specific honest "this could break X under Y" is more useful than
     "no known risks". -->

## Test plan

- [ ] Unit tests added or updated
- [ ] Manual testing performed (describe below)
- [ ] `pre-commit run --all-files` passes locally
- [ ] Local quality scan (`semgrep`, language linters) passes
- [ ] Coverage on new code ≥ 90%

## Notes for reviewer

<!-- Anything specific you want feedback on, or context that won't be
     obvious from the diff. -->
