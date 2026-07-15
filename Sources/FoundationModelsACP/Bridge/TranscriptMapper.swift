import Foundation
import FoundationModels

/// Maps a FoundationModels ``Transcript`` into the ACP ``SessionUpdate`` stream
/// (spec §7), the exact inverse of AgentViewKit's client-side mapping.
///
/// A mapper is fed the running turn's transcript entries as they settle and
/// returns the `session/update` payloads each newly appeared entry produces. It
/// is stateful only to skip entries already mapped, so feeding a growing prefix
/// of the same turn stays idempotent past the point already consumed.
///
/// Reasoning is a first-class ``Transcript/Entry/reasoning(_:)`` entry on this
/// toolchain, so ``agent_thought_chunk`` maps straight from it — no synthesis
/// from a structured reasoning segment is needed (resolving the spec §10 open
/// question). Tool calls correlate to their output by identity: the
/// ``Transcript/ToolOutput`` carries the same `id` as the ``Transcript/ToolCall``
/// it answers, so the emitted `tool_call` and `tool_call_update` share a
/// ``ToolCallId``.
struct TranscriptMapper {
    /// The number of leading entries already mapped, so a transcript re-fed to
    /// ``consume(_:)`` yields only the updates for entries not seen before.
    private var consumedCount = 0

    /// Maps every transcript entry not yet seen into its `session/update`
    /// payloads.
    ///
    /// - Parameter entries: The turn's transcript entries so far; grows
    ///   monotonically across calls, and any already-consumed prefix is skipped.
    /// - Returns: The updates for entries beyond the last consumed index, in
    ///   order.
    mutating func consume(_ entries: some Collection<Transcript.Entry>) -> [SessionUpdate] {
        let all = Array(entries)
        guard all.count > consumedCount else { return [] }
        let fresh = all[consumedCount...]
        consumedCount = all.count
        return fresh.flatMap(Self.updates(for:))
    }

    /// Whether an entry's segments carry the agent's message or its reasoning.
    private enum SegmentRole {
        /// Visible response text, mapped to `agent_message_chunk`.
        case message

        /// Internal reasoning, mapped to `agent_thought_chunk`.
        case thought
    }

    /// Maps one settled transcript entry into its `session/update` payloads.
    ///
    /// Instruction and prompt entries are the turn's input, not the agent's
    /// output, so they map to nothing.
    ///
    /// - Parameter entry: The settled transcript entry to map.
    /// - Returns: The entry's updates, in order; empty for input-only entries.
    static func updates(for entry: Transcript.Entry) -> [SessionUpdate] {
        switch entry {
        case .instructions, .prompt:
            return []
        case .response(let response):
            return response.segments.compactMap { update(for: $0, role: .message) }
        case .reasoning(let reasoning):
            return reasoning.segments.compactMap { update(for: $0, role: .thought) }
        case .toolCalls(let calls):
            return calls.map(toolCallStarted(_:))
        case .toolOutput(let output):
            return [toolCallCompleted(output)]
        @unknown default:
            return []
        }
    }

    /// Maps one response or reasoning segment into its update, if any.
    ///
    /// A structured segment in a response that reads as a plan becomes a `plan`
    /// update; every other structured segment is surfaced as its JSON text.
    /// Attachment and custom segments have no ACP chunk form and map to nothing.
    ///
    /// - Parameters:
    ///   - segment: The segment to map.
    ///   - role: Whether the segment belongs to the message or to reasoning.
    /// - Returns: The segment's update, or nil when it has no chunk form.
    private static func update(for segment: Transcript.Segment, role: SegmentRole) -> SessionUpdate? {
        switch segment {
        case .text(let text):
            return chunk(text.content, role: role)
        case .structure(let structure):
            if role == .message, let plan = plan(from: structure) {
                return .plan(plan)
            }
            return chunk(structure.content.jsonString, role: role)
        case .attachment, .custom:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Wraps text as a message or thought chunk per its role.
    ///
    /// - Parameters:
    ///   - text: The chunk's text.
    ///   - role: Whether to emit a message or a thought chunk.
    /// - Returns: The chunk update.
    private static func chunk(_ text: String, role: SegmentRole) -> SessionUpdate {
        let content = ContentChunk(content: .text(TextContent(text: text)))
        switch role {
        case .message:
            return .agentMessageChunk(content)
        case .thought:
            return .agentThoughtChunk(content)
        }
    }

    /// Maps a requested tool call to a pending `tool_call` update.
    ///
    /// - Parameter call: The transcript tool call.
    /// - Returns: The `tool_call` update, keyed by the call's id.
    private static func toolCallStarted(_ call: Transcript.ToolCall) -> SessionUpdate {
        .toolCall(
            ToolCall(
                title: call.toolName,
                toolCallId: ToolCallId(rawValue: call.id),
                rawInput: json(from: call.arguments),
                status: .pending
            )
        )
    }

    /// Maps a tool's output to a completed `tool_call_update`, correlated to its
    /// call by shared id.
    ///
    /// FoundationModels' ``Transcript/ToolOutput`` carries no failure marker, so
    /// a settled output always reports `completed`; a failed tool instead aborts
    /// the turn, which the prompt response reflects through its stop reason.
    ///
    /// - Parameter output: The transcript tool output.
    /// - Returns: The `tool_call_update` update, keyed by the answered call's id.
    private static func toolCallCompleted(_ output: Transcript.ToolOutput) -> SessionUpdate {
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: output.id),
                content: output.segments.compactMap(toolContent(from:)),
                status: .completed
            )
        )
    }

    /// Maps a tool-output segment to a tool-call content block, if it has one.
    ///
    /// - Parameter segment: The output segment to map.
    /// - Returns: The content block, or nil for segments with no text form.
    private static func toolContent(from segment: Transcript.Segment) -> ToolCallContent? {
        switch segment {
        case .text(let text):
            return .content(Content(content: .text(TextContent(text: text.content))))
        case .structure(let structure):
            return .content(Content(content: .text(TextContent(text: structure.content.jsonString))))
        case .attachment, .custom:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Decodes generated content's JSON into a ``JSONValue``, for a tool call's
    /// raw input.
    ///
    /// - Parameter content: The generated content to decode.
    /// - Returns: The decoded value, or nil when the JSON does not parse.
    private static func json(from content: GeneratedContent) -> JSONValue? {
        guard let data = content.jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Reads a structured segment as an ACP ``Plan``, when it names one.
    ///
    /// Plans are not a first-class transcript entry; FoundationModels emits an
    /// agent plan as a structured-generation segment. The bridge recognizes one
    /// by a `plan` schema name or source whose JSON decodes to a non-empty plan.
    ///
    /// - Parameter structure: The structured segment to inspect.
    /// - Returns: The decoded plan, or nil when the segment is not a plan.
    private static func plan(from structure: Transcript.StructuredSegment) -> Plan? {
        let names = "\(structure.schemaName) \(structure.source)".lowercased()
        guard names.contains("plan"),
            let data = structure.content.jsonString.data(using: .utf8),
            let plan = try? JSONDecoder().decode(Plan.self, from: data),
            !plan.entries.isEmpty
        else {
            return nil
        }
        return plan
    }
}
