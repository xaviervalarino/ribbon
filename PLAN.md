# Ribbon Implementation Plan 🎀

A native macOS scrollable tiling window manager (Niri/PaperWM-style 1D column strip) in Swift, with an AeroSpace-style socket daemon + CLI and near-zero multi-monitor display bleed.

---

## 1. Architecture

- **`ribbon-daemon`**: background daemon holding per-state `Ribbon` column strips, listening to Accessibility (AX) events, computing and applying window frames.
- **`ribbon` (CLI)**: thin client over a per-user Unix domain socket (`focus`, `swap`, `cycle-width`, `slurp`, `barf`, `status`).
- **Corner-stash multi-monitor**: off-ribbon columns park in a configurable corner of *their own* monitor ([AeroSpace #1008](https://github.com/nikitabobko/AeroSpace/discussions/1008)) — macOS can't truly hide individual windows or place them fully offscreen. ~1px sliver stays visible and doubles as crash recovery.

### Settled decisions (grill rounds 1–2, 2026-09-12)
- **Scroll model**: minimal-scroll (Niri default) — viewport moves only enough to bring the focused column into view. Requires an explicit viewport-offset field on `Ribbon` (today the layout always centers the active column).
- **Floating**: auto-float only in v1 — strict admission filter (role `AXWindow`, subrole standard; dialogs/palettes/PiP never enter the ribbon and are left untouched). Manual `float` toggle deferred to v1.5.
- **Config**: hardcoded `Config.default` for MVP. File format (TOML preferred, JSON fallback) deferred until the daemon works — blocked on the broken SPM toolchain anyway.
- **Workspaces**: none built-in. v1 is **FlashSpace-compatible**: observe `NSWorkspace` didHide/didUnhide/didActivate, exclude hidden apps' windows from the ribbon, gate AX moves on `app.isHidden == false`. Native hide/show workspace switching is a possible v2.
- **AX layer**: keep our own thin wrapper (AXSwift is MIT but SPM is broken); port its patterns instead.
- **Mouse interaction**: adopt manual *resizes* into the column's width ratio; manual *moves* snap back on next retile. Drag-to-reorder columns is a committed v2 item (live drop-target math + drag-vs-echo disambiguation is too hairy for v1).
- **Not-displayable policy (unified)**: hidden (FlashSpace/Cmd+H) and minimized windows *leave* the ribbon; on return they re-insert right of the active column. One code path for both. (Upgrade path if order-scrambling annoys: keep-slot-skip-layout, contained change.)
- **Native Spaces**: Tier-1 "rescan on switch" — observe `NSWorkspace.activeSpaceDidChangeNotification`, rescan and reconcile to what's visible; never act on stale window lists. No per-Space ribbon memory, no cross-Space commands.
- **Column close**: neighbors shift left; viewport clamps to `[0, totalWidth − screenWidth]` so the strip stays flush with the screen edge; focus goes to the right neighbor (fallback left). Falls out of the viewport model — test it, don't build it.
- **Borders**: delegated to JankyBorders in v1 (it's already in `ignoredApps`); stashed-sliver exclusion via IPC is v2.
- **Omission**: v1 hardcoded `ignoredApps` + strict admission filter (dialogs/sheets/palettes never enter the ribbon — they auto-float). User-editable ignore rules (bundle id + title regex) land with the config file.
- **Z-order policy**: layout is non-overlapping, so z rarely matters. Rule: raise **only** the focused window on focus changes, never during retile; dialogs/sheets ride above their parent natively; stashed slivers' relative z is irrelevant.
- **Sessionizable layouts (arch constraint now, feature v2)**: `RibbonCore` model stays pure/Codable with no AX types (already true); separate runtime *identity* (CGWindowID) from a persistent *descriptor* (bundle id + title pattern) so saved layouts can re-match windows after app restarts.
- **New-window focus (anti-steal)**: a new window gets focus + ribbon scroll only if its app is frontmost (you triggered it); background apps' windows insert silently right of the active column — no steal mid-typing.
- **Startup adoption order**: on daemon start, existing windows become columns sorted by current x-position.
- **Throwing a window to another Space/workspace**: manual native-Space moves are absorbed by Tier-1 rescan + liveness (window leaves the ribbon, adopted when that Space is visited). Programmatic native-Space moves are a **non-goal** (private CGS APIs only — the most fragile macOS surface). FlashSpace throws work via the displayability policy; v2 `send-to-workspace` shells out to the `flashspace` CLI (app-granularity caveat).
- **Deferred**: event-push IPC channel (JankyBorders tracks focus itself), license choice, rename (candidate: `reel` if published).

### Known macOS constraints (verified 2026-09)
- `kAXHiddenAttribute` is app-level only — not settable on window elements (silently fails).
- Window identity must be `_AXUIElementGetWindow()` → `CGWindowID` (the one private API AeroSpace/yabai use). Never `pid ^ title.hashValue` — dead elements return empty titles, so the destroy path can never match.
- AX calls are synchronous IPC per app (10–100ms+). Set `AXUIElementSetMessagingTimeout` (~1s) on every app element; long-term, per-app AX threads (OmniWM architecture).
- **Tahoe (macOS 26)**: bare binaries no longer get Accessibility grants reliably — the daemon must ship in a **signed `.app` bundle** ([yabai #2688](https://github.com/koekeishiya/yabai/issues/2688)). Codesign with a stable self-signed identity so the grant survives rebuilds.
- `AXUIElementDestroyed` is unreliable since Sequoia ([AeroSpace #471](https://github.com/nikitabobko/AeroSpace/issues/471)) — periodic liveness GC required.
- Chrome/Electron/Firefox: reading AX sets `AXEnhancedUserInterface=true`, which breaks `setFrame` — clear it around every frame write ([Rectangle #912](https://github.com/rxhanson/Rectangle/issues/912)).
- AX *resize* runs at ~10fps; moves are fast. During any scroll animation: position-only writes, resize on settle.

### Reusable prior art (licenses checked)
- **AXSwift** (MIT) — AX wrapper patterns to port; add the `_AXUIElementGetWindow` extern ourselves.
- **paneru** (MIT, Rust) — Niri-style strip on macOS; port sliver/stash logic directly.
- **PaperWM.spoon** (MIT, Lua) — tiling heuristics, gesture handling.
- **AeroSpace** (MIT) — socket protocol shape (versioned handshake, length-framed) when the plaintext protocol outgrows itself.
- **OmniWM** (GPL — *concepts only, no code*) — per-app AX threads, intent/echo ledger, CADisplayLink scroll animation.

---

## 2. Current State (verified by code review, 2026-09-12)

`~/dev/ribbon` @ `7494b56`, 1006 lines across 10 Swift files. **The daemon has never compiled** — `bin/` holds only the CLI. ~65% of Phase 0–3 scope is written, 0% verified running.

Hard blockers, in dependency order:
1. **Compile error** — `AXObserverCallback` closure captures `pid` (`AXEventObserver.swift:70`). Fix: call `AXUIElementGetPid(element, &pid)` inside the callback; no refcon box needed. Also delete the 3 gratuitous `import RibbonCore` lines (`AXElement.swift:4`, `AXEventObserver.swift:4`) — then the flat glob compiles as-is.
2. **`dispatchMain()` kills all events** (`main.swift:21`) — it services the main dispatch queue, not the main CFRunLoop, so AX observers and NSWorkspace notifications never fire. Use `RunLoop.main.run()` (or NSApplication).
3. **Window identity is broken by design** (`WindowManager.swift:59,145,153,160`) — `pid ^ title.hashValue`; destroy path guaranteed to leak zombie columns. Switch to CGWindowID.
4. **Off-ribbon windows are never moved** (`WindowManager.swift:83-91`) — the hidden branch calls the no-op `isHidden` and *skips* `setFrame`, so "zero bleed" currently does nothing.

Other confirmed defects (full review in git history / session notes): destroy notification registered on the app element instead of per-window; app termination never removes windows; `retile()` targets `NSScreen.main` (focus-dependent — can yank all windows across monitors); `focus()` raises but never activates the app (keyboard focus stays behind); no app-activation observation (focus desyncs on cross-app clicks); blocking socket `read()` on the main queue (one bad client freezes the daemon); no SIGPIPE handling (daemon crash on dead client); world-writable `/tmp/ribbon.sock`; `stop()` closes the fd under a live DispatchSource; `windowCreated` applies no role/subrole filter (dialogs get tiled); no minimized/fullscreen checks; `barf()` removes last instead of active window and leaves stale `activeRowIndex`; partially-offscreen columns bleed (only fully-offscreen detected); CLI always exits 0; `retile()` unconditionally re-focuses (echo-loop risk); README overstates ("hidden" windows, "sub-millisecond") — fix alongside.

---

## 3. Roadmap

### Phase 0: Build pipeline
- [x] Replace `build.sh` with a **Makefile**: `cli`, `daemon`, `sign` (ad-hoc default, `CODESIGN_ID` overridable), `clean`; incremental via file targets. *(Flash 3.8, 2026-09-12 — first successful daemon build.)*
- [x] Fix the callback capture (blocker 1) + remove gratuitous imports (incl. `WindowManager.swift` — flat compile needs none).
- [x] Add `bin/` to `.gitignore`.
- [ ] `bundle` target: daemon inside a minimal signed `.app` for Tahoe TCC.
- [ ] Create/reuse a stable self-signed codesign identity; sign on every build (ad-hoc `-` loses the AX grant per rebuild).

### Phase 1: Daemon boots and stays alive
- [ ] `RunLoop.main.run()` instead of `dispatchMain()` (blocker 2); SIGINT/SIGTERM handlers → `wm.stop()`.
- [ ] Socket hardening: per-user path (`$TMPDIR/ribbon.sock` or uid suffix), `chmod 0600`, stale-socket/singleton check, `SO_NOSIGPIPE`, non-blocking or dispatch-source per-connection reads, close fd in the source's cancel handler.
- [ ] CLI: nonzero exit on error, read timeout, document `cycle` alias.
- [ ] `AXUIElementSetMessagingTimeout(~1s)` on every app element; retry `AXObserverCreate` with backoff for freshly launched apps; skip ignored apps in `observeApplication`.

### Phase 2: Correct window model
- [ ] CGWindowID identity via `_AXUIElementGetWindow` (blocker 3); key all state on (pid, CGWindowID).
- [ ] Register `kAXUIElementDestroyed` **per window** (after `kAXWindowCreated`), not on the app element.
- [ ] App-termination cleanup: delegate callback removes the app's windows from ribbon + tracking.
- [ ] Liveness GC: periodic sweep validating tracked windows against CGWindowList / AX probes.
- [ ] Unified admission filter (discovery *and* `windowCreated`): role/subrole + not minimized + not fullscreen + ignore-rules; non-admitted windows are auto-floated (untouched).
- [ ] Clear `AXEnhancedUserInterface` around every frame-write batch.
- [ ] Observe `NSWorkspace` didActivate + didHide/didUnhide + `activeSpaceDidChangeNotification` (focus sync, FlashSpace compatibility, Spaces rescan); gate AX ops on `!app.isHidden`.
- [ ] Unified displayability: hidden or minimized → remove from ribbon; on unhide/unminimize → re-insert right of active column (observe `kAXMinimized` changes).
- [ ] New-window focus policy: focus + scroll only when the spawning app is frontmost; otherwise insert silently.
- [ ] Startup: adopt existing windows as columns ordered by x-position.
- [ ] Split window identity (runtime CGWindowID) from descriptor (bundle id + title pattern) in the model — enables v2 session save/restore.

### Phase 3: Layout, stash, scroll (blocker 4 lives here)
- [ ] Corner-stash placement (port paneru): configurable per-monitor corner, avoid corners adjacent to another display, persist pre-stash frames, restore all frames on quit/crash.
- [ ] Clamp/stash partially-offscreen columns — nothing renders onto an adjacent monitor.
- [ ] Minimal-scroll viewport: explicit offset on `Ribbon`, layout derives from it.
- [ ] Diff tiling plans — only touch changed windows; debounce/coalesce retiles under key repeat.
- [ ] Intent/echo ledger: record intended focus/frame changes (~100ms deadline) so our own AX echoes don't re-trigger retiles; stop unconditional re-focus in `retile()`.
- [ ] Focus across apps: `NSRunningApplication.activate` + raise; screen resolved by frame (not `NSScreen.main`); observe `didChangeScreenParametersNotification`.
- [ ] Raise-on-focus only — never raise windows during retile (z-order policy).
- [ ] Test: `focus left/right`, `cycle-width` (38→50→62→80→100%), close left-most column → neighbor flush with edge.

### Phase 4: Stacking & column ops
- [ ] Fix `barf()` (eject *active* window, re-clamp `activeRowIndex`, focus follows ejected window) and `slurp()` (point `activeRowIndex` at slurped window).
- [ ] Stack height: even split for MVP; clamp so stacks never overflow the screen (min-height floor currently marches past the bottom edge).
- [ ] Adopt manual mouse resizes into the column width ratio (observe `kAXResized` from user, via the echo ledger); manual moves snap back on next retile.
- [ ] Test `focus up/down`, `slurp`, `barf`.

### Phase 5: Integration
- [ ] Karabiner: replace Hammerspoon calls in `karabiner.edn` with `~/dev/ribbon/bin/ribbon ...`.
- [ ] FlashSpace interop: on-switch hook script → `ribbon` CLI; debounce focus-follow ~150ms after workspace change; verify no frame fights with its PiP corner-parking.
- [ ] Latency check: <100ms perceived input-to-motion (AX setFrame IPC is the floor).

### Phase 6: Multi-display & polish
- [ ] Per-screen ribbons; window→screen assignment policy; display connect/disconnect handling.
- [ ] Config file (TOML if SPM fixed, else JSON Codable) + `reload-config`.
- [ ] LaunchAgent plist / login item; README corrections.
- [ ] Config gains user-editable ignore rules (bundle id + title regex).
- [ ] v2 candidates: event-push IPC (bars/borders, stashed-sliver exclusion), manual float toggle, drag-to-reorder columns, keep-slot option for hidden windows, **sessionized layouts** (save/restore named ribbon sessions via window descriptors), native workspace switching, scroll animation (CADisplayLink, position-only writes).

---

## 4. Orchestration

- **Implementer**: Gemini Flash 3.8 via `agy -p "<task>" --model gemini-3.8-flash-high --mode accept-edits` (Antigravity CLI; Homebrew `gemini-cli` is deprecated in its favor).
- **Known quirk**: agy headless auto-denies shell/`unsandboxed` tools — file edits still apply, but Flash can't run `make` to self-verify. Either the orchestrator runs the build itself (current approach) or pass `--dangerously-skip-permissions`.
- **Orchestrator/reviewer**: Claude — writes task specs with the AX pitfalls baked in, reviews diffs, runs `make`.
- Phases 0–1 are one dependent chain: run serially. Phase 2+ items fan out.
