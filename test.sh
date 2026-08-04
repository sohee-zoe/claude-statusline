#!/usr/bin/env bash
# test.sh — regression suite for variants/compact.sh and install.sh
#
#   ./test.sh              width sweep + edge cases + installer paths
#   ./test.sh width        one section only
#   ./test.sh edge
#   ./test.sh install
#
#   TEST_WIDTH_STEP=1      sweep every column instead of every fifth
#
# Written for bash 3.2: no associative arrays, no namerefs, no mapfile.
set -u

cd "$(dirname "$0")" || exit 1

COMPACT=./variants/compact.sh
FULL=./variants/full.sh
INSTALL=./install.sh

pass=0
fail=0
current_section=''

section() { current_section="$1"; printf '\n== %s ==\n' "$1"; }
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
ck()   { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
ck_has() { case "$2" in *"$3"*) ok ;; *) bad "$1: output lacks [$3]" ;; esac; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------- measurement
# The display-width table mirrors the one inside compact.sh. That makes this a
# test of layout selection, not of the width model itself — a cell-width bug
# shared by both would pass here and still look wrong in a terminal.
measure() { # stdin => "<max line width> <line count>"
  perl -CSD -e '
    sub cw {
      my $o = shift;
      return 0 if $o == 0xFE0F || $o == 0xFE0E || $o == 0x200D || $o == 0x20E3
               || ($o >= 0x0300 && $o <= 0x036F);
      return 2 if ($o >= 0x1100 && $o <= 0x115F)
               || ($o >= 0x2E80 && $o <= 0x303E)
               || ($o >= 0x3041 && $o <= 0x33FF)
               || ($o >= 0x3400 && $o <= 0x4DBF)
               || ($o >= 0x4E00 && $o <= 0x9FFF)
               || ($o >= 0xA000 && $o <= 0xA4CF)
               || ($o >= 0xAC00 && $o <= 0xD7A3)
               || ($o >= 0xF900 && $o <= 0xFAFF)
               || ($o >= 0xFE30 && $o <= 0xFE6F)
               || ($o >= 0xFF00 && $o <= 0xFF60)
               || ($o >= 0xFFE0 && $o <= 0xFFE6)
               || ($o >= 0x1F300 && $o <= 0x1FAFF)
               || ($o >= 0x20000 && $o <= 0x3FFFD)
               || $o == 0x231A || $o == 0x231B || $o == 0x23F0 || $o == 0x23F3
               || ($o >= 0x23E9 && $o <= 0x23EC)
               || ($o >= 0x25FD && $o <= 0x25FE)
               || ($o >= 0x2614 && $o <= 0x2615)
               || ($o >= 0x2648 && $o <= 0x2653)
               || $o == 0x267F || $o == 0x2693 || $o == 0x26A1
               || ($o >= 0x2705 && $o <= 0x270B) || $o == 0x2728;
      return 1;
    }
    my ($max, $lines) = (0, 0);
    while (my $l = <STDIN>) {
      chomp $l;
      $l =~ s/\e\[[0-9;]*m//g;
      my $n = 0;
      $n += cw(ord($_)) for split //, $l;
      $max = $n if $n > $max;
      $lines++;
    }
    print "$max $lines";
  '
}

render() { # <fixture file> <columns> <mode>
  printf '%s' "$(cat "$1")" \
    | STATUSLINE_COLUMNS="$2" STATUSLINE_LINES="$3" STATUSLINE_PADDING=0 "$COMPACT"
}

# ------------------------------------------------------------------ fixtures
repo="$work/very-long-project-name"
mkdir -p "$repo"
git -C "$repo" init -q 2>/dev/null
git -C "$repo" checkout -q -b feature/adaptive-statusline 2>/dev/null

kor="$work/한글-프로젝트-디렉터리"
mkdir -p "$kor"

fixture_plain="$work/plain.json"
cat > "$fixture_plain" <<JSON
{"model":{"display_name":"Opus 4.5"},
 "workspace":{"current_dir":"/tmp/example"},
 "context_window":{"context_window_size":200000,"remaining_percentage":72,
   "current_usage":{"input_tokens":40000,"cache_read_input_tokens":16000}},
 "rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1786000000},
   "seven_day":{"used_percentage":88,"resets_at":1786400000}}}
JSON

