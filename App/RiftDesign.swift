import AppKit
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
        static let panel = 0.28
    }

    /// Widths of the floating panels on the map.
    enum Panel {
        static let connections: CGFloat = 320
        static let inspector: CGFloat = 300
        static let edge: CGFloat = 12
    }

    static let trafficSent = Color(nsColor: .systemPurple)
    static let trafficReceived = Color(nsColor: .systemBlue)
    /// Bold routes the user's traffic likely takes.
    static let route = Color.accentColor
    /// The faint background cable network.
    static let cable = Color(nsColor: .systemTeal)
}

/// The meaning of a firewall decision, shown with both a color and a shape so
/// it reads without color.
enum RiftDecision: CaseIterable, Hashable, Sendable {
    case allowed
    case denied
    case byDefault

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .byDefault: "By default"
        }
    }

    var symbol: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .byDefault: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .allowed: Color(nsColor: .systemGreen)
        case .denied: Color(nsColor: .systemRed)
        case .byDefault: Color(nsColor: .systemOrange)
        }
    }
}

/// A small section title for inspectors and side panels.
struct RiftSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A label and value on one line, like a property in an inspector.
struct RiftPropertyRow<Value: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(title).foregroundStyle(.secondary)
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
    case protected

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .unresolved: "Inactive"
        case .warning: "Needs attention"
        case .protected: "Protected"
        }
    }

    var symbol: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .unresolved: "minus.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .protected: "checkmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .allowed, .protected: Color(nsColor: .systemGreen)
        case .denied: Color(nsColor: .systemRed)
        case .unresolved: .secondary
        case .warning: Color(nsColor: .systemOrange)
        }
    }
}

struct RiftStatusBadge: View {
    let tone: RiftStatusTone
    var label: String?

    var body: some View {
        Label(label ?? tone.label, systemImage: tone.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, RiftDesign.Spacing.s)
            .padding(.vertical, RiftDesign.Spacing.xs)
            .background(tone.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
