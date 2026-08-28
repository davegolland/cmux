import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    /// A push frame is delivered as one JSON object. Keep the producer-side
    /// conversion bounded even if a future message model gains a large field.
    private static let maximumWirePayloadBytes = 4 * 1024 * 1024

    static func descriptorChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        return normalizedPrevious.descriptor != current.descriptor
    }

    /// Encodes a wire value into the `[String: Any]` payload shape the
    /// event fan-out expects.
    func wirePayload<T: Encodable>(_ value: T) -> [String: Any]? {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              data.count <= Self.maximumWirePayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
