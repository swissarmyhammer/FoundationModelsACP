import Foundation
import FoundationModelsACP

/// A parsed routing manifest (`meta.json` / `meta.unstable.json`): the three
/// side groups, each mapping a snake_case routing key to a wire method name.
struct RoutingManifest {
    /// Routing groups keyed by side: routing key → wire method name.
    let methodsBySide: [MethodSide: [String: String]]
}

/// One `x-side`/`x-method` annotation target in the schema: the (side, wire
/// method) pair a definition belongs to.
private struct SchemaRoute: Hashable {
    /// The participant that serves the method.
    let side: MethodSide

    /// The method name as it crosses the wire.
    let wireMethod: String
}

extension SchemaGenerator {
    /// The manifest's routing groups in emission order, mapped to sides.
    private static let manifestGroups: [(key: String, side: MethodSide)] = [
        ("agentMethods", .agent),
        ("clientMethods", .client),
        ("protocolMethods", .protocolLevel),
    ]

    /// The only manifest layout revision this generator understands.
    private static let supportedManifestVersion = JSONValue.number(1)

    /// A side's position in emission order (agent, client, protocol).
    ///
    /// - Parameter side: The side to rank.
    /// - Returns: The side's emission rank.
    private static func rank(of side: MethodSide) -> Int {
        manifestGroups.firstIndex { $0.side == side } ?? manifestGroups.count
    }

    /// Builds the method-routing table file from the routing manifests and
    /// the schema's `x-side`/`x-method` annotations.
    ///
    /// - Parameters:
    ///   - definitions: The schema's `$defs` object.
    ///   - metaJSON: The raw bytes of the stable routing manifest.
    ///   - unstableMetaJSON: The raw bytes of the unstable routing manifest;
    ///     when present, its methods beyond the stable manifest are emitted
    ///     into the `Unstable` namespace.
    /// - Returns: The rendered `MethodTable.generated.swift`.
    /// - Throws: `GeneratorError` when a manifest cannot be parsed or the
    ///   manifests disagree with the schema's annotations.
    func methodTableFile(
        definitions: [String: JSONValue],
        metaJSON: Data,
        unstableMetaJSON: Data?
    ) throws -> GeneratedFile {
        let manifest = try parseRoutingManifest(metaJSON, context: "routing manifest")
        let stable = try stableMethodModels(manifest: manifest, routes: try schemaRoutes(from: definitions))
        var declarations = [Emitter.methodTableDeclaration(stable)]
        if let unstableMetaJSON {
            let unstableManifest = try parseRoutingManifest(
                unstableMetaJSON,
                context: "unstable routing manifest"
            )
            declarations.append(
                Emitter.unstableNamespaceDeclaration(
                    try unstableMethodModels(stable: manifest, unstable: unstableManifest)
                )
            )
        }
        return GeneratedFile(
            name: "MethodTable.generated.swift",
            contents: Emitter.file(declarations: declarations)
        )
    }

    /// Parses and validates a routing manifest document.
    ///
    /// The manifest must be a version-1 object carrying exactly the three
    /// known routing groups; an unknown group or version fails loudly rather
    /// than silently dropping routes.
    ///
    /// - Parameters:
    ///   - data: The raw manifest bytes.
    ///   - context: Which manifest, for error messages.
    /// - Returns: The parsed manifest.
    /// - Throws: `GeneratorError.invalidSchema` for any shape deviation.
    private func parseRoutingManifest(_ data: Data, context: String) throws -> RoutingManifest {
        let manifest: JSONValue
        do {
            manifest = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GeneratorError.invalidSchema("\(context) is not parseable as JSON: \(error)")
        }
        guard let members = manifest.objectValue else {
            throw GeneratorError.invalidSchema("\(context) is not a JSON object")
        }
        guard members["version"] == Self.supportedManifestVersion else {
            throw GeneratorError.invalidSchema("\(context) does not declare supported version 1")
        }
        let knownKeys = Set(Self.manifestGroups.map(\.key) + ["version"])
        for key in members.keys.sorted() where !knownKeys.contains(key) {
            throw GeneratorError.invalidSchema("\(context) has unknown member \"\(key)\"")
        }

        var methodsBySide: [MethodSide: [String: String]] = [:]
        for (key, side) in Self.manifestGroups {
            guard let group = members[key]?.objectValue else {
                throw GeneratorError.invalidSchema("\(context) is missing routing group \"\(key)\"")
            }
            var methods: [String: String] = [:]
            var seenWires = Set<String>()
            for (routingKey, value) in group.sorted(by: { $0.key < $1.key }) {
                guard let wireMethod = value.stringValue else {
                    throw GeneratorError.invalidSchema(
                        "\(context) member \(key).\(routingKey) is not a string"
                    )
                }
                guard seenWires.insert(wireMethod).inserted else {
                    throw GeneratorError.invalidSchema(
                        "\(context) routes \"\(wireMethod)\" twice in \(key)"
                    )
                }
                methods[routingKey] = wireMethod
            }
            methodsBySide[side] = methods
        }
        return RoutingManifest(methodsBySide: methodsBySide)
    }

