# Claude Sessions for Omarchy

A bar widget showing every running Claude Code session at a glance: working,
waiting for you, idle, or stopped on an error.

- The icon **pulses** while a session is working, turns **urgent** with a count
  while any session needs you, and hides when no session runs.
- Click it for the list: project, state, how long ago it changed, the last
  message and the working directory.
- **Click a session to jump to its terminal.** A session on the agent shelf
  (`special:scratchpad`) opens the shelf if it is closed; any other session
  switches to its workspace, closing an open shelf on the way.
- Desktop notifications when a session finishes, fails or asks for permission —
  only when you are not already looking at that terminal. Clicking one jumps
  there the same way.

## How it works

`hooks/omarchy-session-state.sh` runs from Claude Code's hooks. It finds the
`claude` process and the terminal window it runs in, and keeps one file per
session in `~/.local/state/claude-sessions/sessions/`, plus `index.json`
holding all of them. The widget only watches `index.json`; once a minute it
asks the script to prune sessions whose process died without a `SessionEnd`.

Requires `jq` and `notify-send`.

## Install

```sh
git clone https://github.com/janrenz/omarchy-claude-sessions \
  ~/.config/omarchy/plugins/jan.claude-sessions
mkdir -p ~/.claude/hooks
ln -s ~/.config/omarchy/plugins/jan.claude-sessions/hooks/omarchy-session-state.sh \
  ~/.claude/hooks/omarchy-session-state.sh
omarchy bar put jan.claude-sessions --section right
```

Then register the hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" start",  "timeout": 10 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" prompt", "timeout": 10 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" tool",   "timeout": 10 }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" notify", "timeout": 10 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" stop",   "timeout": 10 }] }],
    "StopFailure":      [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" fail",   "timeout": 10 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/omarchy-session-state.sh\" end",    "timeout": 10 }] }]
  }
}
```

Sessions started before the hook was registered appear from their next prompt.

## License

MIT
