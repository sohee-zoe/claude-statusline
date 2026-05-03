const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { describe, it } = require('node:test');

const {
  install,
  printSettings,
  resolveClaudeDir,
} = require('../bin/claude-statusline.js');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'claude-statusline-'));
}

describe('claude-statusline CLI helpers', () => {
  it('resolves the Claude config directory from an explicit option', () => {
    const dir = tempDir();

    assert.equal(resolveClaudeDir({ dir }), dir);
  });

  it('installs statusline.sh and merges Claude Code settings', () => {
    const dir = tempDir();
    fs.writeFileSync(
      path.join(dir, 'settings.json'),
      JSON.stringify({ theme: 'dark' }, null, 2)
    );

    const result = install({ dir });
    const scriptPath = path.join(dir, 'statusline.sh');
    const settings = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
    const mode = fs.statSync(scriptPath).mode;

    assert.equal(result.scriptPath, scriptPath);
    assert.match(fs.readFileSync(scriptPath, 'utf8'), /Claude Code|statusline|jq/);
    assert.equal(mode & 0o111, 0o111);
    assert.equal(settings.theme, 'dark');
    assert.deepEqual(settings.statusLine, {
      type: 'command',
      command: '~/.claude/statusline.sh',
      padding: 0,
    });
  });

  it('prints the Claude Code settings snippet', () => {
    assert.equal(
      printSettings(),
      JSON.stringify(
        {
          statusLine: {
            type: 'command',
            command: '~/.claude/statusline.sh',
            padding: 0,
          },
        },
        null,
        2
      )
    );
  });
});
