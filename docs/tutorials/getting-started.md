# Getting started: bootstrap and maintain a project

This tutorial walks through the core loop these plugins are built around: stand
up a project's quality + security toolchain, then let the maintenance pipeline
fix what it safely can.

> **Prerequisites:** macOS + Homebrew, and the `gh` CLI authenticated
> (`gh auth login`). See [Requirements](../reference/requirements.md) for the
> full list.

## 1. Load the plugins

During development, load the plugins from a local checkout:

```sh
claude --plugin-dir ./development --plugin-dir ./development-python
```

Add `--plugin-dir ./development-swift`, `./development-java`, etc. for the
languages your project uses. See
[Install and use the plugins](../how-to/install-and-use-plugins.md) for details.

## 2. Bootstrap the toolchain

From inside your project, run:

```bash
/development:bootstrap
```

Bootstrap detects repo visibility, languages, and Docker presence, then installs
the full **Zero Tolerance** toolchain in one run — linters, security scanners,
the 90% new-code coverage floor, branch protection, pre-commit hooks, and
issue/PR templates. It's idempotent, so it's safe to re-run on a
partially-configured repo. (Optionally add `--claude-approver true` to wire in
the [Claude Approver](../explanation/claude-approver.md) — see
[Adopt the Approver](../how-to/adopt-the-approver.md).)

## 3. Let maintenance fix what it can

```bash
/development:maintenance
```

The orchestrator runs detection + findings-gathering + coverage measurement,
builds a JSON payload, and dispatches to the matching language plugin (and any
topic plugins). Each per-tool agent fixes what it safely can in an isolated
worktree — running your test suite locally before declaring success — and only
escalates to you when human judgment is genuinely required. Use `--dry-run` to
see the payload without dispatching.

## 4. Turn an issue into a merge-ready PR

```bash
/development:resolve-issue <issue#>
```

This gates the story for readiness, branches off fresh `main`, implements,
validates (tests must be green), runs a local review loop, and opens a
bot-authored PR with auto-merge armed. Point it at an epic and it drives every
child. See the [Plugin & command inventory](../reference/plugins.md) for the
full command surface.

## Where to go next

- [Motivation & current gaps](../explanation/motivation.md) — the why, and
  where the implementation still falls short.
- [Why per-language plugins?](../explanation/why-per-language-plugins.md)
- [Plugin & command inventory](../reference/plugins.md)
