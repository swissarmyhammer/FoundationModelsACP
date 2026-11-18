import Foundation
import FoundationModelsACP
import Testing

/// Reads and writes the golden files of the Markdown renderer.
enum GoldenFiles {
    /// The `Golden/` folder beside this file.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")

    /// The recorded session of the core tests, in JSON-RPC frames.
    static let fullSessionFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GoldenFiles.swift
        .deletingLastPathComponent()  // ACPMarkdownTests
        .appendingPathComponent("FoundationModelsACPTests/Fixtures/full-session-agent.ndjson")

    /// `true` when the run writes the `.md` files again.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_GOLDEN"] != nil
    }

    /// Reads the updates of a golden input: one `SessionUpdate` for each
    /// line.
    ///
    /// - Parameter name: The name of the pair.
    /// - Returns: The updates, in order.
    static func updates(named name: String) throws -> [SessionUpdate] {
        let text = try String(contentsOf: directory.appendingPathComponent(name + ".ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(SessionUpdate.self, from: Data(line.utf8))
        }
    }

    /// Reads the `session/update` payloads of the recorded full session.
    ///
    /// - Returns: The updates, in the order of the wire.
    static func fullSessionUpdates() throws -> [SessionUpdate] {
        let text = try String(contentsOf: fullSessionFixture, encoding: .utf8)
        var updates: [SessionUpdate] = []
        for line in text.split(separator: "\n") {
            let frame = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard frame?["method"] as? String == "session/update",
                let params = frame?["params"] as? [String: Any],
                let update = params["update"]
            else {
                continue
            }
            let data = try JSONSerialization.data(withJSONObject: update)
            updates.append(try JSONDecoder().decode(SessionUpdate.self, from: data))
        }
        return updates
    }

    /// Compares a document with its golden file byte for byte, or writes the
    /// golden file when the run records.
    ///
    /// - Parameters:
    ///   - document: The rendered document.
    ///   - name: The name of the pair.
    static func assertGolden(_ document: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = directory.appendingPathComponent(name + ".md")
        if isRecording {
            try Data(document.utf8).write(to: url)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(document == expected, "\(name).md differs; run with RECORD_GOLDEN=1 and review the diff", sourceLocation: sourceLocation)
    }
}
