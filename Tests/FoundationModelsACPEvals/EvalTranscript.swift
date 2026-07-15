import Foundation

@testable import FoundationModelsACP

/// The tool a correct model is expected to select for an eval case, drawn from
/// the tool call recorded in a seed transcript.
///
/// The expectation is ground truth: the eval scores a live turn against it, so
/// it captures only what a well-formed selection must satisfy — the tool's name
/// and the argument keys its input must carry.
struct ToolExpectation: Sendable, Hashable {
    /// The tool name a correct turn must call, matched against a `tool_call`
    /// update's title.
    let toolName: String

    /// The argument keys the call's `rawInput` object must carry, sorted.
    let argumentKeys: [String]
}

/// One behavioral eval case: a prompt to drive through the live model and the
/// tool selection a correct turn should produce (spec §8).
///
/// A case is loaded from a captured golden transcript pair — the client→agent
/// script supplies the prompt, and the agent→client stream supplies the
/// expected tool selection — so a single transcript is both a deterministic
/// wire fixture and an eval case.
struct EvalCase: Sendable {
    /// The case's stable name, taken from its fixture file stem.
    let name: String

    /// The prompt content blocks sent to the model, from the seed's
    /// `session/prompt` request.
    let prompt: [ContentBlock]

    /// The tool selection a correct turn should produce, or `nil` when the seed
    /// records no tool call (a plain-response turn).
    let expectation: ToolExpectation?
}

extension EvalCase {
    /// Loads an eval case from a captured golden transcript pair.
    ///
    /// The script's `session/prompt` request supplies the prompt; the first
    /// `tool_call` update in the agent stream supplies the expected tool name
    /// and argument keys. A stream with no tool call yields a `nil`
    /// expectation.
    ///
    /// - Parameters:
    ///   - name: The case's stable name.
    ///   - scriptURL: The client→agent script fixture (ndJSON).
    ///   - agentURL: The agent→client stream fixture (ndJSON).
    /// - Returns: The loaded eval case.
    /// - Throws: ``EvalTranscriptError`` when either fixture is unreadable or
    ///   the script carries no decodable `session/prompt` request.
    static func load(named name: String, scriptURL: URL, agentURL: URL) throws -> EvalCase {
        let scriptFrames = try decodeNDJSON(at: scriptURL)
        let agentFrames = try decodeNDJSON(at: agentURL)
        let prompt = try promptBlocks(from: scriptFrames)
        return EvalCase(name: name, prompt: prompt, expectation: toolExpectation(from: agentFrames))
    }

    /// Extracts the prompt blocks from a script's `session/prompt` request.
    ///
    /// - Parameter frames: The decoded client→agent frames.
    /// - Returns: The prompt content blocks.
    /// - Throws: ``EvalTranscriptError/missingPromptRequest`` when no decodable
    ///   `session/prompt` request is present.
    private static func promptBlocks(from frames: [JSONValue]) throws -> [ContentBlock] {
        guard
            let request = frames.first(where: { $0["method"]?.evalString == "session/prompt" }),
            let params = request["params"],
            let decoded = try? JSONValue.decodeParams(PromptRequest.self, from: params)
        else {
            throw EvalTranscriptError.missingPromptRequest
        }
        return decoded.prompt
    }

    /// Extracts the first `tool_call` update's expectation from an agent stream.
    ///
    /// - Parameter frames: The decoded agent→client frames.
    /// - Returns: The tool expectation, or `nil` when no `tool_call` update is
    ///   present.
    private static func toolExpectation(from frames: [JSONValue]) -> ToolExpectation? {
        for frame in frames where frame["method"]?.evalString == "session/update" {
            guard
                let update = frame["params"]?["update"],
                update["sessionUpdate"]?.evalString == "tool_call",
                let toolName = update["title"]?.evalString
            else {
                continue
            }
            let keys = update["rawInput"]?.evalObject?.keys.sorted() ?? []
            return ToolExpectation(toolName: toolName, argumentKeys: keys)
        }
        return nil
    }
}

/// A failure loading an eval case from a transcript pair.
enum EvalTranscriptError: Error, Hashable {
    /// The script carried no decodable `session/prompt` request.
    case missingPromptRequest
}

/// Decodes an ndJSON file into its per-line JSON values, skipping blank lines
/// and any line the codec cannot parse.
///
/// - Parameter url: The ndJSON fixture to read.
/// - Returns: The decoded frames, in file order.
/// - Throws: Any error reading the file.
func decodeNDJSON(at url: URL) throws -> [JSONValue] {
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { NDJSONCodec.decode(line: Data($0.utf8), logger: .disabled) }
}

// MARK: - JSON navigation

extension JSONValue {
    /// This value's object fields, or `nil` when it is not an object.
    var evalObject: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    /// This value's string payload, or `nil` when it is not a string.
    var evalString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Reads a child field by key, treating a non-object as having no fields.
    ///
    /// - Parameter key: The object key to read.
    /// - Returns: The child value, or `nil` when absent or not an object.
    subscript(key: String) -> JSONValue? {
        evalObject?[key]
    }
}
