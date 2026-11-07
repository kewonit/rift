import SwiftUI

/// A full-width button that highlights on hover, like a menu item.
struct StatusMenuButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                .padding(.vertical, RiftDesign.Spacing.xs)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .background(
                    hovering ? Color.primary.opacity(0.09) : .clear,
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
