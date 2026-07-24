#!/usr/bin/env bats
#
# Structural tests for the per-language canonical ops-api payloads (#688 Python,
# #935 Java).
#
# These payloads are bootstrap template files the SKILL's render.zsh steps copy
# verbatim into a target service; their RUNTIME conformance is verified downstream
# by the ops-conformance CI job, not here (the test toolchain has no JVM/Python
# service to run, and runs offline). What is cheap and worth guarding here is that
# the files the SKILL render blocks name still exist and keep their contract shape,
# so an accidental move/rename/gutting fails in this repo rather than silently
# breaking a downstream bootstrap. Grep-based and offline, like ops-api-fragment.bats.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LANGS="$REPO_ROOT/development/skills/bootstrap/templates/languages"
  PY="$LANGS/python/ops-api"
  JAVA="$LANGS/java/ops-api"
}

# ---- Python payload (#688) -------------------------------------------------

@test "python ops-api payload files exist at the SKILL render paths" {
  [ -f "$PY/ops_api.py" ]
  [ -f "$PY/requirements.txt" ]
  [ -f "$PY/README.md" ]
}

@test "python ops_api.py registers all five ops endpoints" {
  grep -q '"/info"' "$PY/ops_api.py"
  grep -q '"/health/live"' "$PY/ops_api.py"
  grep -q '"/health/ready"' "$PY/ops_api.py"
  grep -q '"/health"' "$PY/ops_api.py"
  grep -q '"/metrics"' "$PY/ops_api.py"
}

@test "python requirements.txt declares the OTel SDK + Prometheus exporter deps" {
  grep -q 'opentelemetry-sdk' "$PY/requirements.txt"
  grep -q 'opentelemetry-exporter-prometheus' "$PY/requirements.txt"
  grep -q 'prometheus-client' "$PY/requirements.txt"
}

# ---- Java payload (#935) ---------------------------------------------------

@test "java ops-api payload files exist at the SKILL render paths" {
  [ -f "$JAVA/OpsApi.java" ]
  [ -f "$JAVA/build.gradle.kts" ]
  [ -f "$JAVA/README.md" ]
}

@test "java OpsApi keeps the flagged placeholder package (must be re-set on placement)" {
  grep -q '^package com.example.ops;' "$JAVA/OpsApi.java"
}

@test "java OpsApi registers all five ops endpoints" {
  grep -q 'createContext("/info"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health/live"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health/ready"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/metrics"' "$JAVA/OpsApi.java"
}

@test "java OpsApi enforces both halves of the lifecycle-sunset invariant (RFC 8594)" {
  # deprecated MUST carry a sunset, and active MUST NOT — guard both directions.
  grep -q 'needs a sunset date (RFC 8594)' "$JAVA/OpsApi.java"
  grep -q 'must not carry a sunset date' "$JAVA/OpsApi.java"
}

@test "java build.gradle.kts pins the coherent OTel BOMs and declares the three deps" {
  # The version-less deps resolve only via these two BOM pins — guard them too.
  grep -q 'platform("io.opentelemetry:opentelemetry-bom:' "$JAVA/build.gradle.kts"
  grep -q 'platform("io.opentelemetry:opentelemetry-bom-alpha:' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-sdk' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-exporter-otlp' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-exporter-prometheus' "$JAVA/build.gradle.kts"
}
