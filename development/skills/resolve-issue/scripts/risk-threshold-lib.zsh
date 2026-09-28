# risk-threshold-lib.zsh — the ONE definition of `corner_case_risk_threshold`
# (#1920) and of a well-formed risk assessment, SOURCED (never executed) by every
# script that reads either (#1921): consolidate-findings.zsh (the in-loop
# demotion), resolve-story-loop.zsh (the up-front --risk check) and
# build-residue-issues.zsh (the residue filter).
#
# Why a shared file: the threshold decides which findings block and which get
# filed. Two parsers that disagreed on one spelling (`.05`, `1.0`, `0.0005`) would
# demote a finding in the loop and then file it as residue, or the reverse — and
# nothing downstream would notice. One parser cannot disagree with itself.
#
# THE THRESHOLD: the environment variable `corner_case_risk_threshold`, a decimal
# in [0, 1] with at most three decimals (`0.05`, `.05`, `1`, `1.0`). Three states.
# OFF — unset, empty, or any spelling of zero (`0`, `0.0`, `.000`): today's
# behaviour byte-for-byte, silently. IGNORED — set to anything the rule does not
# admit (`30`, `1.5`, `-0.1`, `0.0005`, `abc`): behaves exactly like OFF, and the
# caller announces it. ON — any other value, up to and including 1.
#
# THE ASSESSMENT: a JSON array of
#   { file, line, dimension, title,       ← the finding identity
#     p, p_why, impact, impact_why }      ← the assessment
# with p a number in [0, 1] with at most two decimals, impact one of the four
# anchors 0.1 / 0.4 / 0.7 / 1.0, both rationales non-blank, and at most one entry
# per identity. risk = p × impact is compared in INTEGER THOUSANDTHS — p in
# hundredths times impact in tenths — so no floating-point rounding can move a
# finding across the boundary.

# risk_threshold_parse — read the variable into the CALLER's `thr_raw`,
# `thr_state` (off | ignored | on) and `thr_milli` (the threshold in thousandths;
# 0 unless on). The caller declares the three as locals first; zsh's dynamic
# scoping makes these assignments land there. Prints nothing: announcing an
# ignored value is the caller's job, worded for what that caller does.
risk_threshold_parse() {
  thr_raw="${corner_case_risk_threshold-}" thr_state="off" thr_milli=0
  [[ -n "$thr_raw" ]] || return 0
  # One leading digit at most (0 or 1), then up to three decimals. The digit class
  # is what refuses `30` and `-0.1`; the decimal cap refuses `0.0005`; the range
  # check below refuses `1.5`, which the shape alone would admit.
  if [[ "$thr_raw" =~ '^([01]?)(\.([0-9]{1,3}))?$' && "$thr_raw" != "." ]]; then
    local thr_int="${match[1]:-0}" thr_frac="${match[3]-}"
    thr_frac="${(r:3::0:)thr_frac}"
    thr_milli=$(( 10#$thr_int * 1000 + 10#$thr_frac ))
    if (( thr_milli > 1000 )); then
      thr_state="ignored"
    elif (( thr_milli > 0 )); then
      thr_state="on"
    fi
  else
    thr_state="ignored"
  fi
  [[ "$thr_state" != "ignored" ]] || thr_milli=0
  return 0
}

# risk_validate_file PREFIX FILE — the first defect in an assessment file, as one
# line on stderr beginning with PREFIX, and return 2; return 0 on a well-formed
# file. Every defect is exit 2: the assessment is the conductor's own output, so a
# bad one is a caller mistake to fix and re-run — and must never be read as "drop
# everything" or "keep everything". The message after PREFIX is identical for
# every caller, so the loop's up-front refusal and the consolidator's say the
# same thing.
risk_validate_file() {
  local prefix="$1" file="$2"
  [[ ! -d "$file" ]] || { print -r -u2 -- "$prefix: --risk is a directory: $file"; return 2 }
  [[ -r "$file" && -s "$file" ]] || {
    print -r -u2 -- "$prefix: --risk file missing, unreadable or empty: $file"; return 2 }
  jq -e -s 'length == 1 and (.[0] | type == "array")' "$file" >/dev/null 2>&1 || {
    print -r -u2 -- "$prefix: --risk is not exactly one JSON array: $file"; return 2 }

  # `p` is checked for at most two decimals and `impact` for one of the four
  # anchors by ROUNDING a scaled value and comparing, never by float equality —
  # 0.29 * 100 is 28.999… in jq.
  local risk_err=""
  risk_err=$(jq -r '
    # NB: no apostrophes in this program — it is single-quoted.
    def scaled_ok($x; $k): (($x * $k) as $v | ((($v | round) - $v) | fabs) < 0.000001);
    def nonblank: type == "string" and (gsub("\\s"; "") | length) > 0;
    # the file normalised the way consolidate-findings.zsh matches it (a leading
    # ./ dropped), so two spellings of one finding count as the duplicate they
    # are; the line needs nothing, since a non-number line is refused above
    def ident: [((.file // "") | tostring | sub("^\\./"; "")), (.line // null),
                (.dimension // ""), (.title // "")];
    def entry_name($i): "entry \($i) (\((.title // "<no title>") | tostring | .[0:80]))";
    [ to_entries[] | .key as $i | .value as $e
      | if ($e | type) != "object" then "entry \($i): not an object"
        else ($e | entry_name($i)) as $l
        | if ($e.file | type) != "string" then "\($l): file must be a string"
          elif ($e.dimension | type) != "string" then "\($l): dimension must be a string"
          elif ($e.title | type) != "string" then "\($l): title must be a string"
          elif ($e | has("line")) and (($e.line | type) | . != "number" and . != "null") then "\($l): line must be a number or null"
          elif ($e.p | type) != "number" or $e.p < 0 or $e.p > 1 or (scaled_ok($e.p; 100) | not)
            then "\($l): p must be a number in [0, 1] with at most two decimals (got \($e.p | tojson))"
          elif ($e.impact | type) != "number" or (scaled_ok($e.impact; 10) | not)
               or ([1, 4, 7, 10] | index($e.impact * 10 | round)) == null
            then "\($l): impact must be one of 0.1, 0.4, 0.7, 1.0 (got \($e.impact | tojson))"
          elif ($e.p_why | nonblank | not) then "\($l): p_why must be a non-empty rationale"
          elif ($e.impact_why | nonblank | not) then "\($l): impact_why must be a non-empty rationale"
          else empty end
        end ]
    + ( [ to_entries[] | select(.value | type == "object") | {i: .key, k: (.value | ident)} ]
        | group_by(.k) | map(select(length > 1))
        | map("entry \(.[1].i) duplicates the identity of entry \(.[0].i) — one assessment per finding") )
    | .[0] // empty' "$file" 2>/dev/null) || {
    print -r -u2 -- "$prefix: could not validate --risk: $file"; return 2 }
  [[ -z "$risk_err" ]] || { print -r -u2 -- "$prefix: malformed --risk $file: $risk_err"; return 2 }
  return 0
}
