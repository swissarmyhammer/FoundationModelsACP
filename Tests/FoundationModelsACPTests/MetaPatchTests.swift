import Foundation
import Testing

@testable import FoundationModelsACP

/// Since `schema-v2.0.0-alpha.9` a concrete `_meta` object in an upsert
/// patches the stored `_meta` by top-level key: an omitted key is unchanged, a
/// key set to `null` is removed, and any other value replaces that key without
/// merging nested objects. `null` clears all, and omitted leaves it. The
/// `_meta` of a chunk is scoped to the chunk and never patches the stored one.
@Suite struct MetaPatchTests {
    private static func meta(_ json: String) throws -> JSONValue {
        try WireRoundTrip.parse(json)
    }

    // MARK: - PatchField fold

    @Test func anOmittedMetaLeavesTheStoredMeta() throws {
        let stored = PatchField<JSONValue>.value(try Self.meta(#"{"a":1}"#))
        #expect(PatchField<JSONValue>.unchanged.foldedAsMeta(onto: stored) == stored)
    }

    @Test func aNullMetaClearsTheStoredMeta() throws {
        let stored = PatchField<JSONValue>.value(try Self.meta(#"{"a":1}"#))
        #expect(PatchField<JSONValue>.cleared.foldedAsMeta(onto: stored) == .cleared)
    }

    @Test func anObjectPatchesByTopLevelKey() throws {
        let stored = PatchField<JSONValue>.value(try Self.meta(#"{"keep":1,"change":{"x":1,"y":2},"drop":true}"#))
        let patch = PatchField<JSONValue>.value(try Self.meta(#"{"change":{"x":9},"drop":null,"new":"n"}"#))
        // `change` is replaced whole, with no deep merge; `drop` is removed.
        #expect(patch.foldedAsMeta(onto: stored) == .value(try Self.meta(#"{"keep":1,"change":{"x":9},"new":"n"}"#)))
    }

    @Test func anObjectOnNoStoredMetaStartsFromEmptyAndDropsNullKeys() throws {
        let patch = PatchField<JSONValue>.value(try Self.meta(#"{"a":1,"gone":null}"#))
        #expect(patch.foldedAsMeta(onto: .unchanged) == .value(try Self.meta(#"{"a":1}"#)))
        #expect(patch.foldedAsMeta(onto: .cleared) == .value(try Self.meta(#"{"a":1}"#)))
    }

    @Test func aPatchThatRemovesEveryKeyLeavesAnEmptyObject() throws {
        let stored = PatchField<JSONValue>.value(try Self.meta(#"{"a":1}"#))
        let patch = PatchField<JSONValue>.value(try Self.meta(#"{"a":null}"#))
        #expect(patch.foldedAsMeta(onto: stored) == .value(.object([:])))
    }

    // MARK: - Generated folds and the engine

    @Test func aGeneratedFoldPatchesMetaByKey() throws {
        let first = UserMessage(messageId: MessageId(rawValue: "m"), meta: .value(try Self.meta(#"{"a":1,"b":2}"#)))
        let second = UserMessage(messageId: MessageId(rawValue: "m"), meta: .value(try Self.meta(#"{"b":null,"c":3}"#)))
        #expect(second.folded(onto: first).meta == .value(try Self.meta(#"{"a":1,"c":3}"#)))
    }

    @Test func theEnginePatchesTheMetaOfEachUpsertKind() throws {
        let id = MessageId(rawValue: "m")
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: id, meta: .value(try Self.meta(#"{"a":1,"b":2}"#)))))
        engine.apply(.userMessage(UserMessage(messageId: id, meta: .value(try Self.meta(#"{"b":null,"c":3}"#)))))
        let message = try #require(engine.entry(withID: .userMessage(id))?.kind.message)
        #expect(message.meta == .value(try Self.meta(#"{"a":1,"c":3}"#)))
    }

    @Test func theEnginePatchesTheMetaOfAChildSessionAndAMessage() throws {
        let child = SessionId(rawValue: "child")
        var engine = SessionMergeEngine()
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: child, meta: .value(try Self.meta(#"{"a":1}"#)))))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: child, meta: .value(try Self.meta(#"{"b":2}"#)))))
        #expect(engine.subagents[0].meta == .value(try Self.meta(#"{"a":1,"b":2}"#)))

        let id = MessageId(rawValue: "sm")
        engine.apply(.sessionMessage(SessionMessage(messageId: id, meta: .value(try Self.meta(#"{"a":1}"#)))))
        engine.apply(.sessionMessage(SessionMessage(messageId: id, meta: .value(try Self.meta(#"{"a":null,"b":2}"#)))))
        #expect(engine.entry(withID: .sessionMessage(id))?.kind.sessionMessage?.meta == .value(try Self.meta(#"{"b":2}"#)))
    }

    @Test func aChunkMetaNeverPatchesTheStoredMeta() throws {
        let id = MessageId(rawValue: "m")
        var engine = SessionMergeEngine()
        engine.apply(.agentMessage(AgentMessage(messageId: id, meta: .value(try Self.meta(#"{"a":1}"#)))))
        engine.apply(.agentMessageChunk(ContentChunk(
            content: .text(TextContent(text: "x")), messageId: id, meta: try Self.meta(#"{"chunk":true}"#))))
        let message = try #require(engine.entry(withID: .agentMessage(id))?.kind.message)
        #expect(message.meta == .value(try Self.meta(#"{"a":1}"#)))
        #expect(message.content == [.text(TextContent(text: "x"))])
    }

    @Test func aReplayKeepsTheFoldedMeta() throws {
        let id = MessageId(rawValue: "m")
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: id, meta: .value(try Self.meta(#"{"a":1,"b":2}"#)))))
        engine.apply(.userMessage(UserMessage(messageId: id, meta: .value(try Self.meta(#"{"b":null}"#)))))
        var replayed = SessionMergeEngine()
        for update in engine.transcriptUpdates {
            replayed.apply(update)
        }
        #expect(replayed.entries == engine.entries)
    }
}
