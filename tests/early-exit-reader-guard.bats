#!/usr/bin/env bats
#
# #1797 — no bats test pipes a producer into an early-exit reader where the
# race that sets up can fail the test.
#
# THE RACE. `producer | grep -q x` ends the moment grep sees its first match,
# which can be before the producer has finished writing. The producer's next
# write then meets a closed pipe. Bats runs every test with SIGPIPE ignored,
# inherited from its parent, so the producer does not die quietly: it gets
# EPIPE and prints `write error: Broken pipe` on stderr. Inside `run` that text
# lands in `$output`, and under `set -o pipefail` the producer's non-zero exit
# fails the pipeline. Load decides who wins, so the test reds on trees it has
# nothing to do with (#1492's artifact sweep did, in #1796's flake hunt).
#
# THE RULE. Every tracked `tests/*.bats` and `tests/*.bash` file is swept —
# `git ls-files`, never a closed list, whose pathspecs match at any depth under
# `tests/` (`tests/acceptance/**` included), and the count is pinned below so
# adding a suite is a visible edit here. A line is FLAGGED when a producer is
# piped (`|` or `|&`) into an early-exit reader and the line is at least one of:
#
#   1. inside a shell function body, whose callers may capture its stderr;
#   2. on a line that also holds a bats `run`, which captures the stderr;
#   3. anywhere in a file whose own shell code executes `set -o pipefail` /
#      `set -euo pipefail` — at top level or in any function or `@test` body,
#      `setup()` included.
#
# A `set -o pipefail` inside a quoted string — a `bash -c "…"` body — is that
# string's shell code, not the file's, so it never makes its file a pipefail
# file. It does make the string one: a pipe into an early-exit reader inside a
# quoted body that itself sets pipefail is flagged wherever the line sits,
# because that body's status is then the producer's EPIPE.
#
# A pipeline in a `@test` body, not on a `run` line, in a file without
# pipefail and outside such a string, is NOT flagged: its stderr goes to bats'
# log and its status is the reader's, so it cannot fail the test. One logical
# line is a physical line together with its continuations — a trailing `\`
# outside a comment, a trailing bare `|`, or a quoted string still open at the
# line's end — and the shell reads each of those as one command just the same.
# Heredoc bodies are data, not the file's shell code, and are never scanned.
# Quoted strings ARE scanned, since a `bash -c "…"` body is shell code one
# level down.
#
# THE CLOSED READER SET:
#   - `grep` with a single-dash flag cluster containing `q`, or with
#     `--quiet`, `--silent`, `-m N`, `-mN` (also closing a cluster, `-Em1`) or
#     `--max-count`;
#   - `head` with `-n N`, `-nN`, `-N` or `-c N`;
#   - `sed` whose script runs `q` or `Q`;
#   - `awk` whose program contains `exit`.
# A leading `NAME=value` (`| LC_ALL=C grep -q x`) does not hide the reader.
#
# THE FIX is at the cause, never a retry, a sleep or a skip: a here-string
# (`grep -q x <<< "$v"`, or `<<< "$(producer)"` — no pipe, so no writer to
# break), a reader that drains its input (`sed -n 1p`, an awk `done` flag), or
# no pipe at all (`grep -m1 x file`). Never `producer | grep x >/dev/null`: GNU
# grep ends at the first match when its stdout is /dev/null, exactly as `-q`
# does, so that pipe still races on Linux while it drains on macOS.
#
# THE EXCEPTION LIST is `exceptions` below, one `<file>TAB<exact trimmed
# line>TAB<reason>` entry per line, matched by the line's content, never its
# number — so an entry covers every identical line in that file. A logical
# line's trimmed text is its physical lines, each trimmed, joined by one space.
# Every reason begins `<fact>: ` naming the safety fact that holds — `stderr not
# captured`, `exit status not observed` or `producer finishes first` — and then
# says why. An entry whose file or line no longer exists reds the guard, and so
# does one whose line is no longer flagged, so the list cannot rot into a
# blanket pass.

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# The pinned size of the sweep: every tracked tests/*.bats + tests/*.bash.
SWEPT_FILES=167

exceptions() {
  cat <<'EOF'
tests/telemetry-rollup.bats	run bash -c "zsh '$S' '$FIX/v1-mixed.jsonl' 2>/dev/null | head -1; exit \${PIPESTATUS[0]}"	stderr not captured: the rollup's stderr goes to /dev/null, and the script ends in an unconditional `exit 0`, so a write into the closed pipe moves neither `$output` nor the propagated status
EOF
}