    /// Indexes the schema's `x-side`/`x-method` annotations.
    ///
    /// - Parameter definitions: The schema's `$defs` object.
    /// - Returns: Each annotated (side, method) route mapped to its
    ///   definition names, in name order.
    /// - Throws: `GeneratorError.unsupportedShape` when a definition carries
    ///   only one of the two annotations or an unknown side.
    private func schemaRoutes(from definitions: [String: JSONValue]) throws -> [SchemaRoute: [String]] {
        var routes: [SchemaRoute: [String]] = [:]
        for (name, fragment) in definitions.sorted(by: { $0.key < $1.key }) {
            let sideValue = fragment["x-side"]?.stringValue
            let methodValue = fragment["x-method"]?.stringValue
            if sideValue == nil, methodValue == nil {
                continue
            }
            guard let sideValue, let methodValue else {
                throw GeneratorError.unsupportedShape(
                    context: name,
                    detail: "x-side and x-method must appear together"
                )
            }
            guard let side = MethodSide(rawValue: sideValue) else {
                throw GeneratorError.unsupportedShape(context: name, detail: "unknown x-side \"\(sideValue)\"")
            }
            routes[SchemaRoute(side: side, wireMethod: methodValue), default: []].append(name)
        }
        return routes
    }

    /// Builds the stable routing-table entries, cross-validating the
    /// manifest against the schema's annotations in both directions.
    ///
    /// Every manifest route must resolve to schema definitions and every
    /// annotated definition must be routed by the manifest — the double-entry
    /// check that makes hand-miswiring structurally impossible.
    ///
    /// - Parameters:
    ///   - manifest: The parsed stable routing manifest.
    ///   - routes: The schema's annotation index from `schemaRoutes`.
    /// - Returns: Entries ordered agent, client, protocol, then by wire
    ///   method name within each side.
    /// - Throws: `GeneratorError` on any manifest/schema disagreement,
    ///   duplicate handler name, or stale deprecation config entry.
    private func stableMethodModels(
        manifest: RoutingManifest,
        routes: [SchemaRoute: [String]]
    ) throws -> [MethodModel] {
        var models: [MethodModel] = []
        var consumed = Set<SchemaRoute>()
        for (_, side) in Self.manifestGroups {
            let group = manifest.methodsBySide[side] ?? [:]
            var handlerNames = Set<String>()
            for (routingKey, wireMethod) in group.sorted(by: { $0.value < $1.value }) {
                let route = SchemaRoute(side: side, wireMethod: wireMethod)
                guard let definitionNames = routes[route] else {
                    throw GeneratorError.invalidSchema(
                        "manifest routes \"\(wireMethod)\" on the \(side.rawValue) side but the schema defines no types for it"
                    )
                }
                consumed.insert(route)
                let model = try methodModel(
                    routingKey: routingKey,
                    wireMethod: wireMethod,
                    side: side,
                    definitionNames: definitionNames
                )
                try registerHandlerName(model.handlerName, side: side, in: &handlerNames, label: "handler")
                models.append(model)
            }
        }

        let unrouted = routes.keys
            .filter { !consumed.contains($0) }
            .sorted { (Self.rank(of: $0.side), $0.wireMethod) < (Self.rank(of: $1.side), $1.wireMethod) }
        if let first = unrouted.first {
            throw GeneratorError.invalidSchema(
                "schema annotates \"\(first.wireMethod)\" on the \(first.side.rawValue) side but the manifest does not route it"
            )
        }

        let wireMethods = Set(models.map(\.wireMethod))
        for wireMethod in config.deprecatedMethods.keys.sorted() where !wireMethods.contains(wireMethod) {
            throw GeneratorError.invalidSchema(
                "deprecation config names \"\(wireMethod)\", which is not a routed method"
            )
        }
        return models
    }

