import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Back-to-back wiring

/// A real ``Client`` and a scripted wire ``Agent`` wired back-to-back over an
/// in-memory transport, plus the connections keeping the pair alive.
///
/// The client drives the agent through ``ClientSideConnection``'s outbound
/// methods exactly as a host would, while the agent's reverse Agent→Client
/// calls land on the served client — the full bidirectional surface over one
/// pipe (spec §8).
struct EndToEndPair {
    /// The client connection a test drives the agent through.
    let client: ClientSideConnection

    /// The agent connection serving the agent; kept alive by the caller.
    let agentConnection: AgentSideConnection

    /// The concrete scripted agent, so a test can enqueue scripted turns on it.
    let agent: ScriptedAgent
}

/// Wires a scripted agent and a given client back-to-back over an in-memory
/// transport.
///
/// - Parameters:
///   - sessionId: The identity the agent's `session/new` returns.
///   - client: Builds the served client from its connection.
/// - Returns: The wired client, agent connection, and concrete agent.
func makeEndToEndPair(
    sessionId: SessionId,
    client: @escaping @Sendable (ClientSideConnection) -> any Client
) async -> EndToEndPair {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let box = Mutex<ScriptedAgent?>(nil)
    let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
        let agent = ScriptedAgent(connection: connection, sessionId: sessionId)
        box.withLock { $0 = agent }
        return agent
    }
    let clientConnection = await ClientSideConnection(stream: clientEnd, client)
    return EndToEndPair(
        client: clientConnection,
        agentConnection: agentConnection,
        agent: box.withLock { $0! }
    )
}

// MARK: - Canonical requests and fixtures

/// A canonical initialize request advertising a set of client capabilities.
///
/// - Parameter capabilities: The client capabilities to advertise; read-only
///   filesystem access by default, so a bridged tool may read files.
/// - Returns: An initialize request at the latest protocol version.
func endToEndInitializeRequest(
    capabilities: ClientCapabilities = .readOnly
) -> InitializeRequest {
    InitializeRequest(protocolVersion: .latest, clientCapabilities: capabilities)
}

/// A canonical prompt request carrying one text block.
///
/// - Parameters:
///   - text: The user message text.
///   - sessionId: The session to prompt.
/// - Returns: A single-text-block prompt request.
func endToEndPromptRequest(text: String, sessionId: SessionId) -> PromptRequest {
    PromptRequest(prompt: [.text(TextContent(text: text))], sessionId: sessionId)
}

/// A single allow-once permission option a scripted tool offers.
///
/// - Parameter optionId: The option's id, matched against the grant outcome.
/// - Returns: An allow-once permission option.
func allowOnceOption(optionId: String) -> PermissionOption {
    PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: optionId))
}

// MARK: - Golden fixtures

/// The `Fixtures/` directory beside the end-to-end test files.
let endToEndFixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// Whether the current run should (re)record golden fixtures rather than assert
/// against them, driven by the `RECORD_GOLDEN` environment variable.
var isRecordingGoldenFixtures: Bool {
    ProcessInfo.processInfo.environment["RECORD_GOLDEN"] != nil
}

/// Asserts captured bytes match a committed golden fixture, recording the
/// fixture when it is absent or when recording is requested.
///
/// A missing fixture (or `RECORD_GOLDEN` set) is written and the check passes —
/// the "capture once" step. A present fixture is compared byte-for-byte, and a
/// drift is reported with the first differing line before the check fails, so a
/// regression reads clearly (spec §8).
///
/// - Parameters:
///   - actual: The captured agent→client byte stream.
///   - name: The golden fixture's file name inside `Fixtures/`.
///   - sourceLocation: The caller location, for failure reporting.
/// - Throws: An error if the fixture cannot be read or written.
func expectGolden(
    _ actual: Data,
    matchesFixture name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let url = endToEndFixturesDirectory.appendingPathComponent(name)
    guard !isRecordingGoldenFixtures, FileManager.default.fileExists(atPath: url.path) else {
        try actual.write(to: url)
        return
    }
    let expected = try Data(contentsOf: url)
    if actual != expected {
        reportGoldenDrift(actual: actual, expected: expected, name: name, sourceLocation: sourceLocation)
    }
    #expect(actual == expected, "golden fixture \(name) drifted", sourceLocation: sourceLocation)
}

/// Reports the first line where captured output diverges from a golden fixture.
///
/// - Parameters:
///   - actual: The captured bytes.
///   - expected: The committed golden bytes.
///   - name: The fixture name, for the message.
///   - sourceLocation: The caller location, for failure reporting.
private func reportGoldenDrift(
    actual: Data,
    expected: Data,
    name: String,
    sourceLocation: SourceLocation
) {
    let actualLines = textLines(actual)
    let expectedLines = textLines(expected)
    for index in 0..<max(actualLines.count, expectedLines.count) {
        let actualLine = index < actualLines.count ? actualLines[index] : "<missing>"
        let expectedLine = index < expectedLines.count ? expectedLines[index] : "<missing>"
        if actualLine != expectedLine {
            Issue.record(
                """
                golden fixture \(name) drifted at line \(index + 1):
                expected: \(expectedLine)
                actual:   \(actualLine)
                """,
                sourceLocation: sourceLocation
            )
            return
        }
    }
}

