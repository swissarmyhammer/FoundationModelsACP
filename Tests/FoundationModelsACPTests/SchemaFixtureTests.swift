import Foundation
import Testing

/// Tests that the vendored ACP schema artifacts in `Schema/` exist, parse as
/// JSON, and expose the top-level structure the code generator depends on.
///
/// The artifacts are vendored byte-identical from the
/// `agentclientprotocol/agent-client-protocol` GitHub release assets
/// (see `Schema/README.md` for the pinned tag and bump procedure).
@Suite struct SchemaFixtureTests {
    /// The package-root `Schema/` directory, located relative to this source file.
    private static let schemaDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SchemaFixtureTests.swift
        .deletingLastPathComponent()  // FoundationModelsACPTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Schema")

    /// Loads a vendored schema artifact and parses it as a top-level JSON object.
    ///
    /// - Parameter name: File name inside `Schema/` (e.g. `acp-v1.json`).
    /// - Returns: The parsed top-level JSON dictionary.
    /// - Throws: A test failure if the file is missing, unreadable, or not a JSON object.
    private func loadJSONObject(named name: String) throws -> [String: Any] {
        let url = Self.schemaDirectory.appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Missing vendored schema artifact: \(url.path)"
        )
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(
            parsed as? [String: Any],
            "\(name) must contain a top-level JSON object"
        )
    }

    /// Asserts a method-routing manifest has the expected routing tables,
    /// including the `session/prompt` agent method.
    ///
    /// - Parameter manifest: The parsed top-level object of a meta manifest.
    private func expectRoutingTables(in manifest: [String: Any], from name: String) throws {
        let agentMethods = try #require(
            manifest["agentMethods"] as? [String: String],
            "\(name) must contain an agentMethods routing table"
        )
        let clientMethods = try #require(
            manifest["clientMethods"] as? [String: String],
            "\(name) must contain a clientMethods routing table"
        )
        #expect(manifest["protocolMethods"] as? [String: String] != nil)
        #expect(manifest["version"] != nil)
        #expect(!clientMethods.isEmpty)
        #expect(agentMethods.values.contains("session/prompt"))
    }

    @Test func schemaJSONContainsDefinitions() throws {
        let schema = try loadJSONObject(named: "acp-v1.json")
        let definitions = try #require(
            schema["$defs"] as? [String: Any],
            "acp-v1.json must contain a $defs definitions map"
        )
        #expect(!definitions.isEmpty)
    }

    @Test func metaJSONContainsMethodRouting() throws {
        let manifest = try loadJSONObject(named: "acp-v1.meta.json")
        try expectRoutingTables(in: manifest, from: "acp-v1.meta.json")
    }

    @Test func unstableMetaJSONContainsMethodRouting() throws {
        let manifest = try loadJSONObject(named: "acp-v1.meta.unstable.json")
        try expectRoutingTables(in: manifest, from: "acp-v1.meta.unstable.json")
    }

    @Test func unstableMetaIsSupersetOfStableMeta() throws {
        let stable = try loadJSONObject(named: "acp-v1.meta.json")
        let unstable = try loadJSONObject(named: "acp-v1.meta.unstable.json")
        let stableAgent = try #require(stable["agentMethods"] as? [String: String])
        let unstableAgent = try #require(unstable["agentMethods"] as? [String: String])
        for (key, value) in stableAgent {
            #expect(unstableAgent[key] == value, "unstable manifest dropped agent method \(key)")
        }
    }
}
