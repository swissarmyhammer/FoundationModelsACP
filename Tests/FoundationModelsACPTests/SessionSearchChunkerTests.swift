import Foundation
import Testing

@testable import FoundationModelsACP

/// `SessionSearchChunker`: the search chunks of a transcript (D207 (a)).
@Suite struct SessionSearchChunkerTests {
    // MARK: - Helpers

    /// Folds wire updates into entries.
    private static func entries(_ updates: [String]) throws -> [SessionEntry] {
        let decoded = try updates.map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
        for update in decoded {
            if case .unknown(let type, _) = update, type != "future_update" {
                Issue.record("a test update decoded as unknown \(type)")
            }
        }
        return SessionMergeEngine(replaying: decoded).entries
    }

    private static func chunks(_ updates: [String]) throws -> [SessionSearchChunk] {
        SessionSearchChunker.chunks(of: try entries(updates))
    }

    private static func user(_ id: String, _ text: String) -> String {
        #"{"sessionUpdate":"user_message_chunk","messageId":"\#(id)","content":{"type":"text","text":\#(json(text))}}"#
    }

    private static func agent(_ id: String, _ text: String) -> String {
        #"{"sessionUpdate":"agent_message_chunk","messageId":"\#(id)","content":{"type":"text","text":\#(json(text))}}"#
    }

    private static func thought(_ id: String, _ text: String) -> String {
        #"{"sessionUpdate":"agent_thought_chunk","messageId":"\#(id)","content":{"type":"text","text":\#(json(text))}}"#
    }

    private static func tool(_ id: String, _ title: String, content: String = "[]") -> String {
        #"{"sessionUpdate":"tool_call_update","toolCallId":"\#(id)","title":\#(json(title)),"status":"completed","content":\#(content)}"#
    }

    private static func terminal(_ id: String, command: String, output: String) -> [String] {
        [
            #"{"sessionUpdate":"terminal_update","terminalId":"\#(id)","command":\#(json(command))}"#,
            #"{"sessionUpdate":"terminal_output_chunk","terminalId":"\#(id)","data":"\#(Data(output.utf8).base64EncodedString())"}"#,
        ]
    }

