/// Punycode (RFC 3492) for checking internationalized domain labels. Rift
/// keeps and shows names in their ASCII `xn--` form, so it decodes a label
/// only to check that it's a real, canonical A-label. Labels are at most 63
/// bytes, so every loop here is bounded.
enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 0x80
    private static let maximumValue = Int(Int32.max)

    /// Whether `label` is a lowercase A-label whose Unicode form decodes,
    /// encodes back to the same text, and holds only lowercase letters,
    /// marks and digits, with at least one of them non-ASCII. That's a
    /// conservative subset of what IDNA2008 allows: symbols, punctuation and
    /// emoji are refused, as are the joiners IDNA allows only in context.
    static func isValidALabel(_ label: Substring) -> Bool {
        guard label.hasPrefix("xn--") else { return false }
        let payload = Array(label.utf8.dropFirst(4))
        guard !payload.isEmpty,
              let decoded = decode(payload),
              decoded.contains(where: { !$0.isASCII }),
              decoded.allSatisfy(isPermitted),
              let first = decoded.first, let last = decoded.last,
              !isCombiningMark(first),
              first != "-", last != "-",
              !(decoded.count >= 4 && decoded[2] == "-" && decoded[3] == "-"),
              encode(decoded) == payload else {
            return false
        }
        return true
    }

    private static func isPermitted(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            return (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
        }
        if scalar.properties.changesWhenLowercased { return false }
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    static func decode(_ input: [UInt8]) -> [Unicode.Scalar]? {
        var output: [Unicode.Scalar] = []
        var position = 0
        if let delimiter = input.lastIndex(of: UInt8(ascii: "-")) {
            for byte in input[..<delimiter] {
                guard byte < 0x80 else { return nil }
                output.append(Unicode.Scalar(byte))
            }
            position = delimiter + 1
        }
        var n = initialN
        var i = 0
        var bias = initialBias
        while position < input.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard position < input.count,
                      let digit = digitValue(input[position]) else { return nil }
                position += 1
                guard digit <= (maximumValue - i) / weight else { return nil }
                i += digit * weight
                let t = threshold(k, bias: bias)
                if digit < t { break }
                guard weight <= maximumValue / (base - t) else { return nil }
                weight *= base - t
                k += base
            }
            let count = output.count + 1
            bias = adapt(i - oldI, count: count, first: oldI == 0)
            guard i / count <= maximumValue - n else { return nil }
            n += i / count
            i %= count
            guard n >= initialN, let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        return output
    }

    static func encode(_ input: [Unicode.Scalar]) -> [UInt8]? {
        var output = input.filter(\.isASCII).map { UInt8($0.value) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(UInt8(ascii: "-")) }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < input.count {
            guard let next = input.lazy.map({ Int($0.value) }).filter({ $0 >= n }).min(),
                  next - n <= (maximumValue - delta) / (handled + 1) else { return nil }
            delta += (next - n) * (handled + 1)
            n = next
            for scalar in input {
                let value = Int(scalar.value)
                if value < n {
                    guard delta < maximumValue else { return nil }
                    delta += 1
                }
                guard value == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = threshold(k, bias: bias)
                    if q < t { break }
                    output.append(digitByte(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digitByte(q))
                bias = adapt(delta, count: handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }

    private static func threshold(_ k: Int, bias: Int) -> Int {
        if k <= bias { return tMin }
        if k >= bias + tMax { return tMax }
        return k - bias
    }

    private static func adapt(_ delta: Int, count: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(byte - UInt8(ascii: "a"))
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0")) + 26
        default: nil
        }
    }

    private static func digitByte(_ digit: Int) -> UInt8 {
        digit < 26 ? UInt8(ascii: "a") + UInt8(digit) : UInt8(ascii: "0") + UInt8(digit - 26)
    }
}
