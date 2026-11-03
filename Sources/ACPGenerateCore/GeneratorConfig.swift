/// Configuration for the schema generator, reviewed alongside the output.
///
/// The wire-invariant field table below is the field→invariant-type mapping
/// for rules a schema states only in prose: such fields emit as
/// `AbsolutePath` or `LineNumber` rather than bare `String`/`Int`, so the
/// type name states the rule at each use. Invariant-mapped fields always
/// decode strictly — a value of the wrong JSON type is a decode-time error,
/// and the strict decode wins over any `x-deserialize-default-on-error`
/// annotation on the same field. A schema that gives the rule its own
/// definition (as ACP v2 does for `AbsolutePath`) needs no entries: the
/// `$ref` carries the type, and the definition is listed in
/// `handwrittenDefinitions` instead.
public struct GeneratorConfig: Sendable {
    /// A hand-written invariant-carrying newtype a schema field can map to.
    public enum InvariantType: String, Sendable {
        /// The field carries a file path the schema says must be absolute; it
        /// emits as the hand-written `AbsolutePath`, which carries the value
        /// as sent so the agent can validate it.
        case absolutePath = "AbsolutePath"

        /// The field carries a 1-based line number; it emits as the
        /// hand-written `LineNumber`, rejecting `0` and negatives at decode.
        case lineNumber = "LineNumber"
    }

    /// A named part of the unstable schema document to emit with the stable
    /// surface.
    ///
    /// Nothing else of the unstable document is read: a definition or a
    /// variant that is not named here is not emitted. Every name must exist
    /// in the unstable document, or generation fails, so a stale entry cannot
    /// linger past a re-vendor.
    public struct UnstableOverlay: Sendable {
        /// Definitions that the stable document lacks, copied as they are.
        public var definitions: [String]

        /// Union variants appended to a stable union, keyed by the union's
        /// definition name. Each variant is named by the value of its
        /// `const` discriminator (for example `subagent_update`). The
        /// variant goes before the union's catch-all, in the order listed.
        public var variants: [String: [String]]

        /// Creates an overlay.
        ///
        /// - Parameters:
        ///   - definitions: The definitions to copy.
        ///   - variants: The union variants to append, by union name.
        public init(definitions: [String] = [], variants: [String: [String]] = [:]) {
            self.definitions = definitions
            self.variants = variants
        }

        /// `true` when the overlay names nothing.
        public var isEmpty: Bool {
            definitions.isEmpty && variants.isEmpty
        }
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

    /// Fields with three-state patch semantics — omitted, `null`, and a
    /// concrete value are distinct wire states — keyed by
    /// `"DefinitionName.wireFieldName"` (schema definition names, before
    /// renames), the same key shape `wireInvariantFields` uses.
    ///
    /// ACP v2 states this only in prose (e.g. `ToolCallUpdate`: "Other fields
    /// have patch semantics: omitted fields leave the existing tool call
    /// value unchanged, `null` clears or unsets the value, and concrete
    /// values replace the previous value"); there is no schema keyword for
    /// it, and sniffing description text would be brittle, so this table is
    /// the config-carried alternative. A listed field emits as
    /// `PatchField<Wrapped>` instead of a plain `Optional`; every entry must
    /// name a field the schema still declares or generation fails, so a
    /// stale entry cannot linger past a re-vendor — the same discipline
    /// `deprecatedMethods` enforces for the routing table.
    public var patchSemanticsFields: Set<String>

    /// The parts of the unstable schema document that the stable document
    /// lacks and that the generator emits with the stable surface.
    public var unstableOverlay: UnstableOverlay

    /// The `version` the vendored routing manifests must declare.
    ///
    /// Upstream sets this to the ACP protocol's major version, so it moves with
    /// every protocol bump; which value to accept is therefore vendoring
    /// configuration, not a constant. A manifest declaring anything else fails
    /// generation rather than being parsed hopefully.
    public var manifestVersion: Int

