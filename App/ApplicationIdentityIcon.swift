import RiftCore
import SwiftUI

struct ApplicationIdentityIcon: View {
    let identity: ProcessIdentity?
    let fallbackSystemName: String
    let size: CGFloat
    let artworkStore: ApplicationArtworkStore
    @State private var artwork: ApplicationArtwork?

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
            artwork = nil
            guard let identity else { return }
            let resolved = await artworkStore.artwork(for: identity)
            guard !Task.isCancelled else { return }
            artwork = resolved
        }
    }
}
