import SwiftUI
import AppKit

/// Reports this view's frame in its window's own (AppKit, bottom-left-origin) coordinate system
/// on every layout pass — used instead of a SwiftUI `GeometryReader`'s `.global` frame so handing
/// it to `NSWindow.convertToScreen` (see `ToolbarPanelController.screenFrame(forWindowLocalRect:)`)
/// needs no manual coordinate-space flip.
private struct WindowFrameReporter: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((CGRect) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // `layout()` isn't reliably invoked on a plain, constraint-less NSView — this
            // fires on any change to the view's own frame, including ones SwiftUI applies here
            // as a *result* of an ancestor's layout changing (collapsing the sidebar, a
            // different capture button width, ...), since that still ends in AppKit setting
            // this view's `frame` property.
            postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(reportFrame), name: NSView.frameDidChangeNotification, object: self
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        @objc private func reportFrame() {
            onChange?(convert(bounds, to: nil))
        }
    }
}

/// Shows a floating label just outside the sidebar (left or right, whichever has room — see
/// `TooltipPanelController`) after a short hover delay. Deliberately not `.help(_:)`: a real
/// `NSHelpTag` tooltip always appears right at the cursor with no way to pin it to a fixed side
/// of the whole toolbar, which is what was asked for here.
private struct SidebarTooltip: ViewModifier {
    let text: String
    @ObservedObject var coordinator: DrawSessionCoordinator
    @State private var frameInWindow: CGRect = .zero
    @State private var showWorkItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .background(WindowFrameReporter { frameInWindow = $0 })
            .onHover { hovering in
                showWorkItem?.cancel()
                guard hovering else {
                    coordinator.hideTooltip()
                    return
                }
                let workItem = DispatchWorkItem { coordinator.showTooltip(text, forButtonAt: frameInWindow) }
                showWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
            }
    }
}

private extension View {
    func sidebarTooltip(_ text: String, coordinator: DrawSessionCoordinator) -> some View {
        modifier(SidebarTooltip(text: text, coordinator: coordinator))
    }
}

/// AppKit-side mouse handling for a "click or open a menu" button, layered over the SwiftUI
/// label as an `.overlay` so it is the view AppKit actually hit-tests for the button's clicks.
/// All three interactions live here rather than in SwiftUI gestures: a short click fires
/// `onClick`, holding past `longPressDuration` pops the menu, and a right-click pops the same
/// menu immediately. The previous split — `onLongPressGesture` in SwiftUI plus a *background*
/// `NSView` catching `rightMouseDown` — never worked: the interactive SwiftUI content above the
/// background view claimed its events (so the right-click never arrived), and popping an
/// `NSMenu` from inside a SwiftUI gesture callback runs outside AppKit's real mouse-tracking
/// context, so the menu was dismissed by the still-pending mouse-up instead of opening. Real
/// `mouseDown`/`rightMouseDown` overrides give `NSMenu` the genuine event context, and its
/// native press-and-hold tracking (hold–drag–release or release-then-click) comes for free.
private struct MenuButtonInteraction: NSViewRepresentable {
    let longPressDuration: TimeInterval
    let onClick: () -> Void
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InteractionView) {
        view.longPressDuration = longPressDuration
        view.onClick = onClick
        view.makeMenu = makeMenu
    }

    final class InteractionView: NSView {
        var longPressDuration: TimeInterval = 0.4
        var onClick: (() -> Void)?
        var makeMenu: (() -> NSMenu)?

        private static let dragCancelDistance: CGFloat = 10

        /// The toolbar panel is `isMovableByWindowBackground`; without this, pressing the
        /// button would also start dragging the whole toolbar around.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Without this, a click here while the toolbar isn't key (e.g. right after drawing
        /// a stroke hands key status to that screen's canvas overlay — see
        /// `CanvasView.acceptsFirstMouse`) only brings the toolbar back to key and is swallowed
        /// before reaching `mouseDown` below, so the shape button's first click after drawing
        /// did nothing. Every other toolbar button lives directly in the hosting view's own
        /// SwiftUI content and doesn't hit this; only this button overlays its own real `NSView`.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = event.locationInWindow
            let deadline = Date(timeIntervalSinceNow: longPressDuration)
            // Classic AppKit click-and-hold: consume this press's own event stream until it
            // resolves into a click (mouse up in time), a long press (deadline passes with the
            // button still down), or a drag away from the button (cancel).
            while true {
                guard let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: deadline,
                    inMode: .eventTracking,
                    dequeue: true
                ) else {
                    popUpMenu()
                    return
                }
                if next.type == .leftMouseUp {
                    onClick?()
                    return
                }
                let point = next.locationInWindow
                if hypot(point.x - start.x, point.y - start.y) > Self.dragCancelDistance {
                    return
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        /// Pops the menu beside the button rather than on top of it: mid-long-press the cursor
        /// is still down inside the button, and a menu opening underneath it risks the release
        /// landing on (and instantly triggering) whatever item happens to be there.
        private func popUpMenu() {
            guard let menu = makeMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX + 6, y: bounds.maxY), in: self)
        }
    }
}

