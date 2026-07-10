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
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            onCapture?(event.keyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
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
