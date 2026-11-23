@testable import ACPImport
import Foundation
import FoundationModelsACP
import Testing

/// The bounded metadata reader: `metadata(from:)` of the two readers.
/// (D212 of Testudo, sections 4.3 and 7.)
///
/// The suite is serial, because some tests write a 50 MB file.
@Suite(.serialized) struct SessionFileMetadataTests {
    /// The most bytes that the reader can read from one file: 384 KB.
    static let maximumByteCount = 393_216

    /// The most reads of a typed session and of an automated session.
    static let maximumTypedReadCount = 3
    static let maximumAutomatedReadCount = 2

    /// The length of the windows of the head and of the first tail.
    static let windowLength = 65_536

    /// The length at which the reader cuts a prompt, and the length of a
    /// long prompt.
    static let promptLength = 200
    static let longPromptLength = 500

    /// The number of two-byte characters of the prompt line that holds the
    /// start of the tail window: 80 KB, more than the window.
    static let boundaryCharacterCount = 40_960

    /// The bits of a byte in the middle of a UTF-8 character: `10xxxxxx`.
    static let continuationMask: UInt8 = 0b1100_0000
    static let continuationBits: UInt8 = 0b1000_0000

    /// The last byte of "é" in UTF-8.
    static let lastByteOfE: UInt8 = 0xA9

    /// The number of large records that put the head and the tail far apart.
    static let separatingFillerCount = 4

    static let largeCases: [(SessionFormat, Bool)] = SessionFormat.allCases.flatMap { format in
        [(format, false), (format, true)]
    }

    @Test(arguments: largeCases)
    func theMetadataOfA50MBFileComesFromAtMost384KB(_ format: SessionFormat, automated: Bool) async throws {
        try await GeneratedFiles.withFolder { folder in
            let file = try GeneratedFiles.file(format.largeSession(automated: automated), in: folder)
            let source = CountingByteSource(try FileByteSource(forReadingFrom: file))
            #expect(source.size > SessionFormat.largeFileSize)
            let metadata = try format.metadata(from: source)
            #expect(source.byteCount <= Self.maximumByteCount)
            #expect(source.readCount <= (automated ? Self.maximumAutomatedReadCount : Self.maximumTypedReadCount))
            #expect(metadata == format.largeSessionMetadata(automated: automated))
        }
    }

