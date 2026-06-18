#!/usr/bin/env zsh
setopt err_exit nounset pipefail

# gather-spring-findings.zsh — findings gather for the `development-spring`
# TOPIC plugin. Emits the same v2 gather contract as the language gathers
# (tooling_configured / findings_by_tool / coverage / notes), so the
# orchestrator constructs a payload and dispatches identically.
#
# development-spring COMPOSES alongside development-java (#296 decision #1): it
# only dispatches when BOTH Java and Spring markers are present. This gather is
# invoked by the orchestrator after it confirms the Spring topic marker (an
# `org.springframework.boot` Gradle plugin or a `spring-boot-starter-*`
# dependency). Topics aren't code with tests, so `coverage` is always null.
#
# Tools so far:
#   - spring_config        : config audit -> spring-config-advisor
#   - spring_boot_upgrade  : open Dependabot/Snyk org.springframework.boot
#                            major/minor bump PRs -> spring-boot-upgrade
#                            (development-java DEFERS Boot bumps to here).
#   - spring_container     : bootBuildImage (Cloud Native Buildpacks) config
#                            audit -> spring-container-advisor (JVM mode;
#                            native-image deferred).
#
# `spring_config` discovers the
# project's Spring configuration files (application.yml/.yaml/.properties +
# profile variants) and emits one `config-audit` finding per file. The
# spring-config-advisor agent then READS each file (YAML-aware, which a grep
# can't be) and triages + fixes: deprecated/relocated Spring Boot 4 property
# keys, actuator endpoint over-exposure (`exposure.include: "*"`), and a few
# best-practice gaps. Discovery lives here; the YAML-aware judgement lives in
# the agent. (These projects target Spring Boot 4+ — the baseline is Spring
# Framework 7 / Jakarta EE 11, so there is no javax->jakarta migration; older
# Spring Boot lines are out of scope.) Future slices add a Spring Boot
# version-upgrade agent (config relocations + removed-API fixes per the Boot
# migration guide), bootBuildImage container generation, and the contract-first
# API drift gate.
#
# Usage: gather-spring-findings.zsh <repo_path>
# Output: JSON on stdout.

emulate -L zsh

local repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { print -u2 -- "usage: $0 <repo_path>"; exit 2 }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq required, not on PATH."; exit 2 }
cd "$repo"

local -a notes=()

# --- locate Spring config files ---------------------------------------------
# Conventional locations: src/main/resources/application{,-<profile>}.{yml,yaml,properties}.
local -a config_files
config_files=("${(@f)$(find . \
  -path '*/build/*' -prune -o \
  -path '*/.git/*' -prune -o \
  \( -name 'application.yml' -o -name 'application.yaml' \
     -o -name 'application.properties' -o -name 'application-*.yml' \
     -o -name 'application-*.yaml' -o -name 'application-*.properties' \) \
  -print 2>/dev/null)}")