# The sweep itself. It reads NUL-separated repo-relative paths on stdin; argv
# is the root they resolve against and the exception list. It prints the
# number of files it read, then one `<file>:<line>: <trimmed line>` per
# unexcepted violation, then one line per exception or parse problem — so a
# count line alone is a green guard.
scanner() {
  cat <<'PY'
import os, re, sys

FACTS = ("stderr not captured", "exit status not observed", "producer finishes first")
MAX_SPAN = 400  # physical lines one logical line may span before it is reported


def subst_end(s, i):
    """Index just past the `)` closing the `$(` at s[i], or None when s ends
    first. Quotes, nested substitutions and heredoc bodies inside it are
    skipped, so a `)` or `"` in any of them does not end it."""
    depth, j, pending = 1, i + 2, []
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2; continue
        if c == "\n" and pending:
            j += 1
            for word, dash in pending:
                while j <= len(s):
                    k = s.find("\n", j)
                    line = s[j:] if k < 0 else s[j:k]
                    j = len(s) + 1 if k < 0 else k + 1
                    if terminates(line, word, dash):
                        break
            pending = []
            continue
        if c == "'":
            k = s.find("'", j + 1)
            if k < 0:
                return None
            j = k + 1; continue
        if c == '"':
            k = dq_end(s, j)
            if k is None:
                return None
            j = k; continue
        if c == "<" and s[j:j + 2] == "<<" and s[j:j + 3] != "<<<" and s[j - 1:j] != "<":
            m = HEREDOC.match(s, j)
            if m:
                pending.append((m.group(3), m.group(1) == "-"))
                j = m.end(); continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def dq_end(s, j):
    """Index just past the `"` closing the double quote opened at s[j]."""
    k = j + 1
    while k < len(s):
        c = s[k]
        if c == "\\":
            k += 2; continue
        if c == '"':
            return k + 1
        if c == "$" and s[k + 1:k + 2] == "(" and s[k + 2:k + 3] != "(":
            k = subst_end(s, k)
            if k is None:
                return None
            continue
        k += 1
    return None


def lex(s):
    """Walk s as shell text. Return (mask, strings, open_quote): mask is s with
    quoted text and comments blanked (same length, so an index into the mask
    is an index into s), strings the inner text of every quoted string, and
    open_quote the quote still open at the end of s."""
    out, strings, q, buf, i = [], [], None, [], 0
    while i < len(s):
        c = s[i]
        if q is None:
            if c == "\\" and i + 1 < len(s):
                out.append("  "); i += 2; continue
            if c == "$" and s[i + 1:i + 2] == "'":
                q, buf = "$'", []; out.append("  "); i += 2; continue
            if c in "'\"":
                q, buf = c, []; out.append(" "); i += 1; continue
            if c == "#" and (i == 0 or s[i - 1] in " \t\n;(|&"):
                j = s.find("\n", i)
                j = len(s) if j < 0 else j
                out.append(" " * (j - i)); i = j; continue
            out.append(c); i += 1; continue
        if q == "'":
            if c == "'":
                strings.append(("'", "".join(buf))); q = None
            else:
                buf.append(c)
            out.append(" "); i += 1; continue
        # a double quote or $'...': a backslash escapes the next character,
        # and in a double quote `$(…)` is shell code whose own quotes and
        # heredocs do not end the string
        if q == '"' and c == "$" and s[i + 1:i + 2] == "(" and s[i + 2:i + 3] != "(":
            end = subst_end(s, i)
            if end is None:
                buf.append(s[i:]); out.append(" " * (len(s) - i)); i = len(s); continue
            buf.append(s[i:end]); out.append(" " * (end - i)); i = end; continue
        if c == "\\" and i + 1 < len(s):
            buf.append(s[i:i + 2]); out.append("  "); i += 2; continue
        if (q == '"' and c == '"') or (q == "$'" and c == "'"):
            strings.append((q, "".join(buf))); q = None
        else:
            buf.append(c)
        out.append(" "); i += 1
    return "".join(out), strings, q


def unescape_dq(t):
    return re.sub(r'\\([\\"$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), t)


def words_of(s):
    """The words of the simple command starting at s, up to the first unquoted
    `|`, `;`, `&`, `)` or backtick, as (value, quoted). Leading NAME=value
    assignments are dropped, so words[0] is the command."""
    words, cur, quoted, has, q, i = [], [], False, False, None, 0
    while i < len(s):
        c = s[i]
        if q is None:
            if c in "|;&)`":
                break
            if c in " \t\n":
                if has:
                    words.append(("".join(cur), quoted)); cur, quoted, has = [], False, False
                i += 1; continue
            if c in "'\"":
                q = c; quoted = True; has = True; i += 1; continue
            if c == "\\" and i + 1 < len(s):
                cur.append(s[i + 1]); has = True; i += 2; continue
            cur.append(c); has = True; i += 1; continue
        if c == q:
            q = None
        elif q == '"' and c == "\\" and i + 1 < len(s):
            cur.append(s[i + 1]); i += 1
        else:
            cur.append(c)
        i += 1
    if has:
        words.append(("".join(cur), quoted))
    while words and not words[0][1] and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0][0]):
        words = words[1:]
    return words


