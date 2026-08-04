#!/usr/bin/env bash
# statusline.sh — adaptive Claude Code statusline
#
#   model | project dir | git branch | context left | 5h left | 7d left
#
# Renders on ONE line when the terminal is wide enough; otherwise the usage
# segments wrap to a second line, shrinking bars/labels as space runs out.
#
# Env overrides:
#   STATUSLINE_COLUMNS        force terminal width (integer)
#   STATUSLINE_PADDING        columns reserved by Claude Code's box (default 4)
#   STATUSLINE_LINES          auto | 1 | 2            (default auto)
#   STATUSLINE_DIR_STYLE      basename | path         (default basename)
#   STATUSLINE_CJK_AMBIGUOUS  1 => count box/block glyphs as 2 cells
set -u

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  printf '[statusline] jq not found\n'
  exit 0
fi

# ---------------------------------------------------------------- appearance
GREEN=$'\033[92m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[31m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

SEP_WIDE="${DIM}   |   ${RESET}"
SEP_TIGHT="${DIM} | ${RESET}"
RECORD_SEP=$'\x1e'
RESET_PLACEHOLDER_FULL='mm-dd hh:mm'
RESET_PLACEHOLDER_SHORT='hh:mm'

# ------------------------------------------------------------------- parsing
# Every numeric derivation happens inside this single jq pass, so the render
# loop below stays pure bash (a statusline reruns on every frame).
model_label=''; current_dir=''
ctx_has=0; ctx_pct=0; ctx_tok_full=''; ctx_tok_short=''
five_has=0; five_pct=0; five_reset=''
seven_has=0; seven_pct=0; seven_reset=''

