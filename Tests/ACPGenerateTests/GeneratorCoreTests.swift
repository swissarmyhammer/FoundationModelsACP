import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the schema→Swift generator core against a miniature schema fixture
/// and the full vendored `Schema/acp-v1.json`, asserting the emitted source
/// contains the expected struct/newtype declarations, CodingKeys, and
/// AbsolutePath/LineNumber wire-invariant field mappings.
@Suite struct GeneratorCoreTests {
    /// A miniature schema exercising every shape the generator core handles:
    /// an ID newtype, object structs with required/optional/forgiving fields,
    /// wire-invariant path/line fields, a deferred union, and the hand-written
    /// `ProtocolVersion`.
    private static let miniatureSchema = Data(
        """
        {
          "$defs": {
            "SessionId": {
              "description": "A unique identifier for a conversation session.",
              "type": "string"
            },
            "ProtocolVersion": {
              "description": "The protocol version.",
              "type": "integer",
              "format": "uint16"
            },
            "McpServer": {
              "description": "Configuration for connecting to an MCP server.",
              "anyOf": [
                { "$ref": "#/$defs/EnvVariable" }
              ]
            },
            "EnvVariable": {
              "description": "An environment variable to set.",
              "type": "object",
              "properties": {
                "name": { "description": "The variable name.", "type": "string" },
                "value": { "description": "The variable value.", "type": "string" },
                "_meta": {
                  "type": ["object", "null"],
                  "x-deserialize-default-on-error": true,
                  "additionalProperties": true
                }
              },
              "required": ["name", "value"]
            },
            "NewSessionRequest": {
              "description": "Request parameters for creating a new session.",
              "type": "object",
              "properties": {
                "cwd": {
                  "description": "The working directory. Must be an absolute path.",
                  "type": "string"
                },
                "additionalDirectories": {
                  "description": "Additional workspace roots. Each path must be absolute.",
                  "type": "array",
                  "items": { "type": "string" },
                  "x-deserialize-default-on-error": true,
                  "x-deserialize-skip-invalid-items": true
                },
                "mcpServers": {
                  "description": "MCP servers to connect to.",
                  "type": "array",
                  "items": { "$ref": "#/$defs/McpServer" },
                  "x-deserialize-default-on-error": true,
                  "x-deserialize-skip-invalid-items": true
                },
                "_meta": {
                  "type": ["object", "null"],
                  "x-deserialize-default-on-error": true,
                  "additionalProperties": true
                }
              },
              "required": ["cwd", "mcpServers"],
              "x-side": "agent",
              "x-method": "session/new"
            },
            "ToolCallLocation": {
              "description": "A file location being accessed by a tool.",
              "type": "object",
              "properties": {
                "path": {
                  "description": "The absolute file path being accessed.",
                  "type": "string"
                },
                "line": {
                  "description": "Optional line number within the file.",
                  "type": ["integer", "null"],
                  "format": "uint32",
                  "minimum": 0,
                  "x-deserialize-default-on-error": true
                }
              },
              "required": ["path"]
            },
            "FileSystemCapabilities": {
              "description": "File system capabilities a client may support.",
              "type": "object",
              "properties": {
                "readTextFile": {
                  "description": "Whether fs/read_text_file is supported.",
                  "type": "boolean",
                  "default": false,
                  "x-deserialize-default-on-error": true
                }
              }
            }
          }
        }
        """.utf8)

    /// Generates from the miniature schema and returns the file contents by name.
    ///
    /// - Parameter name: The generated file name to look up.
    /// - Returns: The Swift source text of that file.
    /// - Throws: A test failure when generation fails or the file is missing.
    private func miniatureOutput(named name: String) throws -> String {
        let files = try SchemaGenerator().generate(schemaJSON: Self.miniatureSchema)
        let file = files.first { $0.name == name }
        return try #require(file, "expected generated file \(name)").contents
    }

    @Test func identifierNewtypeIsDistinctWireRawValueStruct() throws {
        let source = try miniatureOutput(named: "Identifiers.generated.swift")
        #expect(source.contains("public struct SessionId: WireRawValueCodable, Hashable, Sendable"))
        #expect(source.contains("public let rawValue: String"))
        #expect(source.contains("public init(rawValue: String)"))
    }

    @Test func objectStructHasExplicitCodingKeysWithWireNames() throws {
        let source = try miniatureOutput(named: "Models.generated.swift")
        #expect(source.contains("public struct EnvVariable: Codable, Hashable, Sendable"))
        #expect(source.contains("enum CodingKeys: String, CodingKey"))
        #expect(source.contains("case meta = \"_meta\""))
        #expect(source.contains("public var meta: JSONValue?"))
    }

    @Test func wireInvariantFieldsUseAbsolutePathAndLineNumber() throws {
        let source = try miniatureOutput(named: "Models.generated.swift")
        #expect(source.contains("public var cwd: AbsolutePath"))
        #expect(source.contains("public var additionalDirectories: [AbsolutePath]?"))
        #expect(source.contains("public var path: AbsolutePath"))
        #expect(source.contains("public var line: LineNumber?"))
    }

