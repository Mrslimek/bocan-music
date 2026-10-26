import SwiftUI

// MARK: - QuittingView

/// The small panel content shown while the app finishes its quit-time work.
///
/// AppKit only presents it when that work outlives a short grace period, so a
/// normal quit never flashes a spinner.
public struct QuittingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            if self.reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            Text(localized: "Quitting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 220, height: 100)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Quitting…"))
    }
}

#if DEBUG
    #Preview("Quitting") {
        QuittingView()
            .padding(20)
            .background(.background)
    }
#endif
