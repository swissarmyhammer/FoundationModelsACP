import Foundation
import Testing

@testable import ACPGenerateCore

/// Emission assertions driven by the **real vendored artifacts** under
/// `Schema/`, not by a synthetic fixture.
///
/// The synthetic suites prove the generator's stages in isolation; these prove
/// that the vendored ACP v2 document actually flows through them and that the
/// checked-in output under `Sources/FoundationModelsACP/Generated/` is exactly
/// what a fresh run produces.
///
/// That last check is the CI codegen diff gate, runnable locally: hand-edit a
/// generated file and this suite fails. It is also strictly stronger than the
/// gate, because it ignores the content-hash stamp. `acp-generate` skips
/// regeneration whenever the vendored artifacts are unchanged, so a change to
/// the *generator* leaves the checked-in output stale and the diff gate silent;
/// generating in memory on every run catches that too.
@Suite struct VendoredSchemaTests {
    /// The package root, derived from this file's location so the suite does
    /// not depend on the test runner's working directory.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ACPGenerateTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    /// Reads a tree-relative file from the package.
    ///
    /// - Parameter treeRelativePath: The path relative to the package root.
    /// - Returns: The file's bytes.
    /// - Throws: An error when the file cannot be read.
    private static func packageFile(_ treeRelativePath: String) throws -> Data {
        try Data(contentsOf: packageRoot.appendingPathComponent(treeRelativePath))
    }

    /// The vendored set under test — the primary set, emitted at the top level.
    private static let set = SchemaSet.acpV2

    /// Generates from the vendored artifacts exactly as `acp-generate` does.
    ///
    /// - Returns: The generated files, keyed by file name.
    /// - Throws: `GeneratorError` when generation fails, or an error when an
    ///   artifact cannot be read.
    private static func generateFromVendoredArtifacts() throws -> [String: String] {
        let files = try SchemaGenerator(config: set.config).generate(
            schemaJSON: try packageFile(set.schemaPath),
            metaJSON: try packageFile(#require(set.metaPath)),
            unstableMetaJSON: try packageFile(#require(set.unstableMetaPath)),
            namespace: set.outputNamespace
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.contents) })
    }

    @Test func primarySetIsTheTopLevelVendoredV2Artifacts() throws {
        #expect(Self.set.versionLabel == "v2")
        #expect(Self.set.outputNamespace == nil)
        #expect(Self.set.schemaPath == "Schema/acp-v2.json")
        #expect(Self.set.metaPath == "Schema/acp-v2.meta.json")
        #expect(Self.set.unstableMetaPath == "Schema/acp-v2.meta.unstable.json")
        #expect(SchemaSet.all.map(\.versionLabel) == ["v2"])
        // Every declared artifact is actually vendored.
        for path in [Self.set.schemaPath, Self.set.metaPath, Self.set.unstableMetaPath].compactMap({ $0 }) {
            #expect(throws: Never.self) { try Self.packageFile(path) }
        }
    }

    @Test func checkedInOutputMatchesAFreshRun() throws {
        let generated = try Self.generateFromVendoredArtifacts()
        for (name, contents) in generated.sorted(by: { $0.key < $1.key }) {
            let checkedIn = try String(
                decoding: Self.packageFile("Sources/FoundationModelsACP/Generated/\(name)"),
                as: UTF8.self
            )
            #expect(checkedIn == contents, "\(name) drifted from the vendored schema; run `swift package generate-acp`")
        }
    }