/// Bridges a Swift closure to the target/action selector a plain `NSMenuItem` requires.
/// `NSMenuItem.target` is `weak`, so each item's own `representedObject` (which the item *does*
/// hold strongly) keeps its action alive for as long as the item exists — no separate owner needed.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

private extension NSEvent.ModifierFlags {
    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

/// Applies a real `.keyboardShortcut` — which SwiftUI renders on its `Menu` item exactly like
/// `showShapeMenu`'s hand-set `NSMenuItem.keyEquivalent` (right-aligned, muted color, for free) —
/// only when the live binding reduces to a plain single character; a no-op otherwise, leaving the
/// shortcut spelled out in the item's own label text as a fallback.
private struct OptionalKeyboardShortcut: ViewModifier {
    let binding: ShortcutBinding

    func body(content: Content) -> some View {
        if let character = binding.singleCharacterKeyEquivalent {
            content.keyboardShortcut(KeyEquivalent(character), modifiers: binding.modifierFlags.swiftUIModifiers)
        } else {
            content
        }
    }
}

struct ToolbarView: View {
    @ObservedObject var coordinator: DrawSessionCoordinator
    @State private var showColorPicker = false
    @State private var showFillColorPicker = false
    @State private var showSizePicker = false

    private static let longPressDuration: TimeInterval = 0.4

    var body: some View {
        VStack(spacing: 10) {
            colorSwatchRow

            if coordinator.isSidebarCollapsed {
                collapsedToolIndicator
                    .transition(.opacity)
            }

            if !coordinator.isSidebarCollapsed {
                Group {
                    sizeSwatch

                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 26, height: 1)

                    toolButton(.pen, systemName: "pencil.tip")
                    toolButton(.highlighter, systemName: "paintbrush.pointed.fill")
                    shapeButton
                    toolButton(.text, systemName: "textformat")
                    toolButton(.move, systemName: "cursorarrow")
                    toolButton(.eraser, systemName: "eraser")

                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 26, height: 1)

                    captureButton
                    Button {
                        coordinator.toggleFreezeBackground()
                    } label: {
                        iconLabel(systemName: "snowflake", selected: coordinator.isBackgroundFrozen)
                    }
                    .buttonStyle(.plain)
                    .sidebarTooltip(tip("Freeze Background", .freezeBackground), coordinator: coordinator)
                    Button {
                        coordinator.toggleAutofade()
                    } label: {
                        iconLabel(systemName: "timer", selected: coordinator.isAutofadeEnabled)
                    }
                    .buttonStyle(.plain)
                    .sidebarTooltip(tip("Auto-Fade Drawings", .toggleAutofade), coordinator: coordinator)
                    actionButton(systemName: "trash.fill") {
                        coordinator.clearCanvas()
                    }
                    .sidebarTooltip(tip("Clear Canvas", .clearCanvas), coordinator: coordinator)
                }
                .transition(.opacity)
            }

            collapseButton

