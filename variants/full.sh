#!/usr/bin/env bash
set -u
shopt -s extglob

IFS= read -r -d '' input

if ! command -v jq >/dev/null 2>&1; then
  printf '[statusline] jq not found\n'
  exit 0
fi

GREEN=$'\033[92m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'
EMPTY_BAR='  --% [          ]'
FIXED_EMPTY_BAR='  --% [          ]'
SEP='   |   '
RATE_RESET_PLACEHOLDER='mm-dd hh:mm'
DETAIL_FIRST_SEGMENT_WIDTH=66
SEVEN_DAY_LABEL_WIDTH=12

_r=''
model_id=''
current_dir=''
ctx_remaining=''
ctx_window_size=''
ctx_input_tokens=''
ctx_output_tokens=''
ctx_cache_creation_tokens=''
ctx_cache_read_tokens=''
ctx_total_input_tokens=''
ctx_total_output_tokens=''
five_used=''
five_reset=''
seven_used=''
seven_reset=''
lines_added=''
lines_removed=''
total_cost=''
total_duration_ms=''
effort_level=''
thinking_state=''
agent_name=''
account_has_limits=''

parsed_vars="$(jq -r '
  def s($v): ($v // "" | tostring | @sh);
  [
    "model_id=" + s(.model.id // .model.display_name // "unknown-model"),
    "current_dir=" + s(.workspace.current_dir // .cwd // "~"),
    "ctx_remaining=" + s(.context_window.remaining_percentage),
    "ctx_window_size=" + s(.context_window.context_window_size),
    "ctx_input_tokens=" + s(.context_window.current_usage.input_tokens),
    "ctx_output_tokens=" + s(.context_window.current_usage.output_tokens),
    "ctx_cache_creation_tokens=" + s(.context_window.current_usage.cache_creation_input_tokens),
    "ctx_cache_read_tokens=" + s(.context_window.current_usage.cache_read_input_tokens),
    "ctx_total_input_tokens=" + s(.context_window.total_input_tokens),
    "ctx_total_output_tokens=" + s(.context_window.total_output_tokens),
    "five_used=" + s(.rate_limits.five_hour.used_percentage),
    "five_reset=" + s(.rate_limits.five_hour.resets_at),
    "seven_used=" + s(.rate_limits.seven_day.used_percentage),
    "seven_reset=" + s(.rate_limits.seven_day.resets_at),
    "lines_added=" + s(.cost.total_lines_added),
    "lines_removed=" + s(.cost.total_lines_removed),
    "total_cost=" + s(.cost.total_cost_usd),
    "total_duration_ms=" + s(.cost.total_duration_ms),
    "effort_level=" + s(.effort.level),
    "thinking_state=" + s(if .thinking.enabled == true then "on" elif .thinking.enabled == false then "off" else "" end),
    "agent_name=" + s(.agent.name),
    "account_has_limits=" + s(if (.rate_limits | type) == "object" and ((.rate_limits.five_hour.used_percentage? != null) or (.rate_limits.seven_day.used_percentage? != null)) then "yes" else "no" end)
  ] | .[]
' <<<"$input" 2>/dev/null)" || {
  printf '[statusline] invalid input\n'
  exit 0
}
eval "$parsed_vars"
model_label="${model_id#claude-}"
display_dir="${current_dir%/}"
display_dir="${display_dir##*/}"
[ -z "$display_dir" ] && display_dir="$current_dir"

number_or_zero() { # <value> -> _r (truncated integer, 0 if not numeric)
  _r=0
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] || return 0
  _r=$((10#${BASH_REMATCH[2]}))
  [ -n "${BASH_REMATCH[1]}" ] && _r=$((-_r))
  return 0
}

number_or_empty() { # <value> -> _r (value if numeric, else empty)
  _r=''
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] && _r="$1"
  return 0
}

integer_or_empty() { # <value> -> _r (truncated integer if numeric, else empty)
  _r=''
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] && number_or_zero "$1"
  return 0
}

number_is_nonzero() {
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] && [[ ! "$1" =~ ^-?0+(\.0+)?$ ]]
}

