#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const DEFAULT_COMMAND = '~/.claude/statusline.sh';

function usage() {
  return [
    'Usage: claude-statusline <command> [options]',
    '',
    'Commands:',
    '  install              Install statusline.sh into ~/.claude and update settings.json',
    '  print-settings       Print the Claude Code statusLine settings snippet',
    '  help                 Show this help',
    '',
    'Options:',
    '  --dir <path>         Claude config directory (default: ~/.claude)',
    '  --no-settings        Copy the script without editing settings.json',
  ].join('\n');
}

function expandHome(value) {
  if (!value) return value;
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return value;
}

function resolveClaudeDir(options = {}) {
  return path.resolve(expandHome(options.dir || process.env.CLAUDE_CONFIG_DIR || '~/.claude'));
}

function statusLineSettings(command = DEFAULT_COMMAND) {
  return {
    type: 'command',
    command,
    padding: 0,
  };
}

function printSettings() {
  return JSON.stringify({ statusLine: statusLineSettings() }, null, 2);
}

function readSettings(settingsPath) {
  if (!fs.existsSync(settingsPath)) return {};
  const raw = fs.readFileSync(settingsPath, 'utf8').trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function install(options = {}) {
  const dir = resolveClaudeDir(options);
  const scriptPath = path.join(dir, 'statusline.sh');
  const settingsPath = path.join(dir, 'settings.json');
  const sourcePath = path.resolve(__dirname, '..', 'statusline.sh');

  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(sourcePath, scriptPath);
  fs.chmodSync(scriptPath, 0o755);

  if (!options.noSettings) {
    const settings = readSettings(settingsPath);
    settings.statusLine = statusLineSettings(options.command || DEFAULT_COMMAND);
    fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
  }

  return { dir, scriptPath, settingsPath };
}

function parseArgs(argv) {
  const options = {};
  const positional = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--dir') {
      i += 1;
      if (!argv[i]) throw new Error('--dir requires a path');
      options.dir = argv[i];
    } else if (arg === '--no-settings') {
      options.noSettings = true;
    } else {
      positional.push(arg);
    }
  }

  return { command: positional[0] || 'help', options };
}

function main(argv = process.argv.slice(2)) {
  const { command, options } = parseArgs(argv);

  if (command === 'install') {
    const result = install(options);
    process.stdout.write(`Installed ${result.scriptPath}\n`);
    if (!options.noSettings) {
      process.stdout.write(`Updated ${result.settingsPath}\n`);
    }
    return 0;
  }

  if (command === 'print-settings') {
    process.stdout.write(`${printSettings()}\n`);
    return 0;
  }

  if (command === 'help' || command === '--help' || command === '-h') {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }

  throw new Error(`Unknown command: ${command}`);
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${usage()}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  install,
  printSettings,
  resolveClaudeDir,
  statusLineSettings,
};
