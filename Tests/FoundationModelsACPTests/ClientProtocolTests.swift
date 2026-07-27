import Testing

@testable import FoundationModelsACP

/// A stub `Client` implementing only the two stable entry points — the
/// entire stable client surface, so there is nothing left to default.
private actor StubClient: Client {
    private(set) var receivedUpdates: [UpdateSessionNotification] = []

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        receivedUpdates.append(notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }
}

/// `Client` — the role protocol that drives an agent.
@Suite struct ClientProtocolTests {
    @Test func stubImplementingOnlyTheTwoEntryPointsCompilesAndWorks() async throws {
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
    }

    @Test func clientCarriesNoUnstableOnlyMethod() throws {
        // Elicitation in particular: unstable-only in the vendored schema, and
        // must not appear as a method on the stable `Client` surface. Checked
        // against the generated unstable handler names rather than the bare
        // word "elicitation", which the protocol's own documentation
        // legitimately uses to explain the deferral.
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
            #expect(!source.contains(removed), "\(removed) is a v1 method; v2's Client has only two entry points")
        }
    }
}
