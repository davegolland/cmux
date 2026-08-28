import CmuxSwiftRender
import Foundation

/// Validation for values that cross the interpreter and remote-render worker
/// pipes. Codable decoding only checks shape, not resource or numeric safety.
/// Keep this boundary independent from the producer so a malformed worker or a
/// future protocol implementation cannot hand invalid values to AppKit.
private enum RenderProtocolLimits {
    static let maxStateEntries = 2_048
    static let maxReloadNames = 64
    static let maxInsets = 10_000.0
    static let maxSourceBytes = 1 * 1024 * 1024
    static let maxPathBytes = 4 * 1024
    static let maxIdentifierBytes = 128
}

private func validProtocolString(
    _ value: String,
    maxBytes: Int,
    allowEmpty: Bool = false
) -> Bool {
    (allowEmpty || !value.isEmpty)
        && value.utf8.count <= maxBytes
        && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

private func validFinite(_ value: Double, maximum: Double, minimum: Double? = nil) -> Bool {
    guard value.isFinite, abs(value) <= maximum else { return false }
    if let minimum { return value >= minimum }
    return true
}

public extension RenderSurfaceGeometry {
    /// Whether this geometry is safe to turn into an AppKit window size.
    func isWithinSecurityLimits() -> Bool {
        validFinite(width, maximum: RenderProtocolLimits.maxInsets, minimum: 0.001)
            && validFinite(height, maximum: RenderProtocolLimits.maxInsets, minimum: 0.001)
            && validFinite(scale, maximum: 8, minimum: 0.1)
    }
}

public extension RenderPointerEvent {
    /// Whether this event is safe to convert to `NSPoint` and scroll deltas.
    func isWithinSecurityLimits() -> Bool {
        validFinite(x, maximum: 100_000)
            && validFinite(y, maximum: 100_000)
            && validFinite(deltaX, maximum: 100_000)
            && validFinite(deltaY, maximum: 100_000)
            && (0...100).contains(clickCount)
    }
}

public extension RenderScene {
    /// Whether this scene can be accepted by a worker without unbounded state
    /// or an invalid file path reaching the model and `URL` APIs.
    func isWithinSecurityLimits() -> Bool {
        guard validProtocolString(filePath, maxBytes: RenderProtocolLimits.maxPathBytes),
              filePath.hasPrefix("/"),
              ["js", "swift", "json"].contains(URL(fileURLWithPath: filePath).pathExtension.lowercased()),
              state.count <= RenderProtocolLimits.maxStateEntries,
              validFinite(topInset, maximum: RenderProtocolLimits.maxInsets, minimum: 0),
              validFinite(bottomInset, maximum: RenderProtocolLimits.maxInsets, minimum: 0) else {
            return false
        }
        return state.allSatisfy { key, value in
            validProtocolString(key, maxBytes: RenderProtocolLimits.maxIdentifierBytes)
                && value.isWithinSecurityLimits()
        }
    }
}

public extension InterpreterRequest {
    /// Whether an interpreter request is bounded before it is encoded or
    /// evaluated. This protects both the host client and the worker entrypoint.
    func isWithinSecurityLimits() -> Bool {
        guard source.utf8.count <= RenderProtocolLimits.maxSourceBytes,
              state.count <= RenderProtocolLimits.maxStateEntries else { return false }
        return state.allSatisfy { key, value in
            validProtocolString(key, maxBytes: RenderProtocolLimits.maxIdentifierBytes)
                && value.isWithinSecurityLimits()
        }
    }
}

public extension InterpreterResponse {
    /// Whether a decoded worker response is safe for the host renderer.
    func isWithinSecurityLimits() -> Bool {
        node?.isWithinSecurityLimits() ?? true
    }
}

public extension ButtonAction {
    /// Whether an action decoded from a worker is bounded before dispatch.
    func isWithinSecurityLimits() -> Bool {
        guard commands.count <= 16 else { return false }
        return commands.allSatisfy { command in
            switch command {
            case let .cmux(method, params):
                guard validProtocolString(method, maxBytes: 128), params.count <= 32 else { return false }
                return params.allSatisfy { key, value in
                    validProtocolString(key, maxBytes: 128)
                        && validProtocolString(value, maxBytes: 4 * 1024, allowEmpty: true)
                }
            case let .openURL(url):
                return validProtocolString(url, maxBytes: 2 * 1024, allowEmpty: true)
            case let .log(message):
                return validProtocolString(message, maxBytes: 4 * 1024, allowEmpty: true)
            }
        }
    }
}

public extension RenderWorkerOutbound {
    /// Whether a decoded worker response is safe to surface to the host.
    func isWithinSecurityLimits() -> Bool {
        switch self {
        case let .context(contextID):
            // Zero is reserved as an uninitialized context id. Rejecting it
            // keeps a malformed worker frame from selecting a default context.
            return contextID > 0
        case .ack:
            return true
        case let .action(action):
            return action.isWithinSecurityLimits()
        }
    }
}

public extension RenderWorkerInbound {
    /// Whether a decoded worker message is safe to apply.
    func isWithinSecurityLimits() -> Bool {
        switch self {
        case let .scene(scene):
            return scene.isWithinSecurityLimits()
        case let .resize(geometry):
            return geometry.isWithinSecurityLimits()
        case let .pointer(event):
            return event.isWithinSecurityLimits()
        case let .reloadSidebars(names):
            guard let names else { return true }
            return names.count <= RenderProtocolLimits.maxReloadNames
                && names.allSatisfy {
                    validProtocolString($0, maxBytes: RenderProtocolLimits.maxIdentifierBytes)
                }
        }
    }
}
