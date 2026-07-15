/// Configuration for the schema generator, reviewed alongside the output.
///
/// The wire-invariant field table below is the spec §4 field→invariant-type
/// mapping: schema fields that carry file paths emit as `AbsolutePath` and
/// line-number fields emit as `LineNumber`, never bare `String`/`Int`, so a
/// relative path or a 0-based line is a decode-time error. Invariant-mapped
/// fields always decode strictly — the invariant wins over any
/// `x-deserialize-default-on-error` annotation on the same field.
public struct GeneratorConfig: Sendable {
    /// A hand-written invariant-carrying newtype a schema field can map to.
    public enum InvariantType: String, Sendable {
        /// The field carries a file path that must be absolute; it emits as
        /// the hand-written `AbsolutePath`, rejecting relative paths at decode.
        case absolutePath = "AbsolutePath"

        /// The field carries a 1-based line number; it emits as the
        /// hand-written `LineNumber`, rejecting `0` and negatives at decode.
        case lineNumber = "LineNumber"
    }

    /// Wire-invariant overrides keyed by `"DefinitionName.wireFieldName"`
    /// (schema definition names, before renames). For array fields the
    /// override applies to the element type.
    public var wireInvariantFields: [String: InvariantType]

    /// Schema definition names mapped to different emitted Swift type names.
    /// Definition names never appear on the wire, so renames are coding-safe.
    public var typeRenames: [String: String]

    /// Definitions whose Swift types are hand-written in the library's Core
    /// directory; the generator resolves references to them but never emits
    /// them.
    public var handwrittenDefinitions: Set<String>

    /// Wire method names deprecated upstream, mapped to the human-readable
    /// deprecation message the routing table carries. Neither the schema nor
    /// the routing manifests mark deprecations, so this is config-carried;
    /// every entry must name a routed method or generation fails, so a stale
    /// entry cannot linger after a schema bump.
    public var deprecatedMethods: [String: String]

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - wireInvariantFields: Field→invariant-type overrides.
    ///   - typeRenames: Definition-name renames.
    ///   - handwrittenDefinitions: Definitions to skip emitting.
    ///   - deprecatedMethods: Wire method → deprecation message markers.
    public init(
        wireInvariantFields: [String: InvariantType] = [:],
        typeRenames: [String: String] = [:],
        handwrittenDefinitions: Set<String> = [],
        deprecatedMethods: [String: String] = [:]
    ) {
        self.wireInvariantFields = wireInvariantFields
        self.typeRenames = typeRenames
        self.handwrittenDefinitions = handwrittenDefinitions
        self.deprecatedMethods = deprecatedMethods
    }

    /// Configuration for the vendored `Schema/acp-v1.json` document.
    public static let acpV1 = GeneratorConfig(
        wireInvariantFields: [
            // Working directories — "Must be an absolute path."
            "CreateTerminalRequest.cwd": .absolutePath,
            "ListSessionsRequest.cwd": .absolutePath,
            "LoadSessionRequest.cwd": .absolutePath,
            "NewSessionRequest.cwd": .absolutePath,
            "ResumeSessionRequest.cwd": .absolutePath,
            "SessionInfo.cwd": .absolutePath,
            // Additional workspace roots — "Each path must be absolute."
            "LoadSessionRequest.additionalDirectories": .absolutePath,
            "NewSessionRequest.additionalDirectories": .absolutePath,
            "ResumeSessionRequest.additionalDirectories": .absolutePath,
            "SessionInfo.additionalDirectories": .absolutePath,
            // File paths — "The absolute file path …" / "Absolute path to …"
            "Diff.path": .absolutePath,
            "ReadTextFileRequest.path": .absolutePath,
            "ToolCallLocation.path": .absolutePath,
            "WriteTextFileRequest.path": .absolutePath,
            // "Absolute path to the MCP server executable."
            "McpServerStdio.command": .absolutePath,
            // 1-based line numbers.
            "ReadTextFileRequest.line": .lineNumber,
            "ToolCallLocation.line": .lineNumber,
        ],
        typeRenames: [
            // `Error` would shadow `Swift.Error` inside the module.
            "Error": "ACPError",
            // Swift API Design Guidelines cased acronym (`entryID`-style).
            "RequestId": "RequestID",
        ],
        handwrittenDefinitions: [
            // Hand-written in Core with the negotiated-version invariant.
            "ProtocolVersion"
        ],
        deprecatedMethods: [
            // v1.19 supersedes session modes with boolean/select session
            // config options; neither schema nor manifest carries the marker.
            "session/set_mode": "Deprecated upstream in favor of session/set_config_option."
        ]
    )
}
