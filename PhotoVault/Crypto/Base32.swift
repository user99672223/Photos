import Foundation

// RFC 4648 base32, no padding. 32-byte key -> 52 chars.
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var result = ""
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((buffer >> UInt64(bits)) & 0x1F)
                result.append(alphabet[index])
            }
        }
        if bits > 0 {
            let index = Int((buffer << UInt64(5 - bits)) & 0x1F)
            result.append(alphabet[index])
        }
        return result
    }

    static func decode(_ string: String) -> Data? {
        var lookup = [Character: UInt64]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt64(i) }
        var result = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for char in string.uppercased() where char != " " && char != "-" {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        return result
    }
}
