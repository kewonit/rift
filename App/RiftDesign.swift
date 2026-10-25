import AppKit
import SwiftUI

enum RiftDesign {
    enum Spacing {
        static let compact: CGFloat = 6
        static let standard: CGFloat = 10
        static let section: CGFloat = 16
        static let spacious: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 8
        static let surface: CGFloat = 12
        static let floating: CGFloat = 14
    }

    enum Motion {
        static let press = 0.12
        static let contextual = 0.20
    }

    static let activityViolet = Color(
        light: NSColor(srgbRed: 0.39, green: 0.20, blue: 0.86, alpha: 1),
        dark: NSColor(srgbRed: 0.66, green: 0.52, blue: 1, alpha: 1)
    )

    static let trafficSent = Color(
        light: NSColor(srgbRed: 0.82, green: 0.30, blue: 0.95, alpha: 1),
        dark: NSColor(srgbRed: 0.88, green: 0.44, blue: 1, alpha: 1)
    )
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
        case .unresolved: "questionmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .protected: "checkmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .allowed, .protected: .green
        case .denied: .red
        case .unresolved: .secondary
        case .warning: .orange
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.11), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct RiftSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var increaseContrast: Bool {
        differentiateWithoutColor || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: RiftDesign.Radius.surface, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: RiftDesign.Radius.surface, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: RiftDesign.Radius.surface, style: .continuous)
                    .stroke(.separator.opacity(increaseContrast ? 0.9 : 0.45), lineWidth: 1)
            }
    }
}

extension View {
    func riftSurface() -> some View { modifier(RiftSurfaceModifier()) }
}

struct RiftPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: RiftDesign.Motion.press),
                value: configuration.isPressed
            )
    }
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
