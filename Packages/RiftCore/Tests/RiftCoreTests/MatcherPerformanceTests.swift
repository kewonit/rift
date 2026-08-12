import Foundation
import Testing
@testable import RiftCore

@Test(.timeLimit(.minutes(1)))
func compiledMatcherMeetsLocalBudgetWithOneHundredThousandRules() throws {
    let identities = try (0..<1_000).map { index -> ProcessIdentity in
        .developerID(try SignedCodeIdentity(
            teamIdentifier: "LOADTEST",
            signingIdentifier: "io.rift.load.\(index)"
        ))
    }
    var rules: [Rule] = []
    rules.reserveCapacity(100_000)
    for index in 0..<100_000 {
        rules.append(try RuleTestSupport.rule(
            id: UInt64(index + 10_000),
            action: .filter(index.isMultiple(of: 3) ? .deny : .allow),
            process: .exact(identities[index % identities.count])
        ))
    }

    let clock = ContinuousClock()
    let compileStart = clock.now
    let matcher = CompiledRuleMatcher(rules: rules)
    let compileDuration = compileStart.duration(to: clock.now)
    #expect(compileDuration < .seconds(10))

    let flow = try RuleTestSupport.flow(
        app: identities[500],
        process: identities[500]
    )
    let context = RuleTestSupport.context()
    let callbackStart = clock.now
    for _ in 0..<1_000 {
        _ = matcher.decision(for: flow, context: context, mode: .alert)
    }
    let callbackDuration = callbackStart.duration(to: clock.now)
    print("MATCHER_BENCHMARK compile=\(compileDuration) callbacks_1000=\(callbackDuration)")
    // This unsigned local budget does not replace p95/p99 measurements in the
    // signed callback lane.
    #expect(callbackDuration < .seconds(5))
}
