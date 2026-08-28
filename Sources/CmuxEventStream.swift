import CmuxControlSocket
import Darwin
import Dispatch
import Foundation

extension TerminalController {
    nonisolated func isEventsStreamRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              case .success(let request) = Self.v2Parser.request(fromLine: line) else {
            return false
        }
        return request.method == "events.stream"
    }

    nonisolated func handleEventsStreamRequest(
        _ line: String,
        socket: Int32,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal,
        passwordAuthorization: SocketPasswordAuthorization
    ) {
        var streamPasswordAuthorization = passwordAuthorization
        guard socketEventStreamAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &streamPasswordAuthorization
        ) else { return }
        guard line.hasPrefix("{"),
              case .success(let request) = Self.v2Parser.request(fromLine: line),
              request.method == "events.stream" else {
            guard socketEventStreamAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &streamPasswordAuthorization
            ) else { return }
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_request", "message": "events.stream requires a JSON object"]
            ], socket: socket)
            return
        }

        let params = request.params
        guard let names = Self.boundedStringSet(params["names"] ?? params["name"]),
              let categories = Self.boundedStringSet(params["categories"] ?? params["category"]) else {
            guard socketEventStreamAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &streamPasswordAuthorization
            ) else { return }
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_params", "message": "events.stream filters are too large"]
            ], socket: socket)
            return
        }
        let afterSequence = Self.eventSequence(params["after_seq"] ?? params["after"])
        let includeHeartbeats = Self.eventBool(params["include_heartbeats"] ?? params["include_heartbeat"]) ?? true

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: afterSequence,
            names: names,
            categories: categories
        )
        let revocationSource = socketEventStreamRevocationSource(
            authorizationRevocationSignal,
            subscription: snapshot.subscription
        )
        defer {
            revocationSource?.cancel()
            CmuxEventBus.shared.unsubscribe(snapshot.subscription)
        }

        guard socketEventStreamAuthorizationIsCurrent(
                  authorizationGeneration,
                  passwordAuthorization: &streamPasswordAuthorization
              ),
              writeEventsStreamLine(snapshot.ack, socket: socket) else { return }
        for event in snapshot.replay {
            guard socketEventStreamAuthorizationIsCurrent(
                      authorizationGeneration,
                      passwordAuthorization: &streamPasswordAuthorization
                  ),
                  writeEventsStreamLine(event, socket: socket) else { return }
        }

        while socketEventStreamAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &streamPasswordAuthorization
        ) {
            let event = snapshot.subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds)
            guard socketEventStreamAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &streamPasswordAuthorization
            ) else { return }
            if let event {
                guard writeEventsStreamLine(event, socket: socket) else { return }
            } else if snapshot.subscription.isClosed {
                if let reason = snapshot.subscription.closeReason {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": [
                            "code": "slow_consumer",
                            "message": reason,
                            "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
                        ]
                    ], socket: socket)
                }
                return
            } else if includeHeartbeats,
                      socketEventStreamAuthorizationIsCurrent(
                          authorizationGeneration,
                          passwordAuthorization: &streamPasswordAuthorization
                      ) {
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: snapshot.subscription)
                guard writeEventsStreamLine(heartbeat, socket: socket) else { return }
            } else if Self.socketPeerClosed(socket) {
                return
            }
        }
    }

    private nonisolated func socketEventStreamRevocationSource(
        _ signal: SocketAuthorizationRevocationSignal,
        subscription: CmuxEventSubscription
    ) -> (any DispatchSourceRead)? {
        let signalDescriptor = signal.readFileDescriptor
        guard signalDescriptor >= 0 else { return nil }

        // Dispatch source cancellation is asynchronous. Give the source its
        // own descriptor so the signal may release its copy without racing a
        // pending event handler, then close this copy in the cancel handler.
        let descriptor = dup(signalDescriptor)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        // DispatchSource bridges the pollable revocation pipe into the
        // subscription's existing wake signal without a timer or polling loop.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            subscription.close()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.activate()
        return source
    }

    nonisolated func publishSocketEvents(command: String, response: String) {
        CmuxSocketEventMapper.publish(command: command, response: response)
    }

    private nonisolated func writeEventsStreamLine(_ object: [String: Any], socket: Int32) -> Bool {
        autoreleasepool {
            guard let line = CmuxEventBus.encodeLine(object) else { return false }
            return transport.writeAll(Data((line + "\n").utf8), to: socket)
        }
    }

    private static let maximumEventFilterItems = 256
    private static let maximumEventFilterStringBytes = 256
    private static let maximumEventFilterTotalBytes = 32 * 1024

    /// Converts a wire filter into a small, bounded set. Returning nil means
    /// the caller supplied an invalid or oversized filter. Only an absent
    /// filter maps to an empty set, which means "all events".
    private nonisolated static func boundedStringSet(_ value: JSONValue?) -> Set<String>? {
        guard let value else { return [] }
        let rawValues: [String]
        switch value {
        case .string(let string):
            rawValues = [string]
        case .array(let values):
            guard values.count <= maximumEventFilterItems else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(values.count)
            for element in values {
                guard case .string(let string) = element else { return nil }
                strings.append(string)
            }
            rawValues = strings
        default:
            return nil
        }

        var result = Set<String>()
        var totalBytes = 0
        for rawValue in rawValues {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let byteCount = value.utf8.count
            guard byteCount <= maximumEventFilterStringBytes,
                  totalBytes <= maximumEventFilterTotalBytes - byteCount,
                  !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                return nil
            }
            totalBytes += byteCount
            result.insert(value)
            guard result.count <= maximumEventFilterItems else { return nil }
        }
        return result
    }

    private nonisolated static func eventSequence(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let value):
            return value
        case .string(let value):
            return Int64(value)
        default:
            return nil
        }
    }

    private nonisolated static func eventBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let value):
            return value
        case .int(0):
            return false
        case .int(1):
            return true
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private nonisolated static func socketPeerClosed(_ socket: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result == 0 {
            return true
        }
        if result > 0 {
            return false
        }
        let errorCode = errno
        return errorCode != EAGAIN && errorCode != EWOULDBLOCK && errorCode != EINTR
    }
}
