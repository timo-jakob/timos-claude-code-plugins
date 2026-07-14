# Why per-language plugins?

An experienced developer looking at the [plugin list](../reference/plugins.md)
asked the obvious question: *"Why are there separate plugins per programming
language at all? Claude already knows how to program each of them."* That
premise is true — and it misses what these plugins actually encode. They don't
teach Claude Python, Java, or Swift. They encode five things a generic "Claude,
fix my project" prompt cannot carry:

1. **My experience and my favorites — accumulated over many years.** This is
   the headline reason. These plugins are opinionated because *I* am: they
   bake in the tools, policies, and defaults I've converged on across years of
   building and maintaining software. Claude knowing Java doesn't tell it that
   here Gradle with the Kotlin DSL is the only build system (Maven is
   rejected, Groovy DSL must be converted), that Spring Boot 4+ is the
   minimum, that gRPC is for internal service-to-service calls while public
   endpoints are REST/OpenAPI contract-first, that async messaging defaults
   to ActiveMQ Artemis (Kafka only at genuine scale), that every linter is
   set to 120 columns, or that new shell scripts are zsh. Each of those is a
   decision, not knowledge — one blessed path with one good default, because
   every extra option is a permanent maintenance and expertise cost. The
   per-language plugin is where those decisions live.

2. **Tool semantics, not just tool names.** Running JaCoCo vs `coverage.py`
   vs `xccov` is a one-line script difference; *interpreting* their output is
   not. JaCoCo reports per-class with method regions, `coverage.py`
   per-module, and Swift coverage needs symbol demangling before it means
   anything (see
   [`demangle-swift-regions.py`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/maintenance/scripts/demangle-swift-regions.py)).
   The same holds for upgrades: a JDK bump (Gradle toolchains, Temurin
   images, migration-guide-licensed code adaptations) and a Python
   interpreter bump (`requires-python`, whatsnew documents, removed stdlib
   modules) share the outer loop but diverge in failure modes, evidence
   sources, and escalation rules. That judgment layer is what the per-language
   agents carry.

3. **Everything mechanical is *already* language-parameterized scripts.**
   The suggestion "put the formatters, linters, and coverage tools in shared
   scripts with the language as a parameter" is not a missed alternative —
   it's the shipped design. The orchestrator's script layer
   ([`development/skills/maintenance/scripts/`](https://github.com/timo-jakob/timos-claude-code-plugins/tree/main/development/skills/maintenance/scripts))
   is mostly language-agnostic (`merge-pr-cycle.zsh`, `await-pr-checks.zsh`,
   `gather-sonarcloud.zsh`, …) with thin per-language
   `gather-<lang>-findings` / `parse-<lang>-coverage` adapters. The plugins
   hold only what genuinely needs per-language judgment and policy; the rest
   was factored into scripts long ago.

4. **Context economy.** Installed plugins load their agent descriptions and
   skill triggers into every Claude Code session. Per-language plugins mean a
   Swift project pays only for Swift context. One monolithic
   "development-everything" plugin — even with perfectly parameterized
   scripts underneath — would push the Java, Python, Spring, and Swift agent
   rosters into every session on every project. In a context-window-
   constrained system, install-what-you-use is an architectural feature, not
   packaging trivia.

5. **Composition.** Topic plugins dispatch *alongside* the language plugin,
   not instead of it: `development-spring` only activates when both Java and
   Spring markers are present, and `development-claude-plugin` layers over
   whatever language the repo uses. The orchestrator → language plugin →
   topic plugin layering works because plugins are the unit of packaging and
   dispatch; a `--language` flag on a monolith cannot express "when both
   markers are present, also run the Spring advisors."

The one valid kernel in the critique: the *prose* of some parallel agents
(the per-language ci-fixers, coverage-improvers, review dimensions) is
substantially duplicated across languages and can drift. That's an
authoring-time problem, not an architecture problem — tracked in
[#619](https://github.com/timo-jakob/timos-claude-code-plugins/issues/619)
(single-source the near-twin agents via shared-core generation), which changes
how those agents are *written* while keeping the per-language plugins exactly
as they are.
