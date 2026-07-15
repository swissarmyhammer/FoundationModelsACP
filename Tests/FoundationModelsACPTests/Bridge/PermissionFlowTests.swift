import Foundation
import Testing

@testable import FoundationModelsACP

/// Asserts that a ``ClientEnvironment`` round-trips `session/request_permission`
/// and maps its outcome to consent: an allowing option grants, while a
/// rejecting option or a cancelled turn surfaces as a typed error the tool
/// converts into a failed `tool_call_update` (spec §7).
@Suite("Permission flow")
struct PermissionFlowTests {
    /// An allowing option the user can select.
    private static let allow = PermissionOption(
        kind: .allowOnce,
        name: "Allow",
        optionId: PermissionOptionId(rawValue: "allow")
    )

    /// A rejecting option the user can select.
    private static let reject = PermissionOption(
        kind: .rejectOnce,
        name: "Reject",
        optionId: PermissionOptionId(rawValue: "reject")
    )

    /// The tool call permission is requested for.
    private static let toolCall = ToolCallUpdate(toolCallId: ToolCallId(rawValue: "call-1"))

    /// The options offered on every request.
    private static let options = [allow, reject]

    /// Wires an environment whose client returns `outcome`, plus the client.
    ///
    /// - Parameter outcome: The permission outcome the client answers with.
    /// - Returns: The environment handle and the recording client.
    private func wire(
        outcome: RequestPermissionOutcome
    ) async -> (environment: ClientEnvironment, client: RecordingEnvironmentClient) {
        let client = RecordingEnvironmentClient(configuration: .init(permissionOutcome: outcome))
        let wired = await makeWiredEnvironment(capabilities: ClientCapabilities(), client: client)
        return (wired.environment, client)
    }

    @Test("Selecting an allowing option grants and returns that option")
    func grantReturnsSelectedOption() async throws {
        let (environment, client) = await wire(
            outcome: .selected(SelectedPermissionOutcome(optionId: Self.allow.optionId))
        )

        let granted = try await environment.requestPermission(toolCall: Self.toolCall, options: Self.options)

        #expect(granted == Self.allow)
        #expect(client.recordedCalls == ["requestPermission"])
        #expect(client.lastPermission?.options == Self.options)
        #expect(client.lastPermission?.sessionId == testSessionId)
    }

    @Test("Selecting a rejecting option denies with a typed error")
    func rejectionThrowsPermissionDenied() async throws {
        let (environment, _) = await wire(
            outcome: .selected(SelectedPermissionOutcome(optionId: Self.reject.optionId))
        )

        await #expect(throws: ClientEnvironmentError.permissionDenied(.rejected(Self.reject.optionId))) {
            _ = try await environment.requestPermission(toolCall: Self.toolCall, options: Self.options)
        }
    }

    @Test("A cancelled outcome denies with a typed error")
    func cancellationThrowsPermissionDenied() async throws {
        let (environment, _) = await wire(outcome: .cancelled)

        await #expect(throws: ClientEnvironmentError.permissionDenied(.cancelled)) {
            _ = try await environment.requestPermission(toolCall: Self.toolCall, options: Self.options)
        }
    }

    @Test("A permission denial drives the tool to a failed tool_call_update")
    func denialBecomesFailedUpdate() async throws {
        let (environment, _) = await wire(
            outcome: .selected(SelectedPermissionOutcome(optionId: Self.reject.optionId))
        )

        // Model a tool wrapping the gated call: it completes on a grant and
        // fails on any client-environment denial. The resulting status is
        // decided by which branch the SUT drives, not assigned up front.
        let update = await Self.toolCallGuardedByPermission(environment)

        #expect(update.status == .failed)
    }

    /// Runs a permission-gated tool call and reports the tool call it would
    /// send: completed on a grant, failed when the environment denies.
    ///
    /// - Parameter environment: The environment whose permission the tool asks.
    /// - Returns: The tool call update reflecting the outcome.
    private static func toolCallGuardedByPermission(_ environment: ClientEnvironment) async -> ToolCallUpdate {
        do {
            _ = try await environment.requestPermission(toolCall: toolCall, options: options)
            return ToolCallUpdate(toolCallId: toolCall.toolCallId, status: .completed)
        } catch is ClientEnvironmentError {
            return ToolCallUpdate(toolCallId: toolCall.toolCallId, status: .failed)
        } catch {
            return ToolCallUpdate(toolCallId: toolCall.toolCallId, status: .unknown("unexpected"))
        }
    }
}
