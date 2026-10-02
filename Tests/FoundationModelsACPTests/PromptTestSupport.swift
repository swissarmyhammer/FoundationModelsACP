@testable import FoundationModelsACP

/// The `session/prompt` acknowledgement that the stub agents in these suites
/// return.
///
/// The schema requires each prompt response to name the user message that the
/// agent inserted. A stub agent does not echo the prompt, and no test that
/// uses this value reads the id. Thus all stubs name the same fixed message.
/// A suite that tests message identity makes its own id instead.
extension PromptResponse {
    /// The acknowledgement of a stub agent, which names one fixed user message.
    static let stubAcknowledgement = PromptResponse(messageId: MessageId(rawValue: "stub-user-message"))
}
