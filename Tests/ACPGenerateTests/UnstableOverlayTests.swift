import Foundation
import Testing

@testable import ACPGenerateCore

/// `GeneratorConfig.unstableOverlay` takes named definitions and named union
/// variants from the unstable document, and nothing else.
@Suite struct UnstableOverlayTests {
    private static let payloads = """
        "A":{"type":"object","properties":{"x":{"type":"string"}},"required":["x"]},
        "B":{"type":"object","properties":{"y":{"type":"string"}},"required":["y"]},
        """

    private static func variant(_ tag: String, payload: String) -> String {
        """
        {"type":"object","properties":{"kind":{"type":"string","const":"\(tag)"}},"required":["kind"],"allOf":[{"$ref":"#/$defs/\(payload)"}]}
        """
    }

    private static func catchAll(excluding tags: [String]) -> String {
        let excluded = tags.map {
            #"{"type":"object","properties":{"kind":{"type":"string","const":"\#($0)"}},"required":["kind"]}"#
        }.joined(separator: ",")
        return """
            {"type":"object","properties":{"kind":{"type":"string"}},"required":["kind"],"not":{"anyOf":[\(excluded)]},"additionalProperties":true}
            """
    }

    private static let stable = Data("""
        {"$defs":{\(payloads)"Update":{"description":"d","oneOf":[\(variant("a", payload: "A")),\(catchAll(excluding: ["a"]))]}}}
        """.utf8)

    private static let unstable = Data("""
        {"$defs":{\(payloads)
          "Update":{"description":"d","oneOf":[\(variant("a", payload: "A")),\(variant("b", payload: "B")),\(catchAll(excluding: ["a", "b"]))]},
          "Extra":{"description":"e","type":"object","properties":{"n":{"type":"string"}},"required":["n"]}
        }}
        """.utf8)

    private func generate(_ overlay: GeneratorConfig.UnstableOverlay, unstable: Data? = unstable) throws -> String {
        let files = try SchemaGenerator(config: GeneratorConfig(unstableOverlay: overlay))
            .generate(schemaJSON: Self.stable, unstableSchemaJSON: unstable)
        return files.map(\.contents).joined(separator: "\n")
    }

    @Test func anEmptyOverlayEmitsOnlyTheStableSurface() throws {
        let source = try generate(.init())
        #expect(!source.contains("struct Extra"))
        #expect(!source.contains("case b("))
    }

    @Test func aNamedDefinitionAndAVariantAreEmitted() throws {
        let source = try generate(.init(definitions: ["Extra"], variants: ["Update": ["b"]]))
        #expect(source.contains("public struct Extra:"))
        #expect(source.contains("case b("))
    }

    @Test func aNamedVariantComesBeforeTheCatchAll() throws {
        let source = try generate(.init(variants: ["Update": ["b"]]))
        let known = try #require(source.range(of: "case b("))
        let fallback = try #require(source.range(of: "case unknown("))
        #expect(known.lowerBound < fallback.lowerBound)
    }

    @Test func anOverlayWithoutTheUnstableDocumentFails() {
        #expect(throws: GeneratorError.self) {
            _ = try generate(.init(definitions: ["Extra"]), unstable: nil)
        }
    }

    @Test(arguments: [
        GeneratorConfig.UnstableOverlay(definitions: ["Missing"]),
        GeneratorConfig.UnstableOverlay(definitions: ["Update"]),
        GeneratorConfig.UnstableOverlay(variants: ["Update": ["missing"]]),
        GeneratorConfig.UnstableOverlay(variants: ["Update": ["a"]]),
        GeneratorConfig.UnstableOverlay(variants: ["Nope": ["b"]]),
    ])
    func anOverlayThatNamesSomethingWrongFailsLoudly(overlay: GeneratorConfig.UnstableOverlay) {
        #expect(throws: GeneratorError.self) {
            _ = try generate(overlay)
        }
    }
}

