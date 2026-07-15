import Foundation
import FoundationModels

/// Folds an ACP ``SessionUpdate`` stream into a growing FoundationModels
/// ``Transcript`` (spec §9, §10), the client-side inverse of ``TranscriptMapper``.
///
/// Where ``TranscriptMapper`` projects a transcript into the `session/update`
/// stream an agent emits, this builder replays that stream back into a
/// transcript, so an ACP client becomes just another producer of the same
/// ``Transcript`` AgentViewKit renders. Feeding it every update of a turn
/// reconstructs, in order, the transcript entries the turn was mapped from.
///
/// The builder is stateful across ``fold(_:)`` calls: consecutive message or
/// reasoning chunks accumulate into one ``Transcript/Response`` or
/// ``Transcript/Reasoning`` entry, and each tool call's name is remembered by
/// its ``ToolCallId`` so the matching `tool_call_update` recovers the
/// ``Transcript/ToolOutput`` tool name the update itself does not carry.
///
/// Only the updates ``TranscriptMapper`` produces have a transcript form:
/// `agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
/// `tool_call_update`, and `plan`. Other updates (user-message chunks, mode,
/// usage, and the rest) are session-level signals with no agent-output entry
/// and are skipped. The stream carries only what the projection preserved, so
/// fields it drops — a response's asset ids, a reasoning entry's signature and
/// metadata, and non-text content blocks — are reconstructed empty; on turns
/// produced by ``TranscriptMapper`` those fields are already empty, so the
/// round trip is lossless.
public struct TranscriptBuilder {
    /// Whether an accumulating segment group carries the agent's message or its
    /// reasoning, so consecutive chunks of one kind fold into one entry.
    private enum ChunkRole {
        /// Visible response text, accumulated into a ``Transcript/Response``.
        case message

        /// Internal reasoning, accumulated into a ``Transcript/Reasoning``.
        case thought
    }

    /// An entry still accumulating consecutive chunks of one role, not yet
    /// appended to ``entries``.
    private struct SegmentGroup {
        /// Whether these segments form a response or a reasoning entry.
        let role: ChunkRole

        /// The segments gathered so far, in arrival order.
        var segments: [Transcript.Segment]

        /// The finalized transcript entry these segments form.
        var entry: Transcript.Entry {
            switch role {
            case .message:
                return .response(Transcript.Response(assetIDs: [], segments: segments))
            case .thought:
                return .reasoning(Transcript.Reasoning(segments: segments))
            }
        }
    }

    /// The schema name a plan's structured segment carries, which
    /// ``TranscriptMapper`` recognizes to re-derive a `plan` update.
    private static let planSchemaName = "plan"

    /// A well-formed empty JSON object, the fallback tool-call input when an
    /// update carries none.
    private static let emptyJSONObject = "{}"

    /// The entries completed so far, in order.
    private var entries: [Transcript.Entry] = []

    /// The entry still accumulating consecutive same-role chunks, if any.
    private var openGroup: SegmentGroup?

    /// Tool names seen on `tool_call` updates, keyed by tool-call id, so a
    /// later `tool_call_update` recovers the name its own payload omits.
    private var toolNamesByCallId: [String: String] = [:]

    /// Creates an empty builder.
    public init() {}

    /// The transcript folded from every update seen so far, including any entry
    /// still accumulating chunks.
    public var transcript: Transcript {
        var all = entries
        if let openGroup {
            all.append(openGroup.entry)
        }
        return Transcript(entries: all)
    }

