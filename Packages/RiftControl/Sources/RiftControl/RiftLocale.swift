import Foundation

/// riftctl prints English in every language, like its commands and flags,
/// so scripts can read it. Text the app makes for riftctl is looked up in
/// English while `english` is set.
public enum RiftLocale {
    @TaskLocal public static var english = false

    /// RiftControl's strings that riftctl can print.
    static var bundle: Bundle { english ? englishModule : .module }

    /// The app's strings that riftctl can print.
    public static var mainBundle: Bundle { english ? englishMain : .main }

    /// Items joined into a list, like “A, B and C”, in the same language.
    public static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = english ? Locale(identifier: "en") : .current
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    /// A bundle's English strings, or the bundle itself when it has none.
    static func englishStrings(of bundle: Bundle) -> Bundle {
        bundle.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? bundle
    }

    private static let englishModule = englishStrings(of: .module)
    private static let englishMain = englishStrings(of: .main)
}