    @Test func checkedInStampMatchesTheVendoredArtifactHash() throws {
        let stampName = SchemaGenerator.stampFileName(namespace: Self.set.outputNamespace)
        let recorded = try String(
            decoding: Self.packageFile("Sources/FoundationModelsACP/Generated/\(stampName)"),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = try SchemaGenerator(config: Self.set.config).generateIfChanged(
            schemaJSON: try Self.packageFile(Self.set.schemaPath),
            metaJSON: try Self.packageFile(#require(Self.set.metaPath)),
            unstableMetaJSON: try Self.packageFile(#require(Self.set.unstableMetaPath)),
            namespace: Self.set.outputNamespace,
            previousHash: recorded
        )
        #expect(outcome == .unchanged(hash: recorded))
    }

    @Test func sessionUpdateCarriesEveryVariantInSchemaOrder() throws {
        let unions = try #require(try Self.generateFromVendoredArtifacts()["Unions.generated.swift"])
        let declaration = try #require(Self.declaration(named: "SessionUpdate", in: unions))
        // The v1→v2 migration guide's display-terminal stream is real and
        // stable: `terminalUpdate` and `terminalOutputChunk` are `session/update`
        // payloads in the vendored schema, not an unstable or
        // documentation-only construct.
        #expect(
            Self.caseNames(in: declaration) == [
                "userMessageChunk", "userMessage", "agentMessageChunk", "agentMessage",
                "agentThoughtChunk", "agentThought", "stateUpdate", "toolCallContentChunk",
                "toolCallUpdate", "terminalUpdate", "terminalOutputChunk", "planUpdate",
                "availableCommandsUpdate", "configOptionUpdate", "sessionInfoUpdate",
                "usageUpdate", "unknown",
            ]
        )
        #expect(declaration.contains("case terminalUpdate(TerminalUpdate)"))
        #expect(declaration.contains("case terminalOutputChunk(TerminalOutputChunk)"))
    }

    @Test func toolCallContentCarriesTheTerminalReference() throws {
        let unions = try #require(try Self.generateFromVendoredArtifacts()["Unions.generated.swift"])
        // The `terminal` variant lives on tool-call content, not on the
        // message-level `ContentBlock` — which is why the docs' five-variant
        // content list showed no terminal.
        let toolCallContent = try #require(Self.declaration(named: "ToolCallContent", in: unions))
        #expect(Self.caseNames(in: toolCallContent) == ["content", "diff", "terminal", "unknown"])
        #expect(toolCallContent.contains("case terminal(Terminal)"))
        let contentBlock = try #require(Self.declaration(named: "ContentBlock", in: unions))
        #expect(!Self.caseNames(in: contentBlock).contains("terminal"))
    }

    @Test func contentBlockHasExactlyTheFiveStandardVariantsPlusFallback() throws {
        let unions = try #require(try Self.generateFromVendoredArtifacts()["Unions.generated.swift"])
        let declaration = try #require(Self.declaration(named: "ContentBlock", in: unions))
        #expect(Self.caseNames(in: declaration) == ["text", "image", "audio", "resourceLink", "resource", "unknown"])
    }

    @Test func unknownVariantsCarryingPayloadStayDeferred() throws {
        let unresolved = try #require(try Self.generateFromVendoredArtifacts()["Unresolved.generated.swift"])
        // Four v2 catch-alls require members beyond the unrecognized tag, which
        // a synthesized `unknown(String)` would drop. Raw JSON keeps them.
        for name in ["AuthMethod", "PlanUpdateContent", "ReplayFrom", "SetSessionConfigOptionRequest"] {
            #expect(unresolved.contains("public typealias \(name) = JSONValue"), "\(name) must not truncate its catch-all")
        }
    }

    @Test func generatedSurfaceNamesNoSupersededProtocolVersion() throws {
        // The package serves v2 only, and a hardcoded version in emitted DocC
        // goes stale silently. Nothing generated may name v1.
        for (name, contents) in try Self.generateFromVendoredArtifacts() {
            #expect(!contents.contains("ACP v1"), "\(name) still names ACP v1")
            #expect(!contents.contains("acp-v1"), "\(name) still names acp-v1")
        }
    }

    @Test func absolutePathDefinitionResolvesToTheHandWrittenInvariant() throws {
        let generated = try Self.generateFromVendoredArtifacts()
        let models = try #require(generated["Models.generated.swift"])
        // v2 models absolute paths as a schema definition, so the invariant
        // type follows the `$ref` — no per-field configuration.
        #expect(models.contains("public var cwd: AbsolutePath"))
        #expect(models.contains("public var additionalDirectories: [AbsolutePath]?"))
        // …and the hand-written type is never re-emitted by the generator.
        let identifiers = try #require(generated["Identifiers.generated.swift"])
        #expect(!identifiers.contains("public struct AbsolutePath"))
    }

    @Test func stableMethodTableRoutesExactlyTheStableManifest() throws {
        let stable = Self.stableSection(of: try Self.methodTable())
        #expect(
            Self.wireMethods(in: stable).sorted() == [
                "$/cancel_request", "auth/login", "auth/logout", "initialize",
                "session/cancel", "session/close", "session/delete", "session/list",
                "session/new", "session/prompt", "session/request_permission",
                "session/resume", "session/set_config_option", "session/update",
            ]
        )
    }

    @Test func unstableNamespaceRoutesExactlyTheUnstableOnlyMethods() throws {
        let table = try Self.methodTable()
        // v2 does publish an unstable routing manifest, so the generator's
        // `Unstable` namespace support is live, not dead code. The namespace
        // carries only what the stable table does not already route — and
        // `mcp/message` is routed on both sides, so it appears twice.
        #expect(table.contains("public enum Unstable {"))
        let unstable = Self.unstableSection(of: table)
        #expect(
            Self.wireMethods(in: unstable).sorted() == [
                "document/didChange", "document/didClose", "document/didFocus",
                "document/didOpen", "document/didSave", "elicitation/complete",
                "elicitation/create", "mcp/connect", "mcp/disconnect", "mcp/message",
                "mcp/message", "nes/accept", "nes/close", "nes/reject", "nes/start",
                "nes/suggest", "providers/disable", "providers/list", "providers/set",
                "session/fork",
            ]
        )
    }

