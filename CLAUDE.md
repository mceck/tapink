# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TapInk is a native macOS menu-bar screen-annotation app: it lives in the tray, and on activation shows a
transparent overlay on top of the live screen (not a screenshot) that you can draw on, across every
connected monitor. Swift Package Manager project, AppKit for system-level pieces (status item, overlay
windows, event monitoring), SwiftUI for toolbar/Settings/About content. Target: macOS 14 Sonoma+,
unsandboxed, ad-hoc/personal-team signed (not App Store).

## Commands

```bash
swift build                 # debug build, fast inner loop for compile-error checking
swift test                   # runs Tests/TapInkKitTests
swift test --filter DrawingDocumentTests            # run a single test case
swift test --filter DrawingDocumentTests/testUndoRemovesLastObject   # run a single test method

Scripts/build.sh             # release build -> assembles & codesigns TapInk.app
Scripts/install.sh           # copies the built TapInk.app into /Applications
```

Run via `open .build/output/TapInk.app` (after `build.sh`) or `open /Applications/TapInk.app` (after
`install.sh`). **Never run the raw binary directly** (`.build/*/TapInk`) — outside a real `.app` bundle it
isn't registered with LaunchServices, so it can't take real keyboard focus and the menu bar item misbehaves.
No Xcode project on purpose: the app is hand-assembled from the terminal.

`build.sh` prefers an "Apple Development" signing identity already in the keychain (stable Team ID, so
Accessibility/Screen Recording grants survive rebuilds); falls back to ad-hoc `--sign -` (TCC permissions
must be re-granted every rebuild). `Package.swift` pins `swift-tools-version: 5.10` (not 6.x) to keep Swift 5
/ relaxed concurrency checking, since the codebase leans on classic AppKit delegate/closure patterns.

## Architecture

### Module layout
- `Sources/TapInk` — thin executable target: `main.swift` bootstraps `NSApplication`, `AppDelegate.swift`
  wires the permission dance. Almost no logic lives here.
- `Sources/TapInkKit` — library target with everything else, by concern: `Model/`, `Windowing/`,
  `Hotkeys/`, `Screenshot/`, `Recording/`, `Settings/`, `MenuBar/`, `UI/`. Unit-testable without a GUI/bundle.

### `DrawSessionCoordinator` is the hub
`Windowing/DrawSessionCoordinator.swift` is an `ObservableObject` owning the whole draw-mode session: one
`OverlayWindowController` per `NSScreen`, the single `ToolbarPanelController`, the shared `DrawingDocument`,
the current `ToolState`. Hotkeys, toolbar buttons, and the status-item menu all call into this one object —
fix window-focus/lifecycle bugs here, not with ad-hoc window calls elsewhere.

