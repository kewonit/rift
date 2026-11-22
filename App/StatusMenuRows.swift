import RiftCore
import SwiftUI

/// A full-width button that highlights on hover, like a menu item.
struct StatusMenuButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                .padding(.vertical, RiftDesign.Spacing.xs)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .background(
                    hovering ? Color.primary.opacity(contrast == .increased ? 0.18 : 0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: RiftDesign.Radius.control - 2, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A command row at the bottom of the menu-bar panel, with its shortcut.
struct StatusMenuActionRow: View {
    let title: String
    var shortcut: String?
    var trailing: String?
    let action: () -> Void

    var body: some View {
        StatusMenuButton(action: action) {
            HStack(spacing: RiftDesign.Spacing.s) {
                Text(title)
                Spacer(minLength: RiftDesign.Spacing.s)
                if let trailing {
                    Text(trailing).foregroundStyle(.secondary).lineLimit(1)
                }
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
        }
    }
}

#if DEBUG
/// Renders the menu-bar panel in an ordinary window for previews.
struct StatusMenuFixtureHost: View {
    @Bindable var session: AppSession

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusMenuView(session: session)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RiftDesign.Radius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: RiftDesign.Radius.panel, style: .continuous)
                        .strokeBorder(.separator.opacity(0.55))
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .frame(minWidth: 360, minHeight: 600)
    }
}
#endif

/// A recent-app row with its five-minute rule on show while the pointer is
/// over it: Allow for a blocked app, Block for an allowed one.
struct StatusMenuFiveMinuteRow<Content: View>: View {
    let undo: FilterAction
    let decide: (FilterAction) -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false
    @FocusState private var buttonFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // On the row's own button, so VoiceOver offers it there.
            content
                .accessibilityAction(named: title) { decide(undo) }
            Button { decide(undo) } label: {
                Image(systemName: undo == .allow ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(undo == .allow ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(title)
            .focused($buttonFocused)
            // Also shown while it has keyboard focus, so a Tab onto it
            // doesn't land on nothing.
            .opacity(hovering || buttonFocused ? 1 : 0)
            .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
    }

    private var title: String { undo == .allow ? "Allow for 5 Minutes" : "Block for 5 Minutes" }
}
