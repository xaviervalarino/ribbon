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

### Known macOS constraints (verified 2026-10-16, Darwin 25.6)
- **SkyLight cannot move other apps' windows.** `SLSMoveWindowWithGroup` returns 0 but WindowServer drops the move for windows the caller does not own; the caller's own windows do move (probe: WezTerm unmoved, own `NSWindow` moved 40pt). Only the Dock connection can move foreign windows (yabai scripting addition, SIP partly off). Never trust a SkyLight return code: read bounds back with `CGWindowListCopyWindowInfo`.
- `AXUIElementSetMessagingTimeout` applies to one object only (HIServices `AXUIElement.h`: "sets it only for that object"). Window elements obtained from an app element fall back to the global default, not the app element's 250ms.
- Capturing another app's window needs Screen Recording. Unpermitted, `SLSHWCaptureWindowList` returns no images, `CGWindowListCreateImage` returns nil, and ScreenCaptureKit throws `-3801`. `SLSHWCaptureWindowList` returns only the on-screen clip of a parked window. Rendering captured pixels costs 12–41ms per window, 24–150ms for five (probe, own windows).
- `SLSRegisterConnectionNotifyProc` fires for a normal process (SIP on, no injection) once `NSApplication` is initialised. Per-window events (804 window destroyed) fire only after `SLSRequestNotificationsForWindows` for those window ids, refreshed as windows come and go (as yabai does on Sequoia/Tahoe, `src/yabai.c`). Registration returns 0 for any event code, so confirm by callback.
- Swift's cooperative pool is capped at the core count and does not grow when threads block: with 8+ actors blocked, a healthy actor waited 1.5s; with 32, 7.5s (probe, `usleep` stand-ins on 8 cores).

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
- [x] `bundle` target: daemon inside a minimal signed `.app` for Tahoe TCC. *(Flash 3.8, 2026-09-13 — `bin/Ribbon.app`, `Resources/Info.plist`, LSUIElement.)*
- [ ] Create/reuse a stable self-signed codesign identity; sign on every build (ad-hoc `-` loses the AX grant per rebuild). *(Blocked on user: no codesigning identity in keychain — create one in Keychain Access, then `make CODESIGN_ID=<name>`.)*

### Phase 1: Daemon boots and stays alive
- [x] `RunLoop.main.run()` instead of `dispatchMain()` (blocker 2); SIGINT/SIGTERM handlers → `wm.stop()`. *(Flash 3.8, 2026-09-13.)*
- [x] Socket hardening: per-user path (`$TMPDIR/ribbon.sock`, fallback uid suffix), `chmod 0600`, live-daemon probe + singleton exit, `SO_NOSIGPIPE`, per-connection dispatch-source reads with 5s idle eviction, close fds in cancel handlers, EMFILE accept backoff, 104-byte sun_path guard. *(Flash 3.8 + Pro adversarial review, 2026-09-13.)*
- [x] CLI: nonzero exit on error, 2s read timeout, per-user socket path, `cycle` alias documented.
- [x] `AXUIElementSetMessagingTimeout(1s)` on app elements (observer + `AXElement.application`); `AXObserverCreate` retry with 0.5/1/2s backoff; ignored apps skipped in `observeApplication`.
- Deferred from Pro review (2026-09-13): simultaneous double-launch TOCTOU → flock lockfile (v2 hardening); single-read plaintext protocol assumes unfragmented commands → absorbed by the planned AeroSpace-style length-framed protocol; not runtime-verified yet — daemon needs the AX grant (blocked on codesign identity above).

### Phase 2: Correct window model — **done 2026-09-14** (Flash 3.8 ×4 dispatches + Pro adversarial review)
- [x] CGWindowID identity via `_AXUIElementGetWindow` (blocker 3); all state keyed on CGWindowID.
- [x] `kAXUIElementDestroyed` registered **per window**; pending-registration queue so slow-connecting apps never drop it.
- [x] App-termination cleanup (`applicationTerminated` delegate + `Ribbon.removeWindows(pid:)`).
- [x] Liveness GC: 10s CGWindowList sweep; freshly adopted ids get one grace cycle.
- [x] Unified admission filter `admits()` (role/subrole + !minimized + !fullscreen) in discovery, `windowCreated`, unhide, rescan.
- [x] `AXEnhancedUserInterface` cleared/restored around per-app frame-write batches.
- [x] NSWorkspace didActivate (focus sync via `focusedWindow`) + didHide/didUnhide + `activeSpaceDidChange` → Tier-1 rescan/reconcile.
- [x] Unified displayability: hidden/minimized leave ribbon; return re-inserts right of active via the shared `adopt()` path.
- [x] New-window focus policy: `activate: app.isActive` — background apps insert silently.
- [x] Startup adoption ordered by x-position.
- [x] Identity/descriptor split: runtime CGWindowID + persistent `bundleId`; model fully Codable.
- Socket path is now deterministic `/tmp/ribbon-<uid>.sock` (Pro finding: $TMPDIR differs across launch contexts).
- Deferred from Pro review (2026-09-14): rescan does per-app AX IPC on the main thread (~1s worst case per wedged app) — revisit with per-app AX threads; single-read socket framing → planned length-framed protocol; `focusedWindow` casts guarded by CFGetTypeID.

