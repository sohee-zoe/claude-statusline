#!/usr/bin/env bash
set -u

input="$(cat)"

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

parsed_vars="$(printf '%s' "$input" | jq -r '
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
' 2>/dev/null)" || {
  printf '[statusline] invalid input\n'
  exit 0
}
eval "$parsed_vars"
model_label="${model_id#claude-}"
display_dir="${current_dir%/}"
display_dir="${display_dir##*/}"
[ -z "$display_dir" ] && display_dir="$current_dir"

number_or_zero() {
  awk -v value="${1:-}" 'BEGIN {
    if (value == "" || value !~ /^-?[0-9]+([.][0-9]+)?$/) value = 0
    printf "%d", value
  }'
}

number_or_empty() {
  awk -v value="${1:-}" 'BEGIN {
    if (value ~ /^-?[0-9]+([.][0-9]+)?$/) printf "%s", value
  }'
}

integer_or_empty() {
  awk -v value="${1:-}" 'BEGIN {
    if (value ~ /^-?[0-9]+([.][0-9]+)?$/) printf "%d", value
  }'
}

number_is_nonzero() {
  awk -v value="${1:-}" 'BEGIN {
    exit !(value ~ /^-?[0-9]+([.][0-9]+)?$/ && value + 0 != 0)
  }'
}

clamp_round_percent() {
  awk -v value="$1" 'BEGIN {
    if (value == "" || value !~ /^-?[0-9]+([.][0-9]+)?$/) value = 0
    if (value < 0) value = 0
    if (value > 100) value = 100
    printf "%d", value + 0.5
  }'
}

remaining_from_used() {
  awk -v used="$1" 'BEGIN {
    if (used == "" || used !~ /^-?[0-9]+([.][0-9]+)?$/) used = 0
    remaining = 100 - used
    if (remaining < 0) remaining = 0
    if (remaining > 100) remaining = 100
    printf "%d", remaining + 0.5
  }'
}

color_for_remaining() {
  local remaining="$1"

  if [ "$remaining" -ge 50 ]; then
    printf '%s' "$GREEN"
  elif [ "$remaining" -ge 20 ]; then
    printf '%s' "$ORANGE"
  else
    printf '%s' "$RED"
  fi
}

join_part() {
  local current="$1"
  local part="$2"

  if [ -z "$part" ]; then
    printf '%s' "$current"
  elif [ -z "$current" ]; then
    printf '%s' "$part"
  else
    printf '%s%s%s' "$current" "$SEP" "$part"
  fi
}

visible_length() {
  printf '%s' "$1" | perl -CS -Mutf8 -pe 's/\e\[[0-9;]*m//g' | awk '{ print length }'
}

pad_visible_right() {
  local text="$1"
  local width="$2"
  local length pad

  length="$(visible_length "$text")"
  pad=$((width - length))
  printf '%s' "$text"
  if [ "$pad" -gt 0 ]; then
    printf '%*s' "$pad" ''
  fi
}

rate_icon_for_remaining() {
  local remaining="$1"

  if [ "$remaining" -eq 0 ]; then
    printf '⌛️'
  else
    printf '⏳'
  fi
}

bar_for_percent() {
  local pct="$1"
  local color="${2:-}"
  local reset_color=''
  local filled empty bar

  pct="$(clamp_round_percent "$pct")"
  filled=$((pct / 10))
  if [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ]; then
    filled=1
  fi
  empty=$((10 - filled))

  bar=""
  if [ "$filled" -gt 0 ]; then
    printf -v FILL "%${filled}s"
    bar="${bar}${FILL// /▓}"
  fi
  if [ "$empty" -gt 0 ]; then
    printf -v PAD "%${empty}s"
    bar="${bar}${PAD// /░}"
  fi

  [ -n "$color" ] && reset_color="$RESET"
  printf '%s%4s%% [%s]%s' "$color" "$pct" "$bar" "$reset_color"
}

format_reset() {
  local epoch="${1:-}"
  if [ -z "$epoch" ] || [ "$epoch" = "null" ]; then
    printf '%s' "$RATE_RESET_PLACEHOLDER"
    return
  fi

  if date -r "$epoch" '+%m-%d %H:%M' >/dev/null 2>&1; then
    date -r "$epoch" '+%m-%d %H:%M'
  else
    date -d "@$epoch" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$epoch"
  fi
}

format_k_tokens() {
  local tokens="$1"

  awk -v tokens="$tokens" 'BEGIN {
    if (tokens == "" || tokens !~ /^[0-9]+([.][0-9]+)?$/) tokens = 0
    if (tokens >= 1000000) {
      printf "%.1fm", tokens / 1000000
    } else {
      printf "%dk", int((tokens + 999) / 1000)
    }
  }'
}

context_tokens_segment() {
  local total input cache_create cache_read used remaining

  total="$ctx_window_size"
  if [ -z "$total" ]; then
    return
  fi

  total="$(number_or_zero "$total")"
  if [ "$total" -le 0 ]; then
    return
  fi

  input="$(number_or_zero "$ctx_input_tokens")"
  cache_create="$(number_or_zero "$ctx_cache_creation_tokens")"
  cache_read="$(number_or_zero "$ctx_cache_read_tokens")"

  used=$((input + cache_create + cache_read))
  remaining=$((total - used))
  [ "$remaining" -lt 0 ] && remaining=0

  printf ' %s / %s' "$(format_k_tokens "$remaining")" "$(format_k_tokens "$total")"
}

