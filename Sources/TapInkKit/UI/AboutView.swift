import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("TapInk").font(.title2).bold()
            Text("Version 1.0").font(.callout).foregroundStyle(.secondary)
            Text("Draw on your screen, live, across every monitor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 280, height: 200)
    }
}
