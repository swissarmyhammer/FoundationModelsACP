import Foundation
import Testing

// MARK: - Fixture location

/// The `Fixtures/` directory beside the test files in this target.
let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // GoldenFixtureSupport.swift
    .appendingPathComponent("Fixtures")

/// A fixture name attempted to name something other than a single file
/// directly inside `Fixtures/` — a path separator, a `..` component, or an
/// empty string, any of which could otherwise escape the fixtures directory
/// via `appendingPathComponent(_:)`.
struct InvalidFixtureName: Error, CustomStringConvertible {
    let name: String

    var description: String {
        "invalid fixture name \"\(name)\": must be a single, non-empty path component with no \"/\" or \"..\""
    }
}

/// Rejects a fixture name that could escape `Fixtures/` — via a path
/// separator, a `..` component, or an empty string — before it reaches
/// `appendingPathComponent(_:)`.
///
/// Every fixture name in this suite is a hardcoded literal the test authors
/// control, so this guards against future misuse (an untrusted or malformed
/// name reaching these helpers) rather than a currently exploitable path.
///
/// - Parameter name: The candidate fixture file name.
/// - Throws: `InvalidFixtureName` if `name` is empty or contains `"/"` or `".."`.
private func requireSafeFixtureName(_ name: String) throws {
    guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
        throw InvalidFixtureName(name: name)
    }
}

/// Loads a recorded ndJSON fixture byte-for-byte.
///
/// - Parameter name: File name inside `Fixtures/`. Must be a single path
///   component, with no `"/"` or `".."`.
/// - Returns: The raw fixture bytes.
/// - Throws: `InvalidFixtureName` if `name` is unsafe, or an error if the
///   fixture is missing or unreadable.
func fixture(named name: String) throws -> Data {
    try requireSafeFixtureName(name)
    return try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

// MARK: - Capture-once, replay-forever golden comparison

/// Whether the current run should (re)record golden fixtures rather than
/// assert against them, driven by the `RECORD_GOLDEN` environment variable.
var isRecordingGoldenFixtures: Bool {
    ProcessInfo.processInfo.environment["RECORD_GOLDEN"] != nil
}

/// Asserts captured bytes match a committed golden fixture, recording the
/// fixture when it is absent or when recording is requested.
///
/// A missing fixture (or `RECORD_GOLDEN` set) is written and the check
/// passes — the "capture once" step. A present fixture is compared
/// byte-for-byte, and a drift is reported with the first differing line
/// before the check fails, so a regression reads clearly.
///
/// - Parameters:
///   - actual: The captured byte stream.
///   - name: The golden fixture's file name inside `Fixtures/`. Must be a
///     single path component, with no `"/"` or `".."`.
///   - sourceLocation: The caller location, for failure reporting.
/// - Throws: `InvalidFixtureName` if `name` is unsafe, or an error if the
///   fixture cannot be read or written.
func expectGolden(
    actual: Data,
    matchesFixture name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try requireSafeFixtureName(name)
    let url = fixturesDirectory.appendingPathComponent(name)
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

/// Reports the first line where captured output diverges from a golden
/// fixture.
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
    let actualLines = textLines(from: actual)
    let expectedLines = textLines(from: expected)
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
private func textLines(from data: Data) -> [String] {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}
