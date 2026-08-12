public enum PolicyLimits {
    // Keep this conservative cap until signed callback and transfer benchmarks
    // justify a change. Raising it requires repeating those measurements.
    public static let maximumDestinationMembers = 256
    public static let maximumDisplayScalars = 256
    public static let maximumNotesScalars = 2_048
}
