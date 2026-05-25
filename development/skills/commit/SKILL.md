---
name: commit
description: Commit code changes after running formatting/linting and generating a commit message
disable-model-invocation: false
---

You are a commit orchestrator. The user wants to commit their changes.

**User input:** $ARGUMENTS

This may contain a commit message, or it may be empty (in which case you will generate one).

## Step 1: Snapshot the Real Changes

Before any formatting or linting, run `git diff` and `git diff --staged` using Bash to capture the **substantive changes** the user made. Save this context — you will need it for the commit message later. Also run `git status` to see untracked files.

## Step 2: Format/Lint and Generate Commit Message

Launch the following agents **in parallel in a single message**. The commit message agent works from the diff captured in Step 1, so it does not need to wait for formatting/linting to finish.

### Agent A — Formatting + Linting

Detect the project language from the changed files and look for a language-specific formatting/linting agent in the appropriate plugin. For example:

- **Swift projects** → use the `swift-lint-format` agent from the `development-swift` plugin
- **Other languages** → if a matching agent exists in an installed plugin, use it; otherwise skip this step and inform the user that no formatter/linter is configured for this language

Spawn the agent with `run_in_background: true`.

### Agent B — Commit Message (sonnet) — skip if user provided a message in `$ARGUMENTS`

Use the `commit-message` agent. Pass it the git diff captured in Step 1.

Wait for both agents to complete before proceeding.

## Step 3: Ensure We Are on a Feature Branch

Before committing, make sure changes are not committed directly to `main`.

1. Run `git branch --show-current` to determine the current branch.
2. **If already on a branch other than `main`** — stay on it and proceed to Step 4.
3. **If on `main`** — create a new branch using the `git-branch-naming` skill:
   - Determine the appropriate branch type (`feat`, `fix`, `chore`, `refactor`, `docs`, `hotfix`) from the changes captured in Step 1.
   - Derive a short kebab-case description from the changes.
   - Ask the user once if there is a GitHub Issue number. If they say no or don't know, proceed without one.
   - Propose the branch name to the user before creating it.
   - Create and switch to the branch: `git switch -c <branch-name>`

## Step 4: Stage and Commit

1. Stage all relevant changes using `git add` on specific files (use `git status` to identify them). Include both the user's original changes and any formatting/linting fixes.
2. Create the commit using the message from Step 2 (or the user-provided message). Use a HEREDOC to pass the message:
   ```
   git commit -m "$(cat <<'EOF'
   <commit message here>
   EOF
   )"
   ```
3. Run `git log --oneline -1` and `git status` to confirm the commit succeeded.
4. Show the user the commit hash, message, and the branch it was committed to.

## Important Rules

- NEVER mention formatting or linting in the commit message. These are invisible hygiene steps.
- NEVER skip the formatting/linting step, even if the user says "quick commit".
- If the formatter or linter reports errors that cannot be auto-fixed, inform the user and ask how to proceed before committing.
- Do NOT push to remote unless the user explicitly asks.