    @Test func generationIsDeterministic() throws {
        #expect(try Self.generateFromVendoredArtifacts() == (try Self.generateFromVendoredArtifacts()))
    }

    // MARK: - Source slicing helpers

    /// The marker line opening the emitted unstable-routing namespace.
    private static let unstableNamespaceMarker = "public enum Unstable {"

    /// The generated method-table source.
    ///
    /// - Returns: The Swift source text of `MethodTable.generated.swift`.
    /// - Throws: A test failure when generation fails or the file is missing.
    private static func methodTable() throws -> String {
        try #require(try generateFromVendoredArtifacts()["MethodTable.generated.swift"])
    }

    /// The portion of the method table preceding the `Unstable` namespace.
    ///
    /// - Parameter table: The generated method-table source.
    /// - Returns: The stable table's source text.
    private static func stableSection(of table: String) -> String {
        guard let unstable = table.range(of: unstableNamespaceMarker) else { return table }
        return String(table[table.startIndex..<unstable.lowerBound])
    }

    /// The portion of the method table inside the `Unstable` namespace.
    ///
    /// - Parameter table: The generated method-table source.
    /// - Returns: The unstable table's source text, empty when absent.
    private static func unstableSection(of table: String) -> String {
        guard let unstable = table.range(of: unstableNamespaceMarker) else { return "" }
        return String(table[unstable.upperBound...])
    }

    /// The wire method names a stretch of routing-table source declares, in
    /// declaration order and with duplicates kept — a method routed on two
    /// sides is two entries.
    ///
    /// - Parameter source: A stretch of generated method-table source.
    /// - Returns: Every `wireMethod:` literal it declares.
    private static func wireMethods(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line in
            let marker = "wireMethod: \""
            guard let start = line.range(of: marker),
                let end = line[start.upperBound...].firstIndex(of: "\"")
            else {
                return nil
            }
            return String(line[start.upperBound..<end])
        }
    }

    /// Extracts one top-level `public enum` declaration from generated source:
    /// its opening line through the first unindented closing brace.
    ///
    /// - Parameters:
    ///   - name: The enum's Swift name.
    ///   - source: The generated file's source text.
    /// - Returns: The declaration's source text, or `nil` when absent.
    private static func declaration(named name: String, in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let opening = lines.firstIndex {
            $0.hasPrefix("public enum \(name):") || $0 == "public enum \(name) {"
        }
        guard let start = opening,
            let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" })
        else {
            return nil
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// The case names declared directly by an enum, in declaration order.
    ///
    /// Only the enum's own one-indent cases count: nested `CodingKeys` cases
    /// and `switch` arms inside its methods sit deeper and are skipped.
    ///
    /// - Parameter declaration: The enum declaration's source text.
    /// - Returns: The case names, associated values stripped.
    private static func caseNames(in declaration: String) -> [String] {
        declaration.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("    case "), !line.hasPrefix("     ") else { return nil }
            return String(line.dropFirst("    case ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }
}
