import Foundation

nonisolated enum ProvisioningExpiry {
    static func installedProfile(in bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return expiration(in: data)
    }

    /// Reads the CMS signed-data payload. iOS validates the actual signature when installing the app.
    static func expiration(in data: Data) -> Date? {
        // 1.2.840.113549.1.7.2 (signedData), followed by 1.2.840.113549.1.7.1 (data).
        let signedData: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7, 2]
        let contentData = Array(signedData.dropLast()) + [1]
        guard data.count <= 4_194_304 else { return nil }
        var outer = Reader(bytes: Array(data))
        guard var wrapper = outer.read(0x30), wrapper.read(0x06)?.remainingBytes == signedData,
              var explicit = wrapper.read(0xa0), var body = explicit.read(0x30),
              body.read(0x02) != nil, body.read(0x31) != nil,
              var content = body.read(0x30), content.read(0x06)?.remainingBytes == contentData,
              var wrappedPayload = content.read(0xa0), let payload = wrappedPayload.read(0x04),
              let plist = try? PropertyListSerialization.propertyList(from: Data(payload.remainingBytes), format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary["ExpirationDate"] as? Date
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int
        let end: Int
        var remainingBytes: [UInt8] { Array(bytes[offset..<end]) }

        init(bytes: [UInt8], offset: Int = 0, end: Int? = nil) {
            self.bytes = bytes
            self.offset = offset
            self.end = end ?? bytes.count
        }

        mutating func read(_ tag: UInt8) -> Reader? {
            guard end - offset >= 2, bytes[offset] == tag else { return nil }
            let first = Int(bytes[offset + 1])
            offset += 2
            var length = first
            if first >= 128 {
                let width = first & 127
                guard (1...4).contains(width), end - offset >= width else { return nil }
                length = 0
                for _ in 0..<width { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard length <= end - offset else { return nil }
            let value = Reader(bytes: bytes, offset: offset, end: offset + length)
            offset += length
            return value
        }
    }
}
