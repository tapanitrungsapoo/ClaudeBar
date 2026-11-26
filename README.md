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

## Two accounts

ClaudeBar shows one column for each account that has a Claude Code login in the Keychain.
If two config folders hold logins for the same account, the popup shows that account once.
The menu bar shows the default login. The popup shows all of them side by side.

To keep a second account (for example, a Team account) logged in next to the default one, give it its own config folder:

```sh
CLAUDE_CONFIG_DIR=~/.claude-team claude
```

In that session, run `/login` and sign in with the second account.
Use the same command each time you work with that account.
The folder name must start with `.claude` in your home folder, or the model and project split for that account stays empty.

## How it works

- Every 5 minutes (and right after each limit resets) it calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint behind `/usage` in Claude Code.
  This only reads numbers. It does not use any of your quota.
  Polling every minute triggers HTTP 429 (rate limited), so keep it at 5 minutes.
- "Today +N%" under Weekly is computed locally: current weekly % minus the first reading of the day.
  Usage before the app's first refresh that day is not counted.
- "Weekly N% by model / by project" splits the used weekly limit by model + effort and by project folder.
  These are estimates from local Claude Code transcripts (`~/.claude*/projects`): tokens weighted by API price,
  with the Fable total rescaled to the real share the API reports. Usage on claude.ai or other machines is not counted.
  Each session goes to the account whose organization its `session-owner` line names. Bedrock requests are skipped.
- The endpoint is undocumented. Anthropic can change it without notice.
- If the popup says the token expired, run Claude Code once to refresh it.
