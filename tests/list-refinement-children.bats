#!/usr/bin/env bats
#
# Behavioral tests for list-refinement-children.zsh (#580, epic #573) — the
# enumerator epic-aware refine-issue uses to find an epic's children that still
# need refinement. The contract: parse the epic body's task-list children (not
# every #N mention), and keep the OPEN ones carrying `needs-refinement`, in body
# order. `gh` is shadowed via PATH with a fake keyed on issue number.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/list-refinement-children.zsh"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"

  # Epic #500 body: a task list (#601 open+needs-refinement, #602 open no-label,
  # #603 closed+needs-refinement, #604 open+needs-refinement) plus a NON-child
  # cross-reference (#999) in prose that must be ignored.
  cat > "$STUB/epic-body.txt" <<'EOF'
This epic tracks the work. See also #999 for context (not a child).

## Children
- [ ] #601 — first child
- [ ] #602 — second child
- [x] #603 — done child
- [ ] owner/repo#604 — fourth child

Some trailing prose mentioning #999 again.
EOF

  # Fake gh: `issue view <epic> --json body` returns the epic body; `issue view
  # <n> --json state,labels` returns per-child metadata from env-like cases.
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
# args: issue view <N> --repo <r> --json <fields> [-q .body]
num="\$3"
if printf '%s' "\$*" | grep -q -- '--json body'; then
  cat "$STUB/epic-body.txt"; exit 0
fi
case "\$num" in
  601) echo '{"state":"OPEN","labels":[{"name":"needs-refinement"},{"name":"feat"}]}' ;;
  602) echo '{"state":"OPEN","labels":[{"name":"feat"}]}' ;;
  603) echo '{"state":"CLOSED","labels":[{"name":"needs-refinement"}]}' ;;
  604) echo '{"state":"OPEN","labels":[{"name":"needs-refinement"}]}' ;;
  *)   echo '{"state":"OPEN","labels":[]}' ;;
esac
exit 0
EOF
  chmod +x "$STUB/gh"
}
run_list() { run env PATH="$STUB:$PATH" zsh "$S" "$@"; }

@test "lists only OPEN children carrying needs-refinement, in body order" {
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  # 601 (open+label) and 604 (open+label) qualify; 602 (no label), 603 (closed),
  # and the non-child #999 do not.
  [ "$output" = "$(printf '601\n604')" ]
}

@test "the non-child cross-reference (#999 in prose) is never included" {
  run_list --repo o/r --epic 500
  [[ "$output" != *"999"* ]]
}

@test "an epic with no refinable children prints nothing (clean exit 0 — terminal case)" {
  # rewrite the body so every listed child is a plain closed/no-label one
  cat > "$STUB/epic-body.txt" <<'EOF'
## Children
- [x] #602 — merged
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "closed children are excluded even when they carry needs-refinement" {
  cat > "$STUB/epic-body.txt" <<'EOF'
- [ ] #603 — closed but labelled
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "regression: an epic-labelled body with ZERO checklist lines is a clean exit 0 (no children)" {
  # prose-only body (children referenced only in prose / tracked elsewhere) —
  # must not abort under pipefail; the terminal case is a clean empty exit 0.
  cat > "$STUB/epic-body.txt" <<'EOF'
This epic is tracked on the project board.
See #601, #602, #604 for context.
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "regression: a checklist line inside a code fence is not parsed as a child" {
  cat > "$STUB/epic-body.txt" <<'EOF'
Here is how to write a task list:

```
- [ ] #601 example syntax
```

## Children
- [ ] #604 — real child
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  # only the real (unfenced) #604 qualifies; the fenced #601 is ignored
  [ "$output" = "604" ]
}

@test "regression: only the FIRST #N on a checklist line is taken (a trailing dep ref is ignored)" {
  cat > "$STUB/epic-body.txt" <<'EOF'
- [ ] #604 — the child, which depends on #999
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ "$output" = "604" ]        # 999 (a dependency ref) must not appear
  [[ "$output" != *"999"* ]]
}

@test "regression: asterisk and plus bullet task-list items are recognised" {
  cat > "$STUB/epic-body.txt" <<'EOF'
* [ ] #601 — asterisk bullet
+ [ ] #604 — plus bullet
EOF
  run_list --repo o/r --epic 500
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '601\n604')" ]
}

@test "regression: a failed epic-body fetch is the documented runtime error (exit 3)" {
  # a gh that fails the body fetch must surface exit 3, not a bare set -e abort
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q -- '--json body'; then echo "gh: 404" >&2; exit 1; fi
echo '{"state":"OPEN","labels":[]}'
EOF
  chmod +x "$STUB/gh"
  run_list --repo o/r --epic 500
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed to fetch epic"* ]]
}

@test "missing --repo is a usage error (exit 2)" {
  run_list --epic 500
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo is required"* ]]
}

@test "missing --epic is a usage error (exit 2)" {
  run_list --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"--epic is required"* ]]
}

@test "non-numeric --epic is a usage error (exit 2)" {
  run_list --repo o/r --epic abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be a number"* ]]
}

@test "a dangling --repo (no value) is a usage error (exit 2)" {
  run_list --epic 500 --repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo needs a value"* ]]
}

@test "unknown arg is a usage error (exit 2)" {
  run_list --repo o/r --epic 500 --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