SED_ADDR = re.compile(
    r"\s*(\d+|\$\{[^}]*\}|\$\d+|\$|/(?:[^/\\]|\\.)*/)"
    r"(\s*,\s*(\d+|\$\{[^}]*\}|\$\d+|\$|/(?:[^/\\]|\\.)*/))?\s*!?\s*")


def sed_quits(script):
    # blank every /…/ span first, so a `;` inside an address regex is not a
    # command separator
    flat = re.sub(r"/(?:[^/\\\n]|\\.)*/", lambda m: "/" + "x" * (len(m.group(0)) - 2) + "/", script)
    for cmd in re.split(r"[;\n{}]", flat):
        m = SED_ADDR.match(cmd)
        rest = cmd[m.end():] if m else cmd.strip()
        if re.fullmatch(r"[qQ]\s*\d*\s*", rest):
            return True
    return False


def exits_early(words):
    """True when words is a reader in the closed early-exit set."""
    if not words:
        return False
    cmd, args = words[0][0], words[1:]
    if cmd == "grep":
        k = 0
        while k < len(args):
            t, quoted = args[k]
            if not quoted:
                if t == "--":
                    break
                if t in ("--quiet", "--silent", "--max-count") or t.startswith("--max-count="):
                    return True
                if re.fullmatch(r"-[A-Za-z]+", t) and "q" in t:
                    return True
                if re.fullmatch(r"-[A-Za-z]*m\d+", t):
                    return True
                if re.fullmatch(r"-[A-Za-z]*m", t) and k + 1 < len(args):
                    return True
                if t in ("-e", "-f", "--regexp", "--file", "-A", "-B", "-C"):
                    k += 1
            k += 1
        return False
    if cmd == "head":
        for k, (t, quoted) in enumerate(args):
            if quoted:
                continue
            if t in ("-n", "-c") and k + 1 < len(args):
                return True
            if re.fullmatch(r"-n.+", t) or re.fullmatch(r"-\d+", t):
                return True
        return False
    if cmd == "sed":
        scripts, first, k = [], None, 0
        while k < len(args):
            t, quoted = args[k]
            if not quoted and t in ("-e", "--expression") and k + 1 < len(args):
                scripts.append(args[k + 1][0]); k += 2; continue
            if not quoted and t.startswith("-"):
                k += 1; continue
            if first is None:
                first = t
            k += 1
        if not scripts and first is not None:
            scripts = [first]
        return any(sed_quits(s) for s in scripts)
    if cmd == "awk":
        return any(re.search(r"\bexit\b", t) for t, _ in args)
    return False


PIPEFAIL = re.compile(r"(^|[;&|({]|\bthen\b|\bdo\b|\belse\b)\s*set\s+([^;&|\n]*\s)?-[A-Za-z]*o\s+pipefail\b", re.M)


def pipes_into_reader(text, depth=0):
    """0 when text holds no `|` into an early-exit reader; 1 when it does, at
    top level or inside a quoted string (a `bash -c "…"` body); 2 when the hit
    sits inside a quoted body that sets pipefail itself."""
    mask, strings, _ = lex(text)
    hit = 0
    for m in re.finditer(r"\|", mask):
        i = m.start()
        if mask[i - 1:i] == "|" or mask[i + 1:i + 2] == "|":
            continue
        rest = text[i + 1:]
        if rest.startswith("&"):
            rest = rest[1:]
        if exits_early(words_of(rest)):
            hit = 1
            break
    if depth < 3:
        for q, inner in strings:
            # a heredoc a quoted `"$(cat <<'EOF' …)"` carries is data, for the
            # pipe search and the pipefail test alike
            body = strip_heredocs(unescape_dq(inner) if q == '"' else inner)
            if "|" not in body:
                continue
            inner_hit = pipes_into_reader(body, depth + 1)
            if inner_hit and PIPEFAIL.search(lex(body)[0]):
                return 2
            hit = max(hit, inner_hit)
    return hit


