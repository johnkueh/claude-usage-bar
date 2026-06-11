# claude-usage-bar

macOS menu bar app for Claude Code usage across accounts. A native wrapper
around `claude-account` (~/.local/bin): glanceable statusline-format numbers,
one-click account switching, optional reset-aware autopilot.

## Menu bar

Statusline format, stacked:

```
S:47%/3h
W:10%/5d
```

S = 5-hour window, W = weekly window, `/Nh` = countdown to reset (same
rounding as ~/.claude/scripts/statusline.sh). The percentage turns amber at
70%, red at 90%. A trailing `~` means cached numbers (live fetch failed).

## Menu

- One row per saved account: usage gauges, exact %, reset times. Click the
  inactive account to switch (runs `claude-account <name>` — same re-snapshot
  safety, same marker file).
- **Autopilot** (off by default): when the active account runs hot (5h ≥ 90%
  or weekly ≥ 99%) and another account has ≥15 points more usable headroom,
  switch automatically — unless the 5h window resets within 20 minutes. Max
  one auto-switch per hour; every switch posts a notification with the reason.
- **Manage Accounts**: Add (snapshots the live keychain login — `/login` as
  the new account first), Remove, Launch at Login. The app also detects a
  live login it doesn't recognize and offers to save it.

## Build

```sh
./build.sh   # swiftc → ~/Applications/Claude Usage.app (ad-hoc signed, no Dock icon)
```

No Xcode project, no dependencies. macOS 13+.

## How it reads data

- Active account token: keychain item "Claude Code-credentials" via
  `/usr/bin/security` (existing ACL applies — no new prompts).
- Inactive accounts: `~/.claude/.cred-<name>` snapshot files.
- Usage: `api.anthropic.com/api/oauth/usage` (read-only). Inactive tokens
  expire ~daily; the menu then shows last-known numbers as stale until the
  next switch refreshes the snapshot.

## Debug hooks

- `DEBUG_SHOOT=1` — renders the status item (dark+light) and menu rows to
  /tmp/cub-*.png + dumps menu structure to /tmp/cub-menu.txt, then quits.
- `DEBUG_SWITCH=<name>` — exercises the switch path, then quits.