### Phase 3: Layout, stash, scroll (blocker 4 lives here) — done 2026-09-14
- [x] Corner-stash placement: `StashCorner` config (default bottomRight); top corners hide horizontally only (WindowServer clamps title bars at screen top); pre-adoption frames persisted to `~/.config/ribbon/restore-frames.json`, restored on clean quit; crash recovery loads the leftover file on next start so true originals survive; minimize/hide keep the original (only dead windows forget it).
- [x] Clamp/stash partially-offscreen columns — columns crossing an edge with an adjacent display get stashed instead of bleeding (`allowLeft/RightBleed` from NSScreen adjacency).
- [x] Minimal-scroll viewport: `Ribbon.viewportOffset` + `LayoutEngine.minimalScrollOffset` (clamped to `[0, stripW − canvasW]`); layout derives all x from it.
- [x] Diff tiling — `lastAppliedFrames` cache skips unchanged writes (<0.5pt) and untouched apps skip the AXEnhancedUserInterface dance; 25ms trailing-coalesce `scheduleRetile()`. Manual-drag staleness mitigated by evicting the cache entry on real focus events; proper fix is Phase 4's `kAXMoved` observation.
- [x] Echo ledger (focus intents, 150ms deadline) consumes our own activate/raise echoes; `retile()` no longer focuses anything — commands focus via `focusActiveWindow()` only when the active window changed.
- [x] Focus across apps: `NSRunningApplication.activate()` + raise; screen resolved by active-window frame overlap; display changes via `CGDisplayRegisterReconfigurationCallback` (works without NSApp, unlike `didChangeScreenParametersNotification`) — invalidates the diff cache.
- [x] Raise-on-focus only — raises happen solely in `focusActiveWindow()`.
- [x] Test: `cycle-width` + error exit codes + restore-on-quit + `focus` verified live.