fixture_git="$work/git.json"
cat > "$fixture_git" <<JSON
{"model":{"display_name":"claude-opus-4-5-20251101"},
 "workspace":{"current_dir":"$repo"},
 "context_window":{"context_window_size":200000,"remaining_percentage":9,
   "current_usage":{"input_tokens":182000}},
 "rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1786000000},
   "seven_day":{"used_percentage":0,"resets_at":1786400000}}}
JSON

fixture_korean="$work/korean.json"
cat > "$fixture_korean" <<JSON
{"model":{"display_name":"Sonnet 4.5"},
 "workspace":{"current_dir":"$kor"},
 "context_window":{"context_window_size":1000000,"remaining_percentage":55,
   "current_usage":{"input_tokens":450000}},
 "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1786000000},
   "seven_day":{"used_percentage":50,"resets_at":1786400000}}}
JSON

# name:file:ceiling(auto):ceiling(1):ceiling(2)
#
# The ceilings pin how narrow the most compact candidate is allowed to be.
# Without them the sweep is self-referential: it derives the floor from the
# script under test, so dropping a compaction level just raises the floor and
# every assertion still passes. Compaction may improve — a floor below the
# ceiling is fine — but it may not silently regress.
fixtures="plain:$fixture_plain:49:75:49
git:$fixture_git:59:111:59
korean:$fixture_korean:49:92:49"

# --------------------------------------------------------------- width sweep
# For each fixture and mode the script has a floor: the width of its most
# compact candidate. At or above the floor every line must fit the budget.
# Below it there is nothing left to shrink, so the requirement is only that
# the output stays pinned at that floor rather than growing again.
#
# What this does not check: that every intermediate compaction level is still
# reachable. Deleting one — say the 6-cell bar — leaves the floor and every
# budget intact, so the sweep passes while the output steps down more coarsely
# than intended. Catching that needs golden layouts pinned per width.
run_width_sweep() {
  section 'width sweep'
  local step="${TEST_WIDTH_STEP:-5}"
  local seen_one ceiling
  local entry name file mode floor_w c out w lines
  local ceil_auto ceil_one ceil_two

  # Fed by here-doc, not a pipe: a piped `while` runs in a subshell and the
  # pass/fail counters would not survive it.
  while IFS=: read -r name file ceil_auto ceil_one ceil_two; do
    [ -n "$name" ] || continue
    for mode in auto 1 2; do
      case "$mode" in
        auto) ceiling="$ceil_auto" ;;
        1)    ceiling="$ceil_one" ;;
        *)    ceiling="$ceil_two" ;;
      esac

      floor_w="$(render "$file" 1 "$mode" | measure | cut -d' ' -f1)"
      if [ "$floor_w" -le "$ceiling" ]; then ok
      else bad "$name/$mode: most compact layout is $floor_w wide, ceiling is $ceiling"; fi

      c=40
      while [ "$c" -le 220 ]; do
        out="$(render "$file" "$c" "$mode")"
        set -- $(printf '%s\n' "$out" | measure)
        w="$1"; lines="$2"

        if [ "$c" -ge "$floor_w" ]; then
          if [ "$w" -gt "$c" ]; then
            bad "$name/$mode/cols=$c: line width $w exceeds budget $c"
          else ok; fi
        else
          if [ "$w" -ne "$floor_w" ]; then
            bad "$name/$mode/cols=$c: below floor but width $w != floor $floor_w"
          else ok; fi
        fi

        case "$mode" in
          1) ck "$name/1/cols=$c line count" "$lines" "1" ;;
          2) ck "$name/2/cols=$c line count" "$lines" "2" ;;
          *) if [ "$lines" -eq 1 ] || [ "$lines" -eq 2 ]; then ok
             else bad "$name/auto/cols=$c: $lines lines, expected 1 or 2"; fi ;;
        esac

        c=$((c + step))
      done

      # auto switches to two lines once and never switches back: widening the
      # terminal must not make the statusline taller.
      if [ "$mode" = auto ]; then
        seen_one=0
        c=40
        while [ "$c" -le 220 ]; do
          lines="$(render "$file" "$c" auto | measure | cut -d' ' -f2)"
          if [ "$lines" -eq 1 ]; then seen_one=1
          elif [ "$seen_one" -eq 1 ]; then
            bad "$name/auto: back to $lines lines at cols=$c after fitting on one"
            break
          fi
          c=$((c + step))
        done
        [ "$seen_one" -eq 1 ] && ok || bad "$name/auto: never used one line up to cols=220"
      fi
    done
  done <<EOF