clamp_round_percent() { # <value> -> _r (0..100, rounded half up)
  _r=0
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] || return 0
  [ -n "${BASH_REMATCH[1]}" ] && return 0
  _r=$((10#${BASH_REMATCH[2]}))
  [ "${BASH_REMATCH[4]:0:1}" -ge 5 ] 2>/dev/null && _r=$((_r + 1))
  [ "$_r" -gt 100 ] && _r=100
  return 0
}

remaining_from_used() { # <used percent> -> _r (100 - used, 0..100, rounded half up)
  local int frac rest
  _r=100
  [[ "${1:-}" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]] || return 0
  [ -n "${BASH_REMATCH[1]}" ] && return 0
  int=$((10#${BASH_REMATCH[2]}))
  frac="${BASH_REMATCH[4]:-0}"
  if [ "$int" -ge 100 ]; then _r=0; return 0; fi
  rest="${frac:1}"
  if [[ "$frac" =~ ^0+$ ]]; then
    _r=$((100 - int))
  elif [ "${frac:0:1}" -lt 5 ] || { [ "${frac:0:1}" -eq 5 ] && [[ "${rest:-0}" =~ ^0+$ ]]; }; then
    _r=$((100 - int))
  else
    _r=$((99 - int))
  fi
  return 0
}

color_for_remaining() { # <remaining> -> _r
  if [ "$1" -ge 50 ]; then _r="$GREEN"
  elif [ "$1" -ge 20 ]; then _r="$ORANGE"
  else _r="$RED"
  fi
}

join_part() { # <current> <part> -> _r
  if [ -z "$2" ]; then _r="$1"
  elif [ -z "$1" ]; then _r="$2"
  else _r="$1$SEP$2"
  fi
}

visible_length() { # <text> -> _r (byte length without ANSI codes)
  local LC_ALL=C
  local plain="${1//$'\033'\[+([0-9;])m/}"
  _r="${#plain}"
}

pad_visible_right() { # <text> <width> -> _r
  local text="$1" pad
  visible_length "$text"
  pad=$(($2 - _r))
  if [ "$pad" -gt 0 ]; then printf -v _r '%s%*s' "$text" "$pad" ''
  else _r="$text"
  fi
}

rate_icon_for_remaining() { # <remaining> -> _r
  if [ "$1" -eq 0 ]; then _r='⌛️'; else _r='⏳'; fi
}

bar_for_percent() { # <percent> [color] -> _r
  local color="${2:-}" reset_color='' filled empty bar='' pct
  clamp_round_percent "$1"; pct="$_r"
  filled=$((pct / 10))
  [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  empty=$((10 - filled))

  if [ "$filled" -gt 0 ]; then printf -v FILL "%${filled}s"; bar="${FILL// /▓}"; fi
  if [ "$empty" -gt 0 ]; then printf -v PAD "%${empty}s"; bar="${bar}${PAD// /░}"; fi

  [ -n "$color" ] && reset_color="$RESET"
  printf -v _r '%s%4s%% [%s]%s' "$color" "$pct" "$bar" "$reset_color"
}

format_reset() { # <epoch> -> _r
  local epoch="${1:-}"
  if [ -z "$epoch" ] || [ "$epoch" = "null" ]; then
    _r="$RATE_RESET_PLACEHOLDER"
    return 0
  fi
  if [[ "$epoch" =~ ^[0-9]+$ ]] && printf -v _r '%(%m-%d %H:%M)T' "$epoch" 2>/dev/null; then
    return 0
  fi
  _r="$(date -d "@$epoch" '+%m-%d %H:%M' 2>/dev/null)" \
    || _r="$(date -r "$epoch" '+%m-%d %H:%M' 2>/dev/null)" \
    || _r="$epoch"
}

format_k_tokens() { # <tokens> -> _r
  local t=0 tenths
  [[ "${1:-}" =~ ^([0-9]+)(\.[0-9]+)?$ ]] && t=$((10#${BASH_REMATCH[1]}))
  if [ "$t" -ge 1000000 ]; then
    tenths=$(((t + 50000) / 100000))
    _r="$((tenths / 10)).$((tenths % 10))m"
  else
    _r="$(((t + 999) / 1000))k"
  fi
}

context_tokens_segment() {
  local total input cache_create cache_read used remaining

  total="$ctx_window_size"
  if [ -z "$total" ]; then
    return
  fi

  number_or_zero "$total"; total="$_r"
  if [ "$total" -le 0 ]; then
    return
  fi

  number_or_zero "$ctx_input_tokens"; input="$_r"
  number_or_zero "$ctx_cache_creation_tokens"; cache_create="$_r"
  number_or_zero "$ctx_cache_read_tokens"; cache_read="$_r"

  used=$((input + cache_create + cache_read))
  remaining=$((total - used))
  [ "$remaining" -lt 0 ] && remaining=0

  local rem_k
  format_k_tokens "$remaining"; rem_k="$_r"
  format_k_tokens "$total"
  printf ' %s / %s' "$rem_k" "$_r"
}

tokens_segment() {
  local input output cache_create cache_read total current

  number_or_zero "$ctx_total_input_tokens"; input="$_r"
  number_or_zero "$ctx_total_output_tokens"; output="$_r"
  total=$((input + output))

  number_or_zero "$ctx_input_tokens"; input="$_r"
  number_or_zero "$ctx_output_tokens"; output="$_r"
  number_or_zero "$ctx_cache_creation_tokens"; cache_create="$_r"
  current=$((input + output + cache_create))

  if [ "$total" -eq 0 ] && [ "$current" -eq 0 ]; then
    return
  fi

  local total_k
  format_k_tokens "$total"; total_k="$_r"
  format_k_tokens "$current"
  printf '💎 tokens   Σ %s (+%s)' "$total_k" "$_r"
}

rate_segment() {
  local label="$1"
  local window="$2"
  local used reset remaining color icon reset_text rate_label label_width

  if [ "$window" = "five_hour" ]; then
    used="$five_used"
    reset="$five_reset"
  else
    used="$seven_used"
    reset="$seven_reset"
    label_width="$SEVEN_DAY_LABEL_WIDTH"
  fi

  if [ -z "$used" ]; then
    if [ "$window" = "five_hour" ]; then
      rate_label="⏳ 5h       "
    else
      pad_visible_right "⏳ $label" "$label_width"; rate_label="$_r"
    fi
    printf '%s%s%s%s (%s)' "$BOLD" "$rate_label" "$RESET" "$FIXED_EMPTY_BAR" "$RATE_RESET_PLACEHOLDER"
  else
    remaining_from_used "$used"; remaining="$_r"
    color_for_remaining "$remaining"; color="$_r"
    rate_icon_for_remaining "$remaining"; icon="$_r"
    format_reset "$reset"; reset_text="$_r"
    if [ "$window" = "five_hour" ]; then
      rate_label="$icon 5h      "
    else
      pad_visible_right "$icon $label" "$label_width"; rate_label="$_r"
    fi
    bar_for_percent "$remaining" "$color"
    printf '%s%s%s %s (%s)' "$BOLD" "$rate_label" "$RESET" "$_r" "$reset_text"
  fi
}

context_segment() {
  local remaining color tokens label segment

  printf -v label '%-10s' '💬 context'

  remaining="$ctx_remaining"
  if [ -z "$remaining" ]; then
    printf -v segment '%s%s%s  %s' "$BOLD" "$label" "$RESET" "$EMPTY_BAR"
    pad_visible_right "$segment" "$DETAIL_FIRST_SEGMENT_WIDTH"
    printf '%s' "$_r"
    return
  fi

  clamp_round_percent "$remaining"; remaining="$_r"
  color_for_remaining "$remaining"; color="$_r"
  tokens="$(context_tokens_segment)"
  
  if [ -n "$tokens" ]; then
    bar_for_percent "$remaining" "$color"
    printf -v segment '%s%s%s  %s %s' "$BOLD" "$label" "$RESET" "$_r" "$tokens"
  else
    bar_for_percent "$remaining" "$color"
    printf -v segment '%s%s%s  %s' "$BOLD" "$label" "$RESET" "$_r"
  fi
  pad_visible_right "$segment" "$DETAIL_FIRST_SEGMENT_WIDTH"
  printf '%s' "$_r"
}

lines_segment() {
  local added removed

  added="$lines_added"
  removed="$lines_removed"

  if [ -z "$added" ] && [ -z "$removed" ]; then
    return
  fi

  number_or_zero "$added"; added="$_r"
  number_or_zero "$removed"; removed="$_r"
  if [ "$added" -eq 0 ] && [ "$removed" -eq 0 ]; then
    return
  fi
  local added_text removed_text added_fmt removed_fmt
  printf -v added_fmt -- '+ %d' "$added"
  printf -v removed_fmt -- '- %d' "$removed"
  if [ "$added" -gt 0 ]; then
    printf -v added_text '%s%s%s' "$GREEN" "$added_fmt" "$RESET"
  else
    added_text="$added_fmt"
  fi
  if [ "$removed" -gt 0 ]; then
    printf -v removed_text '%s%s%s' "$RED" "$removed_fmt" "$RESET"
  else
    removed_text="$removed_fmt"
  fi
  printf '🧾 lines   %s     %s   ' "$added_text" "$removed_text"
}

git_branch_segment() {
  local branch

  branch="$(git -C "$current_dir" symbolic-ref --short -q HEAD 2>/dev/null)" \
    || branch="$(git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)" \
    || return 0
  printf '🌿 %s' "${branch:-unknown}"
}

cost_duration_segment() {
  local cost duration output

  cost="$total_cost"
  duration="$total_duration_ms"

  output=""
  number_or_empty "$cost"; cost="$_r"
  if [ -n "$cost" ]; then
    local cost_fmt
    printf -v cost_fmt '$%.2f' "$cost"
    printf -v output '💰 %s%7s%s' "$YELLOW" "$cost_fmt" "$RESET"
  fi

  integer_or_empty "$duration"; duration="$_r"
  if [ -n "$duration" ]; then
    local total_sec hours mins duration_text
    total_sec=$((duration / 1000))
    hours=$((total_sec / 3600))
    mins=$(((total_sec % 3600) / 60))
    printf -v duration_text '⏳ %02d:%02d' "$hours" "$mins"
    if [ -n "$output" ]; then
      output="$output$SEP$duration_text"
    else
      output="$duration_text"
    fi
  fi

  printf '%s' "$output"
}

usage_line() {
  local cost_duration

  # 1. Priority: Show rate limits if we have ANY subscription indicators
  # (Standard: existence of rate_limits object)
  if [ -n "$five_used" ] || [ -n "$seven_used" ] || \
     [ "${account_has_limits:-}" = "yes" ]; then
    printf '%s%s%s' "$five_hour" "$SEP" "$seven_day"
    return
  fi

  # 2. Only show API cost if there is actual non-zero spend
  if number_is_nonzero "$total_cost"; then
    cost_duration="$(cost_duration_segment)"
    if [ -n "$cost_duration" ]; then
      printf '%s' "$cost_duration"
      return
    fi
  fi

  # 3. Final fallback: Subscription-style display
  printf '%s%s%s' "$five_hour" "$SEP" "$seven_day"
}

meta_segments() {
  local effort thinking agent output

  effort="$effort_level"
  thinking="$thinking_state"
  agent="$agent_name"

  output=""
  [ -n "$effort" ] && { join_part "$output" "⚙️ effort    $effort"; output="$_r"; }
  [ -n "$thinking" ] && { join_part "$output" "💭 thinking    $thinking"; output="$_r"; }
  [ -n "$agent" ] && { join_part "$output" "🤖 agent $agent"; output="$_r"; }

  printf '%s' "$output"
}

context="$(context_segment)"
lines="$(lines_segment)"
tokens="$(tokens_segment)"
git_branch="$(git_branch_segment)"
five_hour="$(rate_segment '5h' 'five_hour')"
seven_day="$(rate_segment '7d' 'seven_day')"
usage="$(usage_line)"
meta="$(meta_segments)"

first_line="${BOLD}${ORANGE}[$model_label]${RESET}   📁 $display_dir"
join_part "$first_line" "$git_branch"; first_line="$_r"
detail_line=""
join_part "$detail_line" "$context"; detail_line="$_r"
join_part "$detail_line" "$lines"; detail_line="$_r"
join_part "$detail_line" "$tokens"; detail_line="$_r"
printf '%s\n' "$first_line"
if [ -n "$detail_line" ]; then
  printf '%s\n' "$detail_line"
fi
printf '%s\n' "$usage"
if [ -n "$meta" ]; then
  printf '%s\n' "$meta"
fi

exit 0
