import RiftControl
import SwiftUI

struct RuleImpactPreviewView: View {
    let preview: RuleImpactPreview?
    let hasRetainedSamples: Bool

    var body: some View {
        GroupBox("Recent Connections") {
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Checked \(preview.evaluatedCount) recent connections • \(preview.affectedCount) match • \(preview.changedCount) would change")
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
                                                    ? "This rule decides" : "Another rule decides")
                        }
                        if let precedence = sample.precedence {
                            Text(precedence)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if preview.samples.count > 5 {
                        Text("\(preview.samples.count - 5) more matching connections")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(hasRetainedSamples
                     ? "Finish the rule to see how it would affect recent connections."
                     : "There are no recent connections to preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