$fixtures
EOF

  # Long names must actually be truncated once there is nothing else to give up.
  out="$(render "$fixture_git" 45 auto)"
  ck_has 'narrow layout ellipsizes the directory' "$out" '…'
}

# ---------------------------------------------------------------- edge cases
run_edge_cases() {
  section 'edge cases'
  local out rc

  out="$(printf '{}' | STATUSLINE_COLUMNS=120 "$COMPACT")"; rc=$?
  ck     'empty object exits 0' "$rc" '0'
  ck_has 'empty object renders placeholders' "$out" '--%'
  ck_has 'empty object falls back to ~' "$out" '~'

  out="$(printf 'not json at all' | STATUSLINE_COLUMNS=120 "$COMPACT")"; rc=$?
  ck     'non-JSON exits 0' "$rc" '0'
  ck     'non-JSON message' "$out" '[statusline] invalid input'

  out="$(printf '' | STATUSLINE_COLUMNS=120 "$COMPACT")"; rc=$?
  ck 'empty input exits 0' "$rc" '0'

  out="$(printf '%s' '{"model":{"id":"claude-sonnet-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "context_window":{"context_window_size":200000,"remaining_percentage":50,
    "current_usage":{"input_tokens":100000}}}' | STATUSLINE_COLUMNS=160 "$COMPACT")"
  ck_has 'missing rate_limits shows --%' "$out" '--%'
  ck_has 'missing rate_limits keeps placeholder time' "$out" 'mm-dd hh:mm'
  ck_has 'missing rate_limits still shows context' "$out" '100k'

  out="$(printf '%s' '{"model":{"id":"claude-sonnet-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1786000000}}}' \
    | STATUSLINE_COLUMNS=160 "$COMPACT")"
  ck_has 'missing context_window shows --%' "$out" '--%'
  ck_has 'missing context_window keeps 5h' "$out" '5h'

  out="$(printf '%s' '{"model":{"id":"claude-opus-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "context_window":{"context_window_size":1000000,"remaining_percentage":80,
    "current_usage":{"input_tokens":200000}}}' | STATUSLINE_COLUMNS=200 "$COMPACT")"
  ck_has '1M context formats with M' "$out" 'M'

  out="$(printf '%s' '{"model":{"id":"claude-opus-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "context_window":{"context_window_size":200000,"remaining_percentage":0,
    "current_usage":{"input_tokens":200000}},
    "rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1786000000},
    "seven_day":{"used_percentage":0,"resets_at":1786400000}}}' \
    | STATUSLINE_COLUMNS=200 "$COMPACT")"
  ck_has '0% context'        "$out" '0%'
  ck_has '100% remaining 7d' "$out" '100%'
  ck_has 'exhausted window uses the drained hourglass' "$out" '⌛'

  out="$(printf '%s' '{"model":{"id":"claude-opus-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1786000000}}}' \
    | STATUSLINE_COLUMNS=200 "$COMPACT")"
  ck_has 'live window uses the running hourglass' "$out" '⏳'

  out="$(printf '%s' '{"model":{"id":"claude-opus-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "context_window":{"context_window_size":200000,"remaining_percentage":150,
    "current_usage":{"input_tokens":400000}}}' | STATUSLINE_COLUMNS=200 "$COMPACT")"
  ck_has 'percentage clamps to 100' "$out" '100%'
  ck_has 'negative remainder clamps to 0k' "$out" '0k'

  out="$(printf '%s' '{"model":{"id":"claude-opus-4-5"},"workspace":{"current_dir":"/tmp/x"},
    "rate_limits":{"five_hour":{"used_percentage":20,"resets_at":"2026-08-11T07:13:20Z"}}}' \
    | STATUSLINE_COLUMNS=200 "$COMPACT")"
  ck_has 'ISO reset time degrades to a placeholder' "$out" 'mm-dd hh:mm'

  out="$(render "$fixture_korean" 200 auto)"
  ck_has 'Korean directory renders' "$out" '한글-프로젝트-디렉터리'

  out="$(render "$fixture_git" 200 auto)"
  ck_has 'git branch detected' "$out" 'feature/adaptive-statusline'

  out="$(printf '%s' '{"model":{"display_name":"Opus 4.5"},"workspace":{"current_dir":"'"$HOME"'"}}' \
    | STATUSLINE_COLUMNS=200 STATUSLINE_DIR_STYLE=path "$COMPACT")"
  ck_has 'DIR_STYLE=path abbreviates $HOME' "$out" '~'

  out="$(render "$fixture_plain" 200 auto)"
  ck_has 'display_name wins over id' "$out" 'Opus 4.5'
  out="$(render "$fixture_git" 200 auto)"
  ck_has 'claude- prefix stripped' "$out" 'opus-4-5-20251101'
  case "$out" in *'claude-opus'*) bad 'claude- prefix stripped: still present' ;; *) ok ;; esac

  # CJK-ambiguous mode widens the bar glyphs, so the same width must compress further
  local a b
  a="$(render "$fixture_plain" 150 auto | measure | cut -d' ' -f1)"
  b="$(printf '%s' "$(cat "$fixture_plain")" | STATUSLINE_COLUMNS=150 STATUSLINE_PADDING=0 \
       STATUSLINE_CJK_AMBIGUOUS=1 "$COMPACT" | measure | cut -d' ' -f1)"
  if [ "$b" -le 150 ]; then ok; else bad "CJK_AMBIGUOUS=1 overflows: $b > 150"; fi

  # full.sh is unchanged, but it should at least still run
  out="$(render "$fixture_plain" 200 auto)"
  printf '%s' "$(cat "$fixture_plain")" | "$FULL" >/dev/null 2>&1
  ck 'full variant exits 0' "$?" '0'
}

