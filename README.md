# ClaudeBar

macOS menu bar app that shows your Claude plan usage: `✱ 14% · W 26%` (5-hour session · weekly).
Click it for a popup with progress bars, reset times, and the Fable weekly limit (hidden if your plan has none).

## Requirements

- macOS 13+
- Swift (Xcode Command Line Tools: `xcode-select --install`)
- [Claude Code](https://claude.com/claude-code) logged in. ClaudeBar reads its OAuth token from the Keychain.

## Install

```sh
./build.sh
```

This builds `ClaudeBar.app`, copies it to `~/Applications`, and launches it.
Tick **Open at login** in the popup to start it automatically.

## How it works

- Every 5 minutes it calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint behind `/usage` in Claude Code.
  This only reads numbers. It does not use any of your quota.
  Polling every minute triggers HTTP 429 (rate limited), so keep it at 5 minutes.
- The endpoint is undocumented and may change.
- If the popup says the token expired, run Claude Code once to refresh it.
