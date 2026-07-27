/// Configuration for the schema generator, reviewed alongside the output.
///
/// The wire-invariant field table below is the field→invariant-type mapping
/// for invariants a schema states only in prose: such fields emit as
/// `AbsolutePath` or `LineNumber` rather than bare `String`/`Int`, so a
/// relative path or a 0-based line is a decode-time error. Invariant-mapped
/// fields always decode strictly — the invariant wins over any
/// `x-deserialize-default-on-error` annotation on the same field. A schema
/// that gives the invariant its own definition (as ACP v2 does for
/// `AbsolutePath`) needs no entries: the `$ref` carries the type, and the
/// definition is listed in `handwrittenDefinitions` instead.
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

    /// Acronyms that must read as a single all-caps word in an emitted
    /// UpperCamelCase type name (e.g. `HTTP`, not `Http`).
    ///
    /// A schema definition name carries the schema author's own casing
    /// (`McpServerHttp`), not Swift's convention for acronyms. Every
    /// generated type name is normalized against this set uniformly —
    /// wherever the acronym appears in the name, not only at one recorded
    /// call site — rather than special-casing individual definitions in
    /// `typeRenames`, which would only catch the names someone remembered to
    /// list. Matching is case-insensitive per word; only whole PascalCase
    /// words are checked, so a word merely containing an entry (e.g.
    /// `Https` against `HTTP`) is left alone.
    public var knownAcronyms: Set<String>

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

    /// The `version` the vendored routing manifests must declare.
    ///
    /// Upstream sets this to the ACP protocol's major version, so it moves with
    /// every protocol bump; which value to accept is therefore vendoring
    /// configuration, not a constant. A manifest declaring anything else fails
    /// generation rather than being parsed hopefully.
    public var manifestVersion: Int

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - wireInvariantFields: Field→invariant-type overrides.
    ///   - typeRenames: Definition-name renames.
    ///   - knownAcronyms: Acronyms normalized to all-caps in type names.
    ///   - handwrittenDefinitions: Definitions to skip emitting.
    ///   - deprecatedMethods: Wire method → deprecation message markers.
    ///   - manifestVersion: The version the routing manifests must declare.
    public init(
        wireInvariantFields: [String: InvariantType] = [:],
        typeRenames: [String: String] = [:],
        knownAcronyms: Set<String> = [],
        handwrittenDefinitions: Set<String> = [],
        deprecatedMethods: [String: String] = [:],
        manifestVersion: Int = 1
    ) {
        self.wireInvariantFields = wireInvariantFields
        self.typeRenames = typeRenames
        self.knownAcronyms = knownAcronyms
        self.handwrittenDefinitions = handwrittenDefinitions
        self.deprecatedMethods = deprecatedMethods
        self.manifestVersion = manifestVersion
    }

    /// Configuration for the vendored `Schema/acp-v2.json` document.
    ///
    /// `wireInvariantFields` is empty by design. v1 needed a per-field table
    /// because it spelled absolute paths as bare `"type": "string"`; v2 gives
    /// them a first-class `AbsolutePath` definition, so every path field
    /// reaches the invariant through its own `$ref` and the table would only
    /// be a second, drift-prone copy of the schema. The override mechanism
    /// stays for schema revisions that describe an invariant in prose alone.
    ///
    /// There is no `.lineNumber` mapping either: the vendored document
    /// contains exactly one line-valued field, `ToolCallLocation.line`, and
    /// neither the schema nor the v2 documentation states that it is 1-based.
    /// An unstated invariant is not enforced at decode time.
    public static let acpV2 = GeneratorConfig(
        typeRenames: [
            // `Error` would shadow `Swift.Error` inside the module.
            "Error": "ACPError",
            // Swift API Design Guidelines cased acronym (`entryID`-style).
            "RequestId": "RequestID",
        ],
        knownAcronyms: [
            // ACP's transport for `McpServer` variants; not an Apple-guideline
            // acronym, but the same all-caps convention applies to any
            // acronym, and the schema spells it mixed-case throughout.
            "MCP",
            "HTTP",
        ],
        handwrittenDefinitions: [
            // Hand-written in Core, rejecting relative paths at decode.
            "AbsolutePath",
            // Hand-written in Core with the negotiated-version invariant.
            "ProtocolVersion",
        ],
        manifestVersion: 2
    )
}
