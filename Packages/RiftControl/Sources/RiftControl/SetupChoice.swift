/// Decides when setup ends with its one question. It only asks someone who
/// hasn't made any choices yet, so an upgrade never asks again.
public enum SetupChoice {
    public static func shouldAsk(
        status: ProtectionStatus,
        ruleCount: Int?,
        alreadyAnswered: Bool
    ) -> Bool {
        guard !alreadyAnswered, status.state == .active(.silentAllow) else { return false }
        return ruleCount == 0
    }
}
