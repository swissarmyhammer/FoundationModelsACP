import Testing

@testable import FoundationModelsACP

// MARK: - Multi-block rendering

@Test("a multi-block prompt renders text, embedded resource, and resource link into one string")
func multiBlockPromptRendersToString() throws {
    let blocks: [ContentBlock] = [
        .text(TextContent(text: "Summarize this file")),
        .resource(
            EmbeddedResource(
                resource: .object([
                    "text": .string("file body"),
                    "uri": .string("file:///notes.txt"),
                ])
            )
        ),
        .resourceLink(ResourceLink(name: "spec", uri: "file:///spec.md")),
    ]

    let rendered = try PromptInputMapper.render(
        blocks,
        capabilities: FoundationModelsAgent.promptCapabilities
    )

    #expect(rendered == "Summarize this file\n\nfile body\n\n[resource: spec](file:///spec.md)")
}

// MARK: - Capability gating

@Test("an audio block is rejected with -32602 when the audio capability is off")
func audioBlockRejectedWhenCapabilityOff() {
    let blocks: [ContentBlock] = [.audio(AudioContent(data: "AAAA", mimeType: "audio/wav"))]

    let error = capturedRequestError {
        _ = try PromptInputMapper.render(blocks, capabilities: FoundationModelsAgent.promptCapabilities)
    }
    #expect(error?.code == -32602)
}

@Test("an image block is rejected with -32602 when the image capability is off")
func imageBlockRejectedWhenCapabilityOff() {
    let blocks: [ContentBlock] = [.image(ImageContent(data: "AAAA", mimeType: "image/png"))]

    let error = capturedRequestError {
        _ = try PromptInputMapper.render(blocks, capabilities: FoundationModelsAgent.promptCapabilities)
    }
    #expect(error?.code == -32602)
}

@Test("an embedded resource is rejected with -32602 when embedded context is off")
func embeddedResourceRejectedWhenCapabilityOff() {
    let blocks: [ContentBlock] = [
        .resource(EmbeddedResource(resource: .object(["text": .string("x")])))
    ]
    let capabilities = PromptCapabilities(audio: false, embeddedContext: false, image: false)

    let error = capturedRequestError {
        _ = try PromptInputMapper.render(blocks, capabilities: capabilities)
    }
    #expect(error?.code == -32602)
}

@Test("an unrecognized block type is rejected with -32602")
func unknownBlockRejected() {
    let blocks: [ContentBlock] = [.unknown("video")]

    let error = capturedRequestError {
        _ = try PromptInputMapper.render(blocks, capabilities: FoundationModelsAgent.promptCapabilities)
    }
    #expect(error?.code == -32602)
}

// MARK: - Helpers

/// Runs `body` and returns the ``RequestError`` it threw, or nil.
///
/// - Parameter body: The rendering call expected to throw.
/// - Returns: The thrown ``RequestError``, or nil when it threw something else
///   or nothing.
private func capturedRequestError(_ body: () throws -> Void) -> RequestError? {
    do {
        try body()
        return nil
    } catch let error as RequestError {
        return error
    } catch {
        return nil
    }
}
