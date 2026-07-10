# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Drawzee is a native macOS menu-bar screen-annotation app: it lives in the tray,
and on activation shows a transparent overlay on top of the live screen (not a screenshot) that you can
draw on, across every connected monitor. Swift Package Manager project, AppKit for all system-level
pieces (status item, overlay windows, event monitoring), SwiftUI for the toolbar/Settings/About content.
Target: macOS 14 Sonoma+, unsandboxed, ad-hoc/personal-team signed (not distributed via the App Store).

## Commands

```bash
swift build                 # debug build, fast inner loop for compile-error checking
swift test                   # runs Tests/DrawzeeKitTests (undo/redo, shortcut encode/decode)
swift test --filter DrawingDocumentTests            # run a single test case
swift test --filter DrawingDocumentTests/testUndoRemovesLastObject   # run a single test method

Scripts/build.sh             # release build -> assembles & codesigns Drawzee.app (see Build pipeline below)
Scripts/install.sh           # copies the built Drawzee.app into /Applications
```

To actually run the app: `open .build/output/Drawzee.app` (after `Scripts/build.sh`) or
`open /Applications/Drawzee.app` (after `Scripts/install.sh`). **Never run the raw binary directly**
(`.build/*/Drawzee`) — an executable run outside a real `.app` bundle isn't registered with
LaunchServices, so it can't take real keyboard focus and the menu bar item misbehaves. This is also why
there is no Xcode project in this repo: the app is built and iterated on entirely from the terminal by
hand-assembling the bundle, rather than authoring a `.xcodeproj`.

`Scripts/build.sh` prefers signing with an "Apple Development" identity already in the keychain (gives a
stable Team ID, so Accessibility/Screen Recording grants survive rebuilds); it falls back to ad-hoc
`--sign -` with a warning if none is found, which means TCC permissions have to be re-granted every
rebuild. `Package.swift` pins `swift-tools-version: 5.10` deliberately (not 6.x) to keep Swift 5 language
mode / relaxed concurrency checking, since the codebase leans on classic AppKit delegate/closure patterns
that would otherwise fight strict Swift 6 concurrency checking.

## Architecture

### Module layout
- `Sources/Drawzee` — thin executable target: `main.swift` bootstraps `NSApplication`, `AppDelegate.swift`
  wires the permission dance and instantiates the pieces below. Almost no logic lives here.
- `Sources/DrawzeeKit` — a library target with everything else, structured by concern
  (`Model/`, `Windowing/`, `Hotkeys/`, `Screenshot/`, `Settings/`, `MenuBar/`, `UI/`), unit-testable in
  isolation from any GUI/bundle context.

### `DrawSessionCoordinator` is the hub
`Windowing/DrawSessionCoordinator.swift` is an `ObservableObject` that owns the entire draw-mode session:
one `OverlayWindowController` per `NSScreen`, the single `ToolbarPanelController`, the shared
`DrawingDocument`, and the current `ToolState`. Nearly everything else (hotkeys, toolbar buttons, the
status-item menu) calls into this one object rather than manipulating windows directly — window-focus and
lifecycle bugs should be fixed here, not by adding ad-hoc window calls elsewhere.

### Window/panel architecture — read this before touching anything focus-related
Two distinct kinds of `NSPanel` exist per draw-mode session:
- One borderless, transparent, `.nonactivatingPanel` overlay per screen (`OverlayWindowController` +
  `CanvasView`), at `.screenSaver` window level with `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary, .ignoresCycle]` collection behavior, so it sits above full-screen apps and follows across
  Spaces. Toggled via `orderOut`/`orderFrontRegardless` + `ignoresMouseEvents` — **never** touch the
  style mask after construction (known AppKit issue: mutating `.nonactivatingPanel` post-init doesn't
  propagate reliably).
- One draggable toolbar panel (`ToolbarPanelController`), one level above the canvases, hosting the
  SwiftUI `ToolbarView` via `NSHostingView`.

Mouse routing doesn't depend on key/active status (AppKit routes clicks to whichever window is topmost at
the cursor), which is why every canvas can be simultaneously mouse-interactive without any of them
becoming key. **Keyboard and `mouseMoved` do depend on activation/key status**, which was the source of
several real bugs (see the two callouts below) — don't assume "the window is visible and mouse-interactive"
implies "it also receives keyboard/moved events."