tokens_segment() {
  local input output cache_create cache_read total current

  input="$(number_or_zero "$ctx_total_input_tokens")"
  output="$(number_or_zero "$ctx_total_output_tokens")"
  total=$((input + output))

  input="$(number_or_zero "$ctx_input_tokens")"
  output="$(number_or_zero "$ctx_output_tokens")"
  cache_create="$(number_or_zero "$ctx_cache_creation_tokens")"
  cache_read="$(number_or_zero "$ctx_cache_read_tokens")"
  current=$((input + output + cache_create + cache_read))

  if [ "$total" -eq 0 ] && [ "$current" -eq 0 ]; then
    return
  fi

  printf '💎 tokens   Σ %s (+%s)' "$(format_k_tokens "$total")" "$(format_k_tokens "$current")"
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
      rate_label="$(pad_visible_right "⏳ $label" "$label_width")"
    fi
    printf '%s%s%s%s (%s)' "$BOLD" "$rate_label" "$RESET" "$FIXED_EMPTY_BAR" "$RATE_RESET_PLACEHOLDER"
  else
    remaining="$(remaining_from_used "$used")"
    color="$(color_for_remaining "$remaining")"
    icon="$(rate_icon_for_remaining "$remaining")"
    reset_text="$(format_reset "$reset")"
    if [ "$window" = "five_hour" ]; then
      if [ "$remaining" -eq 0 ]; then
        rate_label="$icon 5h      "
      else
        rate_label="$icon 5h      "
      fi
    else
      rate_label="$(pad_visible_right "$icon $label" "$label_width")"
    fi
    printf '%s%s%s %s (%s)' "$BOLD" "$rate_label" "$RESET" "$(bar_for_percent "$remaining" "$color")" "$reset_text"
  fi
}

context_segment() {
  local remaining color tokens label segment

  printf -v label '%-10s' '💬 context'

  remaining="$ctx_remaining"
  if [ -z "$remaining" ]; then
    segment="$(printf '%s%s%s  %s' "$BOLD" "$label" "$RESET" "$EMPTY_BAR")"
    pad_visible_right "$segment" "$DETAIL_FIRST_SEGMENT_WIDTH"
    return
  fi

  remaining="$(clamp_round_percent "$remaining")"
  color="$(color_for_remaining "$remaining")"
  tokens="$(context_tokens_segment)"
  
  if [ -n "$tokens" ]; then
    segment="$(printf '%s%s%s  %s %s' "$BOLD" "$label" "$RESET" "$(bar_for_percent "$remaining" "$color")" "$tokens")"
  else
    segment="$(printf '%s%s%s  %s' "$BOLD" "$label" "$RESET" "$(bar_for_percent "$remaining" "$color")")"
  fi
  pad_visible_right "$segment" "$DETAIL_FIRST_SEGMENT_WIDTH"
}

lines_segment() {
  local added removed

  added="$lines_added"
  removed="$lines_removed"

  if [ -z "$added" ] && [ -z "$removed" ]; then
    return
  fi

  added="$(number_or_zero "$added")"
  removed="$(number_or_zero "$removed")"
  if [ "$added" -eq 0 ] && [ "$removed" -eq 0 ]; then
    return
  fi
  local added_text removed_text added_fmt removed_fmt
  printf -v added_fmt -- '+ %d' "$added"
  printf -v removed_fmt -- '- %d' "$removed"
  if [ "$added" -gt 0 ]; then
    added_text="$(printf '%s%s%s' "$GREEN" "$added_fmt" "$RESET")"
  else
    added_text="$added_fmt"
  fi
  if [ "$removed" -gt 0 ]; then
    removed_text="$(printf '%s%s%s' "$RED" "$removed_fmt" "$RESET")"
  else
    removed_text="$removed_fmt"
  fi
  printf '🧾 lines   %s     %s   ' "$added_text" "$removed_text"
}

git_branch_segment() {
  local branch

  if ! git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    return
  fi

  branch="$(git -C "$current_dir" branch --show-current 2>/dev/null)"
  [ -z "$branch" ] && branch="$(git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)"
  printf '🌿 %s' "${branch:-unknown}"
}

cost_duration_segment() {
  local cost duration output

  cost="$total_cost"
  duration="$total_duration_ms"

  output=""
  cost="$(number_or_empty "$cost")"
  if [ -n "$cost" ]; then
    local cost_fmt
    cost_fmt="$(printf '$%.2f' "$cost")"
    output="$(printf '💰 %s%7s%s' "$YELLOW" "$cost_fmt" "$RESET")"
  fi

  duration="$(integer_or_empty "$duration")"
  if [ -n "$duration" ]; then
    local total_sec hours mins duration_text
    total_sec=$((duration / 1000))
    hours=$((total_sec / 3600))
    mins=$(((total_sec % 3600) / 60))
    duration_text="$(printf '⏳ %02d:%02d' "$hours" "$mins")"
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
  [ -n "$effort" ] && output="$(join_part "$output" "⚙️ effort    $effort")"
  [ -n "$thinking" ] && output="$(join_part "$output" "💭 thinking    $thinking")"
  [ -n "$agent" ] && output="$(join_part "$output" "🤖 agent $agent")"

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
first_line="$(join_part "$first_line" "$git_branch")"
detail_line=""
detail_line="$(join_part "$detail_line" "$context")"
detail_line="$(join_part "$detail_line" "$lines")"
detail_line="$(join_part "$detail_line" "$tokens")"
printf '%s\n' "$first_line"
if [ -n "$detail_line" ]; then
  printf '%s\n' "$detail_line"
fi
printf '%s\n' "$usage"
if [ -n "$meta" ]; then
  printf '%s\n' "$meta"
fi

exit 0
