#!/usr/bin/env bats
#
# #2148: /development:maintenance keeps ONE named file per constructed v2
# payload. Phase 4 writes each language and topic payload to
# <payload-dir>/payload-<target>.json; the phase4-payload checkpoint, Phase 6
# (language and topic dispatch), Stage 0's re-dispatch and a --resume reload all
# read that file or its checkpoint copy. Before this, the checkpoint copied
# /tmp/payload-*.json, which no step ever wrote.
#
# SKILL.md is prose the model follows, so the wording is pinned section by
# section (anchored on headings, never line numbers), and the two Phase 4
# snippets are also EXECUTED to prove the directory and file they create.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  [ -f "$SKILL" ]
}

# The raw lines of the section headed exactly "$1", up to the next heading of the
# same or a higher level. Headings inside fenced code blocks (a `# 1. …` shell
# comment) do not end the section.
raw_section() {
  awk -v h="$1" '
    /^[[:space:]]*```/ { fence = !fence }
    !fence && /^#+ / {
      lvl = index($0, " ") - 1
      if (on && lvl <= level) exit
      if ($0 == h) { on = 1; level = lvl }
    }
    on { print }
  ' "$SKILL"
}

# The same section, whitespace-collapsed so a needle may span a line break.
section() {
  raw_section "$1" | tr -s '[:space:]' ' '
}

# The body of the fenced code block in section "$1" that contains "$2".
fence_with() {
  local raw
  raw="$(raw_section "$1")"
  awk -v n="$2" '
    /^[[:space:]]*```/ {
      if (inb) { if (index(buf, n)) { printf "%s", buf; exit } inb = 0; buf = ""; next }
      inb = 1; next
    }
    inb { sub(/^[[:space:]]+/, ""); buf = buf $0 "\n" }
  ' <<<"$raw"
}

H_RESUME='### Resume entry — pick up an interrupted run (#517)'
H_PHASE4='## Phase 4 — construct one payload per supported language'
H_KEEP='### Keep each payload in one file (#2148)'
H_PHASE5='## Phase 5 — `--dry-run`?'
H_PHASE6='## Phase 6 — dispatch per supported language to plan'
H_TOPIC='### Dispatch to topic plugins'
H_STAGE0='### Stage 0 — coverage improver (when present)'
H_DONE='### Run complete — clear the checkpoint (#517)'

@test "every anchored section exists and is non-empty (no needle below can pass vacuously)" {
  for h in "$H_RESUME" "$H_PHASE4" "$H_KEEP" "$H_PHASE5" "$H_PHASE6" "$H_TOPIC" "$H_STAGE0" "$H_DONE"; do
    [ "$(raw_section "$h" | wc -l)" -gt 2 ] || { echo "missing or empty section: $h"; return 1; }
  done
}

