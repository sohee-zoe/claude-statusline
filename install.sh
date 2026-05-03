#!/usr/bin/env bash
set -euo pipefail

repo_url="${CLAUDE_STATUSLINE_REPO_URL:-https://raw.githubusercontent.com/sohee-zoe/claude-statusline/main}"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
script_path="$claude_dir/statusline.sh"
settings_path="$claude_dir/settings.json"

mkdir -p "$claude_dir"
if [ -f "$script_path" ]; then
  script_backup_path="$script_path.backup.$(date '+%Y%m%d%H%M%S')"
  cp "$script_path" "$script_backup_path"
  printf 'Backed up %s to %s\n' "$script_path" "$script_backup_path"
fi
curl -fsSL "$repo_url/statusline.sh" -o "$script_path"
chmod +x "$script_path"

printf 'Installed %s\n\n' "$script_path"

print_settings() {
  cat <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "$script_path",
    "padding": 0
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

  if [ -f "$settings_path" ]; then
    backup_path="$settings_path.backup.$(date '+%Y%m%d%H%M%S')"
    cp "$settings_path" "$backup_path"
    printf 'Backed up %s to %s\n' "$settings_path" "$backup_path"
  else
    printf '{}\n' > "$settings_path"
    backup_path="$settings_path.backup.$(date '+%Y%m%d%H%M%S')"
    cp "$settings_path" "$backup_path"
    printf 'Created %s and backed it up to %s\n' "$settings_path" "$backup_path"
  fi

  tmp_path="$(mktemp)"
  jq --arg command "$script_path" \
    '.statusLine = { "type": "command", "command": $command, "padding": 0 }' \
    "$settings_path" > "$tmp_path"
  mv "$tmp_path" "$settings_path"
  printf 'Updated %s\n' "$settings_path"
}

answer=''
if { exec 3<>/dev/tty; } 2>/dev/null; then
  printf 'Update %s statusLine now? [y/N] ' "$settings_path" >&3
  read -r answer <&3
  exec 3>&-
else
  printf 'No TTY available; skipping settings update prompt.\n'
fi

case "$answer" in
  [Yy]|[Yy][Ee][Ss])
    update_settings
    ;;
  *)
    printf 'Skipped settings update. Add this statusLine block manually:\n'
    print_settings
    ;;
esac
