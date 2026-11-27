# ribbon

A scrollable tiling window manager for macOS (niri/PaperWM style), built as a Swift daemon with a `ribbon` CLI.

## Features

- 1D column strip with minimal scrolling to keep the focused column in view
- Keyboard control through the `ribbon` CLI over a Unix domain socket
- Three-finger trackpad scrubbing that glides and snaps to a column
- Optional Space switching when swiping past the strip's end via InstantSpaceSwitcher (`ISSCli`)
- Screenshot overview grid for picking a window
- Multi-display support

## Requirements

- macOS with Accessibility permission enabled for `Ribbon.app`
- InstantSpaceSwitcher (`ISSCli`), optional, for swipe-based Space switching

## Build and run

- `make`: build the CLI, daemon, and `Ribbon.app` bundle
- `make start`: build and start the daemon
- `make restart`: rebuild and restart the daemon
- `make test`: run `RibbonCore` tests

## Usage

```
ribbon focus <left|right|up|down|first|last>
ribbon swap <left|right|up|down|first|last> (alias: move)
ribbon cycle-width (alias: cycle)
ribbon overview (alias: toggle-overview)
ribbon focus-display [next|prev|<index>]
ribbon status
```

## Status

Personal project, work in progress.
