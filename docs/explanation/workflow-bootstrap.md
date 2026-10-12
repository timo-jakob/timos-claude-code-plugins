# How bootstrap works

`/development:bootstrap` gives a repository the family's full quality and security toolchain: CI workflows composed
per tool, scanner configuration, pre-commit hooks, branch protection, dependency updates, issue and PR templates, the
docs stack and C4 diagrams. It detects as much as it can, asks only what it cannot detect, shows you one plan, and
writes nothing until you confirm it. It is idempotent: on a repository that is already set up it fills only the gaps.

The colour key for the diagrams is on [How the plugins work](how-the-plugins-work.md).

![bootstrap end to end: detect, ask, confirm the plan, review it, write and validate the files, open the
PR](diagrams/bootstrap.svg)

## Detect, ask, plan {#bootstrap-detect-ask-plan}

1. **Step 1 — detect.** `detect-stack.sh` reports the repository's visibility, languages, Docker and IaC markers,
   which artifacts already exist and which are missing, and the GitHub-side state: branch protection, secret names,
   whether a Sonar project exists. If detection fails, it prints no result and the run stops rather than guessing.
2. **Pick the entry state.**
   - **A — no git repository:** offer `git init`.
   - **B — no GitHub remote:** offer to add one.
   - **C — `gh` not authenticated:** offer `gh auth login`, then detect again. If you decline, the GitHub-side steps
     become written instructions instead.
   - **D — remote and authentication in place.** With every file already present, bootstrap does **gap-fill**: it
     offers to apply or reconcile branch protection, store missing secrets and set up the Sonar project — without
     touching a file — and checks the generated files for drift against the current templates.
3. **Ask what detection could not answer** — whether to create the GitHub repository, its name and visibility, the
   toolchain, the languages, whether a Dockerfile is coming, a security contact.
4. **Resolve three decisions.**
   - The **primary language**: a Claude-plugin repo is `claude-plugin`; a single language is itself; otherwise you
     are asked. The others become auxiliary.
   - The **toolchain**, per tool category: what the repo already records, else what you chose, else the visibility
     default — SonarCloud, Snyk and CodeQL for a public repository; self-hosted SonarQube and Trivy for a private one.
     Combinations that cannot work, such as self-hosted SonarQube on a public repository, are rejected.
   - The **approval model**: `human` or `approver`. Plugin and IaC repositories are always human-approved.
5. **Step 2 — the plan.** One block shows everything: visibility, primary type, languages, toolchain and where each
   choice came from, the approval model, and which files will be created, skipped or diffed. This is the single
   consent gate — declining ends the run with nothing written.

## Review, write, finish {#bootstrap-review-write-finish}

1. **Step 2.5 — plan review.** Three reviewers read the planned output, in parallel, before anything is on disk:
   - `bootstrap-security-reviewer` — workflow permissions, secret references, unpinned actions;
   - `bootstrap-config-consistency` — Sonar keys, job ids against branch-protection contexts, secrets against
     `SETUP.md`;
   - `bootstrap-idempotency-reviewer` — skip, overwrite or merge for every file that already exists.

   A BLOCK needs your explicit override, and you confirm each overwrite or merge per file.
2. **Step 3 — generate the files.** Templates are rendered. A missing file is written; an identical one is skipped; a
   different one is shown as a diff, with *skip* as the default. Bootstrap never deletes a file you have.
3. **Step 3.5 — validate.** `bootstrap-validator` checks what was written: YAML and JSON parse, no placeholder is left
   over, workflow `needs:` references resolve. A BLOCK goes back to generation.
4. **Step 3.6 — stamp provenance markers** on the tracked templates, so a later run can tell a generated file that has
   drifted from one you changed on purpose.
5. **Step 4 — post-write actions.** Install the git hooks and run pre-commit until it is clean, apply branch protection
   through the GitHub API, create the `blocked` label, make the build-file edits a language needs (each confirmed),
   and smoke-test the Docker build.
6. **Steps 4d–4e — commit and open the PR.** The change is committed on a properly named branch, and the PR is opened
   by the Maintenance App with auto-merge armed. Bootstrap never opens the PR by hand: without the App it offers to
   install it, or stops.
7. **Step 4f — approve, when the Approver is wired.** Bootstrap waits for green CI, runs the Approver, and confirms the
   merge. Its first CI run is red until the secrets land; it re-triggers CI once they do.
8. **Step 4.5 — setup automation.** On macOS with Homebrew: create the Sonar project and its quality gate, set up
   Snyk, turn on GitHub's security features, and install the Claude Apps.
9. **Step 5 — the manual-setup checklist,** for everything that still needs a human, and one telemetry record.

## Who does what {#bootstrap-who-does-what}

| Actor | Does |
| --- | --- |
| You | Answer the questions, confirm the plan, decide each conflicting file, override a BLOCK if you choose to |
| `bootstrap` (conductor) | Detection, rendering, hooks, branch protection, setup automation |
| `bootstrap-security-reviewer`, `bootstrap-config-consistency`, `bootstrap-idempotency-reviewer` | Review the plan before anything is written |
| `bootstrap-validator` | Validate what was written |
| Maintenance App | Pushes the branch, authors the PR, arms auto-merge |
| Approver App | Approves the PR, when the approval model is `approver` |