**Activation gotcha (already hit and fixed once — don't regress it):** `DrawSessionCoordinator.
enableDrawMode()` deliberately calls the *legacy* `NSApp.activate(ignoringOtherApps: true)`, not the
newer macOS 14 `NSApp.activate()`. The new cooperative API explicitly does not guarantee it will actually
hand over keyboard focus ("the framework does not guarantee that the app will be activated at all" per the
AppKit header) — using it silently broke Esc/undo/redo/screenshot shortcuts and text entry. The call must
also stay synchronous inside the hotkey handler (no `DispatchQueue.main.async` hop) so macOS still treats
it as a direct response to the user's keypress. `disableDrawMode()` restores focus to whatever app was
frontmost before via `NSRunningApplication.activate(options:)`.

**Text tool focus handoff:** only the toolbar panel is key by default. When the text tool starts editing,
`CanvasView.beginTextEditing` explicitly calls `window?.makeKeyAndOrderFront(nil)` on that screen's own
overlay panel before making its text view first responder; `DrawSessionCoordinator.endTextEditing()` /
`cancelTextEditing()` hand key status back to the toolbar via `ToolbarPanelController.reclaimKey()`.

**`canBecomeKey` gotcha (already hit and fixed once — don't regress it):** both panel types use
`styleMask: [.borderless, .nonactivatingPanel]`, but AppKit's default `canBecomeKey` is `false` for any
window without `.titled` in its style mask — confirmed empirically, not just from docs, since this is easy
to get wrong. `.nonactivatingPanel` only controls whether *ordering the panel front* steals app activation;
it says nothing about whether the panel can become key once asked. Without an override, `makeKeyAndOrderFront`
silently orders the panel to the front but never actually grants key status, so keystrokes have no window to
route to — this was exactly why the text tool accepted the initial click but silently ate every typed
character. Both `OverlayWindowController` and `ToolbarPanelController` construct `KeyablePanel`
(`Windowing/KeyablePanel.swift`), an `NSPanel` subclass that overrides `canBecomeKey` to `true`, instead of
plain `NSPanel`.

**Spotlight tool across monitors:** relies on a `NSTrackingArea` with `.activeAlways` (not just
`NSWindow.acceptsMouseMovedEvents`) so `mouseMoved:`/`mouseExited:` fire regardless of which screen
currently holds key status — without `.activeAlways` the spotlight only worked on whichever screen the
toolbar/key window happened to be on. `mouseExited` clears the mask so it doesn't freeze on a screen the
cursor just left.

### Hotkeys — two tiers, on purpose
`Hotkeys/HotkeyManager.swift`: a persistent **global** monitor (`NSEvent.addGlobalMonitorForEvents`)
handles only draw-mode activation, since it must fire even with no Drawzee window yet (requires
Accessibility trust; can't consume the event, but that's fine since the default ⌥Tab binding has no OS
meaning). A **local** monitor (`NSEvent.addLocalMonitorForEvents`) handles every other shortcut
(Esc/undo/redo/screenshot/tool-select/hide-canvas) only while draw mode is active, returning `nil` to
swallow the event so it doesn't also reach whatever app is visually behind the overlay. Shortcut→action
matching goes through `AppSettings.binding(for:)`, which merges user overrides (persisted as JSON in
`UserDefaults`) over the `ShortcutBinding.defaults` table — add new rebindable actions to
`ShortcutAction`, `ShortcutBinding.defaults`, and the `actions` list in `HotkeyManager.handleLocal`.

### Drawing engine
`DrawingDocument` (Model) is the single source of truth: an ordered array of `DrawingObject` (stroke /
shape / text, each tagged with the `CGDirectDisplayID` it was drawn on) plus **one global undo/redo
stack shared across all monitors** (not per-screen — monitors are all visible at once, so "undo my last
action" has one obvious meaning regardless of which physical screen it landed on). `CanvasView.draw(_:)`
replays that screen's objects from the vector list every frame — there's no bitmap cache; this is simpler
and was deliberately chosen over the originally-planned cache since a full redraw is fine at the stroke
counts a screen-annotation session actually accumulates. Only the in-progress stroke/shape is drawn on top
during an active drag.

### Screenshot pipeline
`Screenshot/ScreenshotService.swift` uses `ScreenCaptureKit` (`SCScreenshotManager.captureImage`), not the
legacy `CGWindowListCreateImage`. It captures the display under the cursor at the moment of the shortcut
(independent of wherever the toolbar currently is — see the two distinct "which screen" notions in
`DrawSessionCoordinator`), and excludes only the toolbar's window ID via
`SCContentFilter(display:excludingApplications:exceptingWindows:)` — always that initializer, even with an
empty exclude list, since the `excludingWindows:`-only variant is known to fail to start the stream with
an empty array. `SCDisplay.width`/`height` are in *points*, but `SCStreamConfiguration`'s are in *pixels* —
both `capture` and `captureRegion` scale by `NSScreen.backingScaleFactor` when building the config, or
captures on Retina displays come out at less than native resolution. Every capture plays
`Resources/CameraShutter.wav` (a synthesized double-click, since macOS has no public shutter-sound
API/asset) and then either copies to the pasteboard or saves a timestamped PNG to
`AppSettings.screenshotSaveFolderPath`. ⌘S saves to disk, ⌘C copies.

**Selected-area screenshot:** the toolbar's camera button and ⌘⇧A call
`DrawSessionCoordinator.beginRegionScreenshotSelection()`, which puts every screen's `CanvasView` into a
transient crosshair drag-to-select mode (`CanvasView.setRegionSelectionActive` — an `NSCursor.crosshair`
cursor rect plus short-circuiting `mouseDown`/`mouseDragged`/`mouseUp` before the normal tool switch) without
touching `toolState`, so whichever drawing tool was selected before is still selected after. The rect handed
to `completeRegionScreenshot` is in the *originating screen's own view-local coordinates* (bottom-left
origin, matching `CanvasView.bounds`); `ScreenshotService.captureRegion` flips it to top-left-origin pixel
space before `CGImage.cropping(to:)` — get this flip wrong and the crop silently comes out
vertically-mirrored-in-position. Destination (clipboard vs. `AppSettings.screenshotSaveFolderPath`) is a
separate user setting (`AppSettings.regionScreenshotDestination`, default clipboard) from full-screen ⌘C/⌘S,
which always mean copy/save respectively regardless of it.

### Settings & login item
`Settings/AppSettings.swift` wraps `UserDefaults` (hide-from-dock flag, screenshot folder, shortcut
overrides). `Settings/LoginItemManager.swift` wraps `SMAppService.mainApp` — this only works reliably when
Drawzee runs from a stable path, hence `Scripts/install.sh` copying to `/Applications`. Hide-from-Dock is
a live-toggleable `NSApp.setActivationPolicy(.accessory/.regular)` on top of the static `LSUIElement=true`
baseline in `Info.plist` (see `AppDelegate.applicationWillFinishLaunching`/`applicationDidFinishLaunching`
for the two-step dance that avoids a Dock-icon flash on launch).
