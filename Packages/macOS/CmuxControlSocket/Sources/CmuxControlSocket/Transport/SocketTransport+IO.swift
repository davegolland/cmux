public import Foundation
internal import Darwin

extension SocketTransport {
    private static let maximumProbeCommandBytes = 8 * 1024 * 1024
    private static let maximumProbeResponseBytes = 8 * 1024 * 1024

    /// Writes all of `data` to `socket`, retrying on `EINTR` and partial
    /// writes.
    ///
    /// - Parameters:
    ///   - data: The bytes to write.
    ///   - socket: The destination socket descriptor.
    /// - Returns: False on any write failure other than `EINTR`.
    public func writeAll(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0

            while offset < rawBuffer.count {
                let written = write(
                    socket,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                return false
            }

            return true
        }
    }

    /// Connects to the listener at `socketPath`, sends one line-terminated
    /// command, and returns the first response line (or nil on any failure or
    /// timeout).
    ///
    /// A blocking client with `SO_RCVTIMEO`/`SO_SNDTIMEO` set to `timeout`;
    /// never polls.
    ///
    /// - Parameters:
    ///   - command: The command text; a trailing newline is appended.
    ///   - socketPath: The Unix-domain socket path to connect to.
    ///   - timeout: Send/receive timeout applied to the probe connection.
    /// - Returns: The first response line without its newline, or nil.
    public func probeCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval
    ) -> String? {
        // Check lengths before materializing attacker-controlled byte arrays.
        // The exact sockaddr bound is checked again below when the address is
        // assembled.
        let maxSocketPathBytes = MemoryLayout<sockaddr_un>.size
            - (MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0)
        guard !command.isEmpty,
              command.utf8.count <= Self.maximumProbeCommandBytes,
              command.utf8.allSatisfy({ $0 != 0x00 && $0 != 0x0A && $0 != 0x0D }),
              !socketPath.isEmpty,
              socketPath.utf8.count + 1 <= maxSocketPathBytes,
              !socketPath.utf8.contains(0) else {
            return nil
        }
        let commandBytes = Array(command.utf8)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = configureCloseOnExec(fd)
        configureSocketTimeouts(fd, timeout: timeout)

        _ = configureNoSigPipe(fd)

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        guard writeAll(Data(commandBytes + [0x0A]), to: fd) else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseBytes: [UInt8] = []
        responseBytes.reserveCapacity(buffer.count)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                let readErrno = errno
                if readErrno == EINTR {
                    continue
                }
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if count == 0 {
                break
            }
            let (newCount, overflowed) = responseBytes.count.addingReportingOverflow(count)
            guard !overflowed, newCount <= Self.maximumProbeResponseBytes else { return nil }
            responseBytes.append(contentsOf: buffer[0..<count])
            if let newlineIndex = responseBytes.firstIndex(of: 0x0A) {
                return String(bytes: responseBytes[..<newlineIndex], encoding: .utf8)
            }
        }

        guard let response = String(bytes: responseBytes, encoding: .utf8) else { return nil }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
