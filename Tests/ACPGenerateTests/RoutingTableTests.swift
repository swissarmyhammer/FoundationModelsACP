import Foundation
import Testing

@testable import ACPGenerateCore

/// Emitted-source assertions for the stable method-routing table.
///
/// The table is derived from the vendored routing manifest plus the schema's
/// `x-side`/`x-method` annotations — never hand-wired.
@Suite struct RoutingTableEmissionTests {
    @Test func schemaOnlyGenerationOmitsTheMethodTable() throws {
        let schema = #"{"$defs": {}}"#
        let files = try SchemaGenerator().generate(schemaJSON: Data(schema.utf8))
        #expect(!files.contains { $0.name == "MethodTable.generated.swift" })
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
