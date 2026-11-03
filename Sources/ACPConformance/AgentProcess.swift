import Foundation
import FoundationModelsACP

/// One running agent process with a connection and a recorder.
final class AgentProcess: Sendable {
    let client: ClientSideConnection
    let recorder: WireRecorder
    private let transport: SubprocessTransport
    private let consumer: Task<Void, Never>
    private let configuration: ConformanceConfiguration

    /// Starts the agent.
    /// - Throws: An error when the process cannot start.
    init(_ configuration: ConformanceConfiguration) async throws {
        self.configuration = configuration
        transport = try SubprocessTransport(
            executableURL: configuration.executable, arguments: configuration.arguments,
            environment: configuration.environment)
        let recorder = WireRecorder()
        self.recorder = recorder
        client = await ClientSideConnection(stream: transport) { _ in ConformanceClient(recorder: recorder) }
        let events = client.subscribeToAllSessions().events
        consumer = Task {
            for await event in events {
                switch event.event {
                case .update(let update):
                    await recorder.add(sequence: event.sequence, .update(event.sessionId, update))
                case .requestFinished(let id, let method, let outcome):
                    await recorder.add(
                        sequence: event.sequence, .response(id: id, method: method, succeeded: outcome == .succeeded))
                }
            }
        }
    }

    /// Stops the agent.
    func close() async {
        await client.close()
        transport.close()
        consumer.cancel()
    }

    /// Waits until `condition` holds for the entries, or until the wire has
    /// been quiet for the quiet time of the configuration, or until the timeout.
    ///
    /// - Parameter needsCondition: When true, only the condition ends the wait
    ///   (and the timeout).
    /// - Returns: Whether the condition held.
    @discardableResult
    func wait(needsCondition: Bool = false, until condition: ([RecordedRun.Entry]) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.timeout
        var lastCount = await recorder.count
        var lastChange = clock.now
        while clock.now < deadline {
            if condition(await recorder.entries) { return true }
            let count = await recorder.count
            if count != lastCount {
                lastCount = count
                lastChange = clock.now
            } else if !needsCondition, clock.now - lastChange >= configuration.quiet {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Waits until the wire has been quiet for the quiet time.
    func settle() async {
        await wait { _ in false }
    }
}
