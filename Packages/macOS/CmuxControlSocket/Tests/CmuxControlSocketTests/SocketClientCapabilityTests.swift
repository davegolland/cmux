@testable import CmuxControlSocket
import Foundation
import Testing

@Suite("Socket client capabilities")
struct SocketClientCapabilityTests {
    private let secret = Data(
        repeating: 0x3C,
        count: SocketClientCapabilityAuthority.secureByteCount
    )
    private let nonce = Data(
        repeating: 0xC3,
        count: SocketClientCapabilityAuthority.secureByteCount
    )

    @Test func authorityRecreationPreservesIssuedCapabilities() {
        let original = SocketClientCapabilityAuthority(
            secret: secret,
            audience: "com.cmuxterm.test"
        )
        let recreated = SocketClientCapabilityAuthority(
            secret: secret,
            audience: "com.cmuxterm.test"
        )
        let capability = original.issueCapability(nonce: nonce)

        #expect(recreated.verifies(capability))
    }

    @Test func audienceAndSignatureAreBound() {
        let issuer = SocketClientCapabilityAuthority(
            secret: secret,
            audience: "com.cmuxterm.test"
        )
        let otherAudience = SocketClientCapabilityAuthority(
            secret: secret,
            audience: "com.cmuxterm.other"
        )
        let capability = issuer.issueCapability(nonce: nonce)
        let tampered = capability.dropLast() + (capability.last == "A" ? "B" : "A")

        #expect(!otherAudience.verifies(capability))
        #expect(!issuer.verifies(String(tampered)))
    }

    @Test func envelopeRoundTripsWithoutExposingCapabilityToDispatch() throws {
        let issuer = SocketClientCapabilityAuthority(
            secret: secret,
            audience: "com.cmuxterm.test"
        )
        let capability = issuer.issueCapability(nonce: nonce)
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let command = "hooks claude prompt-submit"

        let parsed = try #require(SocketClientCapabilityCommand(envelope.wrap(command)))
        #expect(parsed.capability == capability)
        #expect(parsed.command == command)
    }

    @Test func envelopeRejectsControlAndOversizedInput() {
        #expect(SocketClientCapabilityEnvelope(capability: "v1.bad\nvalue") == nil)
        #expect(SocketClientCapabilityEnvelope(
            capability: String(repeating: "a", count: SocketClientCapabilityCommand.maximumCapabilityBytes + 1)
        ) == nil)

        let issuer = SocketClientCapabilityAuthority(secret: secret, audience: "com.cmuxterm.test")
        let capability = issuer.issueCapability(nonce: nonce)
        #expect(SocketClientCapabilityCommand(
            "_cmux_capability_v1 \(capability) command\nextra"
        ) == nil)
        #expect(SocketClientCapabilityCommand(
            "_cmux_capability_v1 \(capability) \(String(repeating: "x", count: SocketClientCapabilityCommand.maximumCommandBytes + 1))"
        ) == nil)
    }

    @Test func authorityRejectsOversizedCapabilityBeforeParsing() {
        let issuer = SocketClientCapabilityAuthority(secret: secret, audience: "com.cmuxterm.test")
        let oversized = String(repeating: "a", count: SocketClientCapabilityCommand.maximumCapabilityBytes + 1)
        #expect(!issuer.verifies(oversized))
    }

    @Test func secretStoreReusesPersistentSecret() {
        let store = SocketClientCapabilitySecretStore(
            loadSecret: { secret },
            saveSecret: { _ in
                Issue.record("Existing valid secrets must not be rewritten")
                return false
            },
            randomData: { _ in Data() }
        )

        #expect(store.loadOrCreateSecret() == secret)
    }

    @Test func secretStorePersistsNewSecret() {
        let generated = Data(
            repeating: 0x7E,
            count: SocketClientCapabilityAuthority.secureByteCount
        )
        let store = SocketClientCapabilitySecretStore(
            loadSecret: { nil },
            saveSecret: {
                #expect($0 == generated)
                return true
            },
            randomData: { count in
                #expect(count == SocketClientCapabilityAuthority.secureByteCount)
                return generated
            }
        )

        #expect(store.loadOrCreateSecret() == generated)
    }
}
