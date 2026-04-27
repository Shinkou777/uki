# Claude Floater

EVA NERV-styled macOS desktop HUD that shows your current Anthropic API rate-limit usage in real time. Auto-starts at login, gets out of the way when you don't need it.

<!-- ![max view](docs/screenshots/max.png) -->
<!-- ![min view](docs/screenshots/min.png) -->

## What it shows

- **活動限界 (5h window)**: rolling 5-hour usage
- **当月限界 (7d window)**: weekly cap
- **暴走 (overage)**: optional pay-as-you-go overage if you have it enabled
- Time remaining until each window resets
- One-click minimize to a tiny pill that stays out of the way

A Python daemon polls Anthropic's API headers and writes state to a local file; the SwiftUI app reads that file and renders.

## Requirements

- macOS 13 (Ventura) or later
- Python 3.9+ (system `/usr/bin/python3` works)
- An Anthropic API key (`ANTHROPIC_API_KEY`) — used **only** to read rate-limit headers from your account

## Install

```bash
git clone https://github.com/<YOU>/claude-floater.git
cd claude-floater
bash scripts/install.sh
```

The installer will:

1. Stage `monitor.py` to `~/.claude-usage-monitor/bin/`
2. Build `ClaudeFloater.app` into `/Applications/`
3. Create `~/.claude-usage-monitor/.env` for your API key
4. Register two LaunchAgents so both pieces auto-start at login

After install, edit `~/.claude-usage-monitor/.env` and put your key in:

```
ANTHROPIC_API_KEY=sk-ant-...
```

Then restart the monitor:

```bash
launchctl kickstart -k "gui/$UID/dev.eva.claude-monitor"
```

The floater will pick up the new state within 15 seconds.

## Uninstall

```bash
bash scripts/uninstall.sh           # removes app + LaunchAgents, keeps state/.env
bash scripts/uninstall.sh --purge   # also removes ~/.claude-usage-monitor
```

## First-launch security warning

This binary is unsigned. macOS Gatekeeper will block it on first open. To bypass:

1. Right-click `ClaudeFloater.app` in Finder → **Open** → confirm
2. Or: `xattr -d com.apple.quarantine /Applications/ClaudeFloater.app`

A signed + notarized release is on the roadmap (requires $99/yr Apple Developer Program).

## Architecture

```
Anthropic API
     │  (rate-limit headers)
     ▼
~/.claude-usage-monitor/bin/monitor.py
     │  (writes JSON every 3-30 min, adaptive)
     ▼
~/.claude-usage-monitor/state.json
     │  (read every 15s)
     ▼
/Applications/ClaudeFloater.app   ← SwiftUI, this repo's floater.swift
```

The monitor adapts polling cadence based on system state: 3 min on AC, 5 min on battery, 30 min when idle (>10 min) or low battery (<30%). On wake from sleep, the floater sends `SIGUSR1` to force an immediate refresh.

## Customizing

- **Position**: drag the floater anywhere; it remembers per-launch
- **Size**: click the `▼` to toggle between MAX (290×178) and MIN (116×28)
- **Colors / fonts**: edit `src/floater.swift`, search for `enum Eva` (palette) or `func mincho` (fonts)
- **Icon**: edit `src/make-icon.swift` and rebuild — the squircle, central glyph, and corner accent are all parametric

## Roadmap

- [ ] Signed + notarized release (Developer ID)
- [ ] GitHub Actions CI for automated DMG releases on tag push
- [ ] Sparkle auto-update
- [ ] Optional menu-bar-only mode (no floating panel)
- [ ] Light/dark scheme detection (currently dark-only)

## Trademarks & Credits

> This project is fan art inspired by *Neon Genesis Evangelion* (© khara, Inc.).
> The author is not affiliated with khara, the EVA franchise, or Anthropic.
> "Claude" is a trademark of Anthropic, used here only to indicate compatibility.
> NERV-style geometric motifs are reinterpretations and do not reproduce the
> trademarked NERV logo.

EVA visual references that inspired this project: hazard stripes, octagonal panel cuts, Matisse-style heavy mincho, the magenta→purple gradient palette.

## License

MIT — see [LICENSE](LICENSE).
