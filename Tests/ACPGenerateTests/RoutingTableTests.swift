import Foundation
import FoundationModelsACP
import Testing

@testable import ACPGenerateCore

/// Counts non-overlapping occurrences of a fragment in the source.
///
/// - Parameters:
///   - fragment: The text to count.
///   - source: The emitted Swift source to scan.
/// - Returns: The number of occurrences.
private func occurrences(of fragment: String, in source: String) -> Int {
    guard !fragment.isEmpty else { return 0 }
    var count = 0
    var searchRange = source.startIndex..<source.endIndex
    while let found = source.range(of: fragment, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<source.endIndex
    }
    return count
}

/// Emitted-source assertions for the stable method-routing table.
///
/// The table is derived from `Schema/acp-v1.meta.json` plus the schema's
/// `x-side`/`x-method` annotations — never hand-wired.
@Suite struct RoutingTableEmissionTests {
    @Test func sessionPromptRoutesAsAgentRequest() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        let entry = """
                MethodInfo(
                    wireMethod: "session/prompt",
                    handlerName: "prompt",
                    side: .agent,
                    kind: .request,
                    paramsTypeName: "PromptRequest",
                    resultTypeName: "PromptResponse",
                    deprecationMessage: nil
                ),
        """
        #expect(source.contains(entry))
    }

    @Test func sessionUpdateRoutesAsClientNotification() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        let entry = """
                MethodInfo(
                    wireMethod: "session/update",
                    handlerName: "sessionUpdate",
                    side: .client,
                    kind: .notification,
                    paramsTypeName: "SessionNotification",
                    resultTypeName: nil,
                    deprecationMessage: nil
                ),
        """
        #expect(source.contains(entry))
    }

    @Test func requestHandlerNamesDeriveFromDefinitionNames() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        // NewSessionRequest → newSession, ReadTextFileRequest → readTextFile,
        // CreateTerminalRequest → createTerminal: the pair's shared base name
        // is the handler, not a camelization of the wire method.
        for (wire, handler) in [
            ("session/new", "newSession"),
            ("fs/read_text_file", "readTextFile"),
            ("terminal/create", "createTerminal"),
        ] {
            let fragment = """
                        wireMethod: "\(wire)",
                        handlerName: "\(handler)",
            """
            #expect(source.contains(fragment), "expected \(wire) to route to handler \(handler)")
        }
    }

    @Test func cancellationRoutesOnBothLevels() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        let sessionCancel = """
                MethodInfo(
                    wireMethod: "session/cancel",
                    handlerName: "sessionCancel",
                    side: .agent,
                    kind: .notification,
                    paramsTypeName: "CancelNotification",
                    resultTypeName: nil,
                    deprecationMessage: nil
                ),
        """
        #expect(source.contains(sessionCancel))
        let cancelRequest = """
                MethodInfo(
                    wireMethod: "$/cancel_request",
                    handlerName: "cancelRequest",
                    side: .protocolLevel,
                    kind: .notification,
                    paramsTypeName: "CancelRequestNotification",
                    resultTypeName: nil,
                    deprecationMessage: nil
                ),
        """
        #expect(source.contains(cancelRequest))
    }

    @Test func everyStableManifestMethodIsEmittedExactlyOnce() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        let groups = try routingGroups(from: vendoredMetaURL)
        for (group, methods) in groups {
            for wire in methods.values {
                #expect(
                    occurrences(of: "wireMethod: \"\(wire)\",", in: source) == 1,
                    "expected exactly one entry for \(group) method \(wire)"
                )
            }
        }
    }

    @Test func setSessionModeCarriesDeprecationMarker() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        let message = try #require(
            GeneratorConfig.acpV1.deprecatedMethods["session/set_mode"],
            "acp-v1 config must deprecate session/set_mode"
        )
        let fragment = """
                    wireMethod: "session/set_mode",
                    handlerName: "setSessionMode",
                    side: .agent,
                    kind: .request,
                    paramsTypeName: "SetSessionModeRequest",
                    resultTypeName: "SetSessionModeResponse",
                    deprecationMessage: "\(message)"
        """
        #expect(source.contains(fragment))
    }

    @Test func schemaOnlyGenerationOmitsTheMethodTable() throws {
        let schema = #"{"$defs": {}}"#
        let files = try SchemaGenerator().generate(schemaJSON: Data(schema.utf8))
        #expect(!files.contains { $0.name == "MethodTable.generated.swift" })
    }
}

