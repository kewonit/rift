import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// What VoiceOver hears from a connection alert. The alert counts down every
/// second on screen, but VoiceOver hears the time only when the alert opens
/// and once more when ten seconds are left.
@MainActor
enum ConnectionAlertSpeech {
    /// How long before the end VoiceOver says time is nearly up.
    static let finalWarning: TimeInterval = 10
    /// Alerts already announced, so the minimized bar doesn't repeat one.
    private static var announced: Set<UUID> = []

    /// The countdown in words, such as "Allowing in 25 seconds".
    static func countdown(
        deadline: Date,
        now: Date,
        blocks: Bool = ConnectionAlertCountdown.blocksUnanswered
    ) -> String {
        let remaining = Int(remainingTime(deadline: deadline, now: now, blocks: blocks).rounded(.up))
        guard remaining > 0 else {
            return ConnectionAlertCountdown.label(deadline: deadline, now: now, blocks: blocks)
        }
        return "\(blocks ? "Blocking" : "Allowing") in \(RiftSpokenTime.duration(seconds: remaining))"
    }

    /// Seconds until Rift or the filter answers for the person.
    static func remainingTime(
        deadline: Date,
        now: Date,
        blocks: Bool = ConnectionAlertCountdown.blocksUnanswered
    ) -> TimeInterval {
        let end = blocks ? deadline.addingTimeInterval(-ConnectionAlertCountdown.blockLead) : deadline
        return max(0, end.timeIntervalSince(now))
    }

    /// The headline, then each warning, then how long is left, as one
    /// announcement so none of them cuts another off.
    static func opening(_ headline: String, prompt: PromptRequest, now: Date = Date()) -> String {
        let warnings = ConnectionAlertWarnings.warnings(for: prompt).map { "Warning: \($0.message)" }
        let time = countdown(deadline: prompt.deadline, now: now) + "."
        return ([headline] + warnings + [time]).joined(separator: " ")
    }

    /// Announces an alert. With `onlyOnce`, an alert that was already
    /// announced, for example before it was minimized, stays quiet.
    static func announceOpening(_ headline: String, prompt: PromptRequest, onlyOnce: Bool = false) {
        if onlyOnce, announced.contains(prompt.nonce) { return }
        if announced.count > 200 { announced.removeAll() }
        announced.insert(prompt.nonce)
        AccessibilityNotification.Announcement(opening(headline, prompt: prompt)).post()
    }
}

/// Speaks an alert's last ten seconds once, and a problem that keeps the
/// alert open, such as an answer that couldn't be sent.
struct ConnectionAlertAnnouncements: ViewModifier {
    let prompt: PromptRequest
    /// While an answer is on its way, or once a rule is saved, the countdown
    /// no longer needs saying.
    var answered = false
    var problem: String?
    /// For the minimized bar, which otherwise appears without a word.
    var arrivalHeadline: String?

    private struct CountdownKey: Equatable {
        let nonce: UUID
        let answered: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: prompt.nonce) {
                guard let arrivalHeadline,
                      ConnectionAlertSpeech.remainingTime(deadline: prompt.deadline, now: Date()) >= 5 else { return }
                ConnectionAlertSpeech.announceOpening(arrivalHeadline, prompt: prompt, onlyOnce: true)
            }
            .task(id: CountdownKey(nonce: prompt.nonce, answered: answered)) {
                guard !answered else { return }
                let wait = ConnectionAlertSpeech.remainingTime(deadline: prompt.deadline, now: Date())
                    - ConnectionAlertSpeech.finalWarning
                // An alert that opens with little time left said so already.
                guard wait > 5 else { return }
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                AccessibilityNotification.Announcement(
                    ConnectionAlertSpeech.countdown(deadline: prompt.deadline, now: Date())
                ).post()
            }
            .riftAnnounces(problem)
    }
}

/// The progress bar, key hint and countdown under an alert's buttons as one
/// VoiceOver element. Its value is read when someone moves to it; it isn't
/// a progress indicator, so VoiceOver doesn't speak each tick.
struct ConnectionAlertCountdownElement: ViewModifier {
    let deadline: Date
    let now: Date
    /// The keys on show, such as "Esc Block · Return Allow".
    var keys: String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time to answer")
            .accessibilityValue(ConnectionAlertSpeech.countdown(deadline: deadline, now: now))
            .accessibilityHint(keys.map { "Keys: " + $0.replacingOccurrences(of: " · ", with: ", ") } ?? "")
    }
}

/// A warned alert's tint, so it isn't answered from habit. With Increase
/// Contrast the tint is stronger and the alert gets an orange edge, because a
/// faint wash is easy to miss.
struct ConnectionAlertWarnedTint: ViewModifier {
    let warned: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let orange = Color(nsColor: .systemOrange)
        content
            .background(warned ? orange.opacity(contrast == .increased ? 0.14 : 0.07) : .clear)
            .overlay {
                if warned, contrast == .increased {
                    Rectangle().strokeBorder(orange, lineWidth: 3).accessibilityHidden(true)
                }
            }
    }
}
