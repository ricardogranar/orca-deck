# Orca Deck

Side display for Orca agents, meant for an iPhone used as an extra Mac screen via OpenDisplay.

- Native AppKit window (`main.swift`) that goes native full screen (own Space, no menu bar) on the
  display whose name contains "iPhone"/"OpenDisplay" (override with `DECK_SCREEN=<name>`).
  After each tap it hands keyboard focus back to the previous app (usually Orca).
- UI is a fixed 936×526 canvas (iPhone 8 landscape via OpenDisplay), scaled to fit, using Orca's dark
  theme tokens and the Geist font copied from Orca's bundle.
- Polls `orca worktree ps --json` + `orca terminal list --json` every 1.5 s.
- UI is `web/index.html` (WKWebView). It can only run whitelisted `orca` subcommands.

Build/install: `./build.sh --install` → `~/Applications/Orca Deck.app`.

Dev: `DECK_WEB_DIR=$PWD/web "build/Orca Deck.app/Contents/MacOS/OrcaDeck"` loads the HTML from disk.
`DECK_SNAPSHOT=/tmp/x.png DECK_SNAPSHOT_JS='…'` saves a PNG of the window after load.
Opening `web/index.html` in a browser shows mock data.
