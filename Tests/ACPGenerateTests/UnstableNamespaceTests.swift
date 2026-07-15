import Foundation
import Testing

@testable import ACPGenerateCore

/// Splits the emitted method-table source at the `Unstable` namespace.
///
/// - Returns: The stable-table prefix and the `Unstable` namespace suffix.
/// - Throws: A test failure when the emitted source has no `Unstable`
///   namespace.
private func stableAndUnstableSections() throws -> (stable: Substring, unstable: Substring) {
    let source = try vendoredOutput(named: "MethodTable.generated.swift")
    let marker = "public enum Unstable {"
    let split = try #require(source.range(of: marker), "expected an Unstable namespace in the emitted table")
    return (source[..<split.lowerBound], source[split.lowerBound...])
}

/// The wire methods present only in the unstable manifest, per side group.
///
/// - Returns: Group name → the unstable-only wire method names.
/// - Throws: A test failure when either vendored manifest cannot be loaded.
private func unstableOnlyMethods() throws -> [String: Set<String>] {
    let stable = try routingGroups(from: vendoredMetaURL)
    let unstable = try routingGroups(from: vendoredUnstableMetaURL)
    var difference: [String: Set<String>] = [:]
    for (group, methods) in unstable {
        let stableWires = Set((stable[group] ?? [:]).values)
        difference[group] = Set(methods.values).subtracting(stableWires)
    }
    return difference
}

/// Unstable methods are emitted only inside the `Unstable` namespace, and the
/// stable table never leaks into it.
@Suite struct UnstableNamespaceTests {
    @Test func unstableOnlyMethodsAreEmittedInsideTheUnstableNamespace() throws {
        let sections = try stableAndUnstableSections()
        for (group, wires) in try unstableOnlyMethods() {
            for wire in wires {
                let fragment = "wireMethod: \"\(wire)\","
                #expect(
                    sections.unstable.contains(fragment),
                    "expected \(group) method \(wire) inside the Unstable namespace"
                )
                #expect(
                    !sections.stable.contains(fragment),
                    "unstable \(group) method \(wire) leaked into the stable table"
                )
            }
        }
    }

    @Test func expectedUnstableFamiliesArePresent() throws {
        let sections = try stableAndUnstableSections()
        for wire in [
            "elicitation/create", "providers/list", "session/fork",
            "nes/start", "mcp/message", "document/didOpen",
        ] {
            #expect(
                sections.unstable.contains("wireMethod: \"\(wire)\","),
                "expected unstable method \(wire)"
            )
        }
    }

    @Test func stableMethodsDoNotAppearInTheUnstableNamespace() throws {
        let sections = try stableAndUnstableSections()
        for (group, methods) in try routingGroups(from: vendoredMetaURL) {
            for wire in methods.values {
                #expect(
                    !sections.unstable.contains("wireMethod: \"\(wire)\","),
                    "stable \(group) method \(wire) leaked into the Unstable namespace"
                )
            }
        }
    }

    @Test func unstableEntriesCarryHandlerAndSideOnly() throws {
        let sections = try stableAndUnstableSections()
        let entry = """
                    UnstableMethodInfo(
                        wireMethod: "session/fork",
                        handlerName: "sessionFork",
                        side: .agent
                    ),
        """
        #expect(sections.unstable.contains(entry))
    }

    @Test func methodsServedOnBothSidesGetOneEntryPerSide() throws {
        let sections = try stableAndUnstableSections()
        // The unstable manifest routes mcp/message on both sides.
        for side in ["agent", "client"] {
            let entry = """
                        UnstableMethodInfo(
                            wireMethod: "mcp/message",
                            handlerName: "mcpMessage",
                            side: .\(side)
                        ),
            """
            #expect(sections.unstable.contains(entry), "expected an mcp/message entry on the \(side) side")
        }
    }

    @Test func unstableNamespaceIsDocumentedAsUnsettled() throws {
        let source = try vendoredOutput(named: "MethodTable.generated.swift")
        // The namespace's doc comment (which precedes the declaration) must
        // warn that the surface is unsettled and capability-gated.
        #expect(source.contains("public enum Unstable {"))
        #expect(source.contains("unsettled"))
        #expect(source.contains("capabilit"))
    }
}
