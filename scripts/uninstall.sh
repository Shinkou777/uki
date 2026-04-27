#!/bin/bash
# Reverse of install.sh:
#   - Stops + unregisters LaunchAgents
#   - Removes /Applications/ClaudeFloater.app
#   - Optionally removes ~/.claude-usage-monitor (preserves .env unless --purge)
set -e

LA_DIR="$HOME/Library/LaunchAgents"

echo "[uninstall] stopping LaunchAgents ..."
launchctl bootout "gui/$UID/dev.eva.claude-monitor" 2>/dev/null || true
launchctl bootout "gui/$UID/dev.eva.claude-floater" 2>/dev/null || true
rm -f "$LA_DIR/dev.eva.claude-monitor.plist" \
      "$LA_DIR/dev.eva.claude-floater.plist"

echo "[uninstall] killing any leftover processes ..."
pkill -f "$HOME/.claude-usage-monitor/bin/monitor.py" 2>/dev/null || true
pkill -x ClaudeFloater 2>/dev/null || true

echo "[uninstall] removing /Applications/ClaudeFloater.app ..."
rm -rf /Applications/ClaudeFloater.app

if [ "$1" = "--purge" ]; then
  echo "[uninstall] --purge: removing ~/.claude-usage-monitor (incl. state + .env)"
  rm -rf "$HOME/.claude-usage-monitor"
else
  echo "[uninstall] kept ~/.claude-usage-monitor (use --purge to also delete it)"
fi

echo "Done."
