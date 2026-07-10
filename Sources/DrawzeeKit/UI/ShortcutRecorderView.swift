import SwiftUI
import AppKit

/// Invisible NSView that becomes first responder while `isRecording` is true and
/// reports exactly the next key event, then stops recording.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = { keyCode, modifiers in
            onCapture(keyCode, modifiers)
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
            nsView.startWatchingForOutsideClicks()
        } else {
            nsView.stopWatchingForOutsideClicks()
        }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?
        private var outsideClickMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            onCapture?(event.keyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // Resign immediately after capturing one key: without this, this
            // invisible view stays first responder (nothing else claims key focus
            // in the Settings window), so every subsequent keystroke keeps landing
            // here and silently rebinds the shortcut again instead of going wherever
            // the user's typing next.
            window?.makeFirstResponder(nil)
            stopWatchingForOutsideClicks()
        }

        /// A click anywhere else in the app while recording should cancel the
        /// in-progress rebind rather than leave the row stuck showing "Press a
        /// key…" forever. This view is a 0x0 marker (see the frame in the body
        /// below), so it can't tell "inside the box" from "outside" via its own
        /// hit-testing — instead it watches every mouse-down and cancels
        /// unconditionally. That's still correct for a click that lands back on
        /// this same row's box: SwiftUI's own `.onTapGesture` runs its normal
        /// dispatch right after this monitor and re-sets `isRecording` to true.
        func startWatchingForOutsideClicks() {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.onCancel?()
                return event
            }
        }

        func stopWatchingForOutsideClicks() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            outsideClickMonitor = nil
        }

        deinit {
            stopWatchingForOutsideClicks()
        }
    }
}

struct ShortcutRow: View {
    let action: ShortcutAction
    @State private var isRecording = false
    @State private var binding: ShortcutBinding

    init(action: ShortcutAction) {
        self.action = action
        _binding = State(initialValue: AppSettings.shared.binding(for: action))
    }

    var body: some View {
        HStack {
            Text(action.displayName)
            Spacer()
            ZStack {
                Text(isRecording ? "Press a key…" : binding.displayString)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .opacity(isRecording ? 1 : 0)
                    )
                KeyCaptureView(isRecording: $isRecording) { keyCode, modifiers in
                    let newBinding = ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                    binding = newBinding
                    AppSettings.shared.setBinding(newBinding, for: action)
                }
                .frame(width: 0, height: 0)
            }
            .onTapGesture { isRecording = true }
            Button("Reset") {
                AppSettings.shared.resetBinding(for: action)
                binding = AppSettings.shared.binding(for: action)
            }
            .buttonStyle(.borderless)
        }
    }
}
