---
name: git-branch-naming
description: >
  Defines how git branches must be named at this organization. Use this skill whenever
  Claude Code is about to create a git branch, suggest a branch name, check out a new branch,
  or when the user asks "what should I name this branch", "create a branch for...", or
  "start work on issue #...". Always consult this skill before proposing or creating any
  branch name — even for quick fixes or experiments.
---

# Git Branch Naming Convention

## Format

Branches follow one of two formats depending on whether a GitHub Issue exists:

**With issue number** (preferred when a GitHub Issue exists):

```
<type>/<issue-number>-<short-description>
```

**Without issue number** (for informal/exploratory work):

```
<type>/<short-description>
```

The `type` is always required. The issue number is optional but strongly preferred when work is tracked in GitHub Issues.

### Examples

```
# With GitHub Issue
feat/42-add-oauth-login
fix/87-null-pointer-on-empty-cart
chore/101-upgrade-to-node-20
refactor/55-extract-payment-service
docs/12-api-authentication-guide
hotfix/200-csrf-token-missing

# Without GitHub Issue
feat/add-oauth-login
fix/null-pointer-on-empty-cart
chore/upgrade-to-node-20
refactor/extract-payment-service
docs/api-authentication-guide
hotfix/csrf-token-missing
```

---

## Branch Types

| Type       | When to use                                                     |
|------------|-----------------------------------------------------------------|
| `feat`     | New features or user-facing functionality                       |
| `fix`      | Bug fixes in non-production code                                |
| `hotfix`   | Urgent fixes to production; typically branched from `main`      |
| `chore`    | Dependency updates, CI/CD changes, tooling, build system        |
| `refactor` | Code restructuring with no functional change                    |
| `docs`     | Documentation only changes                                      |

**When in doubt between `feat` and `refactor`**: if the user will notice the change, use `feat`. If only the code
changes, use `refactor`.

---

## Short Description Rules

- **kebab-case only** — all lowercase, words separated by hyphens
- **No underscores**, no spaces, no special characters except hyphens
- **2–5 words** — concise but descriptive enough to understand without looking at the issue
- **Use the imperative mood** — `add-login`, `fix-crash`, not `adding-login`, `fixed-crash`
- **Max 50 characters** for the full branch name (type + optional issue + description)

### Good vs Bad

| ✅ Good                          | ❌ Bad                                    |
|----------------------------------|-------------------------------------------|
| `feat/23-add-user-avatars`       | `feat/23-AddUserAvatars`                  |
| `feat/add-user-avatars`          | `feat/23_add_user_avatars`                |
| `fix/99-login-redirect-loop`     | `fix/99_login_redirect_loop`              |
| `fix/login-redirect-loop`        | `fix/login redirect loop`                 |
| `chore/14-bump-jest-29`          | `chore/14-updated-jest-version-to-29`     |
| `chore/bump-jest-29`             | `chore/bumping-jest-to-version-29-stable` |
| `refactor/67-split-auth-module`  | `67-split-auth-module` (missing type)     |
| `hotfix/fix-xss-in-comments`     | `hotfix-fix-xss` (wrong separator)        |

---

## Issue Numbers

- Issue numbers reference **GitHub Issues** in the repository
- Use the numeric ID as it appears in GitHub (e.g. `#42` → use `42`)
- **When to include**: if the user mentions an issue number, or if the work is clearly tracked in GitHub, always
  include it
- **When to omit**: exploratory spikes, quick experiments, local-only work, or when the user explicitly has no issue
- **Never invent** an issue number — if unsure whether one exists, ask the user once

---

## Protected Branches

Never create branches directly named:

- `main`
- `develop`
- `release/*`
- `staging`

These are managed through PRs only.

---

## Workflow

When asked to start work on a task or create a branch:

1. **Identify the type** — ask if ambiguous
2. **Check for an issue number** — if the user mentions one, use it; if not, ask once: *"Is there a GitHub Issue for
   this? If so, what's the number?"*; if they say no or don't know, proceed without one
3. **Derive a short description** from the task or issue title (apply the rules above)
4. **Propose the branch name** to the user before creating it
5. **Create and switch to** the branch:

   ```bash
   # With issue
   git switch -c feat/42-add-oauth-login

   # Without issue
   git switch -c feat/add-oauth-login
   ```

If the user provides a branch name that violates these rules, point out the violation and suggest a corrected name
before proceeding.
