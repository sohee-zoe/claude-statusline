# Claude Statusline

A compact Claude Code statusline for model, workspace, context, rate limits,
token usage, cost, git branch, and agent metadata.

## Features

- Multi-line Claude Code statusline powered by `statusline.sh`
- Context remaining percentage with a colored progress bar
- Five-hour and seven-day rate-limit windows with reset times
- Git branch detection when the workspace is inside a Git repository
- Optional session details: lines changed, token totals, cost, duration, effort,
  thinking state, and agent name
- Graceful fallbacks for missing fields, invalid JSON, and missing `jq`

## Requirements

- Claude Code with `statusLine` support
- Bash and `jq`
- Common Unix tools: `awk`, `perl`, `date`
- Optional: `git`, for branch display

## Install with npm, Yarn, pnpm, or Bun

Install the package globally, then run the installer:

```bash
npm install -g @zollibee/claude-statusline
claude-statusline install
```

Equivalent package-manager commands:

```bash
yarn global add @zollibee/claude-statusline
pnpm add -g @zollibee/claude-statusline
bun add -g @zollibee/claude-statusline
```

The installer copies `statusline.sh` to `~/.claude/statusline.sh`, marks it
executable, and updates `~/.claude/settings.json` with:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
```

To print the settings snippet without installing:

```bash
claude-statusline print-settings
```

## Install with curl

```bash
curl -fsSL https://raw.githubusercontent.com/sohee-zoe/claude-statusline/main/install.sh | bash
```

The curl installer copies the script and prints the settings snippet. It does
not edit `settings.json` automatically.

## Manual Installation

```bash
mkdir -p ~/.claude
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add the `statusLine` block shown above to `~/.claude/settings.json`.

## Development

Run tests and checks:

```bash
npm test
bash -n statusline.sh
bash -n install.sh
shellcheck statusline.sh install.sh
```

Run a local smoke test:

```bash
printf '%s\n' '{"model":{"id":"claude-sonnet-4-5"},"workspace":{"current_dir":"/tmp/example"},"context_window":{"remaining_percentage":72}}' | ./statusline.sh
```

Preview npm package contents:

```bash
npm pack --dry-run
```

## Publishing

```bash
npm login
npm publish --access public
```

After publishing, the same package can be installed with npm, Yarn, pnpm, and
Bun because they all consume npm registry packages.

## Credits

Inspired by Claude Code statusline tooling and documentation, including
CCometixLine, claude-lens, community `statusline.sh` examples, and the official
Claude Code statusline docs.
