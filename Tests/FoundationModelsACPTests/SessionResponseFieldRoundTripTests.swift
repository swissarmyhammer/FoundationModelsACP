import Testing

@testable import FoundationModelsACP

/// The wire shape of the response fields that `schema-v2.0.0-alpha.5` and
/// `schema-v2.0.0-alpha.6` added: the required `PromptResponse.messageId`, and
/// the optional `availableCommands` on the `session/new` and `session/resume`
/// responses.
@Suite struct SessionResponseFieldRoundTripTests {
    // MARK: - `PromptResponse.messageId` is required

    @Test func aPromptResponseCarryingAMessageIdRoundTrips() throws {
        let response = try WireRoundTrip.expectLossless(PromptResponse.self, #"{"messageId":"user-msg-1"}"#)
        #expect(response.messageId == MessageId(rawValue: "user-msg-1"))
    }

    @Test func aPromptResponseWithoutAMessageIdFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(PromptResponse.self, from: "{}")
        }
    }

    @Test func aPromptResponseWithANullMessageIdFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(PromptResponse.self, from: #"{"messageId":null}"#)
        }
    }

    // MARK: - `availableCommands` on the `session/new` and `session/resume` responses

    @Test(arguments: CommandCarrier.allCases)
    func aResponseCarryingAvailableCommandsRoundTrips(_ carrier: CommandCarrier) throws {
        let commands = try carrier.losslessCommands(
            in: carrier.document(availableCommands: #"[{"name":"create_plan","description":"Make a plan"}]"#)
        )
        #expect(commands == [Self.createPlan])
    }

    @Test(arguments: CommandCarrier.allCases)
    func aResponseWithoutAvailableCommandsOmitsTheKey(_ carrier: CommandCarrier) throws {
        #expect(try carrier.encodedWithoutCommands()["availableCommands"] == nil)
    }

    @Test(arguments: CommandCarrier.allCases)
    func aNullAvailableCommandsListMeansOmitted(_ carrier: CommandCarrier) throws {
        #expect(try carrier.decodedCommands(in: carrier.document(availableCommands: "null")) == nil)
    }

    @Test(arguments: CommandCarrier.allCases)
    func anInvalidAvailableCommandIsSkipped(_ carrier: CommandCarrier) throws {
        // `x-deserialize-skip-invalid-items`: the entry with no `description`
        // drops out, and the valid entry stays.
        let document = carrier.document(
            availableCommands: #"[{"name":"broken"},{"name":"create_plan","description":"Make a plan"}]"#
        )
        #expect(try carrier.decodedCommands(in: document) == [Self.createPlan])
    }

    @Test(arguments: CommandCarrier.allCases)
    func aMalformedAvailableCommandsListDegradesToOmitted(_ carrier: CommandCarrier) throws {
        // `x-deserialize-default-on-error`: a list of the wrong type must not
        // fail the whole response. Reaching the assertion at all is half the
        // claim, because `decodedCommands(in:)` throws otherwise.
        #expect(try carrier.decodedCommands(in: carrier.document(availableCommands: #""garbage""#)) == nil)
    }

    // MARK: - Fixtures

    /// The one valid command that each list above carries.
    private static let createPlan = AvailableCommand(description: "Make a plan", name: "create_plan")
}

/// The two responses that carry `availableCommands`, so that one test body
/// covers both of them.
enum CommandCarrier: CaseIterable, Sendable, CustomTestStringConvertible {
    /// `NewSessionResponse`, the `session/new` result.
    case newSession

    /// `ResumeSessionResponse`, the `session/resume` result.
    case resumeSession

    /// The name that a test report shows for each argument.
    var testDescription: String {
        switch self {
        case .newSession: "NewSessionResponse"
        case .resumeSession: "ResumeSessionResponse"
        }
    }

    /// Builds a response document whose `availableCommands` member holds the
    /// given JSON text, beside the members that the response requires.
    ///
    /// - Parameter availableCommands: The JSON text of the member value.
    /// - Returns: The whole response document.
    func document(availableCommands: String) -> String {
        switch self {
        case .newSession: #"{"sessionId":"s-1","availableCommands":\#(availableCommands)}"#
        case .resumeSession: #"{"availableCommands":\#(availableCommands)}"#
        }
    }

    /// Decodes a response document and returns its `availableCommands`.
    ///
    /// - Parameter json: The response document.
    /// - Returns: The decoded `availableCommands`.
    /// - Throws: `DecodingError` when the document does not decode.
    func decodedCommands(in json: String) throws -> [AvailableCommand]? {
        switch self {
        case .newSession: try WireRoundTrip.decode(NewSessionResponse.self, from: json).availableCommands
        case .resumeSession: try WireRoundTrip.decode(ResumeSessionResponse.self, from: json).availableCommands
        }
    }

    /// Decodes a response document, asserts that it encodes back to the same
    /// document, and returns its `availableCommands`.
    ///
    /// - Parameter json: The response document.
    /// - Returns: The decoded `availableCommands`.
    /// - Throws: `DecodingError` or `EncodingError` from either direction.
    func losslessCommands(in json: String) throws -> [AvailableCommand]? {
        switch self {
        case .newSession: try WireRoundTrip.expectLossless(NewSessionResponse.self, json).availableCommands
        case .resumeSession: try WireRoundTrip.expectLossless(ResumeSessionResponse.self, json).availableCommands
        }
    }

    /// Encodes a response that sets no `availableCommands`.
    ///
    /// - Returns: The encoded document, parsed.
    /// - Throws: `EncodingError` when the response does not encode.
    func encodedWithoutCommands() throws -> JSONValue {
        switch self {
        case .newSession: try WireRoundTrip.encode(NewSessionResponse(sessionId: SessionId(rawValue: "s-1")))
        case .resumeSession: try WireRoundTrip.encode(ResumeSessionResponse())
        }
    }
}
