import Foundation

/// The agent under test and the limits of a run.
struct ConformanceConfiguration: Sendable {
    /// The agent executable. The runner starts it once for each scenario.
    var executable: URL

    /// The arguments of the agent.
    var arguments: [String] = []

    /// The environment of the agent. `nil` inherits the environment of the runner.
    var environment: [String: String]?

    /// The resume scenarios. `nil` runs the two default resumes.
    var script: ConformanceScript?

    /// The working directory that the runner sends in `session/new` and `session/resume`.
    var cwd = "/"

    /// The longest wait for one step.
    var timeout: Duration = .seconds(60)

    /// How long the wire must be quiet before the runner decides that an agent
    /// will send nothing more. A turn that never reports `idle` ends this way.
    var quiet: Duration = .seconds(2)
}

/// The resume scenarios for an agent under test, read from a JSON file:
///
///     { "resumes": [ { "sessionId": "root", "replayFrom": true, "untilToolCall": "call-1" } ] }
///
/// Use a script when the agent needs a particular session to show nested
/// sub-agents. Each step starts a new agent process.
struct ConformanceScript: Codable, Sendable {
    struct Resume: Codable, Sendable {
        /// The session to resume. When absent, the session that the runner created.
        var sessionId: String?

        /// Whether to send `replayFrom: start`. Default: true.
        var replayFrom: Bool?

        /// Stop the recording after the final status of this tool call. When
        /// absent, the recording stops when the wire is quiet after the response.
        var untilToolCall: String?

        init(sessionId: String? = nil, replayFrom: Bool? = nil, untilToolCall: String? = nil) {
            self.sessionId = sessionId
            self.replayFrom = replayFrom
            self.untilToolCall = untilToolCall
        }
    }

    var resumes: [Resume]
}
