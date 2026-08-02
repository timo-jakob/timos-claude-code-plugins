// Canonical Spring Boot resilience + dependency-health dependencies (#1141, epic
// #964). NOT a standalone build file -- FOLD this dependencies block into your
// service's own build.gradle.kts (Gradle Kotlin DSL, the org standard).
//
// resilience4j is THE blessed circuit-breaker library for Spring Boot in this
// family. One library, no options: it gives a named CircuitBreaker per dependency
// in a registry you can read, which is exactly the unit the ops-api /health
// `components` map reports. Spring Cloud Circuit Breaker is deliberately NOT used
// -- its CircuitBreakerFactory abstraction exists to make the breaker library
// swappable, and hides the registry that the /health binding needs to read.
//
// VERSION PINNING -- resilience4j-spring-boot4 is pinned DIRECTLY rather than
// through resilience4j-bom. The BOM (2.4.0) still lists only the Boot 3 starter
// (`resilience4j-spring-boot3`); the Boot 4 module is published but not yet
// managed by it, so importing the BOM would leave this artifact unmanaged anyway
// while implying otherwise.
//
// TWO bots keep this current, in two different places. In the plugin repo that
// SHIPS this template, Renovate's gradle manager reads the pin straight out of
// this fragment (it needs no surrounding Gradle project) and bumps it, so a
// freshly bootstrapped repo starts on a current version. Once you have folded
// the block into your own build, the copy in YOUR repo is yours -- your own
// Renovate or Dependabot keeps it moving; an upstream bump never reaches you
// retroactively.
//
// The starter transitively brings resilience4j-spring6 -> framework-common ->
// circuitbreaker + retry + timelimiter + bulkhead + micrometer, so the four
// mandates that need library support are all on the classpath from this one line.
//
// spring-boot-starter-aop is REQUIRED, not optional: the @CircuitBreaker, @Retry
// and @TimeLimiter annotations are implemented as Spring AOP aspects, and without
// it they are silently inert -- the calls run unprotected and nothing warns you.
dependencies {
    implementation("io.github.resilience4j:resilience4j-spring-boot4:2.4.0")
    implementation("org.springframework.boot:spring-boot-starter-aop")

    // The ops surface: Actuator supplies /info and the application availability
    // state the readiness answer is built on. The ops-api /health, /health/live
    // and /health/ready are served by OpsHealthEndpoint instead (see README.md
    // -- Actuator's health JSON cannot express the ops-api `components` shape).
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-web")

    // NOT optional for ops-api conformance. spring-boot-starter-actuator does NOT
    // bring a Prometheus registry, and Boot only auto-configures the `prometheus`
    // endpoint when io.micrometer.prometheusmetrics.PrometheusMeterRegistry is on
    // the classpath. Without this line the `prometheus` entry in
    // application-resilience.yml's exposure list and its `prometheus: metrics`
    // path-mapping name an endpoint that does not exist, /metrics answers 404, and
    // check-ops-conformance.zsh fails -- after the bootstrap, in the adopter's CI.
    // Micrometer maps to OTel semantic conventions, so this stays consistent with
    // the OTel-only instrumentation policy. Version comes from the Spring Boot BOM.
    implementation("io.micrometer:micrometer-registry-prometheus")
}
