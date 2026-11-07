import AppKit
import SwiftUI

/// Number formatting shared by every surface.
enum RiftFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// A lower bound reads "≥ 12 MB"; callers style the prefix separately.
    static func lowerBoundPrefix(_ partial: Bool) -> String { partial ? "≥" : "" }
}

/// A byte total in monospaced digits. A partial total is a lower bound, marked
/// with a quiet "≥" so the number itself stays easy to scan.
struct RiftBytesText: View {
    let bytes: UInt64?
    var partial = false

    var body: some View {
        Group {
            if let bytes {
                let prefix = Text(RiftFormat.lowerBoundPrefix(partial)).foregroundStyle(.tertiary)
                Text("\(prefix)\(RiftFormat.bytes(bytes))")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let bytes else { return "Unavailable" }
        return (partial ? "At least " : "") + RiftFormat.bytes(bytes)
    }
}

/// A floating surface over the map: Liquid Glass on macOS 26, a material on
/// earlier systems, and an opaque fill when Reduce Transparency is on.
struct RiftPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = RiftDesign.Radius.panel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var strokeOpacity: Double { contrast == .increased ? 0.9 : 0.35 }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 1) }
        } else if #available(macOS 26, *) {
            // Panels hold lists and numbers, so they need a calmer surface than
            // clear glass over a busy map.
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.62), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay {
                    if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(strokeOpacity), lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}

extension View {
    func riftPanel(cornerRadius: CGFloat = RiftDesign.Radius.panel) -> some View {
        modifier(RiftPanelModifier(cornerRadius: cornerRadius))
    }
}

/// The search field used by every list in Rift.
struct RiftSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear Search")
                    .help("Clear search")
            }
        }
        .padding(.horizontal, RiftDesign.Spacing.s)
        .frame(height: 28)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: RiftDesign.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
    }
}

/// A decision shown as a symbol in its color, with the meaning in the label.
struct RiftDecisionBadge: View {
    let decision: RiftDecision
    var showsLabel = false

    var body: some View {
        Group {
            if showsLabel {
                Label(decision.label, systemImage: decision.symbol)
            } else {
                Image(systemName: decision.symbol)
            }
        }
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, decision.color)
        .accessibilityLabel(decision.label)
        .help(decision.label)
    }
}

enum RiftBannerTone { case info, warning, error }

/// An inline message for errors and things that need attention.
struct RiftBanner<Actions: View>: View {
    typealias Tone = RiftBannerTone
    let message: String
    var detail: String?
    var tone: Tone = .info
    @ViewBuilder var actions: Actions

    private var symbol: String {
        switch tone {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: .secondary
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RiftDesign.Spacing.s) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(detail == nil ? .callout : .callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: RiftDesign.Spacing.s)
            actions
        }
        .padding(.horizontal, RiftDesign.Spacing.m)
        .padding(.vertical, RiftDesign.Spacing.s)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: RiftDesign.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension RiftBanner where Actions == EmptyView {
    init(_ message: String, tone: Tone = .info) {
        self.init(message: message, tone: tone) { EmptyView() }
    }
}
