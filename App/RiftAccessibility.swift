import AppKit
import SwiftUI

/// The fill behind a short note laid over other content, such as a table: a
/// material normally, the opaque window background with Reduce Transparency,
/// and an outline with Increase Contrast so its edge stays visible.
struct RiftNoteBackground<Fill: InsettableShape>: ViewModifier {
    let shape: Fill
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .riftContrastOutline(shape)
    }
}

/// An outline drawn only with Increase Contrast, for surfaces whose edge is
/// otherwise a faint tint.
struct RiftContrastOutline<Outline: InsettableShape>: ViewModifier {
    let shape: Outline
    var style: AnyShapeStyle = AnyShapeStyle(.separator)
    var lineWidth: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                shape.strokeBorder(style, lineWidth: lineWidth)
            }
        }
    }
}

extension View {
    func riftNoteBackground<Fill: InsettableShape>(_ shape: Fill) -> some View {
        modifier(RiftNoteBackground(shape: shape))
    }

    func riftContrastOutline<Outline: InsettableShape>(
        _ shape: Outline,
        style: AnyShapeStyle = AnyShapeStyle(.separator),
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(RiftContrastOutline(shape: shape, style: style, lineWidth: lineWidth))
    }

    /// Speaks a message with VoiceOver when it appears or changes, for text
    /// that shows up after an action and would otherwise go unheard.
    func riftAnnounces(_ message: String?) -> some View {
        onChange(of: message) { _, value in
            guard let value, !value.isEmpty else { return }
            AccessibilityNotification.Announcement(value).post()
        }
    }
}

/// Times in words for VoiceOver, where short labels such as "3m" or "12s"
/// would be read as letters.
enum RiftSpokenTime {
    /// "12 seconds", "1 minute, 5 seconds".
    static func duration(seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide)
        )
    }

    /// "Just now" or "3 minutes ago", matching `RiftRelativeTime.short`.
    @MainActor
    static func ago(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 10 { return String(localized: "Just now") }
        return relative.localizedString(for: min(date, now), relativeTo: now)
    }

    @MainActor private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