            if !coordinator.isSidebarCollapsed {
                actionButton(systemName: "xmark.circle.fill", tint: .red) {
                    coordinator.disableDrawMode()
                }
                .transition(.opacity)
                .sidebarTooltip(tip("Exit Draw Mode", .exitDrawMode), coordinator: coordinator)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        // `NSHostingView` centers content that's smaller than its own bounds by
        // default. While collapsing/expanding, the panel's actual frame briefly
        // lags behind (or leads) the VStack's own ideal size, and without pinning
        // to the top here the whole toolbar would visibly drift toward the
        // panel's vertical center during that gap instead of staying anchored
        // at the color swatch, which is what made the resize read as a glitch.
        .frame(maxHeight: .infinity, alignment: .top)
        // Placed last so it wraps every modifier above, including the frame/
        // alignment change — `DrawSessionCoordinator.toggleSidebarCollapsed`
        // also wraps its own mutation in `withAnimation` for the branch that
        // isn't already covered by an async dispatch.
        .animation(.easeInOut(duration: DrawSessionCoordinator.sidebarAnimationDuration), value: coordinator.isSidebarCollapsed)
    }

    private var collapseButton: some View {
        Button {
            coordinator.toggleSidebarCollapsed()
        } label: {
            iconLabel(systemName: "chevron.up", selected: false)
                .rotationEffect(.degrees(coordinator.isSidebarCollapsed ? 180 : 0))
                // Image's default hit area hugs the glyph itself (thin for a
                // chevron), not the 32x32 frame around it — same class of issue
                // as the brush-size dot below; widen it to the whole square.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarTooltip(
            tip(coordinator.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar", .toggleSidebar),
            coordinator: coordinator
        )
    }

    private var colorSwatch: some View {
        Button {
            showColorPicker.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: coordinator.toolState.color))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
            ColorPickerPopover(coordinator: coordinator)
        }
        .sidebarTooltip("Color (\(shortcutText(.nextColor)) cycles)", coordinator: coordinator)
    }

