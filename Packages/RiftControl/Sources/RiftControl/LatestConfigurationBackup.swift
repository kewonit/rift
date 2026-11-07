import Foundation

/// Finds the newest daily backup that can really be read. The record of past
/// backups lives in the damaged database, so this goes by file name, and a
/// backup that fails to read is skipped rather than trusted.
public enum LatestConfigurationBackup {
    public struct Found: Sendable {
        public let url: URL
        public let draft: PolicyConfigurationDraft
        /// The day in the file name, such as 2026-11-07.
        public let day: String
    }

    public static func newest(
        in directory: URL,
        read: (URL) throws -> PolicyConfigurationDraft? = ConfigurationBackupReader.read
    ) -> Found? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names
            .filter { $0.hasPrefix("config-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >)
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            guard let draft = try? read(url) else { continue }
            let day = String(name.dropFirst("config-".count).dropLast(".sqlite".count))
            return Found(url: url, draft: draft, day: day)
        }
        return nil
    }
}
