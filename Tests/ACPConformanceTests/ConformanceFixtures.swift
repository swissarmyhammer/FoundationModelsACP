import Foundation

@testable import ACPConformance
@testable import FoundationModelsACP

private final class BundleToken {}

/// Where the built helper executables are.
enum ConformanceTestSupport {
    static var helperAgentURL: URL {
        Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("acp-test-agent")
    }
}

/// Hand-built runs for the evaluator tests. Each baseline follows the rules;
/// a test changes one thing in it.
enum ConformanceFixtures {
    static let session = SessionId(rawValue: "s1")
    static let promptMethod = WireMethod.prompt
    static let resumeMethod = WireMethod.resume

    static func running() -> RecordedRun.Entry { .update(session, .stateUpdate(.running(RunningStateUpdate()))) }
    static func idle(_ reason: StopReason = .endTurn) -> RecordedRun.Entry {
        .update(session, .stateUpdate(.idle(IdleStateUpdate(stopReason: reason))))
    }
    static func response(_ method: String, id: Double = 1, succeeded: Bool = true) -> RecordedRun.Entry {
        .response(id: .number(id), method: method, succeeded: succeeded)
    }
    static func message() -> RecordedRun.Entry {
        .update(session, .agentMessage(AgentMessage(
            messageId: MessageId(rawValue: "m1"), content: .value([.text(TextContent(text: "hi"))]))))
    }
    static func info() -> RecordedRun.Entry {
        .update(session, .sessionInfoUpdate(SessionInfoUpdate(title: .value("t"))))
    }

    /// A turn that follows the rules: the response, `running`, a message, `idle`.
    static func turn() -> RecordedRun {
        RecordedRun(name: "turn", entries: [response(promptMethod), running(), message(), idle()])
    }

    /// A cancelled turn that follows the rules.
    static func cancel() -> RecordedRun {
        RecordedRun(name: "cancel", entries: [response(promptMethod), running(), idle(.cancelled)])
    }

    /// A resume without `replayFrom` that follows the rules.
    static func resume() -> RecordedRun {
        RecordedRun(
            name: "resume", resumeSessionId: session,
            entries: [idle(), info(), response(resumeMethod)])
    }

    /// A resume with `replayFrom` that follows the rules.
    static func replayingResume() -> RecordedRun {
        RecordedRun(
            name: "resume-replay", resumeSessionId: session,
            entries: [message(), idle(), info(), response(resumeMethod)])
    }
}