# --- tooling_configured ------------------------------------------------------
# spring_config is "configured" when at least one Spring config file exists —
# that is the surface this tool polices.
local has_spring_config="false"
[[ ${#config_files[@]} -gt 0 && -n "${config_files[1]}" ]] && has_spring_config="true"

# --- findings: spring_config (one config-audit finding per config file) ------
local findings="[]"
if [[ "$has_spring_config" == "true" ]]; then
  local f
  local -a finding_objs=()

  for f in "${config_files[@]}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    finding_objs+=("$(jq -n --arg c "${f#./}" \
      '{type:"config", severity:"MINOR", rule:"spring:config-audit",
        component:$c, line:0,
        message:("Audit Spring configuration `" + $c + "` for deprecated/relocated Spring Boot 4 property keys, actuator endpoint over-exposure, and best-practice gaps."),
        key:("spring_config:audit:" + $c)}')")
  done

  if [[ ${#finding_objs[@]} -gt 0 ]]; then
    findings="$(printf '%s\n' "${finding_objs[@]}" | jq -s '.')"
  fi
else
  notes+=("spring_config: no Spring configuration files (application.yml/.yaml/.properties) found under the project; nothing to audit.")
fi

# --- spring_boot_upgrade: open vendor PRs bumping org.springframework.boot ----
# Reactive trigger. development-spring OWNS Spring Boot version bumps (the
# config-property relocations + removed-API fixes a generic dep bump can't do);
# development-java's planner DEFERS org.springframework.boot bumps here. We list
# open Dependabot/Snyk PRs that bump org.springframework.boot to a new MAJOR or
# MINOR (where the Boot configuration changelog matters). In practice patch +
# minor gradle bumps are grouped (so only standalone majors surface here);
# patch bumps stay with development-java's normal vendor-PR triage.
# The tool is "configured" for any Spring repo; findings are [] when gh can't
# list PRs.
local has_boot_upgrade="true"
local boot_findings="[]"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  local raw
  raw="$( { gh pr list --author "app/dependabot" --state open \
              --json number,title,headRefName 2>/dev/null || print -- '[]'
            gh pr list --state open --search "head:snyk-" \
              --json number,title,headRefName 2>/dev/null || print -- '[]'
          } | jq -s 'add // []' )"
  boot_findings="$(print -r -- "$raw" | jq '
    [ .[]
      | select(.title | test("org\\.springframework\\.boot"))
      | (.title | capture("from (?<from>[0-9]+(\\.[0-9]+)+) to (?<to>[0-9]+(\\.[0-9]+)+)")) as $v
      | select($v != null)
      | { from: $v.from, to: $v.to,
          fmaj: ($v.from | split(".")[0] | tonumber),
          tmaj: ($v.to   | split(".")[0] | tonumber),
          fmin: (($v.from | split(".")[1]) // "0" | tonumber),
          tmin: (($v.to   | split(".")[1]) // "0" | tonumber),
          number, title, headRefName }
      | select(.tmaj > .fmaj or (.tmaj == .fmaj and .tmin > .fmin))
      | { type:"dependency", severity:"MAJOR", rule:"spring:boot-upgrade",
          package:"org.springframework.boot",
          from_version:.from, to_version:.to,
          pr_number:.number, title:.title, headRefName:.headRefName,
          source:(if (.headRefName|startswith("snyk-")) then "snyk_prs" else "dependabot" end),
          message:("Spring Boot " + .from + " -> " + .to + " (PR #" + (.number|tostring) + ") — apply the Boot migration (config relocations + removed-API fixes)."),
          key:("spring_boot_upgrade:" + (.number|tostring)) } ]')"
else
  notes+=("spring_boot_upgrade: gh not available/authenticated; can't list open Spring Boot bump PRs.")
fi

# --- spring_container: bootBuildImage config audit ---------------------------
# Spring Boot's Gradle plugin provides bootBuildImage (an OCI image via Cloud
# Native / Paketo Buildpacks, no Dockerfile). Emit one container-audit finding
# per root build file; the advisor reads it (Groovy/Kotlin DSL aware) and
# recommends a pinned builder/run-image + explicit image name + publish config.
local has_spring_container="false"
local container_findings="[]"
local -a build_files
build_files=("${(@f)$(find . -maxdepth 2 \
  -path '*/build/*' -prune -o -path '*/.git/*' -prune -o \
  \( -name 'build.gradle' -o -name 'build.gradle.kts' \) -print 2>/dev/null)}")
if [[ -n "${build_files[1]}" ]]; then
  has_spring_container="true"
  local bf
  local -a container_objs=()
  for bf in "${build_files[@]}"; do
    [[ -n "$bf" && -f "$bf" ]] || continue
    container_objs+=("$(jq -n --arg c "${bf#./}" \
      '{type:"config", severity:"MINOR", rule:"spring:container-audit",
        component:$c, line:0,
        message:("Audit the bootBuildImage (Cloud Native Buildpacks) configuration in `" + $c + "` — pin the builder/run-image, set an explicit image name, and configure publish for reproducible, CVE-patchable OCI images (JVM mode; native-image deferred)."),
        key:("spring_container:audit:" + $c)}')")
  done
  [[ ${#container_objs[@]} -gt 0 ]] && container_findings="$(printf '%s\n' "${container_objs[@]}" | jq -s '.')"
fi

# --- emit --------------------------------------------------------------------
local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.' 2>/dev/null || print -- '[]')"
[[ ${#notes[@]} -eq 0 ]] && notes_json='[]'

jq -n \
  --argjson spring_config_cfg "$has_spring_config" \
  --argjson spring_config_findings "$findings" \
  --argjson boot_upgrade_cfg "$has_boot_upgrade" \
  --argjson boot_upgrade_findings "$boot_findings" \
  --argjson container_cfg "$has_spring_container" \
  --argjson container_findings "$container_findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: {
    spring_config:        $spring_config_cfg,
    spring_boot_upgrade:  $boot_upgrade_cfg,
    spring_container:     $container_cfg
  },
  findings_by_tool: (
    {}
    + (if $spring_config_cfg then {spring_config: $spring_config_findings} else {} end)
    + (if $boot_upgrade_cfg  then {spring_boot_upgrade: $boot_upgrade_findings} else {} end)
    + (if $container_cfg     then {spring_container: $container_findings} else {} end)
  ),
  coverage: null,
  notes: $notes
}
'