    @Test func wireInvariantFieldsDecodeStrictlyDespiteForgivingAnnotation() throws {
        let source = try miniatureOutput(named: "Models.generated.swift")
        // Invariant-mapped fields must not go through the forgiving helpers:
        // a relative path or 0 line is a decode error, never a silent default.
        #expect(source.contains("try container.decode(AbsolutePath.self, forKey: .cwd)"))
        #expect(source.contains("try container.decodeIfPresent(LineNumber.self, forKey: .line)"))
        #expect(source.contains("try container.decodeIfPresent([AbsolutePath].self, forKey: .additionalDirectories)"))
    }

    @Test func forgivingFieldsDecodeThroughForgivingHelpers() throws {
        let source = try miniatureOutput(named: "Models.generated.swift")
        #expect(source.contains("container.forgivingDecode(Bool.self, forKey: .readTextFile, default: false)"))
        #expect(source.contains("container.forgivingDecodeArrayIfPresent(of: McpServer.self, forKey: .mcpServers)")
            || source.contains("container.forgivingDecodeArray(of: McpServer.self, forKey: .mcpServers)"))
        #expect(source.contains("container.forgivingDecodeIfPresent(JSONValue.self, forKey: .meta)"))
    }

    @Test func encodeOmitsNilOptionalsViaEncodeIfPresent() throws {
        let source = try miniatureOutput(named: "Models.generated.swift")
        #expect(source.contains("try container.encodeIfPresent(meta, forKey: .meta)"))
        #expect(source.contains("try container.encode(cwd, forKey: .cwd)"))
    }

    @Test func handwrittenProtocolVersionIsNotEmitted() throws {
        let files = try SchemaGenerator().generate(schemaJSON: Self.miniatureSchema)
        for file in files {
            #expect(
                !file.contents.contains("struct ProtocolVersion"),
                "ProtocolVersion is hand-written in Core and must not be re-emitted"
            )
            #expect(!file.contents.contains("typealias ProtocolVersion"))
        }
    }

    @Test func deferredUnionEmitsPlaceholderTypealiasSeam() throws {
        let source = try miniatureOutput(named: "Unresolved.generated.swift")
        #expect(source.contains("public typealias McpServer = JSONValue"))
    }

    @Test func objectDefaultMismatchingTargetDefaultsFailsLoudly() throws {
        // `fs` declares default {"readTextFile": true} but FileSystemCapabilities'
        // own default is false — rendering `FileSystemCapabilities()` would
        // silently encode the wrong default, so generation must throw.
        let schema = Data(
            """
            {
              "$defs": {
                "FileSystemCapabilities": {
                  "type": "object",
                  "properties": {
                    "readTextFile": {
                      "type": "boolean",
                      "default": false,
                      "x-deserialize-default-on-error": true
                    }
                  }
                },
                "ClientCapabilities": {
                  "type": "object",
                  "properties": {
                    "fs": {
                      "x-deserialize-default-on-error": true,
                      "default": { "readTextFile": true },
                      "allOf": [{ "$ref": "#/$defs/FileSystemCapabilities" }]
                    }
                  }
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func nonEmptyFreeFormObjectDefaultFailsLoudly() throws {
        // A JSONValue-typed field whose object default has members cannot be
        // rendered as `.object([:])` without losing data — must throw.
        let schema = Data(
            """
            {
              "$defs": {
                "Extras": {
                  "type": "object",
                  "properties": {
                    "blob": {
                      "type": "object",
                      "additionalProperties": true,
                      "default": { "a": 1 },
                      "x-deserialize-default-on-error": true
                    }
                  }
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    // MARK: - Full vendored schema

    /// The package-root `Schema/acp-v1.json`, located relative to this file.
    private static let vendoredSchemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GeneratorCoreTests.swift
        .deletingLastPathComponent()  // ACPGenerateTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Schema")
        .appendingPathComponent("acp-v1.json")

    @Test func vendoredSchemaGeneratesExpectedDeclarations() throws {
        let data = try Data(contentsOf: Self.vendoredSchemaURL)
        let files = try SchemaGenerator().generate(schemaJSON: data)
        let all = files.map(\.contents).joined()
        #expect(all.contains("public struct InitializeResponse: Codable, Hashable, Sendable"))
        #expect(all.contains("public struct ToolCallId: WireRawValueCodable, Hashable, Sendable"))
        // `Error` collides with Swift.Error and is renamed via generator config.
        #expect(all.contains("public struct ACPError"))
        #expect(!all.contains("public struct Error"))
    }

    @Test func vendoredSchemaGenerationIsDeterministic() throws {
        let data = try Data(contentsOf: Self.vendoredSchemaURL)
        let first = try SchemaGenerator().generate(schemaJSON: data)
        let second = try SchemaGenerator().generate(schemaJSON: data)
        #expect(first == second)
    }
}
