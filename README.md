# Ribbon 🎀

A lightweight, native Swift scrollable tiling window manager daemon and CLI for macOS, inspired by Niri and PaperWM with an AeroSpace-style socket architecture.

## Key Features

- **Infinite Horizontal Strip:** Windows tile as columns along an infinite horizontal ribbon that slides the active column into the viewport.
- **Zero Display Bleed:** Off-screen columns are hidden rather than placed in coordinate space, completely preventing windows from bleeding into neighboring displays.
- **Sub-Millisecond CLI:** Fast Unix domain socket IPC (`/tmp/ribbon.sock`) allows instant command execution from Karabiner, skhd, or any shell.
- **No SIP Required:** Uses public macOS Accessibility APIs.

## Building

Requires macOS 13+ and Swift 5.9+.

```bash
swift build -c release
```

Binaries will be located at:
- `.build/release/ribbon-daemon` (The background window management engine)
- `.build/release/ribbon` (The client CLI)

## Running

1. Start the daemon (requires Accessibility permissions on first run):
   ```bash
   .build/release/ribbon-daemon
   ```
2. Control windows via the CLI:
   ```bash
   ribbon focus left
   ribbon focus right
   ribbon swap left
   ribbon swap right
   ribbon cycle-width
   ribbon slurp
   ribbon barf
   ```

## Architecture

- **`RibbonCore`**: Pure Swift data models (`Ribbon`, `ColumnModel`, `WindowModel`, `LayoutEngine`, `Config`).
- **`RibbonAccessibility`**: Fast `AXUIElement` attribute manipulation and `AXObserver` window event monitoring.
- **`ribbon-daemon`**: Central controller, window tracker, and Unix socket server.
- **`ribbon-cli`**: Sub-millisecond client that connects to the socket and exits.