/// Runtime acceptance for the checked-in `MethodTable.generated.swift`
/// compiled into the library.
@Suite struct RoutingTableAcceptanceTests {
    /// The checked-in generated table, located relative to this file.
    private var checkedInTableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RoutingTableTests.swift
            .deletingLastPathComponent()  // ACPGenerateTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Sources/FoundationModelsACP/Generated/MethodTable.generated.swift")
    }

    @Test func checkedInTableMatchesFreshGeneration() throws {
        let fresh = try vendoredOutput(named: "MethodTable.generated.swift")
        let checkedIn = String(decoding: try Data(contentsOf: checkedInTableURL), as: UTF8.self)
        #expect(fresh == checkedIn, "checked-in table is stale; run swift run acp-generate")
    }

    @Test func compiledTableCoversBothSidesAndKinds() {
        let byWire = Dictionary(uniqueKeysWithValues: ACPMethodTable.methods.map { ($0.wireMethod, $0) })
        #expect(byWire["session/prompt"]?.side == .agent)
        #expect(byWire["session/prompt"]?.kind == .request)
        #expect(byWire["session/update"]?.side == .client)
        #expect(byWire["session/update"]?.kind == .notification)
        #expect(byWire["$/cancel_request"]?.side == .protocolLevel)
        #expect(byWire["session/set_mode"]?.deprecationMessage != nil)
    }

    @Test func compiledUnstableTableIsDisjointFromStable() {
        let stable = Set(ACPMethodTable.methods.map { SideAndWire(side: $0.side, wireMethod: $0.wireMethod) })
        let unstable = Set(Unstable.MethodTable.methods.map { SideAndWire(side: $0.side, wireMethod: $0.wireMethod) })
        #expect(!unstable.isEmpty)
        #expect(stable.isDisjoint(with: unstable))
    }

    /// A (side, wire method) routing coordinate for disjointness checks.
    private struct SideAndWire: Hashable {
        /// The serving participant.
        let side: MethodSide

        /// The wire method name.
        let wireMethod: String
    }
}

/// A minimal schema whose only routed method is `widget/frob` on the agent
/// side, for fail-loud routing tests.
private let syntheticSchema = #"""
    {
      "$defs": {
        "FrobWidgetRequest": {"type": "object", "properties": {}, "x-side": "agent", "x-method": "widget/frob"},
        "FrobWidgetResponse": {"type": "object", "properties": {}, "x-side": "agent", "x-method": "widget/frob"}
      }
    }
    """#

/// A manifest routing exactly `widget/frob` on the agent side.
private let syntheticManifest = #"""
    {
      "version": 1,
      "agentMethods": {"widget_frob": "widget/frob"},
      "clientMethods": {},
      "protocolMethods": {}
    }
    """#

/// Fail-loud behavior: any disagreement between the routing manifest and the
/// schema's `x-side`/`x-method` annotations aborts generation.
@Suite struct RoutingTableValidationTests {
    /// Runs generation over a synthetic schema/manifest pair, expecting a
    /// `GeneratorError`.
    ///
    /// - Parameters:
    ///   - schema: The schema document JSON.
    ///   - manifest: The stable routing manifest JSON.
    ///   - unstableManifest: The unstable routing manifest JSON, if any.
    ///   - config: The generator configuration; defaults to an empty one.
    private func expectGenerationFails(
        schema: String,
        manifest: String?,
        unstableManifest: String? = nil,
        config: GeneratorConfig = GeneratorConfig()
    ) {
        #expect(throws: GeneratorError.self) {
            try SchemaGenerator(config: config).generate(
                schemaJSON: Data(schema.utf8),
                metaJSON: manifest.map { Data($0.utf8) },
                unstableMetaJSON: unstableManifest.map { Data($0.utf8) }
            )
        }
    }

    @Test func manifestMethodWithoutSchemaDefinitionsFails() {
        let manifest = #"""
            {
              "version": 1,
              "agentMethods": {"widget_frob": "widget/frob", "widget_zap": "widget/zap"},
              "clientMethods": {},
              "protocolMethods": {}
            }
            """#
        expectGenerationFails(schema: syntheticSchema, manifest: manifest)
    }

    @Test func schemaMethodMissingFromManifestFails() {
        let manifest = #"""
            {
              "version": 1,
              "agentMethods": {},
              "clientMethods": {},
              "protocolMethods": {}
            }
            """#
        expectGenerationFails(schema: syntheticSchema, manifest: manifest)
    }

    @Test func requestWithoutResponseFails() {
        let schema = #"""
            {
              "$defs": {
                "FrobWidgetRequest": {"type": "object", "properties": {}, "x-side": "agent", "x-method": "widget/frob"}
              }
            }
            """#
        expectGenerationFails(schema: schema, manifest: syntheticManifest)
    }

    @Test func sideDisagreementBetweenManifestAndSchemaFails() {
        let manifest = #"""
            {
              "version": 1,
              "agentMethods": {},
              "clientMethods": {"widget_frob": "widget/frob"},
              "protocolMethods": {}
            }
            """#
        expectGenerationFails(schema: syntheticSchema, manifest: manifest)
    }

    @Test func staleDeprecationConfigFails() {
        let config = GeneratorConfig(deprecatedMethods: ["widget/zap": "gone"])
        expectGenerationFails(schema: syntheticSchema, manifest: syntheticManifest, config: config)
    }

    @Test func unsupportedManifestVersionFails() {
        let manifest = #"""
            {
              "version": 2,
              "agentMethods": {"widget_frob": "widget/frob"},
              "clientMethods": {},
              "protocolMethods": {}
            }
            """#
        expectGenerationFails(schema: syntheticSchema, manifest: manifest)
    }

    @Test func unknownManifestGroupFails() {
        let manifest = #"""
            {
              "version": 1,
              "agentMethods": {"widget_frob": "widget/frob"},
              "clientMethods": {},
              "protocolMethods": {},
              "serverMethods": {}
            }
            """#
        expectGenerationFails(schema: syntheticSchema, manifest: manifest)
    }

    @Test func unstableManifestWithoutStableManifestFails() {
        expectGenerationFails(
            schema: syntheticSchema,
            manifest: nil,
            unstableManifest: syntheticManifest
        )
    }
}
