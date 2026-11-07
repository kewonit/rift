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
        // Text that was already sanitized arrives wrapped in one isolate pair.
        // Unwrap it once so sanitizing twice doesn't turn that pair into
        // replacement characters; the contents are still checked below.
        var body = Substring(input).unicodeScalars
        if body.count >= 2, body.first == isolateStart, body.last == isolateEnd {
            body = body.dropFirst().dropLast()
        }
        for scalar in body {
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