    /// The definitions that start the emitted subset of the schema document.
    ///
    /// When this set is empty, the generator emits every definition. When it
    /// is not empty, the generator emits only the definitions that these
    /// roots reach through `$ref`, the roots included. The generator does not
    /// classify a definition that no root reaches, so a shape it cannot model
    /// in an unused part of the document does not stop generation. Each entry
    /// must name a definition of the schema, or generation fails.
    public var rootDefinitions: Set<String>

    /// The definitions that another schema set already emits at the top
    /// level.
    ///
    /// The generator does not emit a shared definition, and it does not walk
    /// into it to find more definitions. A `$ref` to it resolves to its
    /// emitted name, which inside a namespace finds the top-level type. Each
    /// entry must name a definition of the schema that a root reaches, or
    /// generation fails, so a stale entry cannot stay after a re-vendor.
    public var sharedDefinitions: Set<String>

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - wireInvariantFields: Field→invariant-type overrides.
    ///   - typeRenames: Definition-name renames.
    ///   - knownAcronyms: Acronyms normalized to all-caps in type names.
    ///   - handwrittenDefinitions: Definitions to skip emitting.
    ///   - deprecatedMethods: Wire method → deprecation message markers.
    ///   - patchSemanticsFields: Fields with three-state patch semantics.
    ///   - unstableOverlay: The unstable definitions and union variants to emit.
    ///   - manifestVersion: The version the routing manifests must declare.
    ///   - rootDefinitions: The definitions that start the emitted subset, or
    ///     an empty set to emit every definition.
    ///   - sharedDefinitions: The definitions that another set emits.
    public init(
        wireInvariantFields: [String: InvariantType] = [:],
        typeRenames: [String: String] = [:],
        knownAcronyms: Set<String> = [],
        handwrittenDefinitions: Set<String> = [],
        deprecatedMethods: [String: String] = [:],
        patchSemanticsFields: Set<String> = [],
        unstableOverlay: UnstableOverlay = UnstableOverlay(),
        manifestVersion: Int = 1,
        rootDefinitions: Set<String> = [],
        sharedDefinitions: Set<String> = []
    ) {
        self.wireInvariantFields = wireInvariantFields
        self.typeRenames = typeRenames
        self.knownAcronyms = knownAcronyms
        self.handwrittenDefinitions = handwrittenDefinitions
        self.deprecatedMethods = deprecatedMethods
        self.patchSemanticsFields = patchSemanticsFields
        self.unstableOverlay = unstableOverlay
        self.manifestVersion = manifestVersion
        self.rootDefinitions = rootDefinitions
        self.sharedDefinitions = sharedDefinitions
    }

