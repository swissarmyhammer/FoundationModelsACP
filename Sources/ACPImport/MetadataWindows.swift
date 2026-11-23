import Foundation

/// A title with its rank. A title of a higher rank is better. Of two titles
/// with the same rank, the later title in the file is better.
struct RankedTitle: Sendable, Hashable {
    var text: String
    var rank: Int
}

/// The metadata fields that a scan of the lines of one window gives. The
/// fields keep the first value and the last value in the order of the file,
/// as the metadata needs them.
struct MetadataFields: Sendable {
    /// The first identifier of the session.
    var sourceID: String?

    /// The last working folder.
    var cwd: String?

    /// The last git branch.
    var gitBranch: String?

    /// The last value that tells if a program started the session.
    var isAutomated: Bool?

    /// The best title.
    var title: RankedTitle?

    /// The first prompt and the last prompt, cut.
    var firstPrompt: String?
    var lastPrompt: String?

    /// The first date and the last date.
    var dates = DateRange()

    /// `true` when a line is a record of the format.
    var isRecognized = false

    /// `true` when a line starts as a JSON object.
    var sawJSON = false

    /// Keeps the first identifier.
    mutating func noteSourceID(_ value: Any?) {
        sourceID = sourceID ?? Self.text(value)
    }

    /// Keeps the last working folder.
    mutating func noteCwd(_ value: Any?) {
        cwd = Self.text(value) ?? cwd
    }

    /// Keeps the last git branch.
    mutating func noteGitBranch(_ value: Any?) {
        gitBranch = Self.text(value) ?? gitBranch
    }

    /// Keeps a prompt: it is the first prompt when there is none, and it is
    /// the last prompt.
    mutating func notePrompt(_ text: String) {
        guard let preview = ImportSupport.promptPreview(text) else {
            return
        }
        firstPrompt = firstPrompt ?? preview
        lastPrompt = preview
    }

    /// Keeps a prompt as the last prompt only.
    mutating func noteLastPrompt(_ text: String) {
        guard let preview = ImportSupport.promptPreview(text) else {
            return
        }
        lastPrompt = preview
    }

    /// Keeps a title when it is not worse than the title of before.
    mutating func noteTitle(_ candidate: RankedTitle) {
        guard title.map({ $0.rank <= candidate.rank }) ?? true else {
            return
        }
        title = candidate
    }

    /// The text of a value, or `nil` when the value is not a string or is
    /// empty.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// The scans of the windows of one file.
struct WindowScans: Sendable {
    /// The scan of the window at the start of the file, or `nil` when the
    /// reader did not read the head.
    var start: MetadataFields?

    /// The scan of the window at the end of the file.
    var end: MetadataFields

    /// The metadata of the file. The values of the start come from the
    /// head; the last values come from the tail, else from the head.
    ///
    /// - Parameters:
    ///   - agent: The agent of the format.
    ///   - sourceID: The identifier that the caller gives, or `nil` to take
    ///     the identifier of the records.
    /// - Throws: ``ImportReadError/notThisFormat`` when no line is a record
    ///   of the format, ``ImportReadError/noReadableRecord`` when no line is
    ///   JSON.
    func metadata(agent: ImportSourceAgent, sourceID: String?) throws -> SessionFileMetadata {
        guard end.isRecognized || start?.isRecognized == true else {
            throw end.sawJSON || start?.sawJSON == true ? ImportReadError.notThisFormat : ImportReadError.noReadableRecord
        }
        let isAutomated = end.isAutomated ?? start?.isAutomated ?? false
        return SessionFileMetadata(
            agent: agent,
            sourceID: sourceID ?? start?.sourceID ?? end.sourceID ?? "",
            cwd: (end.cwd ?? start?.cwd).map { URL(fileURLWithPath: $0) },
            gitBranch: end.gitBranch ?? start?.gitBranch,
            isAutomated: isAutomated,
            title: bestTitle?.text,
            firstPrompt: isAutomated ? nil : start?.firstPrompt,
            lastPrompt: end.lastPrompt ?? start?.lastPrompt,
            firstDate: start?.dates.first,
            lastDate: end.dates.last ?? start?.dates.last
        )
    }

    /// The best title of the two windows. The end is later in the file.
    private var bestTitle: RankedTitle? {
        guard let startTitle = start?.title else {
            return end.title
        }
        guard let endTitle = end.title, endTitle.rank >= startTitle.rank else {
            return startTitle
        }
        return endTitle
    }
}

/// The windows that the bounded metadata reader reads. (D212 of Testudo,
/// section 4.3.)
///
/// 1. The last 64 KB. The bytes before the first line break are dropped.
/// 2. When the tail gave no working folder, the last 256 KB, one time.
/// 3. When the session is not automated, the first 64 KB. The bytes after
///    the last line break are dropped.
///
/// Thus the reader reads at most 384 KB of a file. A session that the tail
/// tells is automated costs at most two reads. A window that holds the full
/// file is the head and the tail together, and the reader reads nothing
/// more.
enum MetadataWindows {
    /// The length of the first tail window: 64 KB.
    static let tailLength = 65_536

    /// The length of the second tail window: 256 KB.
    static let longTailLength = 262_144

    /// The length of the head window: 64 KB.
    static let headLength = 65_536

    /// Reads the windows of a file and scans their lines.
    ///
    /// - Parameters:
    ///   - source: The bytes of the file.
    ///   - scan: Reads one record of a line into the fields.
    /// - Returns: The scans of the windows.
    static func read(
        _ source: some SessionByteSource,
        scan: (Record, inout MetadataFields) -> Void
    ) throws -> WindowScans {
        let size = source.size
        guard size > 0 else {
            return WindowScans(start: nil, end: MetadataFields())
        }
        var tail = try scanTail(of: source, length: tailLength, scan: scan)
        if tail.fields.cwd == nil, !tail.coversFile {
            tail = try scanTail(of: source, length: longTailLength, scan: scan)
        }
        if tail.coversFile {
            return WindowScans(start: tail.fields, end: tail.fields)
        }
        guard tail.fields.isAutomated != true else {
            return WindowScans(start: nil, end: tail.fields)
        }
        let head = try source.read(offset: 0, length: min(headLength, size))
        let start = fields(of: ImportSupport.completeLines(in: head, startsAtLineStart: true), scan: scan)
        return WindowScans(start: start, end: tail.fields)
    }

    /// Reads the last bytes of a file and scans their lines.
    ///
    /// - Returns: The fields, and `true` when the window holds the full file.
    private static func scanTail(
        of source: some SessionByteSource,
        length: Int,
        scan: (Record, inout MetadataFields) -> Void
    ) throws -> (fields: MetadataFields, coversFile: Bool) {
        let windowLength = min(length, source.size)
        let offset = source.size - windowLength
        let window = try source.read(offset: offset, length: windowLength)
        let lines = ImportSupport.completeLines(in: window, startsAtLineStart: offset == 0)
        return (fields(of: lines, scan: scan), offset == 0)
    }

    /// Scans the lines of one window.
    private static func fields(
        of lines: [Data.SubSequence],
        scan: (Record, inout MetadataFields) -> Void
    ) -> MetadataFields {
        var fields = MetadataFields()
        for line in lines {
            if line.first == UInt8(ascii: "{") {
                fields.sawJSON = true
            }
            if let record = ImportSupport.record(line) {
                scan(record, &fields)
            }
        }
        return fields
    }
}
