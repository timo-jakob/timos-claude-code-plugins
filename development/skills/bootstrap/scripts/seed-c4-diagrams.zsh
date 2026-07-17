#!/usr/bin/env zsh
# seed-c4-diagrams.zsh — bootstrap C4 seeding (epic #746 child (b), #791).
#
# Writes a repo's INITIAL C4 architecture diagrams — docs/architecture/
# c4-context.md (System Context) and c4-container.md (Container) — from the
# structural facts #799's detect-stack.sh already found, so a bootstrapped repo
# gets truthful diagrams unattended instead of a placeholder to fill in by hand.
# This is analysis OUTPUT, not a template: the pages are generated from the
# detection model, and carry NO provenance marker (generated content is
# unstampable, and a marker would make #793's content-policed drift check noisy).
#
# The Container diagram is emitted to conform to the c4/v1 declared-container
# shape (ARCHITECTURE.md, #790): each entry is
#   Container(<alias>, "<label>", "<technology>")
# one per line, quoted label/technology — so #790's extract-declared-containers.zsh
# parses the seeded page exactly, and #793's c4_drift can compare it. To keep
# that promise the emitter SANITIZES every interpolated field (a `"` or newline
# would break the quote-aware parse) and UNIQUIFIES aliases (a duplicate alias is
# a hard error for the parser).
#
# Container selection (mirrors #799's detection_confidence contract):
#   - containers present            → one Container entry per detected container.
#   - containers [] + "complete"    → the required minimum: ONE container named
#                                     from the project + its primary interface
#                                     (an honest "there is one deployable unit").
#   - containers [] + "inconclusive"→ seed NO fabricated container; the Container
#                                     diagram carries only the boundary + a note,
#                                     and the detection is reported. Never invent.
#
# Exit codes (plan-user-docs.zsh idiom):
#   0 — pages written under <out>/docs/architecture/.
#   1 — precondition absent (no --detect-json, or the path does not exist) — a
#       reported no-op.
#   2 — usage error.
#   3 — runtime error (bad/unreadable JSON, jq missing, cannot write output).
#
# Usage:
#   seed-c4-diagrams.zsh --project-name <name> --detect-json <detect-stack.json> \
#     --out <staging-dir>

emulate -L zsh
set -euo pipefail

local project_name="" detect_json="" out=""
while (( $# > 0 )); do
  case "$1" in
    --project-name)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -u2 -- "seed-c4-diagrams.zsh: --project-name needs a value"; exit 2; }
      project_name="$2"; shift 2 ;;
    --detect-json)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -u2 -- "seed-c4-diagrams.zsh: --detect-json needs a value"; exit 2; }
      detect_json="$2"; shift 2 ;;
    --out)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -u2 -- "seed-c4-diagrams.zsh: --out needs a value"; exit 2; }
      out="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: seed-c4-diagrams.zsh --project-name <name> --detect-json <file> --out <dir>"
      exit 0 ;;
    *) print -r -u2 -- "seed-c4-diagrams.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$project_name" && -n "$out" ]] || { print -r -u2 -- "seed-c4-diagrams.zsh: --project-name and --out are required"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "seed-c4-diagrams.zsh: jq not found on PATH"; exit 3; }
# Precondition (exit 1, reported no-op): no --detect-json, or the path is absent.
[[ -n "$detect_json" && -e "$detect_json" ]] || exit 1
# Present but unreadable / a directory is a RUNTIME error (exit 3), not a benign
# no-op — a consumer must never misread a broken input as "no diagram to seed".
[[ -f "$detect_json" && -r "$detect_json" ]] || { print -r -u2 -- "seed-c4-diagrams.zsh: cannot read $detect_json"; exit 3; }
jq -e . "$detect_json" >/dev/null 2>&1 || { print -r -u2 -- "seed-c4-diagrams.zsh: --detect-json is not valid JSON"; exit 3; }

# --- sanitize a free-text field for a Mermaid C4 quoted string --------------
# Mermaid C4 has no quote escape, and the c4/v1 parse is quote-aware ("[^"]*"),
# so a `"` or a newline in a project/container name would emit a line the
# extractor hard-rejects. Fold `"`→`'` and any control whitespace → a space.
c4_text() {
  local s="$1"
  s="${s//[$'\n\r\t']/ }"
  s="${s//\"/\'}"
  print -r -- "$s"
}

