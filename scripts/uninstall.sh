#!/bin/bash
# Reverse of install.sh:
#   - Stops + unregisters the LaunchAgents
#   - Removes /Applications/Uki.app
#   - Optionally removes ~/.uki (preserves .env unless --purge)
# It also cleans up an install from before the rename: old LaunchAgent labels,
# the old app bundle and old processes. The old runtime folder is kept so that
# install.sh can move it to ~/.uki; --purge deletes it as well.
set -e

LA_DIR="$HOME/Library/LaunchAgents"
RUNTIME_DIR="$HOME/.uki"
LABELS="com.shinkouniv.uki-monitor com.shinkouniv.uki"

# Cleanup targets from before the rename. The first local setup used labels
# built from the account name (com.<user>.claude-*); the repo's earlier
# installer used dev.eva.claude-*; until 2026-10 the labels were app.shinkolab.uki*, then briefly com.shinkotera.uki*.
OLD_USER_PREFIX="com.$(id -un)"
OLD_LABELS="$OLD_USER_PREFIX.claude-monitor $OLD_USER_PREFIX.claude-floater dev.eva.claude-monitor dev.eva.claude-floater app.shinkolab.uki-monitor app.shinkolab.uki com.shinkotera.uki-monitor com.shinkotera.uki"
OLD_RUNTIME_DIR="$HOME/.claude-usage-monitor"
OLD_APP_DIR="/Applications/ClaudeFloater.app"

echo "[uninstall] stopping LaunchAgents ..."
for label in $LABELS $OLD_LABELS; do
  launchctl bootout "gui/$UID/$label" 2>/dev/null || true
  rm -f "$LA_DIR/$label.plist"
done

echo "[uninstall] killing any leftover processes ..."
pkill -f "$RUNTIME_DIR/bin/monitor.py" 2>/dev/null || true
pkill -f "$OLD_RUNTIME_DIR/bin/monitor.py" 2>/dev/null || true
pkill -x Uki 2>/dev/null || true
pkill -x ClaudeFloater 2>/dev/null || true

echo "[uninstall] removing /Applications/Uki.app ..."
rm -rf /Applications/Uki.app
if [ -d "$OLD_APP_DIR" ]; then
  echo "[uninstall] removing $OLD_APP_DIR ..."
  rm -rf "$OLD_APP_DIR"
fi

if [ "$1" = "--purge" ]; then
  echo "[uninstall] --purge: removing $RUNTIME_DIR (incl. state + .env)"
  rm -rf "$RUNTIME_DIR"
  if [ -d "$OLD_RUNTIME_DIR" ]; then
    echo "[uninstall] --purge: removing $OLD_RUNTIME_DIR"
    rm -rf "$OLD_RUNTIME_DIR"
  fi
else
  echo "[uninstall] kept $RUNTIME_DIR (use --purge to also delete it)"
  if [ -d "$OLD_RUNTIME_DIR" ]; then
    echo "[uninstall] kept $OLD_RUNTIME_DIR; install.sh moves it to $RUNTIME_DIR"
  fi
fi

echo "Done."
