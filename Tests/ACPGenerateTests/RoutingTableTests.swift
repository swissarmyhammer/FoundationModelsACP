import Foundation
import Testing

@testable import ACPGenerateCore
import FoundationModelsACP

/// Emitted-source assertions for the stable method-routing table.
///
/// The table is derived from the vendored routing manifest plus the schema's
/// `x-side`/`x-method` annotations — never hand-wired.
@Suite struct RoutingTableEmissionTests {
    @Test func schemaOnlyGenerationOmitsTheMethodTable() throws {
        // An explicit empty config: `.acpV2`'s default carries a
        // `patchSemanticsFields` table validated against schema content,
        // which this empty schema does not declare.
        let schema = #"{"$defs": {}}"#
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Data(schema.utf8))
        #expect(!files.contains { $0.name == "MethodTable.generated.swift" })
    }

    @Test func manifestVersionIsConfigured() throws {
        // Upstream sets the manifest's `version` to the ACP protocol major
        // version, so it moves with every protocol bump. Which value to accept
        // is configuration, not a constant compiled into the generator.
        let manifest = #"""
            {
              "version": 7,
              "agentMethods": {"widget_frob": "widget/frob"},
              "clientMethods": {},
              "protocolMethods": {}
            }
            """#
        let files = try SchemaGenerator(config: GeneratorConfig(manifestVersion: 7)).generate(
            schemaJSON: Data(syntheticSchema.utf8),
            metaJSON: Data(manifest.utf8)
        )
        let table = try #require(files.first { $0.name == "MethodTable.generated.swift" }).contents
        #expect(table.contains(#"wireMethod: "widget/frob""#))
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

    @Test func responseWithoutRequestFails() {
        // The symmetric case: a lone Response, with no paired Request, is
        // just as malformed a route as a lone Request with no Response.
        let schema = #"""
            {
              "$defs": {
                "FrobWidgetResponse": {"type": "object", "properties": {}, "x-side": "agent", "x-method": "widget/frob"}
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
        // A manifest declaring a version this configuration does not expect is
        // rejected rather than parsed hopefully.
        let manifest = #"""
            {
              "version": 99,
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

/// Runtime acceptance for the checked-in `MethodTable.generated.swift`
/// compiled into the library.
///
/// This is the regression guard for the wrong-wiring bug class this package
/// exists to prevent: the TS-SDK bound `setSessionModel` to `session/set_mode`
/// — a right name on the wrong handler. Because the table is generated from
/// the vendored manifest and schema rather than hand-wired, that particular
/// mistake cannot be made by hand; this suite is what would have caught it if
/// it ever could be.
@Suite struct RoutingTableAcceptanceTests {
    /// The package root, derived from this file's location.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RoutingTableTests.swift
            .deletingLastPathComponent()  // ACPGenerateTests
            .deletingLastPathComponent()  // Tests
    }

    /// The checked-in generated table, located relative to this file.
    private var checkedInTableURL: URL {
        packageRoot.appendingPathComponent("Sources/FoundationModelsACP/Generated/MethodTable.generated.swift")
    }

    @Test func checkedInTableMatchesFreshGeneration() throws {
        let set = SchemaSet.acpV2
        func artifact(_ treeRelativePath: String) throws -> Data {
            try Data(contentsOf: packageRoot.appendingPathComponent(treeRelativePath))
        }
        let files = try SchemaGenerator(config: set.config).generate(
            schemaJSON: try artifact(set.schemaPath),
            metaJSON: try artifact(#require(set.metaPath)),
            unstableMetaJSON: try artifact(#require(set.unstableMetaPath)),
            namespace: set.outputNamespace
        )
        let fresh = try #require(files.first { $0.name == "MethodTable.generated.swift" }).contents
        let checkedIn = String(decoding: try Data(contentsOf: checkedInTableURL), as: UTF8.self)
        #expect(fresh == checkedIn, "checked-in table is stale; run swift run acp-generate")
    }

    @Test func compiledTableCoversBothSidesAndKinds() {
        // Every cell of the (side × kind) matrix, not just three of the four:
        // agent+request, client+notification, agent+notification, and
        // protocolLevel+notification leave client+request unchecked unless
        // `session/request_permission` — the only client request — is pinned
        // too.
        let byWire = Dictionary(uniqueKeysWithValues: ACPMethodTable.methods.map { ($0.wireMethod, $0) })
        #expect(byWire["session/prompt"]?.side == .agent)
        #expect(byWire["session/prompt"]?.kind == .request)
        #expect(byWire["session/update"]?.side == .client)
        #expect(byWire["session/update"]?.kind == .notification)
        #expect(byWire["session/request_permission"]?.side == .client)
        #expect(byWire["session/request_permission"]?.kind == .request)
        #expect(byWire["session/cancel"]?.side == .agent)
        #expect(byWire["session/cancel"]?.kind == .notification)
        #expect(byWire["$/cancel_request"]?.side == .protocolLevel)
        #expect(byWire["$/cancel_request"]?.kind == .notification)
    }

    @Test func compiledUnstableTableIsDisjointFromStable() {
        let stable = Set(ACPMethodTable.methods.map { SideAndWire(side: $0.side, wireMethod: $0.wireMethod) })
        let unstable = Set(Unstable.MethodTable.methods.map { SideAndWire(side: $0.side, wireMethod: $0.wireMethod) })
        #expect(!stable.isEmpty)
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
