import Foundation
import Testing
@testable import agentGui

struct ExecutionProviderReferenceTests {
    @Test
    func builtInReferenceRoundTrips() throws {
        let encoded = try JSONEncoder().encode(ExecutionProviderReference.builtIn)
        let decoded = try JSONDecoder().decode(ExecutionProviderReference.self, from: encoded)

        #expect(decoded == .builtIn)
    }

    @Test
    func externalACPReferenceRoundTrips() throws {
        let id = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let encoded = try JSONEncoder().encode(ExecutionProviderReference.externalACP(profileID: id))
        let decoded = try JSONDecoder().decode(ExecutionProviderReference.self, from: encoded)

        #expect(decoded == .externalACP(profileID: id))
    }

    @Test
    func legacyProviderRawValuesFallBackToBuiltIn() {
        #expect(ExecutionProviderReference.decodePersisted("github_copilot_cli") == .builtIn)
        #expect(ExecutionProviderReference.decodePersisted("opencode_cli") == .builtIn)
        #expect(ExecutionProviderReference.decodePersisted("claude_adapter_cli") == .builtIn)
    }

    @Test
    func missingOrUnknownPersistedValueFallsBackToBuiltIn() {
        #expect(ExecutionProviderReference.decodePersisted(nil) == .builtIn)
        #expect(ExecutionProviderReference.decodePersisted("") == .builtIn)
        #expect(ExecutionProviderReference.decodePersisted("unknown-provider") == .builtIn)
    }
}