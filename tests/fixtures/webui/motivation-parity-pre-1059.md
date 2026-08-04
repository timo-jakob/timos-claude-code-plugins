3. **Maintenance language parity.** Python, Java, and Swift each have the
   full triage + worktree + autonomous-fix pipeline (Java via epic #296,
   Swift via epic #297). JavaScript / Angular, PowerShell, zsh, Go, and Rust
   are not yet implemented. This is intentional sequencing — Python was the
   proving ground for the dispatch contract; the other languages follow once
   each prior loop is solid. Tracked:
   [#170](https://github.com/timo-jakob/timos-claude-code-plugins/issues/170).
4. **macOS + Homebrew lock-in.** `/development:bootstrap`'s automation