    private static func json(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    /// The text of the part of a chunk that comes from an entry.
    private static func part(of id: SessionEntry.ID, in chunk: SessionSearchChunk) -> [String] {
        let characters = Array(chunk.text)
        return chunk.entries.filter { $0.id == id }.map { String(characters[$0.range]) }
    }

    // MARK: - Kinds

    @Test func eachKindGivesItsChunk() throws {
        let chunks = try Self.chunks(
            [
                Self.user("u1", "Find the bug."),
                Self.thought("t1", "Look at the parser."),
                Self.agent("a1", "I look."),
                Self.tool("c1", "Read parser.swift", content: #"[{"type":"content","content":{"type":"text","text":"func parse()"}}]"#),
                #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p1","entries":[{"content":"Read","priority":"high","status":"completed"},{"content":"Fix","priority":"high","status":"pending"}]}}"#,
                #"{"sessionUpdate":"session_message","messageId":"m1","senderSessionId":"01ABC","senderMessageId":"x","content":[{"type":"text","text":"Done."}],"_meta":{"sah":{"message":{"sender":{"kind":"session","sessionId":"01ABC","title":"Build"}}}}}"#,
            ]
        )
        #expect(chunks.map(\.kind) == [.user, .thought, .agent, .tool, .plan, .message])
        #expect(chunks.map(\.text) == ["Find the bug.", "Look at the parser.", "I look.", "Read parser.swift\nfunc parse()", "Read\nFix", "Done."])
        #expect(chunks.map(\.title) == ["", "", "", "Read parser.swift", "", ""])
        #expect(chunks.map(\.author) == [nil, nil, nil, nil, nil, "Build"])
        #expect(chunks.map(\.ordinal) == Array(0..<6))
        #expect(chunks[3].entries == [SessionSearchChunk.EntryRange(id: .toolCall(ToolCallId(rawValue: "c1")), range: 0..<30)])
    }

    @Test func aUserMessageFromAnotherSessionIsAMessageWithItsSender() throws {
        let chunks = try Self.chunks(
            [
                #"{"sessionUpdate":"user_message","messageId":"u1","content":[{"type":"text","text":"Hi."}],"_meta":{"sah":{"message":{"sender":{"kind":"user","sessionId":"01XYZ"}}}}}"#
            ]
        )
        #expect(chunks.map(\.kind) == [.message])
        #expect(chunks.first?.author == "01XYZ")
        #expect(chunks.first?.turn == 1)
    }

    @Test func aSessionMessageWithNoMetaHasItsSenderIdAsAuthor() throws {
        let chunks = try Self.chunks(
            [#"{"sessionUpdate":"session_message","messageId":"m1","senderSessionId":"01ABC","senderMessageId":"x","content":[{"type":"text","text":"Hi."}]}"#]
        )
        #expect(chunks.first?.author == "01ABC")
    }

    @Test func aCompactionAndAnUnknownEntryMakeNoChunk() throws {
        let chunks = try Self.chunks(
            [
                #"{"sessionUpdate":"compaction_update","compactionId":"k1","status":"completed","summary":[{"type":"text","text":"Summary"}]}"#,
                #"{"sessionUpdate":"future_update","value":1}"#,
                #"{"sessionUpdate":"state_update","state":"running"}"#,
            ]
        )
        #expect(chunks.isEmpty)
    }

    // MARK: - Joins and cuts

    @Test func theAgentMessagesAndTheThoughtsOfATurnJoin() throws {
        let chunks = try Self.chunks(
            [
                Self.user("u1", "Go."),
                Self.agent("a1", "One."),
                Self.agent("a2", "Two."),
                Self.thought("t1", "Think one."),
                Self.thought("t2", "Think two."),
            ]
        )
        #expect(chunks.map(\.kind) == [.user, .agent, .thought])
        #expect(chunks[1].text == "One.\n\nTwo.")
        #expect(chunks[1].entries.map(\.range) == [0..<4, 6..<10])
        #expect(Self.part(of: .agentMessage(MessageId(rawValue: "a2")), in: chunks[1]) == ["Two."])
        #expect(chunks[2].text == "Think one.\n\nThink two.")
    }

    @Test func aToolCallBetweenTwoAgentMessagesCutsThem() throws {
        let chunks = try Self.chunks([Self.agent("a1", "Before."), Self.tool("c1", "Run"), Self.agent("a2", "After.")])
        #expect(chunks.map(\.kind) == [.agent, .tool, .agent])
        #expect(chunks.map(\.text) == ["Before.", "Run", "After."])
    }

    @Test func aNewTurnCutsTheAgentMessages() throws {
        let chunks = try Self.chunks([Self.agent("a1", "One."), Self.user("u1", "Next."), Self.agent("a2", "Two.")])
        #expect(chunks.map(\.text) == ["One.", "Next.", "Two."])
    }

    // MARK: - Turns

    @Test func theTurnStartsAtEachPromptAndEachReceivedMessage() throws {
        let chunks = try Self.chunks(
            [
                Self.agent("a0", "Hello."),
                Self.user("u1", "One."),
                Self.agent("a1", "Answer one."),
                #"{"sessionUpdate":"session_message","messageId":"m1","senderSessionId":"01ABC","senderMessageId":"x","content":[{"type":"text","text":"From afar."}]}"#,
                Self.agent("a2", "Answer two."),
                #"{"sessionUpdate":"session_message","messageId":"m2","senderSessionId":"self","recipientSessionId":"01ABC","recipientMessageId":"y","content":[{"type":"text","text":"Sent."}]}"#,
                Self.user("u2", "Three."),
            ]
        )
        #expect(chunks.map(\.turn) == [0, 1, 1, 2, 2, 2, 3])
    }

    // MARK: - Tool calls and terminals

    @Test func aNamedTerminalJoinsItsToolCallAndAnotherTerminalIsItsOwnChunk() throws {
        let chunks = try Self.chunks(
            [Self.tool("c1", "Run ls", content: #"[{"type":"terminal","terminalId":"term-1"}]"#)]
                + Self.terminal("term-1", command: "ls", output: "a.swift\n")
                + Self.terminal("term-2", command: "pwd", output: "/work\n")
        )
        #expect(chunks.map(\.kind) == [.tool, .tool])
        #expect(chunks[0].text == "Run ls\n$ ls\na.swift")
        #expect(chunks[0].title == "Run ls")
        #expect(Self.part(of: .terminal(TerminalId(rawValue: "term-1")), in: chunks[0]) == ["$ ls\na.swift"])
        #expect(chunks[1].text == "$ pwd\n/work")
        #expect(chunks[1].title == "")
    }

    @Test func aDiffGivesItsPatchOrItsPaths() throws {
        let chunks = try Self.chunks(
            [
                Self.tool("c1", "Edit", content: #"[{"type":"diff","changes":[{"operation":"modify","path":"/a.swift"}],"patch":{"format":"git_patch","text":"-old\n+new\n"}}]"#),
                Self.tool("c2", "Move", content: #"[{"type":"diff","changes":[{"operation":"move","oldPath":"/b","path":"/c"}]}]"#),
            ]
        )
        #expect(chunks.map(\.text) == ["Edit\n-old\n+new", "Move\n/b /c"])
    }

    @Test func aLargeToolOutputIsCutAt64KB() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let output = String(repeating: line, count: 1_000)  // 100,000 bytes
        let chunks = try Self.chunks(
            [Self.tool("c1", "Big", content: #"[{"type":"terminal","terminalId":"t"}]"#)]
                + Self.terminal("t", command: "cat big", output: output)
        )
        let total = chunks.map { $0.text.utf8.count }.reduce(0, +)
        #expect(chunks.allSatisfy { $0.kind == .tool && $0.title == "Big" })
        #expect(total <= SessionSearchChunker.maximumToolTextLength)
        #expect(total > SessionSearchChunker.maximumToolTextLength - 2 * SessionSearchChunker.maximumChunkLength)
        #expect(chunks.allSatisfy { $0.text.count <= SessionSearchChunker.maximumChunkLength })
    }

    // MARK: - The cut at 2,000 characters

    @Test func aLongTextIsCutAtTheEndOfALine() throws {
        let line = String(repeating: "a", count: 59) + "\n"  // 60 characters
        let text = String(repeating: line, count: 50)  // 3,000 characters
        let chunks = try Self.chunks([Self.agent("a1", text)])
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.kind == .agent && $0.text.count <= SessionSearchChunker.maximumChunkLength })
        // The first cut is at the last line end in the first 2,000
        // characters: 33 lines of 60, less the line end at the cut.
        #expect(chunks[0].text.count == 33 * 60 - 1)
        #expect(chunks[0].text.hasSuffix("a"))
        #expect(!chunks[1].text.hasPrefix("\n"))
        #expect(chunks[0].entries == [SessionSearchChunk.EntryRange(id: .agentMessage(MessageId(rawValue: "a1")), range: 0..<1_979)])
        #expect(chunks[1].entries.first?.range == 0..<chunks[1].text.count)
        #expect(chunks.map(\.ordinal) == [0, 1])
    }

    @Test func aLongLineIsCutAtASpaceOrAtTheLimit() throws {
        let words = String(repeating: "word ", count: 500)  // 2,500 characters
        let spaced = try Self.chunks([Self.agent("a1", words)])
        #expect(spaced.count == 2)
        #expect(spaced[0].text.hasSuffix("word"))

        let solid = try Self.chunks([Self.agent("a1", String(repeating: "z", count: 4_500))])
        #expect(solid.map { $0.text.count } == [2_000, 2_000, 500])
    }

    @Test func theRangesOfEachEntryFollowTheCut() throws {
        let first = String(repeating: "b", count: 1_500)
        let second = String(repeating: "c", count: 1_500)
        let chunks = try Self.chunks([Self.agent("a1", first), Self.agent("a2", second)])
        // "bbb…\n\nccc…": the cut is at the second line end.
        #expect(chunks.count == 2)
        #expect(chunks[0].entries.map(\.id) == [.agentMessage(MessageId(rawValue: "a1"))])
        #expect(chunks[0].text == first + "\n")
        #expect(chunks[1].text == second)
        #expect(chunks[1].entries == [SessionSearchChunk.EntryRange(id: .agentMessage(MessageId(rawValue: "a2")), range: 0..<1_500)])
    }

    // MARK: - Dates and stability

    @Test func aChunkTakesTheDateOfItsFirstEntryWithADate() throws {
        let entries = try Self.entries([Self.agent("a1", "One."), Self.agent("a2", "Two.")])
        let date = Date(timeIntervalSince1970: 1_000)
        let chunks = SessionSearchChunker.chunks(of: entries, dates: [.agentMessage(MessageId(rawValue: "a2")): date])
        #expect(chunks.first?.date == date)
        #expect(SessionSearchChunker.chunks(of: entries).first?.date == nil)
    }

    @Test func theSameEntriesGiveTheSameChunks() throws {
        let entries = try Self.entries(
            [Self.user("u1", "Go."), Self.agent("a1", String(repeating: "word ", count: 900)), Self.tool("c1", "Run")]
        )
        #expect(SessionSearchChunker.chunks(of: entries) == SessionSearchChunker.chunks(of: entries))
        let replayed = SessionMergeEngine(replaying: SessionMergeEngine(replaying: []).transcriptUpdates + entries.map(\.replayUpdate)).entries
        #expect(SessionSearchChunker.chunks(of: replayed) == SessionSearchChunker.chunks(of: entries))
    }
}

/// The text form of `SessionEntry.ID`.
@Suite struct SessionEntryIDTextTests {
    static let ids: [SessionEntry.ID] = [
        .userMessage(MessageId(rawValue: "u-1")),
        .agentMessage(MessageId(rawValue: "a:1")),
        .agentThought(MessageId(rawValue: "t1")),
        .toolCall(ToolCallId(rawValue: "call-1")),
        .terminal(TerminalId(rawValue: "term-1")),
        .plan(PlanId(rawValue: "plan-1")),
        .compaction(CompactionId(rawValue: "k1")),
        .sessionMessage(MessageId(rawValue: "m1")),
        .unidentified(position: 7),
    ]

    @Test(arguments: ids)
    func eachIdRoundTrips(_ id: SessionEntry.ID) {
        #expect(SessionEntry.ID(searchHitID: id.searchHitID) == id)
        #expect(SessionEntry.ID(id.description) == id)
    }

    @Test func theTextFormIsKindColonWireId() {
        #expect(Self.ids.map(\.searchHitID) == [
            "user:u-1", "agent:a:1", "thought:t1", "tool:call-1", "terminal:term-1",
            "plan:plan-1", "compaction:k1", "message:m1", "position:7",
        ])
    }

    @Test(arguments: ["", "user", "nope:1", "position:-1", "position:x", "position:07"])
    func aWrongTextIsNotAnId(_ text: String) {
        #expect(SessionEntry.ID(searchHitID: text) == nil)
    }
}
