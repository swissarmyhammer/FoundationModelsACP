import Testing

@testable import FoundationModelsACP

/// The wire shape of the client-side authentication capability, and of an
/// `initialize` response that advertises authentication methods.
///
/// `ClientCapabilities.auth` gates which authentication methods an agent may
/// offer, so the three states of a support marker — an empty object, an
/// explicit null, and an omitted key — must stay distinct in both directions.
/// A marker that came back as `{}` where the client wrote nothing would invite
/// the agent to send a `terminal` method the client cannot run.
@Suite struct AuthCapabilitiesRoundTripTests {
    // MARK: - `{}` / `null` / omitted states of `auth`

    @Test func clientCapabilitiesWithoutAuthOmitTheKey() throws {
        let encoded = try WireRoundTrip.encode(ClientCapabilities())
        #expect(encoded["auth"] == nil)
    }

    @Test func aTerminalMarkerEncodesAsANestedEmptyObject() throws {
        let capabilities = ClientCapabilities(auth: AuthCapabilities(terminal: TerminalAuthCapabilities()))
        let encoded = try WireRoundTrip.encode(capabilities)
        #expect(encoded["auth"] == .object(["terminal": .object([:])]))
    }

    @Test func anEmptyObjectTerminalMarkerMeansSupported() throws {
        let capabilities = try WireRoundTrip.expectLossless(
            ClientCapabilities.self,
            #"{"auth":{"terminal":{}}}"#
        )
        #expect(capabilities.auth?.terminal != nil)
    }

    @Test func anExplicitNullAuthCapabilityMeansUnadvertised() throws {
        let capabilities = try WireRoundTrip.decode(ClientCapabilities.self, from: #"{"auth":null}"#)
        #expect(capabilities.auth == nil)
    }

    @Test func anExplicitNullTerminalMarkerLeavesTheAuthObjectPresent() throws {
        // The two nesting levels are separate advertisements: the client still
        // says "I read the auth extension", and says "not the terminal one".
        let capabilities = try WireRoundTrip.decode(ClientCapabilities.self, from: #"{"auth":{"terminal":null}}"#)
        #expect(capabilities.auth != nil)
        #expect(capabilities.auth?.terminal == nil)
    }

    @Test func aMalformedAuthCapabilityDegradesToUnadvertisedRatherThanFailing() throws {
        // `x-deserialize-default-on-error`: a capability field a peer got
        // wrong must not fail the whole `initialize` handshake. Reaching the
        // assertion at all is half the claim — `decode` throws otherwise.
        let capabilities = try WireRoundTrip.decode(ClientCapabilities.self, from: #"{"auth":"garbage"}"#)
        #expect(capabilities.auth == nil)
    }

    // MARK: - Advertised authentication methods

    @Test func anInitializeResponseCarryingBothAuthMethodKindsRoundTrips() throws {
        // `authMethods` is where the two variants meet in one document, so a
        // flattening that leaked one payload's members into its neighbor shows
        // up here and nowhere else.
        let response = try WireRoundTrip.expectLossless(
            InitializeResponse.self,
            """
            {"info":{"name":"agent","version":"1.0.0"},"protocolVersion":2,\
            "authMethods":[\
            {"type":"terminal","methodId":"terminal-login","name":"Terminal login",\
            "args":["auth","login"],"env":[{"name":"TOKEN","value":"abc"}]},\
            {"type":"agent","methodId":"agent-login","name":"Agent login",\
            "description":"Log in through the agent"}],\
            "capabilities":{}}
            """
        )
        let methods = try #require(response.authMethods)
        guard case .terminal(let terminal) = try #require(methods.first) else {
            Issue.record("expected the first method to be .terminal, got \(methods)")
            return
        }
        #expect(terminal.methodId == AuthMethodId(rawValue: "terminal-login"))
        #expect(terminal.args == ["auth", "login"])
        #expect(terminal.env?.first == EnvVariable(name: "TOKEN", value: "abc"))
        // The agent variant declares no `args`, so a payload that captured its
        // neighbor's members would show them here.
        guard case .agent(let agent) = try #require(methods.last) else {
            Issue.record("expected the last method to be .agent, got \(methods)")
            return
        }
        #expect(agent.methodId == AuthMethodId(rawValue: "agent-login"))
        #expect(agent.description == "Log in through the agent")
    }
}