# --- derive an identifier alias from an arbitrary name ----------------------
# The alias must be [A-Za-z0-9_-]; #790's join folds case and -/_ , so we lower
# and map every other char to '_'. Non-empty guaranteed by a fallback.
c4_alias() {
  local raw="$1" a
  a="${(L)raw}"
  a="${a//[^a-z0-9_-]/_}"
  [[ -n "$a" ]] || a="app"
  print -r -- "$a"
}

project_name="$(c4_text "$project_name")"

# --- the repo's primary technology string, e.g. "Python 3.12" / "Java 21" ---
local -A LANG_LABEL=(
  python Python java Java swift Swift go Go
  typescript TypeScript javascript JavaScript rust Rust
)
technology_string() {
  local lang ver label
  lang="$(jq -r '.languages[0]? // empty' "$detect_json")"
  [[ -n "$lang" ]] || { print -r -- "Unspecified"; return; }
  label="${LANG_LABEL[$lang]:-$lang}"
  ver="$(jq -r --arg l "$lang" '((.language_meta // {})[$l] // {}).version // empty' "$detect_json")"
  if [[ -n "$ver" ]]; then print -r -- "$(c4_text "$label $ver")"; else print -r -- "$(c4_text "$label")"; fi
}

# --- a human interface descriptor for the container label -------------------
interface_descriptor() {
  local -a ifaces
  ifaces=("${(@f)$(jq -r '(.interfaces // []) | .[].interface? // empty' "$detect_json")}")
  local i
  for i in "${ifaces[@]}"; do
    case "$i" in
      cli) print -r -- "CLI"; return ;;
      rest) print -r -- "API"; return ;;
      web-ui) print -r -- "Web UI"; return ;;
    esac
  done
  print -r -- "Service"
}

