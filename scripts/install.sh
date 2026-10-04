#!/bin/bash
# One-shot installer:
#   1. Stages monitor.py + status.py to ~/.uki/bin/
#   2. Builds Uki.app into /Applications
#   3. Generates user-specific LaunchAgents from templates and registers them
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$HOME/.uki"
LA_DIR="$HOME/Library/LaunchAgents"
APP_LABEL="com.shinkotera.uki"
MONITOR_LABEL="com.shinkotera.uki-monitor"

# One-time move of the runtime folder used before the rename, so config.json
# and state.json carry over. Runs only while ~/.uki does not exist yet.
OLD_RUNTIME_DIR="$HOME/.claude-usage-monitor"
if [ -d "$OLD_RUNTIME_DIR" ] && [ ! -e "$RUNTIME_DIR" ]; then
  if pgrep -f "$OLD_RUNTIME_DIR/bin/monitor.py" >/dev/null 2>&1; then
    echo "[install] a monitor is still running from $OLD_RUNTIME_DIR." >&2
    echo "[install] Run scripts/uninstall.sh first, then run this installer again." >&2
    exit 1
  fi
  echo "[install] moving $OLD_RUNTIME_DIR to $RUNTIME_DIR ..."
  mv "$OLD_RUNTIME_DIR" "$RUNTIME_DIR"
elif [ -d "$OLD_RUNTIME_DIR" ]; then
  echo "[install] $RUNTIME_DIR already exists, so $OLD_RUNTIME_DIR was left in place."
fi

echo "[install] staging runtime files to $RUNTIME_DIR ..."
mkdir -p "$RUNTIME_DIR/bin"
cp "$REPO/src/monitor.py" "$RUNTIME_DIR/bin/monitor.py"
cp "$REPO/src/status.py"  "$RUNTIME_DIR/bin/status.py"
chmod +x "$RUNTIME_DIR/bin/monitor.py" "$RUNTIME_DIR/bin/status.py"

if [ ! -f "$RUNTIME_DIR/.env" ]; then
  cat > "$RUNTIME_DIR/.env" <<'EOF'
# Required: your Anthropic API key (used only to read rate-limit headers)
ANTHROPIC_API_KEY=
EOF
  chmod 600 "$RUNTIME_DIR/.env"
  echo "[install] created $RUNTIME_DIR/.env — fill in your ANTHROPIC_API_KEY before launching"
fi

echo "[install] building Uki.app ..."
bash "$REPO/scripts/build-app.sh"

echo "[install] installing LaunchAgents to $LA_DIR ..."
mkdir -p "$LA_DIR"
for tmpl in "$REPO"/launchagents/*.plist.template; do
  name="$(basename "$tmpl" .template)"
  sed "s|__HOME__|$HOME|g" "$tmpl" > "$LA_DIR/$name"
done

echo "[install] registering with launchd ..."
# Labels used until 2026-10 (before the ShinkoTera rename): stop them and drop their plists
# so an upgrade does not leave a second monitor and app running.
for old in app.shinkolab.uki-monitor app.shinkolab.uki; do
  launchctl bootout "gui/$UID/$old" 2>/dev/null || true
  rm -f "$LA_DIR/$old.plist"
done
launchctl bootout "gui/$UID/$MONITOR_LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID/$APP_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$LA_DIR/$MONITOR_LABEL.plist"
launchctl bootstrap "gui/$UID" "$LA_DIR/$APP_LABEL.plist"
launchctl kickstart -k "gui/$UID/$MONITOR_LABEL"

echo
echo "Done. Uki is installed and will auto-start at login."
echo "Logs: $RUNTIME_DIR/monitor.{stdout,stderr}.log"
echo "Quit menubar icon -> Quit, or run scripts/uninstall.sh to remove."
