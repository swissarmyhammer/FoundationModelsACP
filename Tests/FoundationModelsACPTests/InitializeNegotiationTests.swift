import Testing

@testable import FoundationModelsACP

/// An `Agent` that answers `initialize` with a rich capability tree —
/// authentication, both MCP transports, `additionalDirectories`, and every
/// prompt extension — so a round trip through it exercises every nested
/// `capabilities.session.*` shape M4 models, not just the baseline.
private struct NegotiatingAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "negotiating-agent", version: "1.2.3", title: "Negotiating Agent"),
            protocolVersion: .v2,
            authMethods: [],
            capabilities: AgentCapabilities(
                auth: AgentAuthCapabilities(),
                session: SessionCapabilities(
                    additionalDirectories: SessionAdditionalDirectoriesCapabilities(),
                    delete: SessionDeleteCapabilities(),
                    mcp: MCPCapabilities(http: MCPHTTPCapabilities(), stdio: MCPStdioCapabilities()),
                    prompt: PromptCapabilities(
                        audio: PromptAudioCapabilities(),
                        embeddedContext: PromptEmbeddedContextCapabilities(),
                        image: PromptImageCapabilities()
                    )
                )
            )
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// `initialize` — required `info`/`capabilities`, empty-object support
/// markers, nested `capabilities.session.*`, and v2-only protocol version
/// negotiation.
@Suite struct InitializeNegotiationTests {
    // MARK: - Full exchange over InMemoryTransport

