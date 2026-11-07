import RiftCore
import SwiftUI

struct ApplicationIdentityIcon: View {
    let identity: ProcessIdentity?
    let fallbackSystemName: String
    let size: CGFloat
    let artworkStore: ApplicationArtworkStore
    @State private var artwork: ApplicationArtwork?

    init(identity: ProcessIdentity?, fallbackSystemName: String, size: CGFloat, artworkStore: ApplicationArtworkStore) {
        self.identity = identity
        self.fallbackSystemName = fallbackSystemName
        self.size = size
        self.artworkStore = artworkStore
        // A recreated row shows cached artwork immediately instead of flashing
        // the placeholder.
        _artwork = State(initialValue: identity.flatMap { artworkStore.cachedArtworkIfAvailable(for: $0) })
    }

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: identity) {
            guard let identity else { artwork = nil; return }
            if let cached = artworkStore.cachedArtworkIfAvailable(for: identity) {
                artwork = cached
                return
            }
            let resolved = await artworkStore.artwork(for: identity)
            guard !Task.isCancelled else { return }
            artwork = resolved
        }
    }
}

/// An app's verified display name, such as "Google Chrome", once Rift has
/// matched its installed bundle to the code-signing identity. Until then, or
/// if it can't, it shows `fallback` (usually the signing identifier).
struct ApplicationNameText: View {
    let identity: ProcessIdentity?
    let fallback: String
    let artworkStore: ApplicationArtworkStore
    @State private var name: String?

    init(identity: ProcessIdentity?, fallback: String, artworkStore: ApplicationArtworkStore) {
        self.identity = identity
        self.fallback = fallback
        self.artworkStore = artworkStore
        _name = State(initialValue: identity.flatMap { artworkStore.cachedArtworkIfAvailable(for: $0)?.displayName })
    }

    var body: some View {
        Text(name ?? fallback)
            .task(id: identity) {
                guard let identity else { name = nil; return }
                if let cached = artworkStore.cachedArtworkIfAvailable(for: identity) {
                    name = cached.displayName
                    return
                }
                let resolved = await artworkStore.artwork(for: identity)
                guard !Task.isCancelled else { return }
                name = resolved?.displayName
            }
    }
}

extension ProcessIdentity {
    /// Who signed the code, in a word or two.
    var signerKind: String {
        switch self {
        case .applePlatform: "Apple"
        case .developerID: "Developer ID"
        case .appStore: "App Store"
        case .otherSigner: "Signed"
        case .adHoc: "Ad hoc signed"
        case .unsigned: "Unsigned"
        }
    }
}
