import SwiftUI
import AppKit

struct ToolbarView: View {
    @ObservedObject var coordinator: DrawSessionCoordinator
    @State private var showColorPicker = false
    @State private var showSizePicker = false

    var body: some View {
        VStack(spacing: 16) {
            colorSwatch
            sizeSwatch

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 30, height: 1)

            toolButton(.pen, systemName: "pencil.tip")
            toolButton(.highlighter, systemName: "paintbrush.pointed.fill")
            shapeButton
            toolButton(.spotlight, systemName: "flashlight.on.fill")
            toolButton(.text, systemName: "textformat")

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 30, height: 1)

            Button {
                coordinator.beginRegionScreenshotSelection()
            } label: {
                iconLabel(systemName: "camera.fill", selected: coordinator.isSelectingRegion)
            }
            .buttonStyle(.plain)
            Button {
                coordinator.toggleFreezeBackground()
            } label: {
                iconLabel(systemName: "snowflake", selected: coordinator.isBackgroundFrozen)
            }
            .buttonStyle(.plain)
            actionButton(systemName: "trash.fill") {
                coordinator.document.clear()
            }
            actionButton(systemName: coordinator.isCanvasHidden ? "eye.fill" : "eye.slash.fill") {
                coordinator.toggleHideCanvas()
            }
            actionButton(systemName: "xmark.circle.fill", tint: .red) {
                coordinator.disableDrawMode()
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
    }

    private var colorSwatch: some View {
        Button {
            showColorPicker.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: coordinator.toolState.color))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
            ColorPickerPopover(coordinator: coordinator)
        }
    }

    private var sizeSwatch: some View {
        Button {
            showSizePicker.toggle()
        } label: {
            Circle()
                .fill(Color.white)
                .frame(width: max(4, min(20, coordinator.toolState.lineWidth)), height: max(4, min(20, coordinator.toolState.lineWidth)))
                .frame(width: 26, height: 26)
                // A `Circle` only hit-tests inside its own path by default, so at
                // small brush sizes the dot is a near-unclickable few points wide.
                // Widening the content shape to the full frame makes the whole
                // 26x26 button area clickable, not just the visible dot.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSizePicker, arrowEdge: .trailing) {
            VStack(spacing: 8) {
                Text("Brush size").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { coordinator.toolState.lineWidth }, set: { coordinator.setLineWidth($0) }),
                    in: 1...40
                )
                .frame(width: 160)
            }
            .padding()
        }
    }

    private var shapeButton: some View {
        Menu {
            ForEach(ShapeKind.allCases, id: \.self) { shape in
                Button(shape.displayName) {
                    coordinator.setShape(shape)
                }
            }
        } label: {
            iconLabel(systemName: coordinator.toolState.selectedShape.symbolName, selected: coordinator.toolState.selectedTool == .shape)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 36, height: 36)
    }

    private func toolButton(_ tool: DrawingTool, systemName: String) -> some View {
        Button {
            coordinator.selectTool(tool)
        } label: {
            iconLabel(systemName: systemName, selected: coordinator.toolState.selectedTool == tool)
        }
        .buttonStyle(.plain)
    }

    private func actionButton(systemName: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    private func iconLabel(systemName: String, selected: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(selected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ColorPickerPopover: View {
    @ObservedObject var coordinator: DrawSessionCoordinator

    private let presets: [NSColor] = [
        .systemYellow, .systemRed, .systemOrange, .systemGreen,
        .systemBlue, .systemPurple, .white, .black,
    ]

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
