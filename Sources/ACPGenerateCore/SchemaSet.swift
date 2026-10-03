/// A vendored schema set: the artifacts, version label, output namespace, and
/// generator configuration for one ACP protocol version.
///
/// The generator's inputs are data, not constants: adding a hypothetical
/// second set is a new `SchemaSet` value appended to `all`, requiring no
/// generator code change. A non-primary set carries a non-nil
/// `outputNamespace`, so its types nest inside a clearly labeled enum rather
/// than colliding with the primary set.
public struct SchemaSet: Sendable {
    /// The human-readable protocol version label (e.g. `v2`).
    public let versionLabel: String

    /// The enclosing namespace enum the emitted types nest inside, or `nil`
    /// to emit at the top level. `nil` for the primary set only.
    public let outputNamespace: String?

    /// The schema document path, tree-relative to the package root.
    public let schemaPath: String

    /// The stable routing manifest path, or `nil` when the set routes no
    /// methods.
    public let metaPath: String?

    /// The unstable routing manifest path, or `nil`.
    public let unstableMetaPath: String?

    /// The generator configuration for this set's schema document.
    public let config: GeneratorConfig

    /// Creates a schema set descriptor.
    ///
    /// - Parameters:
    ///   - versionLabel: The protocol version label.
    ///   - outputNamespace: The enclosing namespace enum, or `nil` for the
    ///     top level.
    ///   - schemaPath: The tree-relative schema document path.
    ///   - metaPath: The tree-relative stable routing manifest path, or `nil`.
    ///   - unstableMetaPath: The tree-relative unstable routing manifest path,
    ///     or `nil`.
    ///   - config: The generator configuration for the schema document.
    public init(
        versionLabel: String,
        outputNamespace: String?,
        schemaPath: String,
        metaPath: String?,
        unstableMetaPath: String?,
        config: GeneratorConfig
    ) {
        self.versionLabel = versionLabel
        self.outputNamespace = outputNamespace
        self.schemaPath = schemaPath
        self.metaPath = metaPath
        self.unstableMetaPath = unstableMetaPath
        self.config = config
    }

    /// The vendored ACP v2 schema set — the primary set, emitted at the top
    /// level.
    ///
    /// v2 publishes an unstable routing manifest alongside the stable one, so
    /// `unstableMetaPath` is populated and the emitted `Unstable` namespace is
    /// live rather than dead configuration.
    public static let acpV2 = SchemaSet(
        versionLabel: "v2",
        outputNamespace: nil,
        schemaPath: "Schema/acp-v2.json",
        metaPath: "Schema/acp-v2.meta.json",
        unstableMetaPath: "Schema/acp-v2.meta.unstable.json",
        config: .acpV2
    )

    /// The vendored ACP v2 unstable schema set, emitted into the `Unstable`
    /// namespace.
    ///
    /// Upstream publishes the unstable surface as a second, full schema
    /// document. This package does not serve that whole surface: the set
    /// emits only the types that the unstable session updates
    /// `compaction_update`, `compaction_summary_chunk` and `notice` reach. The
    /// set routes no methods, because the primary set already routes the
    /// unstable methods by name. The primary set's method table declares the
    /// `Unstable` enum, and this set's files extend it.
    public static let acpV2Unstable = SchemaSet(
        versionLabel: "v2-unstable",
        outputNamespace: "Unstable",
        schemaPath: "Schema/acp-v2.unstable.json",
        metaPath: nil,
        unstableMetaPath: nil,
        config: .acpV2Unstable
    )

    /// Every vendored schema set the generator emits, in output order.
    ///
    /// Vendoring a second protocol version is an append here plus its schema
    /// artifacts under `Schema/`; the generator and CLI iterate this list
    /// without change.
    public static let all: [SchemaSet] = [.acpV2, .acpV2Unstable]
}