    /// Folds one update into the growing transcript.
    ///
    /// Message and thought chunks extend the current entry of their role;
    /// every other mapped update finalizes that entry and appends its own. An
    /// update with no transcript form is skipped.
    ///
    /// - Parameter update: The `session/update` payload to fold in.
    public mutating func fold(_ update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(let chunk):
            appendText(from: chunk, role: .message)
        case .agentThoughtChunk(let chunk):
            appendText(from: chunk, role: .thought)
        case .toolCall(let call):
            flushOpenGroup()
            toolNamesByCallId[call.toolCallId.rawValue] = call.title
            entries.append(Self.toolCallsEntry(from: call))
        case .toolCallUpdate(let update):
            flushOpenGroup()
            entries.append(toolOutputEntry(from: update))
        case .plan(let plan):
            flushOpenGroup()
            if let entry = Self.planEntry(from: plan) {
                entries.append(entry)
            }
        case .userMessageChunk, .availableCommandsUpdate, .currentModeUpdate,
            .configOptionUpdate, .sessionInfoUpdate, .usageUpdate, .unknown:
            break
        }
    }

    /// Folds a whole `session/update` stream into one transcript.
    ///
    /// - Parameter updates: The session's update stream, drained to completion.
    /// - Returns: The transcript folded from every update the stream delivered.
    public static func transcript(
        folding updates: AsyncStream<SessionUpdate>
    ) async -> Transcript {
        var builder = TranscriptBuilder()
        for await update in updates {
            builder.fold(update)
        }
        return builder.transcript
    }

    /// Extends the current group of `role` with a chunk's text, starting a new
    /// group when the role changes or a text-free chunk arrives.
    ///
    /// - Parameters:
    ///   - chunk: The content chunk whose text to append.
    ///   - role: Whether the chunk carries the message or reasoning.
    private mutating func appendText(from chunk: ContentChunk, role: ChunkRole) {
        guard let text = Self.text(from: chunk) else {
            return
        }
        if openGroup?.role != role {
            flushOpenGroup()
            openGroup = SegmentGroup(role: role, segments: [])
        }
        openGroup?.segments.append(.text(Transcript.TextSegment(content: text)))
    }

    /// Appends the accumulating group as a finished entry, if one is open.
    private mutating func flushOpenGroup() {
        if let openGroup {
            entries.append(openGroup.entry)
            self.openGroup = nil
        }
    }

    /// Builds a tool output entry from a tool-call update, recovering the tool
    /// name from the correlated `tool_call` seen earlier.
    ///
    /// - Parameter update: The tool-call update to fold in.
    /// - Returns: A ``Transcript/ToolOutput`` entry keyed by the update's id.
    private func toolOutputEntry(from update: ToolCallUpdate) -> Transcript.Entry {
        let id = update.toolCallId.rawValue
        let toolName = toolNamesByCallId[id] ?? ""
        let segments = (update.content ?? []).compactMap(Self.segment(from:))
        return .toolOutput(Transcript.ToolOutput(id: id, toolName: toolName, segments: segments))
    }

    /// Reads a chunk's text, when it carries a text content block.
    ///
    /// - Parameter chunk: The content chunk to read.
    /// - Returns: The chunk's text, or nil for a non-text content block.
    private static func text(from chunk: ContentChunk) -> String? {
        guard case .text(let content) = chunk.content else {
            return nil
        }
        return content.text
    }

    /// Builds a single-call tool-calls entry from a `tool_call` update.
    ///
    /// - Parameter call: The tool call to fold in.
    /// - Returns: A ``Transcript/ToolCalls`` entry carrying the one call.
    private static func toolCallsEntry(from call: ToolCall) -> Transcript.Entry {
        let toolCall = Transcript.ToolCall(
            id: call.toolCallId.rawValue,
            toolName: call.title,
            arguments: arguments(from: call.rawInput)
        )
        return .toolCalls(Transcript.ToolCalls([toolCall]))
    }

    /// Builds a response entry carrying a plan as a structured segment, the
    /// inverse of ``TranscriptMapper`` recognizing a plan from a structured
    /// segment.
    ///
    /// - Parameter plan: The plan to fold in.
    /// - Returns: A response entry whose structured segment re-derives the
    ///   plan, or nil when the plan cannot be serialized.
    private static func planEntry(from plan: Plan) -> Transcript.Entry? {
        guard let json = jsonString(from: plan),
            let content = try? GeneratedContent(json: json)
        else {
            return nil
        }
        let segment = Transcript.StructuredSegment(schemaName: planSchemaName, content: content)
        return .response(Transcript.Response(assetIDs: [], segments: [.structure(segment)]))
    }

    /// Maps a tool-call content block to a tool-output segment, if it is text.
    ///
    /// - Parameter content: The tool-call content to map.
    /// - Returns: A text segment, or nil for diff, terminal, and non-text
    ///   content, which have no transcript segment form.
    private static func segment(from content: ToolCallContent) -> Transcript.Segment? {
        guard case .content(let wrapper) = content,
            case .text(let text) = wrapper.content
        else {
            return nil
        }
        return .text(Transcript.TextSegment(content: text.text))
    }

    /// Builds generated content for a tool call's arguments from its raw input.
    ///
    /// - Parameter rawInput: The tool call's raw input, or nil when it carried
    ///   none.
    /// - Returns: Generated content parsed from the input's JSON, or from the
    ///   empty object when the input is absent.
    private static func arguments(from rawInput: JSONValue?) -> GeneratedContent {
        let json = rawInput.flatMap(jsonString(from:)) ?? emptyJSONObject
        do {
            return try GeneratedContent(json: json)
        } catch {
            // Unreachable: `json` is either re-encoded from a `JSONValue` or the
            // constant empty object, both well-formed; the empty object parses.
            return try! GeneratedContent(json: emptyJSONObject)
        }
    }

    /// Encodes a value to a JSON string.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The value's JSON text, or nil when encoding fails.
    private static func jsonString(from value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
