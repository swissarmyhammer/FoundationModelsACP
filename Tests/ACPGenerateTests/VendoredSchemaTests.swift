import Foundation
import Testing

@testable import ACPGenerateCore
import FoundationModelsACP

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

    /// The tree-relative directory holding the checked-in generated output.
    private static let generatedDirectory = "Sources/FoundationModelsACP/Generated"

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
    /// - Parameter reorderingMembers: When `true`, each artifact is
    ///   re-serialized with its JSON object members in ascending key order
    ///   before generation. The document's *value* is unchanged — JSON objects
    ///   are unordered — but the generator's maps are then built by a different
    ///   insertion sequence.
    /// - Returns: The generated files, keyed by file name.
    /// - Throws: `GeneratorError` when generation fails, or an error when an
    ///   artifact cannot be read.
    private static func generateFromVendoredArtifacts(reorderingMembers: Bool = false) throws -> [String: String] {
        func artifact(_ treeRelativePath: String) throws -> Data {
            let bytes = try packageFile(treeRelativePath)
            return reorderingMembers ? try memberSorted(bytes) : bytes
        }
        let files = try SchemaGenerator(config: set.config).generate(
            schemaJSON: try artifact(set.schemaPath),
            metaJSON: try artifact(#require(set.metaPath)),
            unstableMetaJSON: try artifact(#require(set.unstableMetaPath)),
            namespace: set.outputNamespace
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.contents) })
    }

    /// The same JSON document with every object's members re-emitted in
    /// ascending key order.
    ///
    /// - Parameter document: The document's bytes.
    /// - Returns: The re-serialized bytes.
    /// - Throws: An error when the bytes are not JSON.
    private static func memberSorted(_ document: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try JSONDecoder().decode(JSONValue.self, from: document))
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
                decoding: Self.packageFile("\(Self.generatedDirectory)/\(name)"),
                as: UTF8.self
            )
            #expect(checkedIn == contents, "\(name) drifted from the vendored schema; run `swift package generate-acp`")
        }
        // Comparing only the files the generator emits leaves a file it no
        // longer emits invisible — and `acp-generate` writes but never deletes,
        // so CI's `git diff` cannot see one either. The directory must hold
        // exactly the emitted set.
        let checkedInNames = try FileManager.default
            .contentsOfDirectory(atPath: Self.packageRoot.appendingPathComponent(Self.generatedDirectory).path)
            .filter { $0.hasSuffix(".swift") }
        #expect(
            Set(checkedInNames) == Set(generated.keys),
            "\(Self.generatedDirectory) holds Swift files the generator no longer emits"
        )
    }

    @Test func checkedInStampMatchesTheVendoredArtifactHash() throws {
        let stampName = SchemaGenerator.stampFileName(namespace: Self.set.outputNamespace)
        let recorded = try String(
            decoding: Self.packageFile("\(Self.generatedDirectory)/\(stampName)"),
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

    @Test func generatedDocCNamesNoProtocolVersion() throws {
        let generated = try Self.generateFromVendoredArtifacts()
        // The regression behind this test was a literal: `methodTableDeclaration`
        // hardcoded "the stable ACP v1 surface" and shipped it as public DocC
        // atop the routing table, where it survived the whole v1→v2 rename. A
        // negative assertion alone cannot catch that class — the v2 schema
        // names no version either way — so pin the banner the emitter does
        // write.
        let table = try #require(generated["MethodTable.generated.swift"])
        #expect(table.contains("/// The method-routing table for the stable ACP surface.\n"))
        // Then sweep for the `ACP vN` / `acp-vN` spelling an emitter would
        // reach for, since a hardcoded "ACP v2" goes stale on the next
        // re-vendor exactly as "ACP v1" did. `Schema/README.md` records the
        // vendored revision instead.
        //
        // Scope, stated precisely because the files are not version-free: the
        // schema's own `description` text carries
        // `https://agentclientprotocol.com/protocol/v2/…` doc links, which
        // pass through into emitted DocC in the hundreds. Those are vendored
        // content, not an emitter literal, and they are correct — the sweep
        // exempts them by matching only the `ACP v`/`acp-v` spelling.
        let versionToken = try Regex("acp[ -]v[0-9]").ignoresCase()
        for (name, contents) in generated {
            #expect(contents.firstMatch(of: versionToken) == nil, "\(name) hardcodes a protocol version in generated text")
        }
    }

    @Test func absolutePathDefinitionResolvesToTheHandWrittenInvariant() throws {
        let generated = try Self.generateFromVendoredArtifacts()
        let models = try #require(generated["Models.generated.swift"])
        // v2 models absolute paths as a schema definition, so the invariant
        // type follows the `$ref` — no per-field configuration.
        //
        // Pin the exact declarations rather than searching the file for a
        // substring: `"public var cwd: AbsolutePath"` occurs inside
        // `"public var cwd: AbsolutePath?"`, so an unscoped `contains` cannot
        // tell a required path from an optional one, and one surviving
        // declaration satisfies it while the others regress.
        #expect(
            Self.properties(ofType: "AbsolutePath", in: models) == [
                "CommandPermissionSubject.cwd: AbsolutePath",
                "DiffPathChange.path: AbsolutePath",
                "DiffPathPairChange.oldPath: AbsolutePath",
                "DiffPathPairChange.path: AbsolutePath",
                "ListSessionsRequest.cwd: AbsolutePath?",
                "McpServerStdio.command: AbsolutePath",
                "NewSessionRequest.cwd: AbsolutePath",
                "NewSessionRequest.additionalDirectories: [AbsolutePath]?",
                "ResumeSessionRequest.cwd: AbsolutePath",
                "ResumeSessionRequest.additionalDirectories: [AbsolutePath]?",
                "SessionInfo.cwd: AbsolutePath",
                "SessionInfo.additionalDirectories: [AbsolutePath]?",
                "TerminalUpdate.cwd: AbsolutePath?",
                "ToolCallLocation.path: AbsolutePath",
            ]
        )
        // …and the hand-written type is never re-emitted, into any file.
        for (name, contents) in generated {
            #expect(!contents.contains("public struct AbsolutePath"), "\(name) re-emits the hand-written AbsolutePath")
        }
    }

    @Test func stableMethodTableRoutesExactlyTheStableManifest() throws {
        // Pinning wire names alone would leave the wiring unchecked, and the
        // wiring is the whole reason this table is generated: the TS-SDK bug
        // this replaces was `setSessionModel` bound to `session/set_mode` —
        // a right name on the wrong handler. Side, kind, handler, params,
        // result, and position are all part of the assertion.
        #expect(
            Self.routingEntries(in: Self.stableSection(of: try Self.methodTable())) == [
                "agent request auth/login -> loginAuth(LoginAuthRequest) : LoginAuthResponse",
                "agent request auth/logout -> logoutAuth(LogoutAuthRequest) : LogoutAuthResponse",
                "agent request initialize -> initialize(InitializeRequest) : InitializeResponse",
                "agent notification session/cancel -> sessionCancel(CancelSessionNotification) : nil",
                "agent request session/close -> closeSession(CloseSessionRequest) : CloseSessionResponse",
                "agent request session/delete -> deleteSession(DeleteSessionRequest) : DeleteSessionResponse",
                "agent request session/list -> listSessions(ListSessionsRequest) : ListSessionsResponse",
                "agent request session/new -> newSession(NewSessionRequest) : NewSessionResponse",
                "agent request session/prompt -> prompt(PromptRequest) : PromptResponse",
                "agent request session/resume -> resumeSession(ResumeSessionRequest) : ResumeSessionResponse",
                "agent request session/set_config_option -> setSessionConfigOption(SetSessionConfigOptionRequest) : SetSessionConfigOptionResponse",
                "client request session/request_permission -> requestPermission(RequestPermissionRequest) : RequestPermissionResponse",
                "client notification session/update -> sessionUpdate(UpdateSessionNotification) : nil",
                "protocolLevel notification $/cancel_request -> cancelRequest(CancelRequestNotification) : nil",
            ]
        )
    }

    @Test func unstableNamespaceRoutesExactlyTheUnstableOnlyMethods() throws {
        let table = try Self.methodTable()
        // v2 does publish an unstable routing manifest, so the generator's
        // `Unstable` namespace support is live, not dead code. The namespace
        // carries only what the stable table does not already route — and
        // `mcp/message` is routed on both sides, which the pinned side on each
        // of its two entries is what actually proves.
        #expect(table.contains("public enum Unstable {"))
        #expect(
            Self.routingEntries(in: Self.unstableSection(of: table)) == [
                "agent document/didChange -> documentDidChange",
                "agent document/didClose -> documentDidClose",
                "agent document/didFocus -> documentDidFocus",
                "agent document/didOpen -> documentDidOpen",
                "agent document/didSave -> documentDidSave",
                "agent mcp/message -> mcpMessage",
                "agent nes/accept -> nesAccept",
                "agent nes/close -> nesClose",
                "agent nes/reject -> nesReject",
                "agent nes/start -> nesStart",
                "agent nes/suggest -> nesSuggest",
                "agent providers/disable -> providersDisable",
                "agent providers/list -> providersList",
                "agent providers/set -> providersSet",
                "agent session/fork -> sessionFork",
                "client elicitation/complete -> elicitationComplete",
                "client elicitation/create -> elicitationCreate",
                "client mcp/connect -> mcpConnect",
                "client mcp/disconnect -> mcpDisconnect",
                "client mcp/message -> mcpMessage",
            ]
        )
    }

    @Test func declarationsAreEmittedInSortedSchemaNameOrder() throws {
        // Emission order is an explicit sort over the schema's `$defs` map, and
        // nothing downstream re-imposes it. Drop that sort and the order
        // follows hash-seeded map iteration instead, so the checked-in output
        // churns between runs for no reason — the classic codegen
        // nondeterminism. Pinning the order is what turns that into a test
        // failure with a name on it.
        //
        // This is the deterministic instrument for that defect and the primary
        // one. Remove the `$defs` sort and it fails on every run — 32 separate
        // processes across two independent samples, never once observed to
        // miss — where the whole-output smoke test below samples the same
        // property and sometimes comes back clean. When either goes red, this
        // is the one that says what broke.
        //
        // Names are compared as the *schema* spells them, since the emitter
        // renames a few — `Error` sorts where `Error` sorts, not where
        // `ACPError` would.
        let schemaNames = Dictionary(uniqueKeysWithValues: Self.set.config.typeRenames.map { ($1, $0) })
        let emitted = try Self.generateFromVendoredArtifacts().mapValues { contents in
            Self.declaredTypeNames(in: contents).map { schemaNames[$0] ?? $0 }
        }
        for (file, names) in emitted {
            #expect(names == names.sorted(), "\(file) emits declarations out of schema-name order")
        }
        // `[] == [].sorted()` is true, so the ordering assertion alone would go
        // green the moment `declaredTypeName(on:)` stopped recognizing a
        // declaration — an attribute line, an indent, or a non-`nil`
        // `outputNamespace` nesting everything one level deeper. Pinning the
        // counts keeps a parse that quietly stops seeing declarations from
        // reading as success.
        #expect(
            emitted.mapValues(\.count) == [
                "Identifiers.generated.swift": 12,
                "MethodTable.generated.swift": 2,
                "Models.generated.swift": 98,
                "Unions.generated.swift": 19,
                "Unresolved.generated.swift": 15,
            ]
        )
    }

    @Test func generationIgnoresSchemaMemberOrder() throws {
        // The ordering pin above is the sharp instrument for declaration order;
        // this is a broader smoke test over the whole output. Re-serializing
        // the vendored documents with their object members in a different order
        // feeds the generator the same values — JSON objects are unordered —
        // built into its `[String: JSONValue]` maps by a different insertion
        // sequence, so emitted content that follows map order rather than an
        // explicit sort *may* diverge.
        //
        // Only *may*: `JSONValue.object` is an unordered `Dictionary`, so
        // textual member order is already gone by the time the generator sees
        // it, and the residual signal is bucket layout — which differs only
        // where insertion order changes a collision probe sequence. So this is
        // a probabilistic detector: run against a generator with its `$defs`
        // sort removed it comes back clean a good share of the time, which is
        // why the ordering pin above is the primary instrument and this is a
        // smoke test kept for its breadth — it compares whole emitted files,
        // not declaration order alone.
        //
        // What holds whatever the sampling: this never fails on a correct
        // generator, so a divergence here is always real and worth chasing,
        // and a pass proves nothing. Do not restate that as a catch rate.
        // Four successive attempts to put a number on how often this form
        // beats a bare two-run in-process comparison have disagreed with each
        // other — and so have two samples of the *identical* configuration —
        // while nothing depends on the answer. Quoting a rate requires
        // measuring it at n >= 30 and saying so.
        #expect(try Self.generateFromVendoredArtifacts() == (try Self.generateFromVendoredArtifacts(reorderingMembers: true)))
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

    /// The routing entries a stretch of method-table source declares, in
    /// declaration order and with duplicates kept — a method routed on two
    /// sides is two entries.
    ///
    /// Each entry is flattened to `side kind wire -> handler(params) : result`,
    /// with `kind` and the type names omitted for the unstable table, which
    /// routes by name and side only. Flattening the whole initializer rather
    /// than the wire name alone is what makes a swapped handler or a
    /// misassigned side fail the assertion.
    ///
    /// - Parameter source: A stretch of generated method-table source.
    /// - Returns: Every routing entry it declares.
    private static func routingEntries(in source: String) -> [String] {
        var entries: [String] = []
        var fields: [String: String] = [:]
        var inEntry = false
        for line in source.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            switch text {
            case "MethodInfo(", "UnstableMethodInfo(":
                inEntry = true
                fields = [:]
            case "),", ")":
                guard inEntry else { continue }
                inEntry = false
                entries.append(routingEntry(from: fields))
            default:
                guard inEntry, let separator = text.range(of: ": ") else { continue }
                let value = text[separator.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ","))
                fields[String(text[text.startIndex..<separator.lowerBound])] =
                    value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        return entries
    }

    /// Renders one parsed routing entry's fields.
    ///
    /// - Parameter fields: The entry's initializer arguments, unquoted.
    /// - Returns: The flattened entry.
    private static func routingEntry(from fields: [String: String]) -> String {
        let side = fields["side"] ?? "?"
        let wire = fields["wireMethod"] ?? "?"
        let handler = fields["handlerName"] ?? "?"
        guard let kind = fields["kind"] else { return "\(side) \(wire) -> \(handler)" }
        let entry = """
            \(side) \(kind) \(wire) -> \(handler)(\(fields["paramsTypeName"] ?? "?")) : \(fields["resultTypeName"] ?? "?")
            """
        guard let deprecation = fields["deprecationMessage"], deprecation != "nil" else { return entry }
        return "\(entry) [deprecated: \(deprecation)]"
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

    /// Every stored property in generated source whose declared type mentions a
    /// given type name, rendered `Owner.property: Type` in declaration order.
    ///
    /// Scoping each property to its enclosing declaration and keeping the full
    /// type is what separates a required property from an optional one: a bare
    /// `contains("public var cwd: AbsolutePath")` over the whole file is
    /// satisfied by `public var cwd: AbsolutePath?` too.
    ///
    /// - Parameters:
    ///   - typeName: The type name to look for inside declared types.
    ///   - source: The generated file's source text.
    /// - Returns: The matching properties.
    private static func properties(ofType typeName: String, in source: String) -> [String] {
        let marker = "    public var "
        var owner = ""
        var matches: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let declared = declaredTypeName(on: line) {
                owner = declared
                continue
            }
            guard line.hasPrefix(marker), let separator = line.range(of: ": ") else { continue }
            let type = String(line[separator.upperBound...])
            guard type.contains(typeName) else { continue }
            let property = line[line.index(line.startIndex, offsetBy: marker.count)..<separator.lowerBound]
            matches.append("\(owner).\(property): \(type)")
        }
        return matches
    }

    /// The top-level declaration names a generated file declares, in emission
    /// order.
    ///
    /// - Parameter source: The generated file's source text.
    /// - Returns: The declared names.
    private static func declaredTypeNames(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap(declaredTypeName(on:))
    }

    /// The Swift name of the top-level declaration a line opens.
    ///
    /// - Parameter line: A line of generated source.
    /// - Returns: The declared name, or `nil` when the line opens no top-level
    ///   declaration.
    private static func declaredTypeName(on line: Substring) -> String? {
        for keyword in ["public struct ", "public enum ", "public typealias "] where line.hasPrefix(keyword) {
            return String(line.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return nil
    }
}
