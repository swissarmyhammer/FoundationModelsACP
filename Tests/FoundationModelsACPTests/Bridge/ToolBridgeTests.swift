import Foundation
import Testing

@testable import FoundationModelsACP

/// Asserts that a ``ClientEnvironment`` turns each tool operation into the right
/// reverse-direction ACP request, and that an un-advertised capability fails
/// locally without reaching the wire (spec §7).
@Suite("Tool bridge → reverse ACP requests")
struct ToolBridgeTests {
    /// A canonical absolute path used across the tool-bridge tests.
    private let path = AbsolutePath(rawValue: "/workspace/file.txt")!

    @Test("Reading a file issues fs/read_text_file and returns the client's content")
    func readsFileThroughClient() async throws {
        let client = RecordingEnvironmentClient(configuration: .init(fileContent: "hello from client"))
        let wired = await makeWiredEnvironment(capabilities: .readOnly, client: client)

        let content = try await wired.environment.readTextFile(path: path)

        #expect(content == "hello from client")
        #expect(client.recordedCalls == ["readTextFile"])
        #expect(client.lastRead?.path == path)
        #expect(client.lastRead?.sessionId == testSessionId)
    }

    @Test("Writing a file issues fs/write_text_file with the content")
    func writesFileThroughClient() async throws {
        let client = RecordingEnvironmentClient()
        let wired = await makeWiredEnvironment(capabilities: .writeOnly, client: client)

        try await wired.environment.writeTextFile(path: path, content: "written")

        #expect(client.recordedCalls == ["writeTextFile"])
        #expect(client.lastWrite?.content == "written")
        #expect(client.lastWrite?.path == path)
        #expect(client.lastWrite?.sessionId == testSessionId)
    }

    @Test("Running a command creates, embeds, waits, and releases a terminal in order")
    func runCommandTerminalSequence() async throws {
        let terminalId = TerminalId(rawValue: "term-42")
        let client = RecordingEnvironmentClient(
            configuration: .init(
                terminalId: terminalId,
                terminalOutput: "build ok",
                truncated: true,
                exitCode: 0
            )
        )
        let wired = await makeWiredEnvironment(capabilities: .terminalOnly, client: client)
        let toolCallId = ToolCallId(rawValue: "call-1")

        let result = try await wired.environment.runCommand(
            toolCallId: toolCallId,
            command: "swift",
            arguments: ["build"],
            outputByteLimit: 4096
        )

        #expect(
            client.recordedCalls == [
                "createTerminal", "sessionUpdate", "waitForTerminalExit", "terminalOutput", "releaseTerminal",
            ]
        )
        #expect(result.terminalId == terminalId)
        #expect(result.output == "build ok")
        #expect(result.truncated)
        #expect(result.exitStatus.exitCode == 0)
        #expect(client.lastCreate?.command == "swift")
        #expect(client.lastCreate?.args == ["build"])
        #expect(client.lastCreate?.outputByteLimit == 4096)
        #expect(client.lastCreate?.sessionId == testSessionId)

        let embedded = try #require(client.recordedUpdates.first)
        guard case .toolCallUpdate(let update) = embedded else {
            Issue.record("expected a tool_call_update embedding the terminal, got \(embedded)")
            return
        }
        #expect(update.toolCallId == toolCallId)
        #expect(update.content == [.terminal(Terminal(terminalId: terminalId))])
    }

    @Test("An un-advertised filesystem read fails locally with no wire traffic")
    func unadvertisedReadFailsLocally() async throws {
        let client = RecordingEnvironmentClient()
        let wired = await makeWiredEnvironment(capabilities: ClientCapabilities(), client: client)

        await #expect(throws: ClientEnvironmentError.capabilityUnavailable(.readTextFile)) {
            _ = try await wired.environment.readTextFile(path: path)
        }
        #expect(client.recordedCalls.isEmpty)
    }

    @Test("An un-advertised filesystem write fails locally with no wire traffic")
    func unadvertisedWriteFailsLocally() async throws {
        let client = RecordingEnvironmentClient()
        let wired = await makeWiredEnvironment(capabilities: ClientCapabilities(), client: client)

        await #expect(throws: ClientEnvironmentError.capabilityUnavailable(.writeTextFile)) {
            try await wired.environment.writeTextFile(path: path, content: "denied")
        }
        #expect(client.recordedCalls.isEmpty)
    }

    @Test("An un-advertised terminal command fails locally with no wire traffic")
    func unadvertisedTerminalFailsLocally() async throws {
        let client = RecordingEnvironmentClient()
        let wired = await makeWiredEnvironment(capabilities: ClientCapabilities(), client: client)

        await #expect(throws: ClientEnvironmentError.capabilityUnavailable(.terminal)) {
            _ = try await wired.environment.runCommand(toolCallId: ToolCallId(rawValue: "call-1"), command: "ls")
        }
        #expect(client.recordedCalls.isEmpty)
    }
}