parsed="$(printf '%s' "$input" | jq -r '
  def n: if type == "number" then . else 0 end;
  def clampi: n | (if . < 0 then 0 elif . > 100 then 100 else . end) | round;
  def kfmt: n | if . >= 1000000 then (((. / 100000) | round) / 10 | tostring) + "M"
                else (((. + 999) / 1000) | floor | tostring) + "k" end;
  def s($v): ($v // "" | tostring | @sh);

  (.context_window // {})                                as $c
  | (.rate_limits // {})                                 as $r
  | (($c.context_window_size // 0) | n)                  as $size
  | ((($c.current_usage.input_tokens // 0) | n)
     + (($c.current_usage.cache_creation_input_tokens // 0) | n)
     + (($c.current_usage.cache_read_input_tokens // 0) | n))   as $used
  | (if $size > 0 then (if $size - $used < 0 then 0 else $size - $used end)
     else 0 end)                                         as $left
  | [
      "model_label=" + s((.model.display_name // .model.id // "unknown-model")
                         | sub("^claude-"; "")),
      "current_dir=" + s(.workspace.current_dir // .cwd // "~"),

      "ctx_has=" + (if $c.remaining_percentage != null then "1" else "0" end),
      "ctx_pct=" + ($c.remaining_percentage | clampi | tostring),
      "ctx_tok_short=" + s(if $size > 0 then ($left | kfmt) else "" end),
      "ctx_tok_full="  + s(if $size > 0 then ($left | kfmt) + "/" + ($size | kfmt) else "" end),

      "five_has="   + (if $r.five_hour.used_percentage != null then "1" else "0" end),
      "five_pct="   + ((100 - ($r.five_hour.used_percentage | n)) | clampi | tostring),
      "five_reset=" + s($r.five_hour.resets_at),

      "seven_has="   + (if $r.seven_day.used_percentage != null then "1" else "0" end),
      "seven_pct="   + ((100 - ($r.seven_day.used_percentage | n)) | clampi | tostring),
      "seven_reset=" + s($r.seven_day.resets_at)
    ] | .[]
' 2>/dev/null)" || {
  printf '[statusline] invalid input\n'
  exit 0
}
[ -z "$parsed" ] && { printf '[statusline] invalid input\n'; exit 0; }
eval "$parsed"

# ------------------------------------------------------------- derived paths
dir_base="${current_dir%/}"
dir_base="${dir_base##*/}"
[ -z "$dir_base" ] && dir_base="$current_dir"
dir_path="${current_dir%/}"
case "$dir_path" in
  "$HOME")   dir_path='~' ;;
  "$HOME"/*) dir_path="~${dir_path#"$HOME"}" ;;
esac
[ -z "$dir_path" ] && dir_path="$dir_base"

_color=''; _bar=''; _ell=''; _f=''; _e=''
_seg_dir=''; _seg_branch=''; _seg_ctx=''; _seg_rate=''; _block=''

branch_name=''
if git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
  branch_name="$(git -C "$current_dir" branch --show-current 2>/dev/null)"
  [ -z "$branch_name" ] && branch_name="$(git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)"
  [ -z "$branch_name" ] && branch_name='unknown'
fi

# One date(1) call per window emits both the long and short reset strings.
# Handles BSD (date -r) and GNU (date -d @) alike.
resolve_reset() { # <epoch> -> "mm-dd HH:MM|HH:MM"
  local epoch="${1:-}" out
  case "$epoch" in ''|null|*[!0-9]*) printf '|'; return ;; esac
  out="$(date -r "$epoch" '+%m-%d %H:%M|%H:%M' 2>/dev/null)" \
    || out="$(date -d "@$epoch" '+%m-%d %H:%M|%H:%M' 2>/dev/null)" \
    || out="$epoch|$epoch"
  printf '%s' "$out"
}
five_r="$(resolve_reset "$five_reset")";   five_full="${five_r%%|*}";   five_short="${five_r#*|}"
seven_r="$(resolve_reset "$seven_reset")"; seven_full="${seven_r%%|*}"; seven_short="${seven_r#*|}"
[ -z "$five_full" ]  && { five_full="$RESET_PLACEHOLDER_FULL";  five_short="$RESET_PLACEHOLDER_SHORT"; }
[ -z "$seven_full" ] && { seven_full="$RESET_PLACEHOLDER_FULL"; seven_short="$RESET_PLACEHOLDER_SHORT"; }

# --------------------------------------------------- pure-bash render pieces
# Every helper writes into a global via printf -v instead of returning through
# $( ), because a statusline reruns on each frame and ~130 subshell forks per
# render was the single biggest cost in the previous version.

set_color() { # <pct> -> _color
  if   [ "$1" -ge 50 ]; then _color="$GREEN"
  elif [ "$1" -ge 20 ]; then _color="$ORANGE"
  else                       _color="$RED"
  fi
}

set_bar() { # <pct> <width> <color> -> _bar ; width 0 => empty
  local pct="$1" width="$2" color="${3:-}" filled empty out
  _bar=''
  [ "$width" -le 0 ] && return
  filled=$((pct * width / 100))
  [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  empty=$((width - filled))
  out=''
  if [ "$filled" -gt 0 ]; then printf -v _f "%${filled}s"; out="${_f// /▓}"; fi
  if [ "$empty" -gt 0 ];  then printf -v _e "%${empty}s";  out="${out}${_e// /░}"; fi
  printf -v _bar ' %s[%s]%s' "$color" "$out" "$RESET"
}

set_ellipsized() { # <text> <max chars> -> _ell
  # Bash slices by character only under a UTF-8 locale; skip non-ASCII input
  # rather than risk cutting a multi-byte sequence in half under LC_ALL=C.
  case "$1" in *[!\ -~]*) _ell="$1"; return ;; esac
  if [ "${#1}" -gt "$2" ] && [ "$2" -gt 1 ]; then _ell="${1:0:$(($2 - 1))}…"
  else _ell="$1"; fi
}

set_dir() { # <basename|path|tiny> -> _seg_dir
  case "$1" in
    path) _seg_dir="📁 $dir_path" ;;
    tiny) set_ellipsized "$dir_base" 14; _seg_dir="📁 $_ell" ;;
    *)    _seg_dir="📁 $dir_base" ;;
  esac
}

set_branch() { # <full|tiny> -> _seg_branch
  if [ -z "$branch_name" ]; then _seg_branch=''; return; fi
  if [ "$1" = tiny ]; then set_ellipsized "$branch_name" 14; _seg_branch="🌿 $_ell"
  else _seg_branch="🌿 $branch_name"; fi
}

set_context() { # <bar width> <full|short|none> -> _seg_ctx
  local bw="$1" ts="$2" tokens=''
  if [ "$ctx_has" != 1 ]; then
    set_bar 0 "$bw" ''
    printf -v _seg_ctx '💬  --%%%s' "$_bar"
    return
  fi
  set_color "$ctx_pct"
  case "$ts" in
    full)  [ -n "$ctx_tok_full" ]  && tokens=" $ctx_tok_full" ;;
    short) [ -n "$ctx_tok_short" ] && tokens=" $ctx_tok_short" ;;
  esac
  set_bar "$ctx_pct" "$bw" "$_color"
  printf -v _seg_ctx '💬 %s%3d%%%s%s%s' "$_color" "$ctx_pct" "$RESET" "$_bar" "$tokens"
}

set_rate() { # <5h|7d> <bar width> <full|short> -> _seg_rate
  local label="$1" bw="$2" rs="$3" has pct reset icon
  if [ "$label" = '5h' ]; then
    has="$five_has"; pct="$five_pct"
    if [ "$rs" = short ]; then reset="$five_short"; else reset="$five_full"; fi
  else
    has="$seven_has"; pct="$seven_pct"
    if [ "$rs" = short ]; then reset="$seven_short"; else reset="$seven_full"; fi
  fi
  if [ "$has" != 1 ]; then
    set_bar 0 "$bw" ''
    printf -v _seg_rate '⏳ %s  --%%%s (%s)' "$label" "$_bar" "$reset"
    return
  fi
  set_color "$pct"
  if [ "$pct" -eq 0 ]; then icon='⌛'; else icon='⏳'; fi
  set_bar "$pct" "$bw" "$_color"
  printf -v _seg_rate '%s %s %s%3d%%%s%s (%s)' "$icon" "$label" "$_color" "$pct" \
    "$RESET" "$_bar" "$reset"
}

# ------------------------------------------------------------ terminal width
detect_columns() {
  local cols pad
  cols="${STATUSLINE_COLUMNS:-${COLUMNS:-}}"
  case "$cols" in ''|*[!0-9]*) cols='' ;; esac
  if [ -z "$cols" ]; then
    cols="$( { stty size </dev/tty | awk '{print $2}'; } 2>/dev/null )"
    case "$cols" in ''|*[!0-9]*) cols='' ;; esac
  fi
  [ -z "$cols" ] && cols=120
  pad="${STATUSLINE_PADDING:-4}"
  case "$pad" in ''|*[!0-9]*) pad=4 ;; esac
  [ "$cols" -gt "$pad" ] && cols=$((cols - pad))
  printf '%s' "$cols"
}

# Prints the first candidate block (records separated by \x1e) whose every
# line fits in $1 display columns; falls back to the last block.
pick_layout() {
  perl -CSD -e '
    my ($cols, $amb) = @ARGV;
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
      return 2 if $amb && (($o >= 0x2190 && $o <= 0x21FF)
                        || ($o >= 0x2300 && $o <= 0x23FF)
                        || ($o >= 0x2500 && $o <= 0x25FF));
      return 1;
    }
    sub width {
      my $s = shift;
      $s =~ s/\e\[[0-9;]*m//g;
      my $n = 0;
      $n += cw(ord($_)) for split //, $s;
      return $n;
    }
    local $/;
    my @blocks = grep { length } split /\x1e/, scalar <STDIN>;
    exit 0 unless @blocks;
    for my $b (@blocks) {
      my $ok = 1;
      for my $l (split /\n/, $b) { if (width($l) > $cols) { $ok = 0; last } }
      if ($ok) { print $b; exit 0 }
    }
    print $blocks[-1];
  ' "$1" "$2"
}

# --------------------------------------------------------------- composition
cols="$(detect_columns)"
amb=0
case "${STATUSLINE_CJK_AMBIGUOUS:-0}" in 1|true|yes) amb=1 ;; esac
dir_style="${STATUSLINE_DIR_STYLE:-basename}"
mode="${STATUSLINE_LINES:-auto}"

# Compactness levels — bar width | context tokens | reset time | separator
#   0 : 10 | 144k/200k | mm-dd hh:mm | wide
#   1 : 10 | 144k      | mm-dd hh:mm | tight
#   2 :  6 | 144k      | mm-dd hh:mm | tight
#   3 :  – | 144k      | mm-dd hh:mm | tight
#   4 :  – | –         | hh:mm       | tight
#   5 :  – | –         | hh:mm       | tight + truncated dir/branch
build() { # <level> <one|two> -> _block
  local lvl="$1" layout="$2" bw ts rs sep dstyle=basename bstyle=full l='' r=''
  case "$lvl" in
    0) bw=10; ts=full;  rs=full;  sep="$SEP_WIDE" ;;
    1) bw=10; ts=short; rs=full;  sep="$SEP_TIGHT" ;;
    2) bw=6;  ts=short; rs=full;  sep="$SEP_TIGHT" ;;
    3) bw=0;  ts=short; rs=full;  sep="$SEP_TIGHT" ;;
    4) bw=0;  ts=none;  rs=short; sep="$SEP_TIGHT" ;;
    *) bw=0;  ts=none;  rs=short; sep="$SEP_TIGHT"; dstyle=tiny; bstyle=tiny ;;
  esac
  [ "$dir_style" = path ] && [ "$lvl" -le 1 ] && dstyle=path

  set_dir "$dstyle"; set_branch "$bstyle"
  l="${BOLD}${ORANGE}[${model_label}]${RESET}"
  [ -n "$_seg_dir" ]    && l="${l}${sep}${_seg_dir}"
  [ -n "$_seg_branch" ] && l="${l}${sep}${_seg_branch}"

  set_context "$bw" "$ts"; r="$_seg_ctx"
  set_rate 5h "$bw" "$rs"; r="${r}${sep}${_seg_rate}"
  set_rate 7d "$bw" "$rs"; r="${r}${sep}${_seg_rate}"

  if [ "$layout" = one ]; then _block="${l}${sep}${r}"
  else _block="${l}"$'\n'"${r}"; fi
}

candidates=''
add() { build "$1" "$2"; candidates="${candidates}${_block}${RECORD_SEP}"; }

case "$mode" in
  1) for lvl in 0 1 2 3 4 5; do add "$lvl" one; done ;;
  2) for lvl in 0 1 2 3 4 5; do add "$lvl" two; done ;;
  *) # prefer one line while it stays readable, then wrap
     for lvl in 0 1 2;       do add "$lvl" one; done
     for lvl in 0 1 2 3 4 5; do add "$lvl" two; done ;;
esac

printf '%s' "$candidates" | pick_layout "$cols" "$amb"
printf '\n'
exit 0
