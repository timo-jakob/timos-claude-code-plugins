# Install and use the plugins

## Load plugins locally during development

```sh
claude --plugin-dir ./development --plugin-dir ./development-swift --plugin-dir ./development-python
```

Then use the slash commands:

```bash
# Development workflow
/development:commit              # format, lint, generate message, commit
/development:commit "Fix auth"   # format, lint, commit with given message

# Swift code review
/development-swift:review                # review all Swift files
/development-swift:review Sources/       # review a specific directory
```

For the full list of commands and agents, see the
[Plugin & command inventory](../reference/plugins.md). For platform and tooling
prerequisites, see [Requirements](../reference/requirements.md).