/// Splits raw ndJSON bytes into their text lines, without the newlines.
///
/// - Parameter data: The raw ndJSON bytes.
/// - Returns: The lines as strings, in order.
private func textLines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

// MARK: - Raw-wire golden driver

/// Drives an agent over a raw in-memory wire, sending recorded client→agent
/// requests and capturing the agent→client byte stream for golden comparison
/// (spec §8).
///
/// Requests are sent and their responses awaited one at a time, so the agent's
/// emitted frames land in a deterministic order. The driver end is never
/// closed while a turn runs, so the agent's read loop never shuts down
/// mid-turn — the "capture once, replay forever" recording is deterministic.
final class GoldenWireDriver {
    /// The driver's end of the in-memory pipe to the agent.
    private let transport: InMemoryTransport

    /// The incremental collector over the agent's emitted frames.
    private let collector: AgentFrameCollector

    /// The exact client→agent bytes sent so far, in order.
    private(set) var scriptBytes = Data()

    /// Creates a driver over one end of an in-memory pair.
    ///
    /// - Parameter transport: The driver's end; its peer serves the agent.
    init(_ transport: InMemoryTransport) {
        self.transport = transport
        self.collector = AgentFrameCollector(transport)
    }

    /// The agent→client bytes captured so far, in order.
    var agentBytes: Data {
        collector.capturedBytes
    }

    /// Sends one framed message to the agent, recording its bytes.
    ///
    /// - Parameter message: The JSON-RPC envelope to frame and send.
    /// - Throws: Rethrows any encoding or transport-write failure.
    func send(_ message: JSONValue) async throws {
        let framed = try NDJSONCodec.encode(message)
        scriptBytes.append(framed)
        try await transport.write(framed)
    }

    /// Sends a raw line to the agent verbatim, for adversarial input such as a
    /// garbage line the codec must skip.
    ///
    /// - Parameter line: The line text, sent with a single trailing newline.
    /// - Throws: Rethrows any transport-write failure.
    func sendRaw(_ line: String) async throws {
        let framed = Data((line + "\n").utf8)
        scriptBytes.append(framed)
        try await transport.write(framed)
    }

    /// Collects every frame through the response echoing `id`, inclusive.
    ///
    /// - Parameter id: The request id whose response terminates the collection.
    /// - Returns: The frames up to and including the matching response.
    /// - Throws: Rethrows any stream failure.
    func collectThroughResponse(id: String) async throws -> [JSONValue] {
        try await collector.framesThroughResponse(id: .string(id))
    }

    /// Collects frames until a response has arrived for each named id.
    ///
    /// - Parameter ids: The request ids whose responses to await, in any order.
    /// - Returns: The response frame for each id, keyed by its id string.
    /// - Throws: Rethrows any stream failure.
    func collectResponses(ids: Set<String>) async throws -> [String: JSONValue] {
        try await collector.responses(forIds: ids)
    }

    /// Sends a request and collects every frame through its response.
    ///
    /// - Parameters:
    ///   - id: The request's string wire id, echoed on its response.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters, encoded verbatim.
    /// - Returns: The frames emitted up to and including the matching response,
    ///   in order — any notifications the turn fired come first.
    /// - Throws: Rethrows any encoding, transport, or stream failure.
    @discardableResult
    func request(id: String, method: String, params: some Encodable) async throws -> [JSONValue] {
        try await send(requestEnvelope(id: id, method: method, params: params))
        return try await collector.framesThroughResponse(id: .string(id))
    }

    /// Reads the next single frame the agent emitted.
    ///
    /// - Returns: The next frame, or `nil` at end of stream.
    /// - Throws: Rethrows any stream failure.
    func nextFrame() async throws -> JSONValue? {
        try await collector.nextFrame()
    }
}

/// Builds a JSON-RPC request envelope with a string id and encoded params.
///
/// - Parameters:
///   - id: The request's string wire id.
///   - method: The JSON-RPC method name.
///   - params: The request parameters to encode.
/// - Returns: The request envelope as a structural value.
/// - Throws: Rethrows any encoding failure.
func requestEnvelope(id: String, method: String, params: some Encodable) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": .string(id),
        "method": .string(method),
        "params": try encodedValue(params),
    ])
}

