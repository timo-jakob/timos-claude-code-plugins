// Canonical Java ops-api dependencies (#935). NOT a standalone build file -- FOLD
// this dependencies block into your service's own build.gradle.kts (Gradle
// Kotlin DSL, the org standard). OpenTelemetry-only instrumentation: the OTel SDK
// is the single metrics source; the Prometheus exporter serves the /metrics
// pull-compat surface, and the OTLP exporter is the primary push pipeline (wired
// in OpsApi when OTEL_EXPORTER_OTLP_ENDPOINT is set).
//
// The two BOMs pin one coherent OpenTelemetry release across every artifact: the
// stable BOM for the SDK + OTLP exporter, the -alpha BOM for the Prometheus
// exporter (still an unstable artifact upstream). Renovate/Dependabot keep both
// versions current in your repo -- bump them together (same base version).
dependencies {
    implementation(platform("io.opentelemetry:opentelemetry-bom:1.49.0"))
    implementation(platform("io.opentelemetry:opentelemetry-bom-alpha:1.49.0-alpha"))

    implementation("io.opentelemetry:opentelemetry-sdk")
    implementation("io.opentelemetry:opentelemetry-exporter-otlp")
    implementation("io.opentelemetry:opentelemetry-exporter-prometheus")
}