    @Test(.timeLimit(.minutes(1)))
    func initializeRoundTripsOverInMemoryTransportWithNegotiatedInfoAndCapabilities() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in NegotiatingAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }

        let request = InitializeRequest(
            info: Implementation(name: "test-client", version: "0.0.1"),
            protocolVersion: .v2,
            capabilities: ClientCapabilities()
        )
        let response = try await client.initialize(request)

        #expect(response.protocolVersion == .v2)
        #expect(response.info.name == "negotiating-agent")
        #expect(response.info.title == "Negotiating Agent")
        #expect(response.capabilities.auth != nil)

        let session = try #require(response.capabilities.session)
        #expect(session.delete != nil)
        #expect(session.additionalDirectories != nil)

        let mcp = try #require(session.mcp)
        #expect(mcp.stdio != nil)
        #expect(mcp.http != nil)

        let prompt = try #require(session.prompt)
        #expect(prompt.audio != nil)
        #expect(prompt.image != nil)
        #expect(prompt.embeddedContext != nil)

        await agentConn.close()
        await client.close()
    }

    // MARK: - protocolVersion 2 on the wire

    @Test(.timeLimit(.minutes(1)))
    func protocolVersion2IsSentOnTheWire() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        let reader = WireReader(agentEnd)

        async let response = client.initialize(handshakeInitializeRequest())

        let request = try #require(try await reader.next())
        guard case .object(let fields) = request, case .object(let params) = fields["params"] ?? .null else {
            Issue.record("expected an initialize request with object params, got \(request)")
            return
        }
        #expect(fields["method"] == .string("initialize"))
        #expect(params["protocolVersion"] == .number(2))

        try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "id": requestID(of: request) ?? .null,
                "result": try WireRoundTrip.encode(
                    InitializeResponse(info: Implementation(name: "agent", version: "0.0.0"), protocolVersion: .v2)
                ),
            ]),
            over: agentEnd
        )
        _ = try await response
    }

    // MARK: - Version mismatch

    @Test(.timeLimit(.minutes(1)))
    func agentAnsweringADifferentProtocolVersionThrowsAClearMismatchError() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        let reader = WireReader(agentEnd)

        async let response = client.initialize(handshakeInitializeRequest())

        let request = try #require(try await reader.next())
        try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "id": requestID(of: request) ?? .null,
                "result": try WireRoundTrip.encode(
                    InitializeResponse(
                        info: Implementation(name: "v1-agent", version: "0.0.0"),
                        protocolVersion: ProtocolVersion(rawValue: 1)
                    )
                ),
            ]),
            over: agentEnd
        )

        do {
            _ = try await response
            Issue.record("expected a protocol-version mismatch error")
        } catch let error as ProtocolVersionMismatchError {
            #expect(error.sent == .v2)
            #expect(error.received == ProtocolVersion(rawValue: 1))
            // The diagnostic must name both versions explicitly, not just
            // report a generic handshake failure.
            let description = String(describing: error)
            #expect(description.contains("2"))
            #expect(description.contains("1"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func agentAnsweringAnUnrecognizedHigherProtocolVersionAlsoMismatches() async throws {
        // v2-only means any deviation from what was sent is unservable, not
        // merely a "lower version" special case.
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        let reader = WireReader(agentEnd)

        async let response = client.initialize(handshakeInitializeRequest())

        let request = try #require(try await reader.next())
        try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "id": requestID(of: request) ?? .null,
                "result": try WireRoundTrip.encode(
                    InitializeResponse(
                        info: Implementation(name: "future-agent", version: "0.0.0"),
                        protocolVersion: ProtocolVersion(rawValue: 3)
                    )
                ),
            ]),
            over: agentEnd
        )

        do {
            _ = try await response
            Issue.record("expected a protocol-version mismatch error")
        } catch let error as ProtocolVersionMismatchError {
            #expect(error.sent == .v2)
            #expect(error.received == ProtocolVersion(rawValue: 3))
        }
    }

    // MARK: - `{}` / `null` / omitted support-marker states

    @Test func emptyObjectSessionCapabilityMeansSupported() throws {
        let capabilities = try WireRoundTrip.expectLossless(AgentCapabilities.self, #"{"session":{}}"#)
        #expect(capabilities.session != nil)
    }

    @Test func explicitNullSessionCapabilityMeansUnsupportedAndIsNotWrittenBack() throws {
        let capabilities = try WireRoundTrip.decode(AgentCapabilities.self, from: #"{"session":null}"#)
        #expect(capabilities.session == nil)
        #expect(try WireRoundTrip.encode(capabilities) == .object([:]))
    }

    @Test func omittedSessionCapabilityMeansUnsupportedAndIsNotWrittenBack() throws {
        let capabilities = try WireRoundTrip.decode(AgentCapabilities.self, from: "{}")
        #expect(capabilities.session == nil)
        #expect(try WireRoundTrip.encode(capabilities) == .object([:]))
    }

    @Test func emptyObjectMcpStdioMarkerMeansSupported() throws {
        // A doubly-nested marker: capabilities.session.mcp.stdio.
        let session = try WireRoundTrip.expectLossless(SessionCapabilities.self, #"{"mcp":{"stdio":{}}}"#)
        #expect(session.mcp?.stdio != nil)
    }

    @Test func explicitNullMcpStdioMarkerMeansUnsupported() throws {
        let session = try WireRoundTrip.decode(SessionCapabilities.self, from: #"{"mcp":{"stdio":null}}"#)
        #expect(session.mcp?.stdio == nil)
    }

    @Test func omittedMcpStdioMarkerMeansUnsupported() throws {
        let session = try WireRoundTrip.decode(SessionCapabilities.self, from: #"{"mcp":{}}"#)
        #expect(session.mcp?.stdio == nil)
    }

    @Test func supportMarkerEncodesAsAnEmptyObjectNeverABoolean() throws {
        let capabilities = AgentCapabilities(session: SessionCapabilities())
        let encoded = try WireRoundTrip.encode(capabilities)
        #expect(encoded["session"] == .object([:]))
    }

    // MARK: - Nested `capabilities.session.*`, both MCP transports and additionalDirectories

    @Test func nestedSessionCapabilitiesModelBothMcpTransportsAndAdditionalDirectories() throws {
        let json = """
            {
              "session": {
                "additionalDirectories": {},
                "delete": {},
                "mcp": {"stdio": {}, "http": {}},
                "prompt": {"audio": {}, "image": {}, "embeddedContext": {}}
              }
            }
            """
        let capabilities = try WireRoundTrip.expectLossless(AgentCapabilities.self, json)
        let session = try #require(capabilities.session)
        #expect(session.additionalDirectories != nil)
        #expect(session.delete != nil)
        #expect(session.mcp?.stdio != nil)
        #expect(session.mcp?.http != nil)
        #expect(session.prompt?.audio != nil)
        #expect(session.prompt?.image != nil)
        #expect(session.prompt?.embeddedContext != nil)
    }

    // MARK: - Unknown nested keys survive a capability round trip

    @Test func capabilityRoundTripPreservesUnknownNestedMetaKeys() throws {
        // "Implementations MUST NOT make assumptions about values at these
        // keys" applies at every nesting level a capability object has, not
        // only the top one — so this puts extension data three levels deep
        // (capabilities -> session -> mcp.stdio) alongside two shallower
        // ones and asserts every one of them survives verbatim.
        let json = """
            {
              "session": {
                "mcp": {
                  "stdio": {"_meta": {"vendor.example/extra": {"nested": [1, 2, 3]}, "flag": true}}
                },
                "_meta": {"sessionExtra": "x"}
              },
              "_meta": {"topExtra": {"deep": {"deeper": "value"}}}
            }
            """
        let capabilities = try WireRoundTrip.expectLossless(AgentCapabilities.self, json)
        #expect(
            capabilities.session?.mcp?.stdio?.meta
                == .object([
                    "vendor.example/extra": .object(["nested": .array([.number(1), .number(2), .number(3)])]),
                    "flag": .bool(true),
                ])
        )
        #expect(capabilities.session?.meta == .object(["sessionExtra": .string("x")]))
        #expect(capabilities.meta == .object(["topExtra": .object(["deep": .object(["deeper": .string("value")])])]))
    }
}
