import Testing

@testable import FoundationModelsACP

/// A stub `Client` implementing the four stable entry points — the entire
/// stable client surface, so there is nothing left to default.
private actor StubClient: Client {
    private(set) var receivedUpdates: [UpdateSessionNotification] = []
    private(set) var receivedCompletions: [CompleteElicitationNotification] = []

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        receivedUpdates.append(notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        .object(["action": .string("decline")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        receivedCompletions.append(notification)
    }
}

/// `Client` — the role protocol that drives an agent.
@Suite struct ClientProtocolTests {
    @Test func stubImplementingTheFourEntryPointsCompilesAndWorks() async throws {
        let client = StubClient()
        let sessionId = SessionId(rawValue: "session-1")

        await client.sessionUpdate(
            UpdateSessionNotification(sessionId: sessionId, update: .userMessage(UserMessage(messageId: MessageId(rawValue: "m1"))))
        )
        #expect(await client.receivedUpdates.count == 1)

        let response = try await client.requestPermission(
            RequestPermissionRequest(
                options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
                sessionId: sessionId,
                title: "Allow this?"
            )
        )
        #expect(response.outcome == .cancelled)

        let elicitation = try await client.createElicitation(
            CreateElicitationRequest(
                message: "Name the file",
                mode: .form(
                    ElicitationFormMode(
                        requestedSchema: ElicitationSchema(),
                        scope: .session(ElicitationSessionScope(sessionId: sessionId))
                    )
                )
            )
        )
        #expect(elicitation == .object(["action": .string("decline")]))

        await client.elicitationComplete(CompleteElicitationNotification(elicitationId: ElicitationId(rawValue: "e1")))
        #expect(await client.receivedCompletions.count == 1)
    }

    @Test func clientCarriesNoUnstableOnlyMethod() throws {
        // Elicitation graduated to the stable surface in the pinned schema
        // revision, so `createElicitation` and `elicitationComplete` belong
        // on `Client` now — what must still never appear is any method the
        // unstable manifest alone routes (`mcp/*` on the client side, and the
        // rest of `Unstable.MethodTable`). Checked against the generated
        // unstable handler names rather than prose keywords, which the
        // protocol's own documentation legitimately uses.
        let source = try sourceOfClientProtocolFile()
        for handlerName in Unstable.MethodTable.methods.map(\.handlerName) {
            #expect(!source.contains("func \(handlerName)("), "\(handlerName) is unstable-only; it must not appear on Client")
        }
    }

    @Test func clientCarriesNoRemovedFilesystemOrTerminalMethod() throws {
        // v2 removed `fs/*` and `terminal/*` outright; agents reach the
        // client's world through MCP instead.
        let source = try sourceOfClientProtocolFile()
        for removed in ["readTextFile", "writeTextFile", "createTerminal", "terminalOutput", "killTerminal", "releaseTerminal"] {
            #expect(!source.contains(removed), "\(removed) is a v1 method; v2's Client has four entry points, none of them these")
        }
    }
}
