#!/bin/bash
# One-shot installer:
#   1. Stages monitor.py + status.py to ~/.claude-usage-monitor/bin/
#   2. Builds ClaudeFloater.app into /Applications
#   3. Generates user-specific LaunchAgents from templates and registers them
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$HOME/.claude-usage-monitor"
LA_DIR="$HOME/Library/LaunchAgents"

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

echo "[install] building ClaudeFloater.app ..."
bash "$REPO/scripts/build-app.sh"

echo "[install] installing LaunchAgents to $LA_DIR ..."
mkdir -p "$LA_DIR"
for tmpl in "$REPO"/launchagents/*.plist.template; do
  name="$(basename "$tmpl" .template)"
  sed "s|__HOME__|$HOME|g" "$tmpl" > "$LA_DIR/$name"
done

echo "[install] registering with launchd ..."
launchctl bootout "gui/$UID/dev.eva.claude-monitor" 2>/dev/null || true
launchctl bootout "gui/$UID/dev.eva.claude-floater" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$LA_DIR/dev.eva.claude-monitor.plist"
launchctl bootstrap "gui/$UID" "$LA_DIR/dev.eva.claude-floater.plist"
launchctl kickstart -k "gui/$UID/dev.eva.claude-monitor"

echo
echo "Done. ClaudeFloater is installed and will auto-start at login."
echo "Logs: $RUNTIME_DIR/monitor.{stdout,stderr}.log"
echo "Quit menubar icon -> Quit, or run scripts/uninstall.sh to remove."
