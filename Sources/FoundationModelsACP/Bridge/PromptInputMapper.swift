import Foundation

/// Maps an ACP prompt's ``ContentBlock`` list into the string a
/// FoundationModels turn is driven with (spec §7), gating each block on the
/// prompt capabilities the bridge advertised at initialization.
///
/// Text and resource links are the baseline every agent supports; embedded
/// resources render as inline context when the `embeddedContext` capability is
/// advertised. A block of any type the bridge did not advertise — image or
/// audio here, or an unrecognized type — is rejected with JSON-RPC invalid
/// params (`-32602`) rather than silently dropped (spec §2: content is
/// capability-gated).
enum PromptInputMapper {
    /// Renders a prompt's content blocks into the FoundationModels prompt
    /// string.
    ///
    /// Every block is checked against `capabilities` first, so an unsupported
    /// block fails the whole prompt before any text is assembled.
    ///
    /// - Parameters:
    ///   - blocks: The prompt's content blocks, in order.
    ///   - capabilities: The prompt capabilities the bridge advertised.
    /// - Returns: The blocks rendered and joined into one prompt string.
    /// - Throws: ``RequestError`` with code `-32602` when a block's type is not
    ///   advertised.
    static func render(_ blocks: [ContentBlock], capabilities: PromptCapabilities) throws -> String {
        for block in blocks {
            try requireSupported(block, capabilities)
        }
        return blocks.compactMap(fragment(for:)).joined(separator: "\n\n")
    }

    /// Rejects a block whose type the bridge did not advertise.
    ///
    /// - Parameters:
    ///   - block: The block to check.
    ///   - capabilities: The advertised prompt capabilities.
    /// - Throws: ``RequestError`` with code `-32602` when the block is not
    ///   advertised.
    private static func requireSupported(
        _ block: ContentBlock,
        _ capabilities: PromptCapabilities
    ) throws {
        let (allowed, typeName): (Bool, String) =
            switch block {
            case .text: (true, "text")
            case .resourceLink: (true, "resource_link")
            case .resource: (capabilities.embeddedContext, "resource")
            case .image: (capabilities.image, "image")
            case .audio: (capabilities.audio, "audio")
            case .unknown(let type): (false, type)
            }
        guard allowed else {
            throw unsupported(typeName)
        }
    }

    /// Renders one supported block to its prompt fragment.
    ///
    /// Only the block kinds the bridge renders into a text prompt return a
    /// fragment; kinds gated out by ``requireSupported(_:_:)`` never reach here
    /// and map to nothing.
    ///
    /// - Parameter block: The block to render.
    /// - Returns: The fragment, or nil when the block has no text form.
    private static func fragment(for block: ContentBlock) -> String? {
        switch block {
        case .text(let text):
            return text.text
        case .resourceLink(let link):
            return "[resource: \(link.name)](\(link.uri))"
        case .resource(let resource):
            return embeddedFragment(resource)
        case .image, .audio, .unknown:
            return nil
        }
    }

    /// Renders an embedded resource as inline context: its text when it carries
    /// text, otherwise a reference to its URI.
    ///
    /// - Parameter resource: The embedded resource block.
    /// - Returns: The inline context fragment.
    private static func embeddedFragment(_ resource: EmbeddedResource) -> String {
        guard case .object(let fields) = resource.resource else {
            return "[embedded resource]"
        }
        if case .string(let text)? = fields["text"] {
            return text
        }
        if case .string(let uri)? = fields["uri"] {
            return "[embedded resource: \(uri)]"
        }
        return "[embedded resource]"
    }

    /// Builds the invalid-params error naming an unadvertised content type.
    ///
    /// - Parameter type: The rejected block's wire type name.
    /// - Returns: The `-32602` error carrying the type in its data.
    private static func unsupported(_ type: String) -> RequestError {
        RequestError(
            code: -32602,
            message: "Invalid params",
            data: .object([
                "reason": .string(
                    "content block type '\(type)' is not supported by this agent's prompt capabilities"
                )
            ])
        )
    }
}
