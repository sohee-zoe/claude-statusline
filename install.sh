#!/usr/bin/env bash
set -euo pipefail

repo_url="${CLAUDE_STATUSLINE_REPO_URL:-https://raw.githubusercontent.com/sohee-zoe/claude-statusline/main}"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
script_path="$claude_dir/statusline.sh"

mkdir -p "$claude_dir"
curl -fsSL "$repo_url/statusline.sh" -o "$script_path"
chmod +x "$script_path"

printf 'Installed %s\n\n' "$script_path"
printf 'Add this to %s/settings.json:\n' "$claude_dir"
cat <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
JSON