### Window/panel architecture — read before touching anything focus-related
Two `NSPanel` kinds per session: one borderless/transparent `.nonactivatingPanel` overlay per screen
(`OverlayWindowController` + `CanvasView`, `.screenSaver` level, `[.canJoinAllSpaces, .fullScreenAuxiliary,
.stationary, .ignoresCycle]`) so it sits above full-screen apps and follows Spaces; and one draggable
toolbar panel (`ToolbarPanelController`) one level above, hosting SwiftUI `ToolbarView` via `NSHostingView`.
Toggle overlays via `orderOut`/`orderFrontRegardless` + `ignoresMouseEvents` — **never** mutate the style
mask after construction (AppKit doesn't propagate `.nonactivatingPanel` changes post-init reliably).

Mouse routing depends only on which window is topmost at the click (not key/active status), so every canvas
is mouse-interactive simultaneously without any becoming key. **Keyboard/`mouseMoved` do depend on
activation/key status** — three gotchas already hit once, don't regress them:
- **Activation:** `enableDrawMode()` calls the *legacy* `NSApp.activate(ignoringOtherApps: true)`, not
  macOS 14's `NSApp.activate()` — the new cooperative API doesn't guarantee it hands over keyboard focus,
  which silently broke Esc/undo/redo/shortcuts/text entry. Must stay synchronous inside the hotkey handler
  (no `DispatchQueue.main.async` hop). `disableDrawMode()` restores the previously-frontmost app via
  `NSRunningApplication.activate(options:)`.
- **`canBecomeKey`:** both panel types use `styleMask: [.borderless, .nonactivatingPanel]`, but AppKit
  defaults `canBecomeKey` to `false` without `.titled` — confirmed empirically. `.nonactivatingPanel` only
  affects whether ordering-front steals app activation, not whether the panel can become key once asked.
  Both controllers use `KeyablePanel` (`Windowing/KeyablePanel.swift`), an `NSPanel` override, instead of
  plain `NSPanel` — without it, `makeKeyAndOrderFront` orders front but grants no key status, so keystrokes
  have nowhere to route (this is why the text tool used to eat every typed character).
- **Text tool focus handoff:** only the toolbar is key by default. `CanvasView.beginTextEditing` calls
  `window?.makeKeyAndOrderFront(nil)` on that screen's own overlay before making the text view first
  responder; `endTextEditing()`/`cancelTextEditing()` hand key back via `ToolbarPanelController.reclaimKey()`.

**Spotlight tool across monitors:** uses an `NSTrackingArea` with `.activeAlways` (not just
`acceptsMouseMovedEvents`) so `mouseMoved`/`mouseExited` fire regardless of key status — otherwise spotlight
only worked on whichever screen held key. `mouseExited` clears the mask so it doesn't freeze when the
cursor leaves a screen.

### Hotkeys — two tiers, on purpose
`Hotkeys/HotkeyManager.swift`: a persistent **global** monitor handles only draw-mode activation (must fire
with no TapInk window yet; requires Accessibility trust). A **local** monitor handles every other shortcut,
only while draw mode is active, returning `nil` to swallow the event so it doesn't reach whatever's behind
the overlay. Matching goes through `AppSettings.binding(for:)` (user overrides over `ShortcutBinding
.defaults`) — **to add a rebindable action**, update `ShortcutAction`, `ShortcutBinding.defaults`, and the
`actions` list in `HotkeyManager.handleLocal`.

### Drawing engine
`DrawingDocument` (Model) is the single source of truth: an ordered array of `DrawingObject` (stroke/shape/
text, each tagged with its `CGDirectDisplayID`) plus **one global undo/redo stack shared across all
monitors** (they're all visible at once, so "undo" has one obvious meaning regardless of screen).
`CanvasView.draw(_:)` replays a screen's objects from the vector list every frame — no bitmap cache;
deliberate, since a full redraw is fine at realistic stroke counts. Only the in-progress stroke/shape draws
on top during an active drag.

### Screenshot pipeline
`Screenshot/ScreenshotService.swift` uses `ScreenCaptureKit`'s `SCScreenshotManager.captureImage` (not the
legacy `CGWindowListCreateImage`). Captures the display under the cursor at shortcut time, excluding only
the toolbar's window ID via `SCContentFilter(display:excludingApplications:exceptingWindows:)` — **always**
that initializer, even with an empty exclude list (the `excludingWindows:`-only variant fails to start with
one). `SCDisplay.width/height` are points, `SCStreamConfiguration`'s are pixels — both `capture` and
`captureRegion` scale by `NSScreen.backingScaleFactor` or Retina captures come out under-resolution. Every
capture plays `Resources/CameraShutter.wav` (synthesized; no public shutter-sound API) then copies to the
pasteboard or saves a timestamped PNG to `AppSettings.screenshotSaveFolderPath` (⌘S disk, ⌘C clipboard).

**Selected-area screenshot:** ⌘⇧A (or the toolbar's capture dropdown) calls `beginRegionScreenshotSelection
()`, arming every `CanvasView` into crosshair drag-select mode (`setRegionSelectionActive`) without touching
`toolState`. The completed rect is in the *originating screen's bottom-left-origin view-local coordinates*;
`completeRegionSelection` routes it onward and `captureRegion` flips it to top-left pixel space before
`CGImage.cropping(to:)` — get the flip wrong and the crop comes out vertically-mirrored-in-position.
Destination is a separate setting (`AppSettings.regionScreenshotDestination`) from full-screen ⌘C/⌘S, which
always mean copy/save regardless of it.

### Screen recording pipeline
`Recording/ScreenRecordingService.swift` is `ScreenshotService`'s stateful sibling: keeps an `SCStream`
running, feeding sample buffers straight into an `AVAssetWriter` (H.264, `.mov`) saved alongside screenshots
in `AppSettings.screenshotSaveFolderPath` (`TapInk Recording <timestamp>.mov`). No audio track
(`capturesAudio` stays `false` — not requested, would need mic permission).

- **One recording at a time:** `DrawSessionCoordinator.activeRecordingKind` (`.screen`/`.region`/`nil`).
  `ToolbarView.captureButton` is a `@ViewBuilder`: while nothing's recording it's a `Menu` with all four
  actions (Screenshot Screen/Area, Record Screen/Area); once a recording starts it swaps to a plain red stop
  button (`stopRecording()` directly, no dropdown) — stopping must be a single click, not a menu traversal.
- Region screenshot and region recording **share the same crosshair drag-select flow**
  (`isSelectingRegion`); `pendingRegionPurpose` (private, set by `beginRegion{Screenshot,Recording}Selection`)
  decides which one runs once the drag completes.
- **Crops at the source**, not per-frame: `SCStreamConfiguration.sourceRect` (points, top-left origin —
  flipped from the region's bottom-left AppKit coords by `ScreenRecordingService.sourceRect(...)`) tells
  `SCStream` to only capture that sub-rect. `width`/`height` are Retina-scaled like the screenshot path, then
  rounded to the nearest **even** number (`evenPixelLength`) — H.264 4:2:0 chroma subsampling can reject odd
  dimensions.
- **Persistent frame overlay while recording a region:** `CanvasView.setActiveRecordingFrame(_:)` draws a
  red border around the recorded rect for the whole recording (unlike the transient drag-select overlay,
  which disappears once the drag ends). Drawn with an *outward* margin — never on/inside the rect's edge —
  since that rect is exactly `sourceRect`'s crop; a border on the boundary would partially leak into the
  captured video.
- **Cursor visible by default** (`AppSettings.recordCursorInVideos`, toggle in Settings) — opposite of
  screenshots (`showsCursor = false`), since seeing the pointer matters for a tutorial-style recording.
- Only `SCFrameStatus.complete` frames are appended — other statuses (`.idle`, `.suspended`, ...) can carry
  no real image. `stop()` schedules `AVAssetWriterInput.markAsFinished()` onto the same serial queue the
  stream callback runs on (not called directly from the `@MainActor` caller), so it only runs after every
  already-queued buffer — appending to a finished input raises.

### Toast HUD feedback
`Windowing/ToastPanelController.swift` + `UI/ToastView.swift`: a single reusable borderless panel that
shows a brief icon+text pill near the bottom of whichever screen currently hosts the toolbar
(`ToolbarPanelController.currentScreen`), then fades out on its own (animated fade in/hold/fade out) — used
for draw-mode on/off, tool/shape changes, screenshot taken, recording saved, freeze/unfreeze background,
auto-fade toggle, and canvas cleared (`DrawSessionCoordinator.showToast`, called from each of those actions).
Like the toolbar, its window must be excluded from screenshots/recordings
(`DrawSessionCoordinator.excludedCaptureWindowNumbers` bundles both). A few deliberate silences worth
knowing about: tool-change toasts skip spotlight entirely (mouse-driven, toggled too rapidly to announce)
and only fire when the tool/shape actually changed (`selectTool`/`setShape` guard on that); freeze/unfreeze
toasts live in `toggleFreezeBackground()` specifically, not in `freezeBackground()`/`unfreezeBackground()`
themselves, since those two are also called internally as a silent state reset by `enableDrawMode()`/
`disableDrawMode()`.

**Gotcha (already hit and fixed once — don't regress it):** every `Task { ... }` in
`DrawSessionCoordinator` that `await`s a `@MainActor`-isolated call (`ScreenshotService`/
`ScreenRecordingService`'s methods all are) and then touches AppKit afterward — showing a toast,
mutating a `@Published` property, calling `setActiveRecordingFrame` — must itself be
`Task { @MainActor in ... }`. Without it, resuming after the `await` isn't guaranteed to land back
on the main thread, and AppKit calls off-main crash. This is exactly what was crashing the
screenshot/recording toasts before every such `Task` in that file got the annotation.

### Settings & login item
`Settings/AppSettings.swift` wraps `UserDefaults` (dock-hide flag, screenshot/recording folder, cursor-in-
recordings flag, shortcut overrides). `Settings/LoginItemManager.swift` wraps `SMAppService.mainApp`, which
only works reliably from a stable path — hence `install.sh` copying to `/Applications`. Hide-from-Dock is a
live-toggleable `NSApp.setActivationPolicy(.accessory/.regular)` on top of the static `LSUIElement=true` in
`Info.plist` (see `AppDelegate` launch methods for the two-step dance avoiding a Dock-icon flash).
