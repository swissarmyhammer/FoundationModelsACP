import Testing

@testable import FoundationModelsACP

/// A minimal `Agent` conformer implementing only the session baseline, to
/// prove that a conforming type needs nothing else to serve a session.
private struct BaselineAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "baseline-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
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

/// An `Agent` conformer that also implements every capability-gated method,
/// so overriding the defaults can be exercised alongside them.
private struct FullAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "full-agent", version: "0.0.0"),
            protocolVersion: .v2,
            authMethods: [],
            capabilities: AgentCapabilities(session: SessionCapabilities(delete: SessionDeleteCapabilities()))
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

    func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        LoginAuthResponse()
    }

    func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        LogoutAuthResponse()
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        DeleteSessionResponse()
    }

    func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        SetSessionConfigOptionResponse(configOptions: [])
    }
}

/// `Agent` — the role protocol a client drives.
@Suite struct AgentProtocolTests {
    private static let cwd = AbsolutePath(rawValue: "/tmp")!

    @Test func conformerImplementingOnlyTheBaselineCompilesAndServesASession() async throws {
        // The whole point: a type declaring only the six baseline methods
        // plus `initialize` satisfies `Agent` with no help from a default.
        let agent = BaselineAgent()

        let initResponse = try await agent.initialize(
            InitializeRequest(info: Implementation(name: "test-client", version: "1.0.0"), protocolVersion: .v2)
        )
        #expect(initResponse.protocolVersion == .v2)

        let newSession = try await agent.newSession(NewSessionRequest(cwd: Self.cwd))
        #expect(newSession.sessionId == SessionId(rawValue: "session-1"))

        let listed = try await agent.listSessions(ListSessionsRequest())
        #expect(listed.sessions.isEmpty)

        _ = try await agent.resumeSession(ResumeSessionRequest(cwd: Self.cwd, sessionId: newSession.sessionId))
        _ = try await agent.closeSession(CloseSessionRequest(sessionId: newSession.sessionId))
        _ = try await agent.prompt(PromptRequest(prompt: [], sessionId: newSession.sessionId))
        await agent.sessionCancel(CancelSessionNotification(sessionId: newSession.sessionId))
    }

    @Test func unimplementedCapabilityGatedMethodsYieldMethodNotFoundNotACrash() async throws {
        let agent = BaselineAgent()
        let sessionId = SessionId(rawValue: "session-1")

        await #expect(throws: RequestError.self) {
            _ = try await agent.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "oauth")))
        }
        await #expect(throws: RequestError.self) {
            _ = try await agent.logoutAuth(LogoutAuthRequest())
        }
        await #expect(throws: RequestError.self) {
            _ = try await agent.deleteSession(DeleteSessionRequest(sessionId: sessionId))
        }
        await #expect(throws: RequestError.self) {
            _ = try await agent.setSessionConfigOption(
                SetSessionConfigOptionRequest(
                    configId: SessionConfigId(rawValue: "opt"),
                    sessionId: sessionId,
                    value: .boolean(true)
                )
            )
        }
    }

    @Test func defaultMethodNotFoundErrorsNameTheWireMethodFromTheRoutingTable() async throws {
        // The literal wire-method strings the defaults report must agree
        // with the generated table, not drift from it silently.
        let agent = BaselineAgent()
        let byHandler = Dictionary(uniqueKeysWithValues: ACPMethodTable.methods.map { ($0.handlerName, $0.wireMethod) })

        do {
            _ = try await agent.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "oauth")))
            Issue.record("expected method-not-found")
        } catch let error as RequestError {
            #expect(error.data == .object(["method": .string(byHandler["loginAuth"]!)]))
        }

        do {
            _ = try await agent.deleteSession(DeleteSessionRequest(sessionId: SessionId(rawValue: "session-1")))
            Issue.record("expected method-not-found")
        } catch let error as RequestError {
            #expect(error.data == .object(["method": .string(byHandler["deleteSession"]!)]))
        }
    }

    @Test func authMethodsAreAbsentByDefaultAndPresentWhenOverridden() async throws {
        // "Absent when `authMethods` is empty": a conformer that advertises
        // no auth methods needs no override, and calling the un-overridden
        // method fails loud rather than silently succeeding.
        let withoutAuth = BaselineAgent()
        await #expect(throws: RequestError.self) {
            _ = try await withoutAuth.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "oauth")))
        }

        // "Present when not": a conformer that does advertise auth methods
        // overrides them, and the override — not the default — answers.
        let withAuth = FullAgent()
        let response = try await withAuth.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "oauth")))
        #expect(response == LoginAuthResponse())

        // The same gating/default pattern applies to `logoutAuth`, which
        // shares `loginAuth`'s `authMethods` capability but is otherwise
        // independent — an agent could in principle offer one without the
        // other, so both directions are worth checking on their own.
        await #expect(throws: RequestError.self) {
            _ = try await withoutAuth.logoutAuth(LogoutAuthRequest())
        }
        let logoutResponse = try await withAuth.logoutAuth(LogoutAuthRequest())
        #expect(logoutResponse == LogoutAuthResponse())
    }

    @Test func sessionDeleteIsGatedAndOverridableIndependently() async throws {
        let withoutDelete = BaselineAgent()
        await #expect(throws: RequestError.self) {
            _ = try await withoutDelete.deleteSession(DeleteSessionRequest(sessionId: SessionId(rawValue: "session-1")))
        }

        let withDelete = FullAgent()
        let response = try await withDelete.deleteSession(DeleteSessionRequest(sessionId: SessionId(rawValue: "session-1")))
        #expect(response == DeleteSessionResponse())
    }

    @Test func agentCarriesNoUnstableOnlyMethod() throws {
        // Elicitation in particular: unstable-only in the vendored schema, and
        // must not appear as a method on the stable `Agent` surface. Checked
        // against the generated unstable handler names rather than the bare
        // word "elicitation", since prose explaining a deferral is legitimate
        // even though a method with that name is not.
        let source = try sourceOfAgentProtocolFile()
        for handlerName in Unstable.MethodTable.methods.map(\.handlerName) {
            #expect(!source.contains("func \(handlerName)("), "\(handlerName) is unstable-only; it must not appear on Agent")
        }
    }
}
