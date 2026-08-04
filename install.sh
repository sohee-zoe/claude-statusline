#!/usr/bin/env bash
set -euo pipefail

repo_url="${CLAUDE_STATUSLINE_REPO_URL:-https://raw.githubusercontent.com/sohee-zoe/claude-statusline/main}"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
script_path="$claude_dir/statusline.sh"
settings_path="$claude_dir/settings.json"
variant_marker="$claude_dir/.statusline-variant"

variant="${CLAUDE_STATUSLINE_VARIANT:-}"
update_settings_answer=''   # '' = ask, y = yes, n = no

# Newline-delimited rather than an array: `${#arr[@]}` on an empty array is an
# unbound-variable error under `set -u` in bash < 4.4 (macOS ships 3.2).
backups=''

usage() {
  cat <<'TXT'
Usage: install.sh [options]

  --compact           Adaptive one/two-line statusline (default)
  --full              Original multi-line statusline
  --variant NAME      Same as above; NAME is "compact" or "full"
  -y, --yes           Update settings.json without asking
  -n, --no-settings   Never touch settings.json
  -h, --help          Show this message

Environment:
  CLAUDE_STATUSLINE_VARIANT   compact | full
  CLAUDE_CONFIG_DIR           Defaults to ~/.claude

Piped install:
  curl -fsSL .../install.sh | bash -s -- --compact -y
TXT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --compact)      variant=compact; shift ;;
    --full)         variant=full; shift ;;
    --variant)      variant="${2:-}"; shift 2 ;;
    --variant=*)    variant="${1#*=}"; shift ;;
    -y|--yes)       update_settings_answer=y; shift ;;
    -n|--no-settings) update_settings_answer=n; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$variant" in
  ''|compact|full) ;;
  *) printf 'Unknown variant: %s (expected "compact" or "full")\n' "$variant" >&2; exit 2 ;;
esac

# One TTY handle reused by every prompt. `curl | bash` leaves stdin bound to the
# pipe, so prompts must read from /dev/tty or they consume the script itself.
tty_ok=0
if { exec 3<>/dev/tty; } 2>/dev/null; then
  tty_ok=1
fi

previous_variant=''
[ -f "$variant_marker" ] && previous_variant="$(tr -d '[:space:]' < "$variant_marker" 2>/dev/null || true)"
case "$previous_variant" in compact|full) ;; *) previous_variant='' ;; esac

if [ -z "$variant" ]; then
  default_variant="${previous_variant:-compact}"
  if [ "$tty_ok" -eq 1 ]; then
    {
      printf '\nWhich statusline do you want?\n\n'
      printf '  1) compact  one line when the terminal is wide, two when it is not\n'
      printf '              model | dir | branch | context | 5h | 7d\n'
      printf '  2) full     original multi-line layout, additionally shows lines\n'
      printf '              changed, token totals, cost, effort, thinking, agent\n\n'
      printf 'Select 1 or 2 [default: %s]: ' "$default_variant"
    } >&3
    read -r reply <&3 || reply=''
    case "$reply" in
      1|c|compact) variant=compact ;;
      2|f|full)    variant=full ;;
      '')          variant="$default_variant" ;;
      *) printf 'Unrecognised choice "%s"; using %s.\n' "$reply" "$default_variant" >&3
         variant="$default_variant" ;;
    esac
  else
    variant="$default_variant"
    printf 'No TTY available; installing the "%s" variant.\n' "$variant"
  fi
fi

# Dependency preflight. The two variants do not need the same tools.
missing=''
check_cmd() { command -v "$1" >/dev/null 2>&1 || missing="${missing}${missing:+ }$1"; }
check_cmd jq
check_cmd perl
check_cmd date
[ "$variant" = full ] && check_cmd awk
if [ -n "$missing" ]; then
  printf 'Warning: missing required command(s) for the "%s" variant: %s\n' "$variant" "$missing" >&2
  printf 'The statusline will not render correctly until these are installed.\n\n' >&2
