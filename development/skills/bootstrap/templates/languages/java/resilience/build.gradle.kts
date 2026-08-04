// Canonical NON-Spring Java resilience dependencies (#1142, epic #964). NOT a
// standalone build file -- FOLD this dependencies block into your service's own
// build.gradle.kts (Gradle Kotlin DSL, the org standard).
//
// resilience4j is THE blessed circuit-breaker library for Java in this family --
// the same one the Spring payload blesses, so the two realizations differ only in
// how the breaker is applied, never in what a breaker means. It gives a named
// CircuitBreaker per dependency in a registry you can read, which is exactly the
// unit the ops-api /health `components` map reports.
//
// VERSION PINNING -- through resilience4j-bom, which is the OPPOSITE of what the
// Spring payload does, for a reason worth stating so neither looks like a
// mistake. The BOM manages every module a plain-Java service needs
// (resilience4j-core, -circuitbreaker, -retry among them); what it does NOT
// manage is the Boot 4 starter (it still lists only `resilience4j-spring-boot3`),
// which is why the Spring payload pins that one artifact directly. Here the BOM
// is the right tool: one version line governs the whole set.
//
// TWO bots keep this current, in two different places. In the plugin repo that
// SHIPS this template, Renovate's gradle manager reads the pin straight out of
// this fragment (it needs no surrounding Gradle project) and bumps it, so a
// freshly bootstrapped repo starts on a current version. Once you have folded
// the block into your own build, the copy in YOUR repo is yours -- your own
// Renovate or Dependabot keeps it moving; an upstream bump never reaches you
// retroactively.
//
// TWO MODULES, NOT `resilience4j-all`. The aggregate artifact also drags in
// ratelimiter, bulkhead, cache and micrometer -- and its `Decorators` builder,
// the only thing it adds that we would use, buys nothing here: the six mandates
// compose from the two static `decorateSupplier` helpers in one readable
// expression (see DependencyCatalog.call), where the nesting order is visible
// rather than implied by a fluent chain. Fewer transitive artifacts on a service
// classpath is worth more than the builder.
//
// NO AOP MODULE, and no annotations. @CircuitBreaker / @Retry are Spring AOP
// aspects: outside Spring there is nothing to weave them, and -- unlike the
// Spring payload, where a missing spring-boot-starter-aop leaves them silently
// inert -- here they would not even compile without resilience4j-annotations.
// This payload therefore decorates PROGRAMMATICALLY, which is the supported
// non-Spring usage and makes the aspect order explicit instead of configured.
dependencies {
    implementation(platform("io.github.resilience4j:resilience4j-bom:2.4.0"))

    implementation("io.github.resilience4j:resilience4j-circuitbreaker")
    implementation("io.github.resilience4j:resilience4j-retry")
}