    /// Fill only means anything for the shape tool, so its swatch only appears alongside the
    /// main color swatch while `.shape` is selected — smaller, offset down-right, and declared
    /// first so it paints behind the (in-front) main swatch, mirroring the classic stroke-over-
    /// fill dual color well look (e.g. Finder's/Preview's color icon).
    private var colorSwatchRow: some View {
        ZStack {
            if coordinator.toolState.selectedTool == .shape {
                fillColorSwatch
                    .offset(x: 10, y: 10)
                    .transition(.opacity)
            }
            colorSwatch
        }
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.15), value: coordinator.toolState.selectedTool == .shape)
    }

    private var fillColorSwatch: some View {
        Button {
            showFillColorPicker.toggle()
        } label: {
            ZStack {
                CheckerboardSwatchBackground()
                Circle().fill(Color(nsColor: coordinator.toolState.fillColor))
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            // Otherwise only the tiny sliver poking out from behind the main swatch is
            // clickable — same class of issue as the brush-size dot elsewhere in this file.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFillColorPicker, arrowEdge: .trailing) {
            FillColorPickerPopover(coordinator: coordinator)
        }
        .sidebarTooltip("Fill Color", coordinator: coordinator)
    }

    // Mirrors the systemName used by each `toolButton`/`shapeButton` below, so
    // the collapsed-sidebar indicator always matches what the expanded tool
    // row would highlight.
    private var selectedToolSystemName: String {
        coordinator.toolState.selectedTool == .shape
            ? coordinator.toolState.selectedShape.symbolName
            : coordinator.toolState.selectedTool.symbolName
    }

    private var collapsedToolIndicator: some View {
        iconLabel(systemName: selectedToolSystemName, selected: true)
    }

    private var isTextTool: Bool {
        coordinator.toolState.selectedTool == .text
    }

    private var sizeSwatch: some View {
        Button {
            showSizePicker.toggle()
        } label: {
            Group {
                if isTextTool {
                    // A dot whose diameter tracks `lineWidth` says nothing useful
                    // about text; show the actual point size the text tool will
                    // render at instead.
                    Text("\(Int(coordinator.toolState.textFontSize))px")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: max(4, min(18, coordinator.toolState.lineWidth)), height: max(4, min(18, coordinator.toolState.lineWidth)))
                }
            }
            .frame(width: 24, height: 24)
            // A `Circle` only hit-tests inside its own path by default, so at
            // small brush sizes the dot is a near-unclickable few points wide.
            // Widening the content shape to the full frame makes the whole
            // 24x24 button area clickable, not just the visible dot.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSizePicker, arrowEdge: .trailing) {
            VStack(spacing: 8) {
                Text(isTextTool ? "Font size" : "Brush size").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { coordinator.toolState.lineWidth }, set: { coordinator.setLineWidth($0) }),
                    in: 1...40
                )
                .frame(width: 160)
            }
            .padding()
        }
        .sidebarTooltip(
            isTextTool ? "Font Size (\u{2318}+Scroll)" : "Brush Size (\u{2318}+Scroll)",
            coordinator: coordinator
        )
    }

    /// A short click re-selects the shape tool with whichever shape was last used (like every
    /// other `toolButton`); a long press or a right-click instead brings up the shape picker. A
    /// SwiftUI `Menu` always opens on left-click with no way to gate that on press duration or
    /// button, so an AppKit overlay (`MenuButtonInteraction`) owns all of this button's mouse
    /// handling and pops the hand-built `NSMenu` from `makeShapeMenu()`.
    private var shapeButton: some View {
        Image(systemName: coordinator.toolState.selectedShape.symbolName)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(coordinator.toolState.selectedTool == .shape ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(MenuButtonInteraction(
                longPressDuration: Self.longPressDuration,
                onClick: { coordinator.selectTool(.shape) },
                makeMenu: makeShapeMenu
            ))
            .sidebarTooltip("Shapes - hold/right-click to choose", coordinator: coordinator)
    }

    private func makeShapeMenu() -> NSMenu {
        let menu = NSMenu()
        for shape in ShapeKind.allCases {
            let binding = AppSettings.shared.binding(for: shape.shortcutAction)
            let action = MenuAction { coordinator.setShape(shape) }
            let item = NSMenuItem(title: shape.displayName, action: #selector(MenuAction.invoke), keyEquivalent: "")
            // A real key equivalent gets AppKit's native right-aligned, muted-color rendering for
            // free; only spell the shortcut out in the title when the live binding doesn't reduce
            // to a plain single character (e.g. rebound to a named key like Tab or Esc).
            if let character = binding.singleCharacterKeyEquivalent {
                item.keyEquivalent = String(character)
                item.keyEquivalentModifierMask = binding.modifierFlags
            } else {
                item.title = "\(shape.displayName) (\(binding.displayString))"
            }
            item.image = NSImage(systemSymbolName: shape.symbolName, accessibilityDescription: nil)
            item.state = shape == coordinator.toolState.selectedShape ? .on : .off
            item.target = action
            item.representedObject = action
            menu.addItem(item)
        }
        return menu
    }

    /// While nothing is recording: a dropdown covering all four capture actions (two screenshot
    /// flavors, two recording flavors), mirroring `shapeButton`'s `Menu`-as-button styling. Once
    /// a recording is running, this swaps to a plain stop button — no dropdown to navigate,
    /// tinted red so it reads as "recording" at a glance instead of the usual accent blue.
    @ViewBuilder
    private var captureButton: some View {
        if let activeRecordingKind = coordinator.activeRecordingKind {
            Button {
                coordinator.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .sidebarTooltip(
                tip("Stop Recording", activeRecordingKind == .region ? .regionRecording : .recordScreen),
                coordinator: coordinator
            )
        } else {
            Menu {
                captureMenuItem("Screenshot Screen", systemImage: "camera.fill", action: .copyScreenshot) {
                    coordinator.captureScreenshot(saveToDisk: false)
                }
                captureMenuItem("Screenshot Area", systemImage: "crop", action: .regionScreenshot) {
                    coordinator.beginRegionScreenshotSelection()
                }
                Divider()
                captureMenuItem("Record Screen", systemImage: "record.circle", action: .recordScreen) {
                    coordinator.toggleScreenRecording()
                }
                captureMenuItem("Record Area", systemImage: "rectangle.dashed", action: .regionRecording) {
                    coordinator.toggleRegionRecording()
                }
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .background(coordinator.isSelectingRegion ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .sidebarTooltip("Capture", coordinator: coordinator)
        }
    }

    /// A capture-menu row: a real `.keyboardShortcut` (right-aligned, muted, native) when the
    /// live binding allows one, else the shortcut spelled out inline in the label as a fallback —
    /// see `OptionalKeyboardShortcut`.
    private func captureMenuItem(_ label: String, systemImage: String, action: ShortcutAction, perform: @escaping () -> Void) -> some View {
        let binding = AppSettings.shared.binding(for: action)
        return Button(action: perform) {
            Label(binding.singleCharacterKeyEquivalent != nil ? label : tip(label, action), systemImage: systemImage)
        }
        .modifier(OptionalKeyboardShortcut(binding: binding))
    }

    private func toolButton(_ tool: DrawingTool, systemName: String) -> some View {
        Button {
            coordinator.selectTool(tool)
        } label: {
            iconLabel(systemName: systemName, selected: coordinator.toolState.selectedTool == tool)
        }
        .buttonStyle(.plain)
        .sidebarTooltip(tip(tool.displayName, tool.shortcutAction), coordinator: coordinator)
    }

    /// The live binding's display string (e.g. "⌘⇧A") for a rebindable action, so tooltips never
    /// drift from whatever the user has actually bound in Settings.
    private func shortcutText(_ action: ShortcutAction) -> String {
        AppSettings.shared.binding(for: action).displayString
    }

    private func tip(_ label: String, _ action: ShortcutAction?) -> String {
        guard let action else { return label }
        return "\(label) (\(shortcutText(action)))"
    }

    private func actionButton(systemName: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconLabel(systemName: String, selected: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(selected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            // Same class of issue as the brush-size dot and the collapse chevron:
            // a thin/sparse glyph (pencil tip, line diagonal, eraser...) only
            // hit-tests over its own visible strokes by default, leaving most of
            // the 32x32 button visually present but unclickable. Force the whole
            // square to be tappable.
            .contentShape(Rectangle())
    }
}

private struct ColorPickerPopover: View {
    @ObservedObject var coordinator: DrawSessionCoordinator

    private let presets: [NSColor] = ToolState.colorPalette

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24)), count: 4), spacing: 10) {
                ForEach(presets.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(nsColor: presets[index]))
                        .frame(width: 24, height: 24)
                        .onTapGesture { coordinator.setColor(presets[index]) }
                }
            }
            ColorPicker(
                "Custom",
                selection: Binding(
                    get: { Color(nsColor: coordinator.toolState.color) },
                    set: { coordinator.setColor(NSColor($0)) }
                )
            )
        }
        .padding()
        .frame(width: 160)
    }
}

