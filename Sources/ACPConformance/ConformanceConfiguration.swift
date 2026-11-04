import Foundation

/// The agent under test and the limits of a run.
struct ConformanceConfiguration: Sendable {
    /// The default longest wait for one step.
    static let defaultTimeoutSeconds = 60
    static let defaultTimeout = Duration.seconds(defaultTimeoutSeconds)

    /// The default quiet time.
    static let defaultQuietSeconds = 2
    static let defaultQuiet = Duration.seconds(defaultQuietSeconds)

    /// The agent executable. The runner starts it once for each scenario.
    var executable: URL

    /// The arguments of the agent.
    var arguments: [String] = []

    /// The environment of the agent. `nil` inherits the environment of the runner.
    var environment: [String: String]?

    /// The resume scenarios. `nil` runs the two default resumes.
    var script: ConformanceScript?

    /// The working directory that the runner sends in `session/new` and `session/resume`.
    /// The command line makes a new empty folder when `--cwd` is absent.
    var cwd = "/"

    /// The longest wait for one step.
    var timeout = defaultTimeout

    /// How long the wire must be quiet before the runner decides that an agent
    /// will send nothing more. A turn that never reports `idle` ends this way.
    var quiet = defaultQuiet
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

    /// Whether the runner plays an extra turn that it breaks off. The turn
    /// sends the prompt without waiting for the response, waits until a
    /// second session reports `running` (a child of the prompted session),
    /// and then closes the agent. The resumes then target the session of that
    /// turn. Use it for an agent that restores a child which was running when
    /// the process ended. Default: false.
    var interruptedTurn: Bool?

    init(resumes: [Resume], interruptedTurn: Bool? = nil) {
        self.resumes = resumes
        self.interruptedTurn = interruptedTurn
    }
}