    /// Builds one stable entry from a route's schema definitions.
    ///
    /// A `*Request`/`*Response` pair is a request whose handler is the pair's
    /// shared base name (`NewSessionRequest` → `newSession`); a single
    /// `*Notification` is a notification whose handler is the manifest
    /// routing key camelCased (`session_update` → `sessionUpdate`).
    ///
    /// - Parameters:
    ///   - routingKey: The manifest's snake_case routing key.
    ///   - wireMethod: The wire method name.
    ///   - side: The serving participant.
    ///   - definitionNames: The schema definitions annotated with this route.
    /// - Returns: The routing-table entry model.
    /// - Throws: `GeneratorError.unsupportedShape` when the definitions form
    ///   neither shape or a name yields no plain Swift identifier.
    private func methodModel(
        routingKey: String,
        wireMethod: String,
        side: MethodSide,
        definitionNames: [String]
    ) throws -> MethodModel {
        let context = "method \(wireMethod)"
        var requests: [String] = []
        var responses: [String] = []
        var notifications: [String] = []
        for name in definitionNames.sorted() {
            if name.hasSuffix("Notification") {
                notifications.append(name)
            } else if name.hasSuffix("Response") {
                responses.append(name)
            } else if name.hasSuffix("Request") {
                requests.append(name)
            } else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "definition \(name) is neither a Request, a Response, nor a Notification"
                )
            }
        }
        let deprecationMessage = config.deprecatedMethods[wireMethod]
        if requests.count == 1, responses.count == 1, notifications.isEmpty {
            let base = String(requests[0].dropLast("Request".count))
            return MethodModel(
                wireMethod: wireMethod,
                handlerName: try swiftCaseName(fromWire: lowerFirst(base), context: context),
                side: side,
                kind: .request,
                paramsTypeName: emittedName(requests[0]),
                resultTypeName: emittedName(responses[0]),
                deprecationMessage: deprecationMessage
            )
        }
        if notifications.count == 1, requests.isEmpty, responses.isEmpty {
            return MethodModel(
                wireMethod: wireMethod,
                handlerName: try swiftCaseName(fromWire: routingKey, context: context),
                side: side,
                kind: .notification,
                paramsTypeName: emittedName(notifications[0]),
                resultTypeName: nil,
                deprecationMessage: deprecationMessage
            )
        }
        throw GeneratorError.unsupportedShape(
            context: context,
            detail: "definitions [\(definitionNames.sorted().joined(separator: ", "))] form neither a Request/Response pair nor a single Notification"
        )
    }

    /// Builds the `Unstable` namespace entries: methods the unstable
    /// manifest routes beyond the stable manifest, per side.
    ///
    /// The vendored stable schema defines no types for these methods, so
    /// entries carry names and side only, with handlers camelCased from the
    /// manifest routing keys.
    ///
    /// - Parameters:
    ///   - stable: The parsed stable routing manifest.
    ///   - unstable: The parsed unstable routing manifest.
    /// - Returns: Entries ordered agent, client, protocol, then by wire
    ///   method name within each side.
    /// - Throws: `GeneratorError` on a routing key that yields no plain
    ///   Swift identifier or a duplicate handler name within a side.
    private func unstableMethodModels(
        stable: RoutingManifest,
        unstable: RoutingManifest
    ) throws -> [UnstableMethodModel] {
        var models: [UnstableMethodModel] = []
        for (_, side) in Self.manifestGroups {
            let stableWires = Set((stable.methodsBySide[side] ?? [:]).values)
            let group = unstable.methodsBySide[side] ?? [:]
            var handlerNames = Set<String>()
            for (routingKey, wireMethod) in group.sorted(by: { $0.value < $1.value })
            where !stableWires.contains(wireMethod) {
                let handlerName = try swiftCaseName(
                    fromWire: routingKey,
                    context: "unstable method \(wireMethod)"
                )
                try registerHandlerName(handlerName, side: side, in: &handlerNames, label: "unstable handler")
                models.append(
                    UnstableMethodModel(wireMethod: wireMethod, handlerName: handlerName, side: side)
                )
            }
        }
        return models
    }

    /// Records a handler name in a side's seen-set, failing on a collision.
    ///
    /// Both the stable and unstable builders route through this single
    /// check, so the uniqueness rule cannot drift between the two tables.
    ///
    /// - Parameters:
    ///   - handlerName: The derived handler name to register.
    ///   - side: The side the handler serves, for the error message.
    ///   - seen: The side's already-registered handler names.
    ///   - label: The table being built (`handler` / `unstable handler`),
    ///     for the error message.
    /// - Throws: `GeneratorError.invalidSchema` when the name is taken.
    private func registerHandlerName(
        _ handlerName: String,
        side: MethodSide,
        in seen: inout Set<String>,
        label: String
    ) throws {
        guard seen.insert(handlerName).inserted else {
            throw GeneratorError.invalidSchema(
                "duplicate \(label) name \(handlerName) on the \(side.rawValue) side"
            )
        }
    }

    /// Lowercases a type name's leading character to form a handler name.
    ///
    /// - Parameter name: The Pascal-case base name (e.g. `NewSession`).
    /// - Returns: The lower-camel form (e.g. `newSession`).
    private func lowerFirst(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }
}