HEREDOC = re.compile(r"<<(-?)[ \t]*\\?(['\"]?)([^\s;|&<>()'\"]+)\2")
RUN = re.compile(r"(^|[;&|({!]|\bthen\b|\bdo\b|\belse\b)\s*run(\s|$)", re.M)
FUNC = re.compile(r"\s*(function\s+[A-Za-z_][\w:.-]*\s*(\(\))?|[A-Za-z_][\w:.-]*\s*\(\))\s*(\{.*)?$", re.S)
TEST = re.compile(r"\s*@test\s")


def heredocs_in(text):
    """(word, dash) for each heredoc text opens, in order. A `<<` inside an
    arithmetic `((…))` is a shift, not a heredoc."""
    mask, docs = lex(text)[0], []
    for h in re.finditer(r"(?<!<)<<(?!<)", mask):
        before = mask[:h.start()]
        if before.count("((") > before.count("))"):
            continue
        m = HEREDOC.match(text, h.start())
        if m:
            docs.append((m.group(3), m.group(1) == "-"))
    return docs


def terminates(line, word, dash):
    return (line.lstrip("\t") if dash else line) == word


def strip_heredocs(text):
    """text without the bodies of the heredocs it opens — the ones a quoted
    `"$(cat <<'EOF' …)"` carries into a logical line, which are data."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        out.append(lines[i])
        docs = heredocs_in(lines[i])
        i += 1
        for word, dash in docs:
            while i < len(lines) and not terminates(lines[i], word, dash):
                i += 1
            i += 1
    return "\n".join(out)


def continues(text):
    mask, _, open_quote = lex(text)
    if open_quote is not None:
        return True
    tail = mask.rstrip()
    if mask.endswith("\\"):
        return True
    return tail.endswith("|") and not tail.endswith("||")


def logical_lines(lines, name, problems):
    """Yield (first line number, physical lines) per logical line. A heredoc
    body is consumed where the shell reads it — after the physical line that
    opened it, before any continuation — and is never yielded."""
    i = 0
    while i < len(lines):
        start, parts, consumed = i, [lines[i]], 0
        i += 1
        while True:
            text = "\n".join(parts)
            docs = heredocs_in(text)
            for word, dash in docs[consumed:]:
                while i < len(lines) and not terminates(lines[i], word, dash):
                    i += 1
                if i >= len(lines):
                    problems.append(f"{name}:{start + 1}: unterminated heredoc <<{word}")
                i += 1
            consumed = len(docs)
            if i >= len(lines) or not continues(text):
                break
            if len(parts) >= MAX_SPAN:
                problems.append(f"{name}:{start + 1}: a logical line runs past {MAX_SPAN} lines (an unbalanced quote?)")
                break
            parts.append(lines[i])
            i += 1
        yield start + 1, parts


def trimmed(parts):
    return " ".join(p.strip() for p in parts).strip()


def scan(path, name, problems):
    """One file's flagged lines as (line number, trimmed text), plus the set of
    all its trimmed logical lines (what an exception entry must still match)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    hits, stack, pipefail, seen = [], [], False, set()
    for no, parts in logical_lines(lines, name, problems):
        text = "\n".join(parts)
        mask, _, _ = lex(text)
        code = mask.strip()
        if not code:
            continue
        seen.add(trimmed(parts))
        indent = len(parts[0]) - len(parts[0].lstrip())
        if code.startswith("}") and stack and indent <= stack[-1][1]:
            stack.pop()
            continue
        opener = "test" if TEST.match(mask) else "func" if FUNC.match(mask) else None
        if PIPEFAIL.search(mask):
            pipefail = True
        in_func = opener == "func" or any(kind == "func" for kind, _ in stack)
        hit = pipes_into_reader(text)
        if hit:
            hits.append((no, trimmed(parts), hit == 2 or in_func or bool(RUN.search(mask))))
        if opener and not re.search(r"(^|[;&\s])\}\s*$", code):
            stack.append((opener, indent))
    # condition 3 is file-wide: a pipefail statement anywhere flags every hit
    return [(no, t) for no, t, why in hits if why or pipefail], seen


root, exceptions = sys.argv[1], sys.argv[2]
files = [f for f in sys.stdin.read().split("\0") if f]
allowed, problems = {}, []
for entry in exceptions.split("\n"):
    if not entry.strip():
        continue
    fields = entry.split("\t")
    if len(fields) != 3 or not all(f.strip() for f in fields):
        problems.append(f"malformed exception (want <file>TAB<line>TAB<reason>): {entry}")
        continue
    f, line, reason = fields
    if not any(reason.startswith(fact + ": ") and reason[len(fact) + 2:].strip() for fact in FACTS):
        problems.append(f"exception reason names no safety fact ({' / '.join(FACTS)}): {f}: {line}")
    allowed.setdefault(f, set()).add(line)
