import Foundation
import Testing

@testable import ACPGenerateCore

/// The package-root `Schema` directory, located relative to this file.
private let vendoredSchemaDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // GenerationTestSupport.swift
    .deletingLastPathComponent()  // ACPGenerateTests
    .deletingLastPathComponent()  // Tests
    .appendingPathComponent("Schema")

/// The package-root `Schema/acp-v1.json`, located relative to this file.
private let vendoredSchemaURL = vendoredSchemaDirectory
    .appendingPathComponent("acp-v1.json")

/// The vendored stable routing manifest `Schema/acp-v1.meta.json`.
let vendoredMetaURL = vendoredSchemaDirectory
    .appendingPathComponent("acp-v1.meta.json")

/// The vendored unstable routing manifest `Schema/acp-v1.meta.unstable.json`.
let vendoredUnstableMetaURL = vendoredSchemaDirectory
    .appendingPathComponent("acp-v1.meta.unstable.json")

/// Generates from the vendored schema and manifests and returns one file's
/// contents.
///
/// - Parameter name: The generated file name to look up.
/// - Returns: The Swift source text of that file.
/// - Throws: A test failure when generation fails or the file is missing.
func vendoredOutput(named name: String) throws -> String {
    let data = try Data(contentsOf: vendoredSchemaURL)
    let files = try SchemaGenerator().generate(
        schemaJSON: data,
        metaJSON: Data(contentsOf: vendoredMetaURL),
        unstableMetaJSON: Data(contentsOf: vendoredUnstableMetaURL)
    )
    let file = files.first { $0.name == name }
    return try #require(file, "expected generated file \(name)").contents
}

/// Loads the vendored schema document and both routing manifests as raw bytes.
///
/// - Returns: The schema, stable-manifest, and unstable-manifest bytes.
/// - Throws: A test failure when any artifact cannot be read.
func vendoredArtifacts() throws -> (schema: Data, meta: Data, unstableMeta: Data) {
    (
        try Data(contentsOf: vendoredSchemaURL),
        try Data(contentsOf: vendoredMetaURL),
        try Data(contentsOf: vendoredUnstableMetaURL)
    )
}

/// Loads a vendored routing manifest's side groups for data-driven tests.
///
/// - Parameter url: The manifest file to load.
/// - Returns: The manifest's routing groups: group name → (routing key →
///   wire method name).
/// - Throws: A test failure when the manifest does not have the expected
///   `agentMethods`/`clientMethods`/`protocolMethods` shape.
func routingGroups(from url: URL) throws -> [String: [String: String]] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let manifest = try #require(object as? [String: Any], "manifest is not a JSON object")
    var groups: [String: [String: String]] = [:]
    for name in ["agentMethods", "clientMethods", "protocolMethods"] {
        groups[name] = try #require(manifest[name] as? [String: String], "missing routing group \(name)")
    }
    return groups
}