fi
command -v git >/dev/null 2>&1 || printf 'Note: git not found; branch display will be skipped.\n\n'

mkdir -p "$claude_dir"

# Download to a temp file and vet it before replacing a working script.
tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT
curl -fsSL "$repo_url/variants/$variant.sh" -o "$tmp_script"

reject() {
  printf 'Downloaded script %s; aborting without changing %s\n' "$1" "$script_path" >&2
  exit 1
}

# `bash -n` alone is not enough: a download cut mid-file can still parse, and
# then a truncated statusline gets installed over a working one. Require the
# terminating `exit 0` as well, then actually run it — a script that renders
# nothing is broken however cleanly it parses.
bash -n "$tmp_script" 2>/dev/null || reject 'failed a syntax check'
[ "$(tail -n 1 "$tmp_script")" = 'exit 0' ] || reject 'looks truncated'
[ -n "$(printf '{}' | bash "$tmp_script" 2>/dev/null)" ] || reject 'rendered nothing on a smoke run'

if [ -f "$script_path" ]; then
  script_backup_path="$script_path.backup.$(date '+%Y%m%d%H%M%S')"
  cp "$script_path" "$script_backup_path"
  backups="${backups}${script_backup_path}"$'\n'
fi
cp "$tmp_script" "$script_path"
chmod +x "$script_path"
printf '%s\n' "$variant" > "$variant_marker"

printf 'Installed %s (%s variant)\n\n' "$script_path" "$variant"

print_settings() {
  cat <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "$script_path"
  }
}
JSON
}

update_settings() {
  local backup_path tmp_path

  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to update %s automatically.\n' "$settings_path"
    printf 'Add this statusLine block manually:\n'
    print_settings
    return
  fi

  [ -f "$settings_path" ] || printf '{}\n' > "$settings_path"
  backup_path="$settings_path.backup.$(date '+%Y%m%d%H%M%S')"
  cp "$settings_path" "$backup_path"
  backups="${backups}${backup_path}"$'\n'

  tmp_path="$(mktemp)"
  # Merge instead of assigning, so refreshInterval / padding / hideVimModeIndicator
  # that the user set by hand survive a reinstall.
  jq --arg command "$script_path" \
    '.statusLine = ((.statusLine // {}) + {type: "command", command: $command})' \
    "$settings_path" > "$tmp_path"
  mv "$tmp_path" "$settings_path"
  printf 'Updated %s\n' "$settings_path"
}

if [ -z "$update_settings_answer" ]; then
  if [ "$tty_ok" -eq 1 ]; then
    printf 'Update %s statusLine now? [y/N] ' "$settings_path" >&3
    read -r update_settings_answer <&3 || update_settings_answer=''
  else
    printf 'No TTY available; skipping settings update prompt.\n'
  fi
fi
[ "$tty_ok" -eq 1 ] && exec 3>&-

case "$update_settings_answer" in
  [Yy]|[Yy][Ee][Ss]) update_settings ;;
  *) printf 'Skipped settings update. Add this statusLine block manually:\n'
     print_settings ;;
esac

if [ -n "$backups" ]; then
  printf '\nBackups created:\n'
  printf '%s' "$backups" | while IFS= read -r b; do
    [ -n "$b" ] && printf '  %s\n' "$b"
  done
fi

if [ "$variant" = compact ]; then
  printf '\nTuning (export before launching Claude Code):\n'
  printf '  STATUSLINE_LINES=1|2          force one or two lines\n'
  printf '  STATUSLINE_PADDING=N          columns reserved for UI chrome (default 4)\n'
  printf '  STATUSLINE_DIR_STYLE=path     show the full ~/... path\n'
  printf '  STATUSLINE_CJK_AMBIGUOUS=1    bar glyphs render 2 cells wide\n'
fi