print(f"swept {len(files)} files")
seen_by_file, flagged_by_file = {}, {}
for f in files:
    flagged, seen_by_file[f] = scan(os.path.join(root, f), f, problems)
    flagged_by_file[f] = {t for _, t in flagged}
    for no, t in flagged:
        if t not in allowed.get(f, ()):
            print(f"{f}:{no}: {t}")
for f in sorted(allowed):
    for line in sorted(allowed[f]):
        if line not in seen_by_file.get(f, ()):
            problems.append(f"stale exception (file or line no longer exists): {f}: {line}")
        elif line not in flagged_by_file[f]:
            problems.append(f"unused exception (the line is no longer flagged): {f}: {line}")
for p in problems:
    print(p)
PY
}

# guard_report <root> <exceptions> — the guard's verdict over <root>'s tracked
# suites, minus its `swept N files` count line: empty output means green.
guard_report() {
  guard_run "$@" | sed 1d
}

# guard_run <root> <exceptions> — the scanner's whole output, count line first.
guard_run() {
  git -C "$1" ls-files -z -- 'tests/*.bats' 'tests/*.bash' \
    | python3 -c "$(scanner)" "$1" "$2"
}

# A throwaway git repo holding one suite, read from stdin, at <root>/<rel>.
# Fixture heredocs spell a test opener `%test`, mapped back to `@test` here:
# bats' preprocessor rewrites a line-start `@test "…" {` into a function even
# inside a heredoc on some platforms (Linux CI), which would turn every
# fixture @test body into a helper and flag it.
fixture_suite() {
  local root="$1" rel="$2"
  [ -d "$root/.git" ] || git -C "$(mkdir -p "$root" && cd "$root" && pwd)" init -q
  mkdir -p "$root/$(dirname "$rel")"
  sed 's/^\([[:blank:]]*\)%test /\1@test /' > "$root/$rel"
  git -C "$root" add -- "$rel"
}

@test "#1797 the sweep reads every tracked tests/*.bats and tests/*.bash: the count is pinned" {
  local n swept
  n="$(git -C "$REPO_ROOT" ls-files -z -- 'tests/*.bats' 'tests/*.bash' | tr -cd '\000' | wc -c | tr -d ' ')"
  [ "$n" -eq "$SWEPT_FILES" ] || {
    printf 'git ls-files enumerates %s files, the pin says %s: update SWEPT_FILES\n' "$n" "$SWEPT_FILES" >&2
    return 1
  }
  # ...and the scanner reads exactly that set, not a narrower one
  swept="$(guard_run "$REPO_ROOT" "$(exceptions)" | sed -n 1p)"
  [ "$swept" = "swept $SWEPT_FILES files" ]
}

@test "#1797 no suite pipes a producer into an early-exit reader where the race can fail a test" {
  run guard_report "$REPO_ROOT" "$(exceptions)"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1797 MUTATION: re-introducing the #1492 line into a helper function reds the guard, naming file:line" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/sweep.bats <<'EOF'
#!/usr/bin/env bats
problems_in() {
  local script="$1" s
  while IFS= read -r s; do
    printf '%s\n' "$script" | grep -qxF -- "$s" && continue
    printf '%s\n' "$s"
  done <<< "$2"
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "tests/sweep.bats:5: printf '%s\n' \"\$script\" | grep -qxF -- \"\$s\" && continue" ]
}

@test "#1797 MUTATION: a helper in a tracked tests/**/*.bash file reds the guard too" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/lib/helpers.bash <<'EOF'
has_x() {
  printf '%s\n' "$1" | grep -q x
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "tests/lib/helpers.bash:2: printf '%s\n' \"\$1\" | grep -q x" ]
}

@test "#1797 MUTATION: every reader in the closed set reds the guard from a helper function" {
  local root="$BATS_TEST_TMPDIR/r" reader i=0
  while IFS= read -r reader; do
    i=$((i + 1))
    printf 'h() {\n  printf x | %s\n}\n' "$reader" | fixture_suite "$root" "tests/r$i.bats"
  done <<'EOF'
grep -q x
grep -qxF -- x
grep -Eq x
grep --quiet x
grep --silent x
grep -m 1 x
grep -m1 x
grep -Em1 x
grep -om 1 x
grep --max-count=1 x
grep --max-count 1 x
LC_ALL=C grep -q x
head -n 1
head -n1
head -1
head -c 1
LC_ALL=C head -n 1
sed q
sed 2q
sed -n '/x/{p;q;}'
sed -n '/a;b/q'
sed "${n}q"
sed '$q'
sed '/x/!q'
sed "$1q"
sed '/x/q5'
sed -n -e p -e '/x/Q'
awk '{ print; exit }'
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  local n
  n="$(grep -c '^tests/r[0-9]*\.bats:2: ' <<< "$output")"
  [ "$n" -eq "$i" ] || { printf 'only %s of %s readers flagged:\n%s\n' "$n" "$i" "$output" >&2; return 1; }
  # one case per family, named, so a family dropped from the set is visible
  for reader in grep head sed awk; do
    grep -qF "| $reader " <<< "$output" || { echo "no $reader case reds" >&2; return 1; }
  done
}

