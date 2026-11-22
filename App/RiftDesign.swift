import AppKit
import RiftControl
import SwiftUI

/// Rift's design tokens. Views use these instead of literal sizes and colors so
/// every surface shares one type scale, spacing rhythm and color meaning.
enum RiftDesign {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
    }

    enum Motion {
        static let press = 0.12
        static let contextual = 0.20
        static let exit = 0.15
        /// How far small surfaces travel as they enter and leave.
        static let travel: CGFloat = 8

        /// Starts fast and settles gently, for things entering or leaving.
        static func enter(_ duration: Double = contextual) -> Animation {
            .timingCurve(0.19, 1, 0.22, 1, duration: duration)
        }

        /// A small surface sliding in and leaving the way it came. With Reduce
        /// Motion it only fades.
        static func slide(fromY offset: CGFloat, reduceMotion: Bool) -> AnyTransition {
            guard !reduceMotion else {
                return .opacity.animation(.easeOut(duration: press))
            }
            let moved = AnyTransition.opacity.combined(with: .offset(y: offset))
            return .asymmetric(
                insertion: moved.animation(enter()),
                removal: moved.animation(enter(exit))
            )
        }
    }

    /// Height of the controls in the bar above each table.
    static let barControlHeight: CGFloat = 24
}

/// The meaning of a firewall decision, shown with both a color and a shape so
/// it reads without color.
enum RiftDecision: CaseIterable, Hashable, Sendable {
    case allowed
    case denied
    case byDefault
    case timedOut
    case mixed

    var label: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Blocked")
        case .byDefault: String(localized: "No rule")
        case .timedOut: String(localized: "Timed out")
        case .mixed: String(localized: "Some blocked")
        }
    }

    var symbol: String {
        switch self {
        case .allowed: "checkmark"
        case .denied: "xmark"
        case .byDefault: "minus"
        case .timedOut: "clock"
        // Its own shape: in the same red as Blocked, a cross would tell the
        // two apart only by the words beside it.
        case .mixed: "circle.lefthalf.filled"
        }
    }

    var color: Color {
        switch self {
        case .allowed, .byDefault: .secondary
        case .denied, .mixed: Color(nsColor: .systemRed)
        case .timedOut: Color(nsColor: .systemOrange)
        }
    }
}

/// A titled group of rows in an inspector.
struct RiftInspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// `LabeledContent` as an inspector row, matching `RiftPropertyRow`.
struct RiftInspectorRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RiftDesign.Spacing.s) {
            configuration.label.foregroundStyle(.secondary)
            Spacer(minLength: RiftDesign.Spacing.s)
            configuration.content.multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// A label and value on one line, like a property in an inspector. A literal
/// title is looked up in the string catalog; a `String` is shown as it is.
struct RiftPropertyRow<Value: View>: View {
    let title: Text
    var symbol: String?
    @ViewBuilder let value: Value

    init(title: LocalizedStringKey, symbol: String? = nil, @ViewBuilder value: () -> Value) {
        self.title = Text(title)
        self.symbol = symbol
        self.value = value()
    }

    @_disfavoredOverload
    init(title: String, symbol: String? = nil, @ViewBuilder value: () -> Value) {
        self.title = Text(title)
        self.symbol = symbol
        self.value = value()
    }

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            title.foregroundStyle(.secondary)
            Spacer(minLength: RiftDesign.Spacing.s)
            value
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

enum RiftStatusTone: String, CaseIterable {
    case allowed
    case denied
    case unresolved
    case warning
    case on

    var label: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Blocked")
        case .unresolved: String(localized: "Inactive")
        case .warning: String(localized: "Needs attention")
        case .on: String(localized: "On")
        }
    }

    var color: Color {
        switch self {
        case .allowed, .on: Color(nsColor: .systemGreen)
        case .denied: Color(nsColor: .systemRed)
        case .unresolved: .secondary
        case .warning: Color(nsColor: .systemOrange)
        }
    }
}

/// A word with a small dot in its tone.
struct RiftStatusBadge: View {
    let tone: RiftStatusTone
    var label: String?

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs + 1) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label ?? tone.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension ProtectionStatus {
    var color: Color {
        switch tone {
        case .good: Color(nsColor: .systemGreen)
        case .neutral: Color(nsColor: .systemBlue)
        case .attention: Color(nsColor: .systemOrange)
        case .preview: .secondary
        }
    }

    /// The menu bar uses the outline symbol, and larger surfaces the filled one.
    var filledSymbolName: String {
        tone == .preview ? symbolName : "\(symbolName).fill"
    }
}
