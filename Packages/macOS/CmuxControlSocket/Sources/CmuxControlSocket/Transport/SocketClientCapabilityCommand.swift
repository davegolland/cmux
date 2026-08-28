/// A structurally parsed capability-bearing control-socket command.
public struct SocketClientCapabilityCommand: Sendable {
    static let wirePrefix = "_cmux_capability_v1"

    /// Hard bounds for the single-line capability envelope. The capability
    /// issued by the authority is currently 91 ASCII bytes, so this leaves
    /// room for versioned formats without allowing parser amplification.
    public static let maximumCapabilityBytes = 512
    public static let maximumCommandBytes = 8 * 1024 * 1024

    /// Opaque capability presented by the client.
    public let capability: String

    /// Original control-socket command without the capability envelope.
    public let command: String

    /// Parses a capability envelope without validating its signature.
    ///
    /// - Parameter line: Raw socket command line.
    public init?(_ line: String) {
        guard line.utf8.count <= Self.maximumCommandBytes else { return nil }
        let prefix = Self.wirePrefix + " "
        guard line.hasPrefix(prefix) else { return nil }
        let remainder = line.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: " ") else { return nil }
        let capability = String(remainder[..<separator])
        let command = String(remainder[remainder.index(after: separator)...])
        guard Self.isCapabilityToken(capability),
              !command.isEmpty,
              command.utf8.count <= Self.maximumCommandBytes,
              command.utf8.allSatisfy({ $0 != 0x00 && $0 != 0x0A && $0 != 0x0D }) else {
            return nil
        }
        self.capability = capability
        self.command = command
    }

    static func isCapabilityToken(_ capability: String) -> Bool {
        let bytes = Array(capability.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumCapabilityBytes else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39)
                || ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }
}