@test "#1797 the closed set's edge: readers outside it, and pipe-free forms, are never flagged" {
  local root="$BATS_TEST_TMPDIR/r" reader i=0
  while IFS= read -r reader; do
    i=$((i + 1))
    printf 'h() {\n  %s\n}\n' "$reader" | fixture_suite "$root" "tests/d$i.bats"
  done <<'EOF'
printf x | grep -c x
printf x | grep -xF -- -q
printf x | grep -e -q x
printf x | tail -n 1
printf x | sed -n 1p
printf x | sed 's/q/Q/'
printf x | awk '{ print $1 }'
grep -q x <<< "$v"
head -1 <<< "$v"
grep -m1 x file
false || grep -q x file
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1797 BOUNDARY: a @test-body pipeline, not on a run line, in a file without pipefail is not flagged" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/boundary.bats <<'EOF'
#!/usr/bin/env bats
%test "reads its own pipe" {
  printf 'a\nb\n' | grep -q b
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "#1797 MUTATION: the same pipeline in a helper function IS flagged, and only there" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/helper.bats <<'EOF'
#!/usr/bin/env bats
has_b() {
  printf 'a\nb\n' | grep -q b
}
one_liner() { printf 'a\nb\n' | grep -q b; }
function keyword_form {
  printf 'a\nb\n' |& grep -q b
}
%test "calls the helpers, then reads its own pipe" {
  has_b
  printf 'a\nb\n' | grep -q b
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  # the @test-body line (11) is past every closed helper, so it stays unflagged
  [ "$output" = "tests/helper.bats:3: printf 'a\nb\n' | grep -q b
tests/helper.bats:5: one_liner() { printf 'a\nb\n' | grep -q b; }
tests/helper.bats:7: printf 'a\nb\n' |& grep -q b" ]
}

@test "#1797 MUTATION: a run bash -c \"producer | grep -q x\" line in a @test body of a file without pipefail reds" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/run-line.bats <<'EOF'
#!/usr/bin/env bats
%test "runs a pipe" {
  run bash -c "seq 1 100000 | grep -q 5"
  [ "$status" -eq 0 ]
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ "$output" = 'tests/run-line.bats:3: run bash -c "seq 1 100000 | grep -q 5"' ]
}

@test "#1797 condition 3: pipefail inside a quoted bash -c string does not make a pipefail file; a statement in the file's own code does" {
  local root="$BATS_TEST_TMPDIR/r" where
  fixture_suite "$root" tests/quoted.bats <<'EOF'
#!/usr/bin/env bats
%test "a pipefail that is someone else's shell code" {
  bash -c "set -o pipefail; true"
  bash -c 'set -euo pipefail; true'
  printf 'a\nb\n' | grep -q b
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'a quoted pipefail flagged the file:\n%s\n' "$output" >&2; return 1; }

  local all='top setup helper test euo split oneliner tail'
  for where in $all; do
    : > "$BATS_TEST_TMPDIR/head.bash"
    : > "$BATS_TEST_TMPDIR/tail.bash"
    case "$where" in
      top)      printf 'set -o pipefail\n' ;;
      setup)    printf 'setup() {\n  set -o pipefail\n}\n' ;;
      helper)   printf 'strict() {\n  set -o pipefail\n}\n' ;;
      test)     printf '@test "strict" {\n  set -o pipefail\n}\n' ;;
      euo)      printf 'set -euo pipefail\n' ;;
      split)    printf 'set -e -o pipefail\n' ;;
      oneliner) printf 'setup() { set -o pipefail; }\n' ;;
    esac > "$BATS_TEST_TMPDIR/head.bash"
    # the statement AFTER the pipeline it makes unsafe: condition 3 is file-wide
    [ "$where" != tail ] || printf 'teardown() {\n  set -o pipefail\n}\n' > "$BATS_TEST_TMPDIR/tail.bash"
    { cat "$BATS_TEST_TMPDIR/head.bash"
      printf '@test "reads its own pipe" {\n  printf "a\\nb\\n" | grep -q b\n}\n'
      cat "$BATS_TEST_TMPDIR/tail.bash"
    } | fixture_suite "$root" "tests/pf-$where.bats"
  done
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  for where in $all; do
    grep -q "^tests/pf-$where\.bats:[0-9]*: printf \"a\\\\nb\\\\n\" | grep -q b\$" <<< "$output" \
      || { printf 'pipefail in %s did not flag its file:\n%s\n' "$where" "$output" >&2; return 1; }
  done
  [ "$(grep -c '' <<< "$output")" -eq 8 ]
}

