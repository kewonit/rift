import RiftControl
import SwiftUI

struct RuleImpactPreviewView: View {
    let preview: RuleImpactPreview?
    let hasRetainedSamples: Bool

    var body: some View {
        GroupBox("Sample impact") {
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evaluated \(preview.evaluatedCount) recent visible flows • \(preview.affectedCount) match • \(preview.changedCount) results change")
                        .font(.caption)
                    ForEach(preview.samples.prefix(5)) { sample in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.application).lineLimit(1)
                                Text(sample.endpoint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(sample.currentResult)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .accessibilityLabel("changes to")
                            Text(sample.proposedResult)
                                .font(.caption)
                            Image(systemName: sample.candidateWins
                                  ? "checkmark.seal.fill" : "circle.dashed")
                                .foregroundStyle(sample.candidateWins ? .green : .secondary)
                                .accessibilityLabel(sample.candidateWins
                                                    ? "Proposed rule wins" : "Another rule wins")
                        }
                        if let precedence = sample.precedence {
                            Text(precedence)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if preview.samples.count > 5 {
                        Text("\(preview.samples.count - 5) additional matching samples")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(hasRetainedSamples
                     ? "Enter a valid condition to preview it with the current matcher."
                     : "No retained visible flows are available for a sample preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