    /// Configuration for the vendored `Schema/acp-v2.json` document.
    ///
    /// `wireInvariantFields` names only the line number. v1 needed a per-field table
    /// because it spelled absolute paths as bare `"type": "string"`; v2 gives
    /// them a first-class `AbsolutePath` definition, so every path field
    /// reaches the invariant through its own `$ref` and the table would only
    /// be a second, drift-prone copy of the schema. The override mechanism
    /// stays for schema revisions that describe an invariant in prose alone.
    ///
    /// The one line-valued field, `ToolCallLocation.line`, is mapped to
    /// `.lineNumber`: since `schema-v2.0.0-alpha.10` the schema states that it
    /// is 1-based (`minimum: 1`, "`0` is invalid").
    public static let acpV2 = GeneratorConfig(
        wireInvariantFields: [
            // 1-based since `schema-v2.0.0-alpha.10`; hand-written in Core.
            "ToolCallLocation.line": .lineNumber
        ],
        typeRenames: [
            // `Error` would shadow `Swift.Error` inside the module.
            "Error": "ACPError",
        ],
        knownAcronyms: [
            // ACP's transport for `McpServer` variants; not an Apple-guideline
            // acronym, but the same all-caps convention applies to any
            // acronym, and the schema spells it mixed-case throughout.
            "MCP",
            "HTTP",
        ],
        handwrittenDefinitions: [
            // Hand-written in Core. The schema states the absolute-path rule
            // in prose, and the agent enforces it.
            "AbsolutePath",
            // Hand-written in Core with the negotiated-version invariant.
            "ProtocolVersion",
        ],
        // The six upsert definitions' own descriptions give `_meta` a
        // three-state meaning ("Omitted means no metadata update; `null` is
        // an explicit clear signal"), and five of the six say the same of
        // their other fields ("Other fields have patch semantics: omitted
        // fields leave the stored value unchanged, `null` clears it, and
        // concrete values replace it") — `SessionInfoUpdate` states it as a
        // whole-definition rule instead ("Omitted fields leave the existing
        // session info unchanged. `null` clears the corresponding value").
        // `UserMessage`/`AgentMessage`/`AgentThought` single out `content`
        // by name for the same rule; `messageId` is required and carries no
        // patch prose, so it stays a plain required field. `ToolCallUpdate.name`
        // (added in `schema-v2.0.0-alpha.4`) also states the rule in its own
        // description: omission means no change, `null` clears the name.
        // `CompactionUpdate` (stable since `schema-v2.0.0-alpha.8`) states it
        // for three fields: "`summary`, `error`, and `_meta` have patch
        // semantics: omission leaves the stored value unchanged, `null`
        // clears it, and a concrete value replaces it."
        // `UsageUpdate.cost` (since `schema-v2.0.0-alpha.11`): "Omitted leaves the
        // last reported cost unchanged. `null` clears it. A value replaces it."
        // `CompactionSummaryChunk._meta` and `Notice._meta` say that omission
        // and `null` both mean absent, so they stay plain optionals.
        patchSemanticsFields: [
            "UsageUpdate.cost", "SubagentUpdate.title", "SubagentUpdate.description",
            "SubagentUpdate.capabilities", "SubagentUpdate.state", "SubagentUpdate.cwd",
            "SubagentUpdate.additionalDirectories", "SubagentUpdate._meta",
            "SessionMessage.content", "SessionMessage.senderSessionId", "SessionMessage.recipientSessionId",
            "SessionMessage.senderMessageId", "SessionMessage.recipientMessageId", "SessionMessage._meta",
            "CompactionUpdate.summary", "CompactionUpdate.error", "CompactionUpdate._meta",
            "UserMessage.content", "UserMessage._meta",
            "AgentMessage.content", "AgentMessage._meta",
            "AgentThought.content", "AgentThought._meta",
            "SessionInfoUpdate.title", "SessionInfoUpdate.updatedAt", "SessionInfoUpdate._meta",
            "TerminalUpdate.command", "TerminalUpdate.cwd", "TerminalUpdate.output",
            "TerminalUpdate.exitStatus", "TerminalUpdate._meta",
            "ToolCallUpdate.name", "ToolCallUpdate.title", "ToolCallUpdate.kind", "ToolCallUpdate.status",
            "ToolCallUpdate.content", "ToolCallUpdate.locations", "ToolCallUpdate.rawInput",
            "ToolCallUpdate.rawOutput", "ToolCallUpdate._meta", "ToolCallUpdate.capabilities",
            "TerminalUpdate.capabilities",
        ],
        unstableOverlay: UnstableOverlay(
            // The ACP v2 "Subagent Sessions" and "Background Work" RFDs. The
            // stable schema has none of them; the unstable one defines them.
            definitions: [
                "BackgroundSubagent", "SessionCancelCapabilities", "SessionMessage",
                "SessionMessageChunk", "SubagentSessionCapabilities", "SubagentUpdate",
            ],
            variants: [
                "BackgroundWork": ["subagent"],
                "SessionUpdate": ["subagent_update", "session_message", "session_message_chunk"],
            ]
        ),
        manifestVersion: 2
    )
}