@test "#1797 MUTATION: a quoted body that sets pipefail itself is flagged even off a run line" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/strict-body.bats <<'EOF'
#!/usr/bin/env bats
%test "its own strict shell" {
  bash -c "set -o pipefail; seq 1 100000 | grep -q 5"
  bash -c "seq 1 100000 | grep -q 5"
}
EOF
  # the expected line lives in a heredoc: spelled in a quoted string here, it
  # would be the very shape this test proves the guard flags
  local expected
  expected="$(cat <<'EOF'
tests/strict-body.bats:3: bash -c "set -o pipefail; seq 1 100000 | grep -q 5"
EOF
)"
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  # the second line's body has no pipefail, so its status is grep's: exempt
  [ "$output" = "$expected" ]
}

@test "#1797 a continued line counts as one line, reported at its first physical line" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/continued.bats <<'EOF'
#!/usr/bin/env bats
backslash() {
  printf 'a\nb\n' \
    | grep -q b
}
bare_pipe() {
  printf 'a\nb\n' |
    grep -q b
}
past_a_heredoc() {
  cat <<'DOC' |
b
DOC
    grep -q b
}
%test "a quoted body still open at the line's end" {
  run bash -c "true
    seq 1 100000 | grep -q 5"
}
EOF
  # a statement-level heredoc, not one inside "$(…)": the expected text holds
  # a `<<'DOC'` that tests/find-inert-bracket-assertions.zsh would otherwise
  # read as code
  local expected
  IFS= read -r -d '' expected <<'EOF' || true
tests/continued.bats:3: printf 'a\nb\n' \ | grep -q b
tests/continued.bats:7: printf 'a\nb\n' | grep -q b
tests/continued.bats:11: cat <<'DOC' | grep -q b
tests/continued.bats:17: run bash -c "true seq 1 100000 | grep -q 5"
EOF
  expected="${expected%$'\n'}"
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "#1797 a comment ending in a backslash does not continue the line" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/comment.bats <<'EOF'
#!/usr/bin/env bats
h() {
  # a path like C:\
}
%test "after the helper closed" {
  printf 'a\nb\n' | grep -q b
}
EOF
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'the helper never closed:\n%s\n' "$output" >&2; return 1; }
}

@test "#1797 MUTATION: a pipe inside a quoted \$(…) is shell code; a heredoc body inside one is data" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/subst.bats <<'OUTER'
#!/usr/bin/env bats
h() {
  first="$(printf 'a\nb\n' | head -n "$n")"
}
%test "a heredoc captured in a quoted substitution" {
  expected="$(cat <<'EOF'
it's ) not the end
set -o pipefail
bash -c "set -o pipefail; seq 1 100000 | grep -q 5"
EOF
)"
  printf 'a\nb\n' | grep -q b
}
after() { printf 'a\nb\n' | grep -q b; }
OUTER
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  # the heredoc's pipefail neither flags its own line nor makes the file a
  # pipefail file, so the later @test-body pipeline stays unflagged; and its
  # apostrophe and `)` do not swallow the helper that follows
  [ "$output" = "tests/subst.bats:3: first=\"\$(printf 'a\\nb\\n' | head -n \"\$n\")\"
tests/subst.bats:14: after() { printf 'a\\nb\\n' | grep -q b; }" ]
}

