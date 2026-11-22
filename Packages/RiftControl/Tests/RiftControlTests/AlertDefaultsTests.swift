import RiftControl
import Testing

@Test func nothingUsedYetOffersALastingDomainRule() {
    #expect(AlertDefaults.lifetime(preset: AlertDefaults.lastUsed, lastUsed: nil) == .permanent)
    #expect(AlertDefaults.destination(preset: AlertDefaults.lastUsed, lastUsed: nil, domainAvailable: true) == .domain)
}

@Test func aConnectionWithoutADomainFallsBackToTheExactDestination() {
    #expect(AlertDefaults.destination(preset: AlertDefaults.lastUsed, lastUsed: nil, domainAvailable: false) == .exact)
    #expect(AlertDefaults.destination(preset: "This domain", lastUsed: nil, domainAvailable: false) == .exact)
    #expect(AlertDefaults.destination(
        preset: "This destination, any port", lastUsed: nil, domainAvailable: false
    ) == .anyPort)
}

@Test func lastUsedFollowsTheMostRecentAnswer() {
    #expect(AlertDefaults.lifetime(preset: AlertDefaults.lastUsed, lastUsed: "One hour") == .oneHour)
    #expect(AlertDefaults.lifetime(preset: AlertDefaults.lastUsed, lastUsed: "Once") == .once)
    #expect(AlertDefaults.destination(
        preset: AlertDefaults.lastUsed, lastUsed: "This destination", domainAvailable: true
    ) == .exact)
}

@Test func aFixedPresetWinsOverTheLastAnswer() {
    #expect(AlertDefaults.lifetime(preset: "Five minutes", lastUsed: "Always") == .fiveMinutes)
    #expect(AlertDefaults.destination(
        preset: "This destination", lastUsed: "This domain", domainAvailable: true
    ) == .exact)
}

@Test func anyDestinationIsNeverPreselected() {
    #expect(AlertDefaults.destination(
        preset: AlertDefaults.lastUsed, lastUsed: "Any destination", domainAvailable: true
    ) == .domain)
    #expect(AlertDefaults.destination(preset: "Any destination", lastUsed: nil, domainAvailable: false) == .exact)
    #expect(!AlertDefaults.remembersDestination(.any, domainAvailable: true))
}

@Test func answersWithoutADomainChoiceAreNotRemembered() {
    #expect(!AlertDefaults.remembersDestination(.exact, domainAvailable: false))
    #expect(AlertDefaults.remembersDestination(.exact, domainAvailable: true))
    #expect(AlertDefaults.remembersDestination(.domain, domainAvailable: true))
}

@Test func storedValuesFromEarlierVersionsStillRead() {
    #expect(AlertLifetime(stored: "Permanent") == .permanent)
    #expect(AlertDefaults.lifetime(preset: "Permanent", lastUsed: nil) == .permanent)
    #expect(AlertDefaults.normalizedLifetimePreset("Permanent") == "Always")
    #expect(AlertDefaults.normalizedLifetimePreset("Forever") == AlertDefaults.lastUsed)
    #expect(AlertDefaults.normalizedDestinationPreset("This domain") == "This domain")
    #expect(AlertDefaults.normalizedDestinationPreset("Any destination") == AlertDefaults.lastUsed)
}

@Test func timedLifetimesHaveDurations() {
    #expect(AlertLifetime.fifteenMinutes.duration == 900)
    #expect(AlertLifetime.oneDay.duration == 86_400)
    #expect(AlertLifetime.oneWeek.duration == 604_800)
    #expect(AlertLifetime.once.duration == nil)
    #expect(AlertLifetime.permanent.duration == nil)
}
