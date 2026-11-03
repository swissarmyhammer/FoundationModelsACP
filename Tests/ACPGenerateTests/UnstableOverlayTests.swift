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