### Phase 4: Stacking & column ops
- [x] Fix `barf()` (LIFO eject right, reclamp `activeRowIndex`) and `slurp()` (point `activeRowIndex` at slurped window), plus position-size-position frame application.
- [x] Stack height: even split for MVP; clamp so stacks never overflow the screen (min-height floor currently marches past the bottom edge).
- [x] Adopt manual mouse resizes into the column width ratio (observe `kAXResized` from user, via the echo ledger); manual moves snap back on next retile.
- [x] Test `focus up/down`, `slurp`, `barf`.
- [ ] Column jumps for long ribbons: `focus first|last` and `move first|last` (move the active column to the strip's start or end). One long slide each; with focus at slide end only the landing window activates.
- [ ] Window tags: mark a window with a tag, then `focus tag <name>` jumps to it from anywhere in the ribbon.
- [ ] Open questions on stacked columns (raised 2026-10-17):
  - Mail keeps a minimum width, so in a stacked column it sticks out past the column. Should the column widen to the largest minimum width of its windows? Minimum heights are already learned and honored.
  - `move` skips over a stacked column. Should it drop the window into a row of the column, or is that a separate command?
  - When a window enters a stacked column that is full, which window leaves: the last row (and the column reflows), or the row it replaces?

### Phase 5: Integration
- [x] Karabiner: replace Hammerspoon calls in `karabiner.edn` with `~/dev/ribbon/bin/ribbon ...`.
- PaperWM on/off is **manual only** (`~/.config/ribbon/paperwm.disabled` + `hs -c "hs.reload()"`, wired 2026-09-13) — user decision: ribbon must never flip this flag itself.
- [x] FlashSpace / Space interop: `ribbon rescan` and `ribbon retile` CLI commands; debounced focus-follow (150ms) after space change; sync active column to frontmost window on new Space.
- [x] Latency check: <100ms input-to-motion via immediate retile in IPC, position-only translates, and cached screen resolution.

### Phase 6: Multi-display & polish
- [x] Per-screen ribbons; window→screen assignment policy; display connect/disconnect handling.
- [ ] Config file (TOML if SPM fixed, else JSON Codable) + `reload-config`.
- [ ] LaunchAgent plist / login item; README corrections.
- [ ] Config gains user-editable ignore rules (bundle id + title regex).
- [ ] v2 candidates: event-push IPC (bars/borders, stashed-sliver exclusion), manual float toggle, drag-to-reorder columns, keep-slot option for hidden windows, **sessionized layouts** (save/restore named ribbon sessions via window descriptors), native workspace switching, scroll animation (CADisplayLink, position-only writes).

### Phase 7: Ribbon 2.0 corrections (2026-10-16)
The Ribbon 2.0 spec (agy session notes, not in repo) drove commits `6a37dd4`..`6bbcd9b`. Its SkyLight premise is false (see constraints above), and its performance figures were never measured.

**Cut from the spec:** the SkyLight move fast path (PR 3); trackpad gestures fed into `SLSMoveWindowWithGroup` (§4.1); the 85% IPC, 120Hz, <1.2ms and <0.4ms figures; the 16-byte binary IPC (`ribbon status` round trip measured 7.5ms median against 2.3ms for spawning `/usr/bin/true`, and command-to-AX-resize took 33–75ms in the 2026-10-16 daemon log, so text parsing is not the bottleneck); the "theorems" as proofs (keep them as invariants backed by tests). A capture-based curtain for smooth scrolling is rejected: it needs Screen Recording, freezes live content, and adds 25–150ms before the first frame.

**Process:** verify each PR's metric by reading the result back before the next PR builds on it.

- [x] Pure translations use one AX position write; the focus target is focused by its AppDriver after its move lands; `AXEnhancedUserInterface` stays off unless VoiceOver runs (`47587aa`).
- [ ] Give `AppDriver` a serial executor (`DispatchSerialQueue`, as the spec describes) so blocked AX calls do not hold cooperative-pool threads.
- [ ] Coalesce in `AppDriver`: an actor runs `drainQueue` to completion per message, so `isDraining` is never true and queued retiles against a hung app each pay a full drain. Stamp mutations with a retile generation and drop older ones.
- [ ] Move the applied-frame cache into the drivers, or report failures back: AX write results are discarded, so a timed-out write is cached as applied and never resent.
- [ ] Remove main-thread AX reads (`syncFocusedWindowToRibbon`, `applicationActivated`, `reconcileWindows`, on-demand re-track, event-handler size/position reads): route through drivers or use `CGWindowListCopyWindowInfo`. Set the 250ms timeout on every window element when it is tracked.
- [ ] Cache `AXEnhancedUserInterface` per PID instead of reading it every batch.
- [ ] Top/bottom stash edges contradict the Phase 3 note on title-bar clamping (`FreeEdgeStashEngine.swift` `.top` parks at `minY - h + 1`): verify on hardware or restrict stashing to left/right.
- [ ] Delete `SkyLightBridge.moveWindow` (unused since `47587aa`).
- [ ] Measure the floor: AX position-write latency per app class (AppKit, Electron, Firefox) and keypress-to-last-write, before any smoothness work.
- [ ] Experiment: atomic cut. Wrap a batch in `SLSDisableUpdate`/`SLSReenableUpdate` on Ribbon's connection and await all drivers (~100ms cap); confirm it freezes compositing globally so every window jumps in one frame.
- [ ] Experiment: slide only the focused column with ~10 AX position writes over ≤180ms (PaperWM.spoon approach); expect lag on Electron.
- [ ] Experiment: trackpad follow (spec §4.1 reworked) with throttled AX position writes, one per frame per visible window, from a `CGEventTap` on continuous scroll events.
- [x] Resize timing A/B (2026-10-17; 3 slurps and 3 barfs per round, 0.4s apart; `slow step` lines in the daemon log). `instant` stalls the resizing app's slide 42–124ms at slide-ms 100 and 44–65ms at 55; `end` stalls 0; `grow-first` stalls only on barf (40–60ms). The stall is the app's resize time, so slide length does not shorten it. Defaults are now `resize-mode end` and `slide-ms 55`. Trade-off: on barf, `end` shows the desktop beside growing windows until the slide lands.
- [ ] Open: long slides may favor `grow-first`, since `end` shows the desktop for the whole slide while a 40–60ms stall shrinks as a share of it. The threshold is unmeasured; rerun the A/B at slide-ms 150, 200 and 300 before tying resize timing to slide length or adding a config option.
- [ ] Experiment: SLS notify pump (spec PR 5). Confirm event 1401 maps 1:1 to a manual Space switch before relying on it; `NSWorkspace.activeSpaceDidChangeNotification` stays the source of truth until then.

---

## 4. Orchestration

- **Implementer**: Gemini Flash 3.8 via `agy -p "<task>" --model gemini-3.8-flash-high --mode accept-edits` (Antigravity CLI; Homebrew `gemini-cli` is deprecated in its favor).
- **Known quirk**: agy headless auto-denies shell/`unsandboxed` tools — file edits still apply, but Flash can't run `make` to self-verify. Either the orchestrator runs the build itself (current approach) or pass `--dangerously-skip-permissions`.
- **Orchestrator/reviewer**: Claude — writes task specs with the AX pitfalls baked in, reviews diffs, runs `make`.
- Phases 0–1 are one dependent chain: run serially. Phase 2+ items fan out.
