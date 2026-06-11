#!/bin/sh
# Install claude-usage-bar: the claude-account CLI (if you don't have it)
# and Claude Usage.app into ~/Applications.
set -eu
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

# claude-account does the credential snapshots + switching; the app drives it.
if [ ! -e "$HOME/.local/bin/claude-account" ]; then
  mkdir -p "$HOME/.local/bin"
  cp bin/claude-account "$HOME/.local/bin/claude-account"
  chmod +x "$HOME/.local/bin/claude-account"
  echo "Installed claude-account to ~/.local/bin"
else
  echo "claude-account already present — leaving yours in place"
fi

./build.sh

echo
echo "Done. Next:"
echo "  1. claude-account snapshot <name>   # while logged into your current account"
echo "  2. /login as your other account in any Claude Code session"
echo "  3. claude-account snapshot <other-name>"
echo "  4. open ~/Applications/'Claude Usage.app'"