# Shape gate: valid JSON of the WRONG type (a string .interfaces, a bare-string
# .containers, a non-object .language_meta) would make the per-field jq below
# error mid-run. Validate the shape ONCE, up front, and map any mismatch to the
# documented exit 3 (never jq's own exit 5). This also subsumes the "array of
# bare strings" case that would otherwise fabricate a bogus container.
jq -e '
  ((.containers // []) | type == "array") and
  ((.containers // []) | all(.[]?; type == "object")) and
  ((.interfaces // []) | type == "array") and
  ((.language_meta // {}) | type == "object")
' "$detect_json" >/dev/null 2>&1 \
  || { print -r -u2 -- "seed-c4-diagrams.zsh: --detect-json has an unexpected shape"; exit 3; }

# Precompute EVERYTHING here, at top level, where errexit is live — a jq failure
# aborts deterministically. The emit_* functions below are then pure `print`
# formatters over these variables (no jq, no failure-prone logic), so the
# `page="$(emit)" || exit 3` write guard cannot mask an extraction failure.
local tech iface_desc sys_alias confidence n_containers
tech="$(technology_string)"
iface_desc="$(interface_descriptor)"
confidence="$(jq -r '.detection_confidence // "complete"' "$detect_json")"
n_containers="$(jq '.containers // [] | length' "$detect_json")"

# The system alias, defended against colliding with the reserved Person id 'user'.
sys_alias="$(c4_alias "$project_name")"
[[ "$sys_alias" == "user" ]] && sys_alias="user_system"

# Build the container-entry lines. Mermaid ids share ONE namespace per diagram,
# so the uniquifier is pre-seeded with the reserved ids (Person `user`, the
# boundary) — a detected container named "user" is then renamed, not collided.
local -a container_lines
local -A seen_alias
seen_alias[user]=1
seen_alias[${sys_alias}_boundary]=1
local primary_alias=""
if (( n_containers > 0 )); then
  local i name alias base label k
  for (( i = 0; i < n_containers; i++ )); do
    name="$(jq -r --argjson i "$i" '.containers[$i].name? // empty' "$detect_json")"
    [[ -n "$name" ]] || continue   # a name-less container is not a real declared unit
    alias="$(c4_alias "$name")"
    if [[ -n "${seen_alias[$alias]:-}" ]]; then
      base="$alias"; k=2
      while [[ -n "${seen_alias[${base}_${k}]:-}" ]]; do (( k++ )); done
      alias="${base}_${k}"
    fi
    seen_alias[$alias]=1
    if (( n_containers == 1 )); then
      label="$(c4_text "$project_name $iface_desc")"
    else
      label="$(c4_text "${(C)name}")"
    fi
    container_lines+=("        Container($alias, \"$label\", \"$tech\")")
    [[ -n "$primary_alias" ]] || primary_alias="$alias"
  done
fi
if [[ -z "$primary_alias" ]]; then
  if [[ "$confidence" == "inconclusive" ]]; then
    # Detection could not resolve a named image — seed NO fabricated container.
    container_lines+=("        %% Container detection was inconclusive — no container is asserted here.")
    container_lines+=("        %% Add the deployable unit(s) by hand once known (see the adopt how-to).")
  else
    # complete + no detected container → the honest single deployable unit.
    container_lines+=("        Container($sys_alias, \"$(c4_text "$project_name $iface_desc")\", \"$tech\")")
    primary_alias="$sys_alias"
  fi
fi

mkdir -p "$out/docs/architecture" || { print -r -u2 -- "seed-c4-diagrams.zsh: cannot create $out/docs/architecture"; exit 3; }

# --- pure formatters over the precomputed variables -------------------------
emit_context() {
  print -r -- "# System Context"
  print -r --
  print -r -- "The system context for **$project_name** — who uses it and the systems it"
  print -r -- "talks to. Refine the actors and external systems as the architecture settles."
  print -r --
  print -r -- '```mermaid'
  print -r -- "C4Context"
  print -r -- "    title System Context diagram for $project_name"
  print -r --
  print -r -- "    Person(user, \"User\", \"Uses $project_name\")"
  print -r -- "    System($sys_alias, \"$project_name\", \"$iface_desc — $tech\")"
  print -r --
  print -r -- "    Rel(user, $sys_alias, \"Uses\")"
  print -r -- '```'
}
emit_container() {
  print -r -- "# Container Diagram"
  print -r --
  print -r -- "The deployable units that make up **$project_name**, seeded from detected"
  print -r -- "structure. Each \`Container(...)\` entry follows the c4/v1 declared-container"
  print -r -- "shape (see ARCHITECTURE.md) so the maintenance pipeline can compare it against"
  print -r -- "the code. Refine labels, technologies, and relationships as needed."
  print -r --
  print -r -- '```mermaid'
  print -r -- "C4Container"
  print -r -- "    title Container diagram for $project_name"
  print -r --
  print -r -- "    Person(user, \"User\", \"Uses $project_name\")"
  print -r --
  print -r -- "    Container_Boundary(${sys_alias}_boundary, \"$project_name\") {"
  local l
  for l in "${container_lines[@]}"; do print -r -- "$l"; done
  print -r -- "    }"
  print -r --
  # Relate the user to the primary container (skipped when none was seeded, so
  # the Rel never dangles against an undefined alias).
  [[ -n "$primary_alias" ]] && print -r -- "    Rel(user, ${primary_alias}, \"Uses\")"
  print -r -- '```'
}

# Generate then write, each with its own guarded status (generation is a pure
# formatter, so a non-zero here is a genuine write failure → exit 3).
local ctx_page cont_page
ctx_page="$(emit_context)" || { print -r -u2 -- "seed-c4-diagrams.zsh: failed to render c4-context.md"; exit 3; }
cont_page="$(emit_container)" || { print -r -u2 -- "seed-c4-diagrams.zsh: failed to render c4-container.md"; exit 3; }
print -r -- "$ctx_page" > "$out/docs/architecture/c4-context.md" \
  || { print -r -u2 -- "seed-c4-diagrams.zsh: cannot write c4-context.md under $out"; exit 3; }
print -r -- "$cont_page" > "$out/docs/architecture/c4-container.md" \
  || { print -r -u2 -- "seed-c4-diagrams.zsh: cannot write c4-container.md under $out"; exit 3; }

exit 0