# ------------------------------------------------------------- installer
run_install_tests() {
  section 'installer'
  local h out rc good bad_repo n

  h="$work/i-default"; mkdir -p "$h"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" </dev/null >/dev/null 2>&1
  ck 'piped install exits 0' "$?" '0'
  ck 'defaults to compact' "$(cat "$h/.claude/.statusline-variant" 2>/dev/null)" 'compact'
  ck 'script is executable' "$([ -x "$h/.claude/statusline.sh" ] && echo yes)" 'yes'
  ck 'script matches variants/compact.sh' \
     "$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)" \
     "$(sha256sum variants/compact.sh | cut -d' ' -f1)"

  h="$work/i-full"; mkdir -p "$h"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" --full -y </dev/null >/dev/null 2>&1
  ck '--full exits 0' "$?" '0'
  ck '--full marker' "$(cat "$h/.claude/.statusline-variant")" 'full'
  ck '--full matches variants/full.sh' \
     "$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)" \
     "$(sha256sum variants/full.sh | cut -d' ' -f1)"
  ck 'settings command' "$(jq -r '.statusLine.command' "$h/.claude/settings.json")" \
     "$h/.claude/statusline.sh"
  ck 'settings type' "$(jq -r '.statusLine.type' "$h/.claude/settings.json")" 'command'
  ck 'no padding written' "$(jq -r '.statusLine.padding // "absent"' "$h/.claude/settings.json")" 'absent'

  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" -y </dev/null >/dev/null 2>&1
  ck 'reinstall remembers the variant' "$(cat "$h/.claude/.statusline-variant")" 'full'
  ck 'reinstall backs up the script' \
     "$(ls "$h"/.claude/statusline.sh.backup.* 2>/dev/null | wc -l | tr -d ' ')" '1'

  h="$work/i-bad"; mkdir -p "$h"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" --variant nope -y </dev/null >/dev/null 2>&1
  ck 'unknown variant exits 2' "$?" '2'
  ck 'unknown variant installs nothing' "$([ -e "$h/.claude/statusline.sh" ] && echo yes || echo no)" 'no'

  HOME="$h" bash "$INSTALL" --bogus </dev/null >/dev/null 2>&1
  ck 'unknown flag exits 2' "$?" '2'
  HOME="$h" bash "$INSTALL" -h </dev/null >/dev/null 2>&1
  ck '--help exits 0' "$?" '0'

  h="$work/i-merge"; mkdir -p "$h/.claude"
  printf '%s\n' '{"theme":"dark","statusLine":{"type":"command","command":"/old.sh","padding":2,"refreshInterval":500,"hideVimModeIndicator":true}}' \
    > "$h/.claude/settings.json"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" --compact -y </dev/null >/dev/null 2>&1
  ck 'merge keeps padding'         "$(jq -r '.statusLine.padding' "$h/.claude/settings.json")" '2'
  ck 'merge keeps refreshInterval' "$(jq -r '.statusLine.refreshInterval' "$h/.claude/settings.json")" '500'
  ck 'merge keeps hideVimMode'     "$(jq -r '.statusLine.hideVimModeIndicator' "$h/.claude/settings.json")" 'true'
  ck 'merge keeps sibling keys'    "$(jq -r '.theme' "$h/.claude/settings.json")" 'dark'
  ck 'merge updates command'       "$(jq -r '.statusLine.command' "$h/.claude/settings.json")" "$h/.claude/statusline.sh"
  ck 'settings backed up' \
     "$(ls "$h"/.claude/settings.json.backup.* 2>/dev/null | wc -l | tr -d ' ')" '1'

  h="$work/i-nosettings"; mkdir -p "$h/.claude"
  printf '{"theme":"light"}\n' > "$h/.claude/settings.json"
  good="$(sha256sum "$h/.claude/settings.json" | cut -d' ' -f1)"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" bash "$INSTALL" --compact -n </dev/null >/dev/null 2>&1
  ck '-n leaves settings alone' "$(sha256sum "$h/.claude/settings.json" | cut -d' ' -f1)" "$good"
  ck '-n still installs the script' "$([ -x "$h/.claude/statusline.sh" ] && echo yes)" 'yes'

  h="$work/i-custom"; mkdir -p "$h"
  HOME="$h" CLAUDE_CONFIG_DIR="$h/custom" CLAUDE_STATUSLINE_REPO_URL="file://$PWD" \
    bash "$INSTALL" --compact -y </dev/null >/dev/null 2>&1
  ck 'CLAUDE_CONFIG_DIR honoured' "$([ -x "$h/custom/statusline.sh" ] && echo yes)" 'yes'
  ck 'CLAUDE_CONFIG_DIR skips ~/.claude' "$([ -e "$h/.claude" ] && echo yes || echo no)" 'no'

  h="$work/i-env"; mkdir -p "$h"
  HOME="$h" CLAUDE_STATUSLINE_VARIANT=full CLAUDE_STATUSLINE_REPO_URL="file://$PWD" \
    bash "$INSTALL" -y </dev/null >/dev/null 2>&1
  ck 'CLAUDE_STATUSLINE_VARIANT honoured' "$(cat "$h/.claude/.statusline-variant")" 'full'

  # A cut-off download must never replace a working script. bash -n alone is
  # not enough: some truncation points still parse.
  bad_repo="$work/bad-repo"; mkdir -p "$bad_repo/variants"
  h="$work/i-trunc"; mkdir -p "$h/.claude"
  n=250
  while [ "$n" -lt 13000 ]; do
    printf '#!/usr/bin/env bash\necho GOOD\n' > "$h/.claude/statusline.sh"
    chmod +x "$h/.claude/statusline.sh"
    good="$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)"
    head -c "$n" variants/compact.sh > "$bad_repo/variants/compact.sh"
    HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$bad_repo" bash "$INSTALL" --compact -y \
      </dev/null >/dev/null 2>&1
    if [ "$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)" = "$good" ]; then ok
    else bad "truncated download at $n bytes replaced the installed script"; fi
    n=$((n + 250))
  done

  h="$work/i-404"; mkdir -p "$h/.claude"
  printf '#!/usr/bin/env bash\necho GOOD\n' > "$h/.claude/statusline.sh"
  good="$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)"
  HOME="$h" CLAUDE_STATUSLINE_REPO_URL="file://$work/does-not-exist" bash "$INSTALL" --compact -y \
    </dev/null >/dev/null 2>&1
  ck 'failed download exits nonzero' "$([ $? -ne 0 ] && echo yes)" 'yes'
  ck 'failed download leaves the script intact' \
     "$(sha256sum "$h/.claude/statusline.sh" | cut -d' ' -f1)" "$good"
}

# ---------------------------------------------------------------------- main
for f in "$COMPACT" "$FULL" "$INSTALL"; do
  bash -n "$f" || { printf 'syntax error in %s\n' "$f" >&2; exit 1; }
done

case "${1:-all}" in
  width)   run_width_sweep ;;
  edge)    run_edge_cases ;;
  install) run_install_tests ;;
  all)     run_width_sweep; run_edge_cases; run_install_tests ;;
  *)       printf 'usage: %s [all|width|edge|install]\n' "$0" >&2; exit 2 ;;
esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