    @Test(arguments: largeCases)
    func theMetadataOfA50MBFileIsTheMetadataOfAFullRead(_ format: SessionFormat, automated: Bool) async throws {
        try await GeneratedFiles.withFolder { folder in
            let file = try GeneratedFiles.file(format.largeSession(automated: automated), in: folder)
            let metadata = try format.metadata(from: try FileByteSource(forReadingFrom: file))
            let full = try format.fullRead(Data(contentsOf: file)).metadata
            #expect(metadata.sourceID == full.sourceID)
            #expect(metadata.cwd == full.cwd)
            #expect(metadata.title == full.title)
            #expect(metadata.lastDate == full.lastDate)
            #expect(metadata.firstDate == (format == .claudeCode && automated ? nil : full.firstDate))
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func theFixtureGivesEachField(_ format: SessionFormat) throws {
        let source = CountingByteSource(try FileByteSource(forReadingFrom: format.fixtureURL))
        #expect(try format.metadata(from: source) == Self.fixtureMetadata(format))
    }

    @Test(arguments: SessionFormat.allCases)
    func aSmallFileIsReadOneTime(_ format: SessionFormat) throws {
        let source = CountingByteSource(try FileByteSource(forReadingFrom: format.fixtureURL))
        _ = try format.metadata(from: source)
        #expect(source.readRanges == [0..<source.size])
    }

    @Test func aClaudeCodeFileWithNoEntrypointIsTyped() async throws {
        try await GeneratedFiles.withFolder { folder in
            let line = #"{"type":"user","uuid":"u","sessionId":"s","cwd":"/w","message":{"role":"user","content":"Hi"}}"#
            let source = try GeneratedFiles.source([line], in: folder)
            #expect(try ClaudeCodeSessionReader().metadata(from: source).isAutomated == false)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aPromptIsCutAt200Characters(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let text = String(repeating: "a", count: Self.longPromptLength)
            let lines = format.headLines(automated: false) + [format.prompt(text, automated: false)]
            let metadata = try format.metadata(from: try GeneratedFiles.source(lines, in: folder))
            #expect(metadata.firstPrompt == String(repeating: "a", count: Self.promptLength))
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aFirstPromptRecordLargerThanTheHeadGivesNoFirstPrompt(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            // The two-byte characters put the end of the head window in the
            // middle of a line, and maybe in the middle of a character.
            let largePrompt = String(repeating: "é", count: Self.windowLength)
            let lines = format.headLines(automated: false)
                + [format.prompt(largePrompt, automated: false)]
                + (0..<Self.separatingFillerCount).map { format.filler($0, automated: false) }
                + [format.titleLine, format.lastPrompt(SessionFormat.lastPrompt), format.context(automated: false)]
            let metadata = try format.metadata(from: try GeneratedFiles.source(lines, in: folder))
            #expect(metadata.firstPrompt == nil)
            #expect(metadata.cwd == URL(fileURLWithPath: SessionFormat.cwd))
            #expect(metadata.gitBranch == SessionFormat.gitBranch)
            #expect(metadata.title == SessionFormat.title)
            #expect(metadata.lastPrompt == SessionFormat.lastPrompt)
            #expect(metadata.lastDate == SessionFormat.date(SessionFormat.lastDateText))
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func anIncompleteLastLineIsNotRead(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let lines = format.headLines(automated: false)
                + [format.prompt(SessionFormat.firstPrompt, automated: false), format.lastPrompt("complete"), format.lastPrompt("partial")]
            let source = try GeneratedFiles.source(lines, in: folder, endsWithLineBreak: false)
            #expect(try format.metadata(from: source).lastPrompt == "complete")
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aTailWindowThatStartsInACharacterDropsThatLine(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let lines = try Self.linesWithTheTailStartInACharacter(format)
            let source = try GeneratedFiles.source(lines, in: folder)
            let metadata = try format.metadata(from: source)
            // The line with the large prompt holds the start of the tail
            // window, thus the last prompt is the prompt of the head.
            #expect(metadata.lastPrompt == SessionFormat.firstPrompt)
            #expect(metadata.cwd == URL(fileURLWithPath: SessionFormat.cwd))
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func anEmptyFileHasNoReadableRecordAndNoRead(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let source = try GeneratedFiles.source([], in: folder)
            #expect(throws: ImportReadError.noReadableRecord) { try format.metadata(from: source) }
            #expect(source.readCount == 0)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aFileOfTheOtherFormatIsNotThisFormat(_ format: SessionFormat) throws {
        let source = try FileByteSource(forReadingFrom: format.other.fixtureURL)
        #expect(throws: ImportReadError.notThisFormat) { try format.metadata(from: source) }
    }

    @Test func aWindowDropsThePartialLinesAtItsEnds() {
        // The window starts with the last byte of "é" and ends in a line
        // with no line break.
        let window = Data([Self.lastByteOfE] + Array("dropped\n{\"a\":1}\n{\"b\":2}\npartial".utf8))
        let lines = ImportSupport.completeLines(in: window, startsAtLineStart: false)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func aWindowAtTheStartOfTheFileKeepsItsFirstLine() {
        let window = Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8)
        let lines = ImportSupport.completeLines(in: window, startsAtLineStart: true)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
    }

    /// The metadata of the fixture of a format.
    static func fixtureMetadata(_ format: SessionFormat) -> SessionFileMetadata {
        switch format {
        case .claudeCode:
            SessionFileMetadata(
                agent: .claudeCode,
                sourceID: ImportFixtures.claudeSource,
                cwd: URL(fileURLWithPath: "/work/app"),
                isAutomated: false,
                title: "Test fix",
                firstPrompt: "Fix the test",
                lastPrompt: "What is in this image?",
                firstDate: ImportFixtures.date("2026-11-01T10:00:00.000Z"),
                lastDate: ImportFixtures.date("2026-11-01T10:00:17.000Z")
            )
        case .codex:
            SessionFileMetadata(
                agent: .codex,
                sourceID: ImportFixtures.codexSource,
                cwd: URL(fileURLWithPath: "/work/cli"),
                isAutomated: false,
                title: "Add a README",
                firstPrompt: "List the files and add a README.",
                lastPrompt: "Thanks.",
                firstDate: ImportFixtures.date("2026-11-02T09:00:00.000Z"),
                lastDate: ImportFixtures.date("2026-11-02T09:00:15.000Z")
            )
        }
    }

    /// The lines of a file whose last 64 KB start in the middle of a
    /// two-byte character of a prompt line. The prompt line is the only line
    /// with a prompt in the tail, and the small last line has the working
    /// folder, thus the tail is read one time.
    static func linesWithTheTailStartInACharacter(_ format: SessionFormat) throws -> [String] {
        let before = format.headLines(automated: false)
            + [format.prompt(SessionFormat.firstPrompt, automated: false)]
            + (0..<separatingFillerCount).map { format.filler($0, automated: false) }
        let after = format.context(automated: false)
        let prefixLength = before.reduce(0) { $0 + $1.utf8.count + 1 }
        let characters = String(repeating: "é", count: boundaryCharacterCount)
        for padding in ["", "a"] {
            let promptLine = format.lastPrompt(characters + padding)
            let size = prefixLength + promptLine.utf8.count + 1 + after.utf8.count + 1
            let position = size - windowLength - prefixLength
            let byte = Array(promptLine.utf8)[position]
            if byte & continuationMask == continuationBits {
                return before + [promptLine, after]
            }
        }
        Issue.record("no padding puts the start of the tail in a character")
        return []
    }
}

/// The streaming reader: `updates(from:blockSize:)` of the two readers.
///
/// The suite is serial, because the tests write a 50 MB file.
@Suite(.serialized) struct SessionUpdateStreamTests {
    /// A small block, so that the lines of a fixture cross the blocks.
    static let smallBlockSize = 512

    /// All the updates of a stream.
    static func collect(_ batches: SessionUpdateBatches) async throws -> [SessionUpdate] {
        var updates: [SessionUpdate] = []
        for try await batch in batches {
            updates += batch
        }
        return updates
    }

    @Test(arguments: SessionFormat.allCases)
    func theStreamGivesTheUpdatesOfAFullRead(_ format: SessionFormat) async throws {
        let file = format.fixtureURL
        let batches = format.updates(from: try FileByteSource(forReadingFrom: file), blockSize: Self.smallBlockSize)
        #expect(try await Self.collect(batches) == format.fullUpdates(Data(contentsOf: file)))
    }

    /// The block read of the copy gives the session of a full read: the
    /// metadata, each update, and the count and the kinds of the skipped
    /// records. A line that is not JSON is skipped and counted.
    @Test(arguments: SessionFormat.allCases)
    func theBlockReadGivesTheSessionOfAFullRead(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            var data = try Data(contentsOf: format.fixtureURL)
            data.append(Data("this line is not JSON\n".utf8))
            let file = folder.appendingPathComponent("with-a-bad-line.jsonl")
            try data.write(to: file)

            let session = try format.read(
                from: try FileByteSource(forReadingFrom: file), blockSize: Self.smallBlockSize)

            let full = try format.fullRead(data)
            #expect(session == full)
            #expect(session.skippedRecordCount > 0)
        }
    }

    /// A file whose last record has no line break gives that record, as a
    /// full read does.
    @Test(arguments: SessionFormat.allCases)
    func theStreamGivesALastRecordWithNoLineBreak(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            var data = try Data(contentsOf: format.fixtureURL)
            while data.last == UInt8(ascii: "\n") { data.removeLast() }
            let file = folder.appendingPathComponent("no-final-line-break.jsonl")
            try data.write(to: file)
            let batches = format.updates(from: try FileByteSource(forReadingFrom: file), blockSize: Self.smallBlockSize)
            let updates = try await Self.collect(batches)
            #expect(try updates == format.fullUpdates(data))
            #expect(!updates.isEmpty)
        }
    }

    /// A last line that an agent writes now is not complete JSON: the
    /// stream skips it, as a full read does.
    @Test(arguments: SessionFormat.allCases)
    func theStreamSkipsALastLineThatIsNotComplete(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            var data = try Data(contentsOf: format.fixtureURL)
            let complete = try format.fullUpdates(data)
            data.append(Data(#"{"type":"user","message":{"role":"us"#.utf8))
            let file = folder.appendingPathComponent("live.jsonl")
            try data.write(to: file)
            let batches = format.updates(from: try FileByteSource(forReadingFrom: file), blockSize: Self.smallBlockSize)
            #expect(try await Self.collect(batches) == complete)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func theFirstBatchComesBeforeTheEndOfTheFile(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let source = try GeneratedFiles.source(format.largeSession(automated: false), in: folder)
            var iterator = format.updates(from: source).makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.isEmpty == false)
            #expect(source.byteCount <= SessionUpdateBatches.defaultBlockSize)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func eachReadIsOneBlockAndEachByteIsReadOneTime(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let source = try GeneratedFiles.source(format.largeSession(automated: false), in: folder)
            let updates = try await Self.collect(format.updates(from: source))
            #expect(updates.count == format.largeSessionUpdateCount)
            let blockSize = SessionUpdateBatches.defaultBlockSize
            #expect(source.readRanges.allSatisfy { $0.count <= blockSize })
            let ends = source.readRanges.map(\.lowerBound).dropFirst()
            #expect(Array(ends) == source.readRanges.map(\.upperBound).dropLast())
            #expect(source.readRanges.first?.lowerBound == 0)
            #expect(source.readRanges.last?.upperBound == source.size)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func theLineReaderKeepsAtMostOneLine(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let lines = format.largeSession(automated: false)
            let longestLine = lines.map(\.utf8.count).max() ?? 0
            var reader = LineReader(source: try GeneratedFiles.source(lines, in: folder), blockSize: SessionUpdateBatches.defaultBlockSize)
            var largestBuffer = 0
            var lineCount = 0
            while !reader.isAtEnd {
                lineCount += try reader.nextLines().count
                largestBuffer = max(largestBuffer, reader.bufferedByteCount)
            }
            #expect(lineCount == lines.count)
            #expect(largestBuffer <= longestLine)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aCancelledTaskStopsTheStream(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let source = try GeneratedFiles.source(format.largeSession(automated: false), in: folder)
            let batches = format.updates(from: source)
            let task = Task {
                var iterator = batches.makeAsyncIterator()
                _ = try await iterator.next()
                withUnsafeCurrentTask { $0?.cancel() }
                let readsAtCancel = source.readCount
                await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
                return source.readCount - readsAtCancel
            }
            #expect(try await task.value == 0)
            #expect(source.byteCount < source.size)
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func anEmptyFileHasNoReadableRecord(_ format: SessionFormat) async throws {
        try await GeneratedFiles.withFolder { folder in
            let source = try GeneratedFiles.source([], in: folder)
            await #expect(throws: ImportReadError.noReadableRecord) { _ = try await Self.collect(format.updates(from: source)) }
        }
    }

    @Test(arguments: SessionFormat.allCases)
    func aFileOfTheOtherFormatIsNotThisFormat(_ format: SessionFormat) async throws {
        let source = try FileByteSource(forReadingFrom: format.other.fixtureURL)
        await #expect(throws: ImportReadError.notThisFormat) { _ = try await Self.collect(format.updates(from: source)) }
    }
}
