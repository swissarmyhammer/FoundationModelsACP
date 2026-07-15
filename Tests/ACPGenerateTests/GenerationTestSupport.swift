import Foundation
import Testing

@testable import ACPGenerateCore

/// The package-root `Schema/acp-v1.json`, located relative to this file.
private let vendoredSchemaURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // GenerationTestSupport.swift
    .deletingLastPathComponent()  // ACPGenerateTests
    .deletingLastPathComponent()  // Tests
    .appendingPathComponent("Schema")
    .appendingPathComponent("acp-v1.json")

/// Generates from the vendored schema and returns one file's contents.
///
/// - Parameter name: The generated file name to look up.
/// - Returns: The Swift source text of that file.
/// - Throws: A test failure when generation fails or the file is missing.
func vendoredOutput(named name: String) throws -> String {
    let data = try Data(contentsOf: vendoredSchemaURL)
    let files = try SchemaGenerator().generate(schemaJSON: data)
    let file = files.first { $0.name == name }
    return try #require(file, "expected generated file \(name)").contents
}
