import Foundation
import Testing

@testable import FoundationModelsACP

/// The `error` stop reason and the `error` object of an idle `state_update`.
///
/// `schema-v2.0.0-alpha.8` adds `stopReason: "error"` and an optional JSON-RPC
/// error object beside it. A proxy must decode and encode the two with no data
/// loss, so the error object is a typed field and not a dropped member.
@Suite struct IdleErrorRoundTripTests {
    /// The wire object of an idle update that ended with a failure.
    private static let idleWire = #"""
        {"state":"idle","stopReason":"error",
         "error":{"code":-32603,"message":"Model failed","data":{"retryable":false}}}
        """#

    /// The typed value that `idleWire` holds.
    private static let idle = IdleStateUpdate(
        error: ACPError(
            code: .internalError,
            message: "Model failed",
            data: .object(["retryable": .bool(false)])
        ),
        stopReason: .error
    )

    @Test func idleErrorDecodesAndEncodesWithNoDataLoss() throws {
        let decoded = try WireRoundTrip.expectLossless(StateUpdate.self, Self.idleWire)
        #expect(decoded == .idle(Self.idle))
    }

    @Test func idleErrorRoundTripsInsideASessionUpdate() throws {
        let wire = #"""
            {"sessionUpdate":"state_update","state":"idle","stopReason":"error",
             "error":{"code":-32603,"message":"Model failed","data":{"retryable":false}}}
            """#
        let decoded = try WireRoundTrip.expectLossless(SessionUpdate.self, wire)
        #expect(decoded == .stateUpdate(.idle(Self.idle)))
    }

    @Test func errorStopReasonWithoutAnErrorObjectStaysWithoutOne() throws {
        let decoded = try WireRoundTrip.expectLossless(StateUpdate.self, #"{"state":"idle","stopReason":"error"}"#)
        #expect(decoded == .idle(IdleStateUpdate(stopReason: .error)))
    }

    @Test func errorStopReasonEncodesAsItsWireValue() throws {
        #expect(try WireRoundTrip.encode(StopReason.error) == .string("error"))
    }
}