@test "SKILL.md names no phantom /tmp/payload- path anywhere" {
  run grep -n '/tmp/payload-' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "Phase 3 reloads findings files from the checkpoint store on resume, not /tmp" {
  s="$(section '## Phase 3 — gather findings per supported language')"
  contains "$s" 'On resume, re-read every findings file from `checkpoint.zsh dir`, not `/tmp`.'
}

@test "Phase 4 creates one per-run payload directory and one kept file per target, live and dry-run alike" {
  s="$(section "$H_PHASE4")"
  contains "$s" '( umask 077 && mktemp -d "${TMPDIR:-/tmp}/claude-maintenance-payloads.XXXXXXXX" )'
  contains "$s" 'substitute it as `<payload-dir>` in every later step'
  contains "$s" 'chmod 600 "<payload-dir>/payload-<target>.json"'
  contains "$s" 'language and topic alike'
  contains "$s" 'This happens on live and `--dry-run` runs alike.'
  contains "$s" 'Then write each payload with the Write tool to `<payload-dir>/payload-<target>.json`, where `<target>` is the language or topic name, and give it mode 600, as `write-payload.zsh` does for its hand-over temp:'
}

@test "Phase 4 states the payload directory's lifetime: Run complete, Phase 5 under --dry-run, else the OS" {
  s="$(section "$H_KEEP")"
  contains "$s" '`<payload-dir>` lives until the run ends: *Run complete — clear the checkpoint* removes it on a live run, and Phase 5 removes it under `--dry-run`.'
  contains "$s" 'After a crash, or an ending that never reaches *Run complete*, it is left in `$TMPDIR` for the OS to reap, as `write-payload.zsh` already does with its temp.'
}

@test "Phase 4's two snippets, executed, make a private directory and a mode-600 kept file" {
  mk="$(fence_with "$H_KEEP" 'claude-maintenance-payloads')"
  wr="$(fence_with "$H_KEEP" 'chmod 600')"
  [ -n "$mk" ]
  [ -n "$wr" ]

  run env TMPDIR="$BATS_TEST_TMPDIR" zsh -c "$mk"
  [ "$status" -eq 0 ]
  dir="$output"
  [ -d "$dir" ]
  case "$dir" in "$BATS_TEST_TMPDIR"/claude-maintenance-payloads.*) ;; *) echo "unexpected dir: $dir"; return 1 ;; esac
  [ "$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")" = "700" ]

  # The session writes the file with the Write tool and substitutes the
  # placeholders; do the same, then run the chmod.
  f="$dir/payload-claude-plugin.json"
  printf '%s\n' '{"schema_version":"2","language":"claude-plugin"}' > "$f"
  chmod 644 "$f"
  wr="${wr//<payload-dir>/$dir}"
  wr="${wr//<target>/claude-plugin}"
  run zsh -c "$wr"
  [ "$status" -eq 0 ]
  [ -f "$f" ]
  [ "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" = "600" ]
  [ "$(jq -r .language "$f")" = "claude-plugin" ]
}

@test "the phase4-payload checkpoint copies exactly the kept files, and is skipped under --dry-run" {
  s="$(section "$H_KEEP")"
  contains "$s" '**Checkpoint `phase4-payload`** (skip under `--dry-run`): copy exactly the kept files in `<payload-dir>` into the store'
  contains "$s" 'cp "<payload-dir>"/payload-*.json "$ckdir/"'
  contains "$s" 'save --phase phase4-payload --data -'
}

@test "Phase 5 prints from the kept files, then removes the payload directory" {
  raw="$(raw_section "$H_PHASE5")"
  s="$(tr -s '[:space:]' ' ' <<<"$raw")"
  contains "$s" 'If `--dry-run`: print each payload from its kept file (`jq . "<payload-dir>/payload-<target>.json"`) labeled by language **and topic**'
  contains "$s" 'nothing was copied into the checkpoint store'
  contains "$raw" 'rm -rf -- "<payload-dir>"'
  # The removal comes after the print, never before.
  print_at="$(grep -n 'jq . "<payload-dir>' <<<"$raw" | head -1 | cut -d: -f1)"
  rm_at="$(grep -n 'rm -rf -- "<payload-dir>"' <<<"$raw" | head -1 | cut -d: -f1)"
  [ -n "$print_at" ] && [ -n "$rm_at" ]
  [ "$rm_at" -gt "$print_at" ]
}

