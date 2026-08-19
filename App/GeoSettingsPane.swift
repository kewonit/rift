import RiftControl
import SwiftUI

struct GeoSettingsPane: View {
    let geolocation: GeolocationController

    var body: some View {
        @Bindable var geolocation = geolocation
        Form {
            Section("Offline destination locations") {
                LabeledContent("Status", value: geolocation.statusMessage)
                if let metadata = geolocation.metadata {
                    LabeledContent("Source", value: metadata.sourceName)
                    LabeledContent("Version", value: metadata.sourceVersion)
                    LabeledContent(
                        "Ranges",
                        value: metadata.recordCount.formatted()
                    )
                    LabeledContent("Imported", value: metadata.importedAt.formatted())
                    if let modified = metadata.sourceModifiedAt {
                        LabeledContent("Source date", value: modified.formatted(date: .long, time: .omitted))
                    }
                    LabeledContent("Database age", value: "\(ageInDays(metadata)) days")
                    if ageInDays(metadata) > 62 {
                        Text("This database is over two months old. Import a current snapshot for better coverage.")
                            .foregroundStyle(.orange)
                    }
                }
                Button(
                    geolocation.metadata == nil
                        ? "Import DB-IP City Lite CSV…" : "Replace Location Database…"
                ) {
                    Task { await geolocation.importCSV() }
                }
                .disabled(!geolocation.canImport || geolocation.isImporting)
                if geolocation.isImporting {
                    ProgressView("Validating and building the offline index…")
                }
            }

            Section("Get the data") {
                if let source = URL(string: GeoCSVImporter.sourceURLString) {
                    Link("Download DB-IP City Lite", destination: source)
                }
                Text("Download the City Lite CSV archive, extract it, then choose the .csv file above. Rift does not auto-download or upload database data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The extracted CSV is much larger than the compressed download. Import runs off the UI thread and may take several minutes; keep enough free space for both the CSV and local index.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let source = URL(string: GeoCSVImporter.sourceURLString) {
                        Link(GeoCSVImporter.attribution, destination: source)
                    }
                    Text("•")
                    if let license = URL(string: GeoCSVImporter.licenseURLString) {
                        Link("CC BY 4.0", destination: license)
                    }
                }
                .font(.caption)
            }

            Section("Privacy and accuracy") {
                Text("Rift performs IP-to-location lookups only on this Mac. Locations are approximate and can be stale or incorrect; they must not be used to identify a person or precise address.")
                Text("The destination map is hidden by default. When you show it, MapKit requests Apple map tiles and Rift asks api64.ipify.org for your public IP once per map session. Rift resolves that address locally, keeps only a coarse coordinate in memory, and does not send destination IPs, hostnames, or application identities to ipify or DB-IP.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await geolocation.start() }
    }

    private func ageInDays(_ metadata: GeoDatabaseMetadata) -> Int {
        let date = metadata.sourceModifiedAt ?? metadata.importedAt
        return max(0, Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0)
    }
}
