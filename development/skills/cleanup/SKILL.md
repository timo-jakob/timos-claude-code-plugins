---
name: cleanup
description: >
  Cleans up the local git environment after merging a branch to main.
  Prunes stale remote-tracking branches and deletes local branches that
  are already merged into main. Run this after a PR is merged to main.
disable-model-invocation: true
---

You are a git cleanup orchestrator. The user wants to tidy up their local repository after merging a branch to main.

## Step 1: Run the cleanup script

The script is at `scripts/cleanup.sh` inside this skill's base directory. Make it executable and run it from the
**user's current working directory**:

```bash
chmod +x <skill-base-dir>/scripts/cleanup.sh
<skill-base-dir>/scripts/cleanup.sh
```

Capture and display the full output to the user. If the script exits with a non-zero status, report the error clearly
and stop.

## Step 2: Summarise

After the script completes, show the user a clear summary:

- Which branch they are now on
- Which remote-tracking refs were pruned (if any)
- Which local branches were deleted (if any), or "none" if there were none
- A confirmation that the cleanup is complete

## Important rules

- Do not push anything, create commits, or modify any files in the user's repository.