@test "Phase 6 language dispatch hands over from the kept file, or its checkpoint copy on resume" {
  s="$(section "$H_PHASE6")"
  contains "$s" '"<skill-base-dir>/scripts/write-payload.zsh" \ < "<payload-dir>/payload-<lang>.json"'
  contains "$s" 'prints the temp'"'"'s absolute path; substitute it as # <payload-file> in steps 2 and 3.'
  # Scoped to the language Skill() block: the section also holds the topic block's args=.
  contains "$(fence_with "$H_PHASE6" 'development-<lang>:maintenance')" 'args="<payload-file>"'
  contains "$s" 'On a run resumed past # phase4-payload, read the checkpoint copy in `checkpoint.zsh dir` instead.'
  contains "$s" 'delete the # hand-over temp — only it, never the kept file.'
  contains "$s" 'the kept file'"'"'s `tooling_configured`, `findings_by_tool` and `coverage` (and, for a topic, `notes`) must equal those fields of `findings-<target>.json`.'
  contains "$s" 'restore those fields in the kept file (on a run resumed past `phase4-payload`, its checkpoint copy) from `findings-<target>.json`, leave the rest as Phase 4 built it, and dispatch again.'
}

@test "Phase 6 topic dispatch hands over from the kept topic file too" {
  s="$(section "$H_TOPIC")"
  contains "$s" 'same file-handover (from the kept `<payload-dir>/payload-<topic>.json`, or its checkpoint copy on a run resumed past `phase4-payload`'
  contains "$s" 'the same `rm -f -- "<payload-file>"` of only the hand-over temp afterwards'
  contains "$s" 'args="<payload-file>"'
}

@test "Stage 0's re-dispatch hands over from the same kept file, or its checkpoint copy on resume" {
  s="$(section "$H_STAGE0")"
  contains "$s" '"<skill-base-dir>/scripts/write-payload.zsh" \ < "<payload-dir>/payload-<lang>.json"'
  contains "$s" 'or its checkpoint copy in `checkpoint.zsh dir` on a run resumed past `phase4-payload`), substituting the printed temp path as `<payload-file>`:'
  contains "$s" 'args="<payload-file>"'
  contains "$s" '# only the hand-over temp — never the kept file'
}

@test "no hand-over rebuilds a payload from the session variable or carries a path in one, and every rm -f there removes only the temp" {
  for h in "$H_PHASE6" "$H_STAGE0"; do
    raw="$(raw_section "$h")"
    run grep -F 'print -r -- "$payload_json"' <<<"$raw"
    [ "$status" -eq 1 ] || { echo "$h still pipes \$payload_json into the hand-over"; return 1; }
    run grep -F '$payload_file' <<<"$raw"
    [ "$status" -eq 1 ] || { echo "$h carries the temp path in a shell variable across steps"; return 1; }
    rms="$(grep -E '^[[:space:]]*rm ' <<<"$raw")"
    [ -n "$rms" ]
    run grep -vxE '[[:space:]]*rm -f -- "<payload-file>"' <<<"$rms"
    [ "$status" -eq 1 ] || { echo "$h has an rm other than the hand-over temp: $output"; return 1; }
  done
}

@test "the Resume entry reloads payloads from the checkpoint copies, never <payload-dir> or /tmp" {
  s="$(section "$H_RESUME")"
  contains "$s" 'A run resumed past `phase4-payload` reads its payloads from the `payload-<target>.json` copies in `checkpoint.zsh dir`, never from `<payload-dir>` or `/tmp`; it creates no `<payload-dir>` of its own.'
}

@test "Run complete removes the payload directory after the checkpoint clear, and nothing when none was created" {
  raw="$(raw_section "$H_DONE")"
  s="$(tr -s '[:space:]' ' ' <<<"$raw")"
  clear_at="$(grep -n 'checkpoint.zsh" clear' <<<"$raw" | head -1 | cut -d: -f1)"
  rm_at="$(grep -n 'rm -rf -- "<payload-dir>"' <<<"$raw" | head -1 | cut -d: -f1)"
  [ -n "$clear_at" ] && [ -n "$rm_at" ]
  [ "$rm_at" -gt "$clear_at" ]
  contains "$s" 'Remove `<payload-dir>` only when this session created one.'
  contains "$s" 'so it removes nothing here beyond the checkpoint.'
  contains "$s" 'clear after the Phase 9 emit instead, with the same payload-directory removal.'
  contains "$s" 'Phase 5 already removed its payload directory.'
}
