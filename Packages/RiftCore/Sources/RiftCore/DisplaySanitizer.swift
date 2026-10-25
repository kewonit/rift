public enum DisplaySanitizer {
    private static let replacement: Unicode.Scalar = "�"
    private static let isolateStart: Unicode.Scalar = "⁨"
    private static let isolateEnd: Unicode.Scalar = "⁩"

    public static func plainText(
        _ input: String,
        maximumScalars: Int = PolicyLimits.maximumDisplayScalars
    ) -> String {
        let limit = max(0, maximumScalars)
        var scalars = String.UnicodeScalarView()
        scalars.append(isolateStart)
        var count = 0
        for scalar in input.unicodeScalars {
            guard count < limit else { break }
            if scalar.properties.isBidiControl || scalar.value < 0x20 || scalar.value == 0x7F {
                scalars.append(replacement)
            } else {
                scalars.append(scalar)
            }
            count += 1
        }
        scalars.append(isolateEnd)
        return String(scalars)
    }
}
