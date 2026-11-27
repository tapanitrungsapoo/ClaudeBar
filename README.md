# ClaudeBar

macOS menu bar app that shows your Claude plan usage: `✱ 14% · W 26%` (5-hour session · weekly).
Click it to open a popup with progress bars and reset times.
If your plan has a Fable weekly limit, the popup shows it too.

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

- ClaudeBar shows the account that is logged in to Claude Code in `~/.claude`.
  If you switch accounts with `/login`, the popup changes to the new account at the next refresh.
- Every 5 minutes (and right after each limit resets) it calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint behind `/usage` in Claude Code.
  This only reads numbers. It does not use any of your quota.
  Polling every minute triggers HTTP 429 (rate limited), so keep it at 5 minutes.
  The limit is per login token, and Claude Code's own calls with that token also count.
  After an HTTP 429, the popup keeps the last numbers, and the app waits for the time in `Retry-After`.
- "Today +N%" under Weekly is computed locally: current weekly % minus the first reading of the day.
  Usage before the app's first refresh that day is not counted.
- "Weekly N% by model / by project" splits the used weekly limit by model + effort and by project folder.
  These are estimates from local Claude Code transcripts (`~/.claude/projects`): tokens weighted by API price,
  with the Fable total rescaled to the real share the API reports. Usage on claude.ai or other machines is not counted.
  Only sessions of the logged-in account count, by the organization in their `session-owner` line. Bedrock requests are skipped.
- The endpoint is undocumented. Anthropic can change it without notice.
- Claude Code renews its token only while it runs. A token lasts about 8 hours.
  If the popup says that the login expired, run `claude` once.
  The app sends no call with an expired token, because repeated calls with a bad token get HTTP 429.