@test "#1797 heredoc bodies are data, not the file's shell code" {
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/heredoc.bats <<'OUTER'
#!/usr/bin/env bats
set -o pipefail
write_stub() {
  cat > "$1" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" | grep -q statusCheckRollup && echo '{}'
  EOF
printf x | grep -q x
EOF
  cat > "$2" <<\END-X
printf y | grep -q y
END-X
  cat <<-EOF | sort > "$3"
	printf z | grep -q z
	EOF
  n=$(( 1 << 3 ))
}
OUTER
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1797 MUTATION: a heredoc that never ends, or a quote that never closes, reds the guard" {
  # each would otherwise swallow the rest of its file unscanned
  local root="$BATS_TEST_TMPDIR/r"
  fixture_suite "$root" tests/open-heredoc.bats <<'OUTER'
#!/usr/bin/env bats
h() {
  cat <<'EOF'
payload
}
OUTER
  { printf '#!/usr/bin/env bats\nh() {\n  echo "never closed\n'
    for _ in $(seq 1 410); do printf 'filler\n'; done
  } | fixture_suite "$root" tests/open-quote.bats
  run guard_report "$root" ""
  [ "$status" -eq 0 ]
  [ "$output" = "tests/open-heredoc.bats:3: unterminated heredoc <<EOF
tests/open-quote.bats:3: a logical line runs past 400 lines (an unbalanced quote?)" ]
}

@test "#1797 an exception entry suppresses its own line, matched by content" {
  # entries are built off the `run` line: the guard scans quoted text on a
  # `run` line as shell code, so a pipe spelled there would flag this file
  local root="$BATS_TEST_TMPDIR/r" tab=$'\t' line='printf x | grep -q x' entry
  fixture_suite "$root" tests/excepted.bats <<'EOF'
#!/usr/bin/env bats
h() {
  printf x | grep -q x
  printf y | grep -q y
  printf x | grep -q x && true
}
EOF
  fixture_suite "$root" tests/other.bats <<'EOF'
#!/usr/bin/env bats
h() {
  printf x | grep -q x
}
EOF
  local fact
  for fact in 'stderr not captured' 'exit status not observed' 'producer finishes first'; do
    entry="tests/excepted.bats${tab}${line}${tab}${fact}: one byte, written before grep can read it"
    run guard_report "$root" "$entry"
    [ "$status" -eq 0 ]
    # the entry excuses its exact line in its own file: not a longer line that
    # starts with it, and not the same line in another file
    [ "$output" = "tests/excepted.bats:4: printf y | grep -q y
tests/excepted.bats:5: printf x | grep -q x && true
tests/other.bats:3: printf x | grep -q x" ] \
      || { printf 'fact %s:\n%s\n' "$fact" "$output" >&2; return 1; }
  done
}

@test "#1797 MUTATION: a stale or unused exception entry reds the guard" {
  local root="$BATS_TEST_TMPDIR/r" tab=$'\t' reason='stderr not captured: sent to /dev/null'
  local line='printf x | grep -q x' entry
  fixture_suite "$root" tests/kept.bats <<'EOF'
#!/usr/bin/env bats
h() {
  true
}
%test "an unflagged pipe" {
  printf x | grep -q x
}
EOF
  entry="tests/kept.bats${tab}printf z | grep -q z${tab}$reason"
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  [ "$output" = "stale exception (file or line no longer exists): tests/kept.bats: printf z | grep -q z" ]

  entry="tests/gone.bats${tab}${line}${tab}$reason"
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  [ "$output" = "stale exception (file or line no longer exists): tests/gone.bats: $line" ]

  # the line still exists, but nothing flags it, so the entry excuses nothing
  entry="tests/kept.bats${tab}${line}${tab}$reason"
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  [ "$output" = "unused exception (the line is no longer flagged): tests/kept.bats: $line" ]
}

@test "#1797 MUTATION: an exception whose reason names no safety fact, or a malformed entry, reds the guard" {
  local root="$BATS_TEST_TMPDIR/r" tab=$'\t' line='printf x | grep -q x' entry
  fixture_suite "$root" tests/excepted.bats <<'EOF'
#!/usr/bin/env bats
h() {
  printf x | grep -q x
}
EOF
  entry="tests/excepted.bats${tab}${line}${tab}it has never flaked"
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  starts_with "$output" 'exception reason names no safety fact ('
  ends_with "$output" "): tests/excepted.bats: $line"

  # the fact alone, with nothing after it, is no reason either
  entry="tests/excepted.bats${tab}${line}${tab}stderr not captured: "
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  starts_with "$output" 'exception reason names no safety fact ('

  entry="tests/excepted.bats $line"
  run guard_report "$root" "$entry"
  [ "$status" -eq 0 ]
  contains "$output" "malformed exception (want <file>TAB<line>TAB<reason>): $entry"
}

@test "#1797 every real exception entry names one of the three safety facts" {
  local entry reason
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    reason="$(cut -f3 <<< "$entry")"
    case "$reason" in
      'stderr not captured: '?* | 'exit status not observed: '?* | 'producer finishes first: '?*) ;;
      *) printf 'no safety fact: %s\n' "$entry" >&2; return 1 ;;
    esac
  done <<< "$(exceptions)"
}
