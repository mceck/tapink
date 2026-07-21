import SwiftUI

/// A small HUD-style pill — icon + short label — used for brief, self-dismissing feedback
/// (draw mode on/off, tool changed). `.fixedSize()` keeps it at its natural width instead of
/// stretching to whatever `ToastPanelController` sizes the hosting view to.
struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(VisualEffectBackground())
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}
