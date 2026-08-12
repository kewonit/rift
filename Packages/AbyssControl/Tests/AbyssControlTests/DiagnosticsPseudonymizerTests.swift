import AbyssControl
import Foundation
import Testing

@Test func diagnosticsPseudonymsAreBundleScopedAndDoNotContainSource() throws {
    let first = try DiagnosticsPseudonymizer(keyMaterial: Data(repeating: 1, count: 32))
    let sameBundle = try DiagnosticsPseudonymizer(keyMaterial: Data(repeating: 1, count: 32))
    let nextBundle = try DiagnosticsPseudonymizer(keyMaterial: Data(repeating: 2, count: 32))
    let source = "private.example.test"
    #expect(first.token(for: source) == sameBundle.token(for: source))
    #expect(first.token(for: source) != nextBundle.token(for: source))
    #expect(!first.token(for: source).contains("private"))
    #expect(first.token(for: source).count == 18)
    #expect(throws: DiagnosticsPseudonymizerError.insufficientKeyMaterial) {
        try DiagnosticsPseudonymizer(keyMaterial: Data())
    }
}
