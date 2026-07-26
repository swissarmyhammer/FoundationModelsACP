import Foundation
import Testing

@testable import FoundationModelsACP

/// `RequestError` — the JSON-RPC error object as a throwable Swift value.
@Suite struct RequestErrorTests {
    @Test func namedErrorsCarryTheirCodesFromTheSchema() throws {
        // The numbers come from the generated `ErrorCode`, which comes from
        // the schema's own constants. Nothing here restates one, so a code
        // that changed upstream cannot disagree with this type.
        #expect(RequestError.parseError.code.wireValue == -32700)
        #expect(RequestError.invalidRequest.code.wireValue == -32600)
        #expect(RequestError.methodNotFound("x").code.wireValue == -32601)
        #expect(RequestError.invalidParams.code.wireValue == -32602)
        #expect(RequestError.internalError().code.wireValue == -32603)
        #expect(RequestError.requestCancelled.code.wireValue == -32800)
        #expect(RequestError.authenticationRequired.code.wireValue == -32000)
        #expect(RequestError.resourceNotFound(uri: "file:///x").code.wireValue == -32002)
    }

    @Test func detailsRideInDataNotInTheMessage() throws {
        // The rule this type exists to keep: a peer reads `data`, never parses
        // `message`. So the details appear as JSON members, and the message
        // stays the code's own short sentence.
        let notFound = RequestError.methodNotFound("session/nope")
        #expect(notFound.message == "Method not found")
        #expect(notFound.data == .object(["method": .string("session/nope")]))

        let missing = RequestError.resourceNotFound(uri: "file:///gone.txt")
        #expect(missing.message == "Resource not found")
        #expect(missing.data == .object(["uri": .string("file:///gone.txt")]))

        let failed = RequestError.internalError(detail: "handler exploded")
        #expect(failed.message == "Internal error")
        #expect(failed.data == .object(["detail": .string("handler exploded")]))
    }

    @Test func anErrorWithoutDetailsOmitsDataEntirely() throws {
        // Not `"data": null`: an absent member and a null member are different
        // documents, and only one of them says "there were no details".
        #expect(RequestError.invalidParams.data == nil)
        #expect(
            try WireRoundTrip.encode(RequestError.invalidParams)
                == .object(["code": .number(-32602), "message": .string("Invalid params")])
        )
    }

    @Test func theWireFormRoundTrips() throws {
        let error = try WireRoundTrip.expectLossless(RequestError.self, """
            {"code":-32602,"message":"Invalid params","data":{"field":"cwd","reason":"must be absolute"}}
            """)
        #expect(error.code == .invalidParams)
        #expect(error.data?["reason"] == .string("must be absolute"))
    }

    @Test func anUnrecognizedCodeSurvivesTheRoundTrip() throws {
        // A peer's implementation-defined code in the JSON-RPC server range is
        // not an ACP constant, and must not be normalized away or rejected.
        let error = try WireRoundTrip.expectLossless(RequestError.self, """
            {"code":-32099,"message":"Vendor specific"}
            """)
        #expect(error.code == .unknown(-32099))
        #expect(error.code.wireValue == -32099)
    }

    @Test func itIsThrowableAndCatchableAsItself() throws {
        // The one thing the schema cannot state about the error object.
        func failing() throws {
            throw RequestError.authenticationRequired
        }
        #expect(throws: RequestError.self) {
            try failing()
        }
    }
}