/// A small gray/white checker pattern shown behind a color swatch so a fully (or partially)
/// transparent fill reads as "transparent" rather than as an odd flat gray.
private struct CheckerboardSwatchBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            ZStack {
                Color.white
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: half, height: half)
                    .position(x: half / 2, y: half / 2)
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: half, height: half)
                    .position(x: proxy.size.width - half / 2, y: proxy.size.height - half / 2)
            }
        }
    }
}

private struct FillColorPickerPopover: View {
    @ObservedObject var coordinator: DrawSessionCoordinator

    private let presets: [NSColor] = ToolState.colorPalette

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24)), count: 4), spacing: 10) {
                noFillSwatch
                ForEach(presets.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(nsColor: presets[index]))
                        .frame(width: 24, height: 24)
                        .onTapGesture { coordinator.setFillColor(presets[index]) }
                }
            }
            ColorPicker(
                "Custom",
                selection: Binding(
                    get: { Color(nsColor: coordinator.toolState.fillColor) },
                    set: { coordinator.setFillColor(NSColor($0)) }
                )
            )
        }
        .padding()
        .frame(width: 160)
    }

    /// Explicit "no fill" swatch — without one, there'd be no way back to a transparent fill
    /// once a real color is picked, short of dragging the custom picker's opacity to zero.
    private var noFillSwatch: some View {
        ZStack {
            CheckerboardSwatchBackground()
            if coordinator.toolState.fillColor.alphaComponent == 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black.opacity(0.6))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1))
        .onTapGesture { coordinator.setFillColor(.clear) }
    }
}
