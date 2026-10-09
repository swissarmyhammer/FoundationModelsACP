import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The time limit of each test in this suite, in minutes.
private let outboundRuleTestTimeout = 1

/// The session of each update in this suite.
private let ruleSession = StubAgent.sessionId

/// The context window size of a correct `usage_update`.
private let windowSize = 200_000

/// The tokens in context of a correct `usage_update`.
private let tokensUsed = 1_234

/// A token count below the schema minimum of zero.
private let negativeTokenCount = -1

/// The cumulative cost of a correct `cost` object.
private let sessionCost = 0.42

/// A currency code that agrees with ISO 4217.
private let validCurrency = "USD"

/// An idle update with a stop reason, wrapped in a notification.
///
/// - Parameter reason: The stop reason of the idle update.
/// - Returns: The notification that carries the idle update.
private func idleUpdate(stoppedBy reason: StopReason) -> UpdateSessionNotification {
    UpdateSessionNotification(sessionId: ruleSession, update: .stateUpdate(.idle(IdleStateUpdate(stopReason: reason))))
}

/// A `usage_update`, wrapped in a notification.
///
/// - Parameter usage: The usage values.
/// - Returns: The notification that carries the usage update.
private func usageUpdate(_ usage: UsageUpdate) -> UpdateSessionNotification {
    UpdateSessionNotification(sessionId: ruleSession, update: .usageUpdate(usage))
}

/// A correct `usage_update` whose cost has a currency code.
///
/// - Parameter currency: The currency code of the cost.
/// - Returns: The notification that carries the usage update.
private func usageUpdate(costIn currency: String) -> UpdateSessionNotification {
    usageUpdate(UsageUpdate(size: windowSize, used: tokensUsed, cost: Cost(amount: sessionCost, currency: currency)))
}

/// A correct update that a test sends after a refused one, to show that the
/// refused update did not reach the wire.
private let correctUpdate = idleUpdate(stoppedBy: .endTurn)

/// The members of a `session/update` frame that this suite reads.
private struct NotificationFrame: Decodable {
    /// The JSON-RPC method of the frame.
    let method: String

    /// The notification that the frame carries.
    let params: UpdateSessionNotification
}

/// An agent connection, and a reader of the frames that it writes.
private struct OutboundHarness {
    /// The agent side, which sends `session/update`.
    let agent: AgentSideConnection

    /// Reads the frames that reach the client end of the transport.
    let reader: WireReader

    /// Connects a `StubAgent` to a raw client end over `InMemoryTransport`.
    static func connect() async -> OutboundHarness {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
        return OutboundHarness(agent: agent, reader: WireReader(clientEnd))
    }

    /// Reads the next frame from the wire, and decodes its parameters as a
    /// `session/update` notification.
    ///
    /// - Returns: The notification on the wire.
    /// - Throws: An error when no frame arrives, or the frame does not decode.
    func nextSentUpdate() async throws -> UpdateSessionNotification {
        let frame = try #require(try await reader.next())
        let notification = try frame.decoded(as: NotificationFrame.self)
        #expect(notification.method == "session/update")
        return notification.params
    }

    /// Sends an update that the agent must refuse, and gives the error.
    ///
    /// The method also sends `correctUpdate`, and expects it as the next
    /// frame. Thus the refused update did not reach the wire.
    ///
    /// - Parameter update: The update that breaks a rule.
    /// - Returns: The description of the encoding error. When the agent did
    ///   not refuse the update, the description of `nil`.
    func refusal(of update: UpdateSessionNotification) async throws -> String {
        let error = await #expect(throws: EncodingError.self) {
            try await agent.sessionUpdate(update)
        }
        try await agent.sessionUpdate(correctUpdate)
        #expect(try await nextSentUpdate() == correctUpdate)
        return String(describing: error)
    }

    /// Sends an update that the agent must send, and expects it on the wire.
    ///
    /// - Parameter update: The update that obeys each rule.
    func expectSent(_ update: UpdateSessionNotification) async throws {
        try await agent.sessionUpdate(update)
        #expect(try await nextSentUpdate() == update)
    }

    /// Closes the agent side.
    func close() async {
        await agent.close()
    }
}

// MARK: - Stop reasons

/// The agent side refuses a stop reason that ACP reserves for itself.
///
/// A custom stop reason starts with `_`. A value without `_` that ACP does
/// not define is reserved for a future ACP version, so an agent must not send
/// it. A peer that receives such a value still decodes it.
@Suite(.timeLimit(.minutes(outboundRuleTestTimeout)))
struct OutboundStopReasonRuleTests {
    @Test(arguments: [StopReason.endTurn, .cancelled, .unknown("_vendor_paused")])
    func aStopReasonThatACPDefinesOrACustomOneIsSent(reason: StopReason) async throws {
        let harness = await OutboundHarness.connect()
        try await harness.expectSent(idleUpdate(stoppedBy: reason))
        await harness.close()
    }

    @Test func anUnknownCaseThatHoldsAnACPValueIsSentAsThatValue() async throws {
        let harness = await OutboundHarness.connect()
        try await harness.agent.sessionUpdate(idleUpdate(stoppedBy: .unknown(StopReason.endTurn.wireValue)))
        #expect(try await harness.nextSentUpdate() == idleUpdate(stoppedBy: .endTurn))
        await harness.close()
    }

    @Test(arguments: ["paused", "", "vendor_paused"])
    func aReservedStopReasonIsRefused(value: String) async throws {
        let harness = await OutboundHarness.connect()
        let description = try await harness.refusal(of: idleUpdate(stoppedBy: .unknown(value)))
        #expect(description.contains("stopReason"))
        await harness.close()
    }
}

// MARK: - Usage values

/// The agent side refuses a `usage_update` whose values break the schema.
///
/// `used` and `size` are `uint64` values, and `cost.currency` is an ISO 4217
/// code of three upper-case letters.
@Suite(.timeLimit(.minutes(outboundRuleTestTimeout)))
struct OutboundUsageRuleTests {
    @Test func usageWithCountsOfZeroOrMoreIsSent() async throws {
        let harness = await OutboundHarness.connect()
        try await harness.expectSent(usageUpdate(UsageUpdate(size: windowSize, used: tokensUsed)))
        try await harness.expectSent(usageUpdate(UsageUpdate(size: 0, used: 0)))
        await harness.close()
    }

    @Test func aNegativeUsedCountIsRefused() async throws {
        let harness = await OutboundHarness.connect()
        let update = usageUpdate(UsageUpdate(size: windowSize, used: negativeTokenCount))
        let description = try await harness.refusal(of: update)
        #expect(description.contains("used"))
        await harness.close()
    }

    @Test func aNegativeSizeIsRefused() async throws {
        let harness = await OutboundHarness.connect()
        let update = usageUpdate(UsageUpdate(size: negativeTokenCount, used: tokensUsed))
        let description = try await harness.refusal(of: update)
        #expect(description.contains("size"))
        await harness.close()
    }

    @Test func aCostWithAnISO4217CurrencyIsSent() async throws {
        let harness = await OutboundHarness.connect()
        try await harness.expectSent(usageUpdate(costIn: validCurrency))
        await harness.close()
    }

    @Test(arguments: ["usd", "US", "USDX", "U$D", "", "ÄBC"])
    func aCurrencyThatIsNotThreeUpperCaseLettersIsRefused(currency: String) async throws {
        let harness = await OutboundHarness.connect()
        let description = try await harness.refusal(of: usageUpdate(costIn: currency))
        #expect(description.contains("currency"))
        await harness.close()
    }
}