/// Builds a JSON-RPC notification envelope with encoded params.
///
/// - Parameters:
///   - method: The JSON-RPC method name.
///   - params: The notification parameters to encode.
/// - Returns: The notification envelope as a structural value.
/// - Throws: Rethrows any encoding failure.
func notificationEnvelope(method: String, params: some Encodable) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": try encodedValue(params),
    ])
}

/// Incrementally decodes an agent's emitted byte stream into frames while
/// retaining the exact bytes, so a test can both assert frame structure and
/// compare the raw stream to a golden fixture.
final class AgentFrameCollector {
    /// The iterator over the agent's outgoing byte chunks.
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    /// The incremental line framer over the byte stream.
    private var framer = NDJSONFramer()

    /// Decoded frames not yet handed to a caller, in order.
    private var buffered: [JSONValue] = []

    /// The raw bytes consumed so far, in order.
    private(set) var capturedBytes = Data()

    /// Creates a collector over a transport's incoming bytes.
    ///
    /// - Parameter transport: The end whose peer is the agent under test.
    init(_ transport: some ACPTransport) {
        iterator = transport.bytes.makeAsyncIterator()
    }

    /// Returns the next decoded frame, reading more bytes as needed.
    ///
    /// - Returns: The next frame, or `nil` once the stream finishes.
    /// - Throws: Rethrows any stream failure.
    func nextFrame() async throws -> JSONValue? {
        while buffered.isEmpty {
            guard let chunk = try await iterator.next() else {
                return nil
            }
            capturedBytes.append(chunk)
            for line in framer.append(chunk) {
                if let frame = NDJSONCodec.decode(line: line, logger: .disabled) {
                    buffered.append(frame)
                }
            }
        }
        return buffered.removeFirst()
    }

    /// Collects frames until the response echoing `id` arrives, inclusive.
    ///
    /// - Parameter id: The request id whose response terminates the collection.
    /// - Returns: The frames up to and including the matching response.
    /// - Throws: Rethrows any stream failure.
    func framesThroughResponse(id: JSONValue) async throws -> [JSONValue] {
        var collected: [JSONValue] = []
        while let frame = try await nextFrame() {
            collected.append(frame)
            if isResponse(frame, forId: id) {
                return collected
            }
        }
        return collected
    }

    /// Collects frames until a response has arrived for every named id.
    ///
    /// - Parameter ids: The request ids to await responses for, in any order.
    /// - Returns: The response frame for each id, keyed by its id string.
    /// - Throws: Rethrows any stream failure.
    func responses(forIds ids: Set<String>) async throws -> [String: JSONValue] {
        var found: [String: JSONValue] = [:]
        while found.count < ids.count, let frame = try await nextFrame() {
            for id in ids where isResponse(frame, forId: .string(id)) {
                found[id] = frame
            }
        }
        return found
    }
}

/// Reports whether a frame is the JSON-RPC response for a given request id.
///
/// - Parameters:
///   - frame: The frame to inspect.
///   - id: The request id to match.
/// - Returns: `true` when the frame carries `id` and a `result` or `error`.
func isResponse(_ frame: JSONValue, forId id: JSONValue) -> Bool {
    guard case .object(let fields) = frame, fields["id"] == id else {
        return false
    }
    return fields["result"] != nil || fields["error"] != nil
}

/// Extracts the wire method of a notification or request frame.
///
/// - Parameter frame: The frame to inspect.
/// - Returns: The `method` value's string, or `nil` when absent.
func method(of frame: JSONValue) -> String? {
    guard case .object(let fields) = frame, case .string(let method) = fields["method", default: .null] else {
        return nil
    }
    return method
}

/// Extracts the `result` payload of a JSON-RPC response frame.
///
/// - Parameter frame: The response frame to inspect.
/// - Returns: The `result` value, or `nil` when the frame carries none.
func result(of frame: JSONValue) -> JSONValue? {
    guard case .object(let fields) = frame else {
        return nil
    }
    return fields["result"]
}

/// Wires a scripted agent behind a raw-wire golden driver, enqueuing the
/// session's scripted turn in the connection factory so it is present before
/// the read loop can dispatch a prompt.
///
/// - Parameters:
///   - sessionId: The session the scripted turn belongs to.
///   - scriptedTurn: The scripted turn `prompt` runs.
/// - Returns: The driver over the client end and the agent connection, which
///   the caller keeps alive and may use to emit late updates.
func makeGoldenDriver(
    sessionId: SessionId,
    scriptedTurn: @escaping ScriptedTurn
) async -> (driver: GoldenWireDriver, connection: AgentSideConnection) {
    let (driverEnd, agentEnd) = InMemoryTransport.pair()
    let connection = await AgentSideConnection(stream: agentEnd) { connection in
        let agent = ScriptedAgent(connection: connection, sessionId: sessionId)
        agent.enqueueTurn(scriptedTurn)
        return agent
    }
    return (GoldenWireDriver(driverEnd), connection)
}