/// `GeneratorConfig.UnstableOverlay.members` adds a property to a stable
/// definition, and `methods` routes an unstable method with its types.
@Suite struct UnstableOverlayMemberAndMethodTests {
    private static let stable = Data(#"""
        {"$defs":{
          "Caps":{"type":"object","properties":{"a":{"type":"boolean"}}},
          "PingRequest":{"type":"object","properties":{},"x-side":"agent","x-method":"session/ping"},
          "PingResponse":{"type":"object","properties":{},"x-side":"agent","x-method":"session/ping"}
        }}
        """#.utf8)

    private static let unstable = Data(#"""
        {"$defs":{
          "Caps":{"type":"object","properties":{"a":{"type":"boolean"},"fork":{"anyOf":[{"$ref":"#/$defs/ForkCaps"},{"type":"null"}]}}},
          "ForkCaps":{"type":"object","properties":{"n":{"type":"string"}}},
          "ForkRequest":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"x-side":"agent","x-method":"session/fork"},
          "ForkResponse":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"x-side":"agent","x-method":"session/fork"}
        }}
        """#.utf8)

    private static let meta = Data(#"""
        {"version":1,"agentMethods":{"ping":"session/ping"},"clientMethods":{},"protocolMethods":{}}
        """#.utf8)

    private static let unstableMeta = Data(#"""
        {"version":1,"agentMethods":{"ping":"session/ping","session_fork":"session/fork","other":"session/other"},"clientMethods":{},"protocolMethods":{}}
        """#.utf8)

    private static let forkOverlay = GeneratorConfig.UnstableOverlay(
        definitions: ["ForkCaps", "ForkRequest", "ForkResponse"],
        members: ["Caps": ["fork"]],
        methods: ["session/fork"]
    )

    private func generate(_ overlay: GeneratorConfig.UnstableOverlay, unstableMeta: Data? = unstableMeta) throws -> String {
        let files = try SchemaGenerator(config: GeneratorConfig(unstableOverlay: overlay)).generate(
            schemaJSON: Self.stable,
            unstableSchemaJSON: Self.unstable,
            metaJSON: Self.meta,
            unstableMetaJSON: unstableMeta
        )
        return files.map(\.contents).joined(separator: "\n")
    }

    @Test func aMemberIsAddedToTheStableDefinition() throws {
        let source = try generate(Self.forkOverlay)
        #expect(source.contains("public var fork: ForkCaps?"))
        #expect(source.contains("public var a: Bool?"))
    }

    @Test func aMethodRoutesWithItsTypesAndLeavesTheUnstableNamespace() throws {
        let source = try generate(Self.forkOverlay)
        #expect(source.contains(#"wireMethod: "session/fork""#))
        #expect(source.contains(#"paramsTypeName: "ForkRequest""#))
        #expect(source.contains(#"resultTypeName: "ForkResponse""#))
        let unstableSection = try #require(source.range(of: "public enum Unstable {")).upperBound
        #expect(!source[unstableSection...].contains("session/fork"))
        #expect(source[unstableSection...].contains("session/other"))
    }

    @Test(arguments: [
        GeneratorConfig.UnstableOverlay(definitions: ["ForkCaps"], members: ["Caps": ["missing"]]),
        GeneratorConfig.UnstableOverlay(definitions: ["ForkCaps"], members: ["Caps": ["a"]]),
        GeneratorConfig.UnstableOverlay(definitions: ["ForkCaps"], members: ["Nope": ["fork"]]),
        GeneratorConfig.UnstableOverlay(definitions: ["ForkRequest", "ForkResponse"], methods: ["session/missing"]),
        GeneratorConfig.UnstableOverlay(methods: ["session/ping"]),
    ])
    func anOverlayThatNamesAWrongMemberOrMethodFailsLoudly(overlay: GeneratorConfig.UnstableOverlay) {
        #expect(throws: GeneratorError.self) {
            _ = try generate(overlay)
        }
    }

    @Test func aMethodWithoutTheUnstableManifestFails() {
        #expect(throws: GeneratorError.self) {
            _ = try generate(Self.forkOverlay, unstableMeta: nil)
        }
    }

    @Test func theTypesWithoutTheMethodFailBecauseNothingRoutesThem() {
        // The copied definitions carry the route annotations, so the
        // double-entry check refuses them when the overlay does not route
        // the method.
        #expect(throws: GeneratorError.self) {
            _ = try generate(.init(definitions: ["ForkRequest", "ForkResponse"]))
        }
    }
}