extension Emitter {
    /// Maps a side to the emitted `MethodSide` case reference.
    ///
    /// - Parameter side: The side to render.
    /// - Returns: The Swift member-access expression (e.g. `.agent`).
    private static func sideCase(_ side: MethodSide) -> String {
        switch side {
        case .agent: ".agent"
        case .client: ".client"
        case .protocolLevel: ".protocolLevel"
        }
    }

    /// Renders the stable method-routing table.
    ///
    /// - Parameter methods: The entries in emission order.
    /// - Returns: The rendered `ACPMethodTable` declaration.
    static func methodTableDeclaration(_ methods: [MethodModel]) -> String {
        var lines = [
            "/// The method-routing table for the stable ACP v1 surface.",
            "///",
            "/// Derived from the vendored `meta.json` routing manifest and the schema's",
            "/// `x-side`/`x-method` annotations — never hand-wired.",
            "public enum ACPMethodTable {",
            "    /// Every stable method, ordered agent, client, protocol and by wire",
            "    /// method name within each side.",
            "    public static let methods: [MethodInfo] = [",
        ]
        for method in methods {
            lines.append(contentsOf: [
                "        MethodInfo(",
                "            wireMethod: \(stringLiteral(method.wireMethod)),",
                "            handlerName: \(stringLiteral(method.handlerName)),",
                "            side: \(sideCase(method.side)),",
                "            kind: .\(method.kind.rawValue),",
                "            paramsTypeName: \(stringLiteral(method.paramsTypeName)),",
                "            resultTypeName: \(method.resultTypeName.map(stringLiteral) ?? "nil"),",
                "            deprecationMessage: \(method.deprecationMessage.map(stringLiteral) ?? "nil")",
                "        ),",
            ])
        }
        lines.append("    ]")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Renders the `Unstable` namespace and its method table.
    ///
    /// - Parameter methods: The unstable-only entries in emission order.
    /// - Returns: The rendered `Unstable` declaration.
    static func unstableNamespaceDeclaration(_ methods: [UnstableMethodModel]) -> String {
        var lines = [
            "/// Protocol surface upstream ACP has not stabilized.",
            "///",
            "/// Everything in this namespace is unsettled — wire names and shapes can",
            "/// change between releases — so callers must gate use behind explicitly",
            "/// negotiated capabilities, never protocol version alone.",
            "public enum Unstable {",
            "    /// Methods routed only by the vendored `meta.unstable.json` manifest.",
            "    ///",
            "    /// The vendored stable schema defines no parameter or result types for",
            "    /// them, so entries carry names and side only.",
            "    public enum MethodTable {",
            "        /// Every unstable-only method, ordered agent, client, protocol and",
            "        /// by wire method name within each side.",
            "        public static let methods: [UnstableMethodInfo] = [",
        ]
        for method in methods {
            lines.append(contentsOf: [
                "            UnstableMethodInfo(",
                "                wireMethod: \(stringLiteral(method.wireMethod)),",
                "                handlerName: \(stringLiteral(method.handlerName)),",
                "                side: \(sideCase(method.side))",
                "            ),",
            ])
        }
        lines.append(contentsOf: ["        ]", "    }", "}"])
        return lines.joined(separator: "\n")
    }
}
