import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - RoleRouting

@Suite struct RoleRoutingTests {
    @Test func servedOnAgentReturnsExactlyTheAgentSideEntriesKeyedByWireMethod() {
        let served = RoleRouting.served(on: .agent)
        let expected = ACPMethodTable.methods.filter { $0.side == .agent }
        #expect(served.count == expected.count)
        for entry in expected {
            #expect(served[entry.wireMethod]?.handlerName == entry.handlerName)
        }
    }

    @Test func servedOnClientReturnsExactlyTheClientSideEntriesKeyedByWireMethod() {
        let served = RoleRouting.served(on: .client)
        let expected = ACPMethodTable.methods.filter { $0.side == .client }
        #expect(served.count == expected.count)
        for entry in expected {
            #expect(served[entry.wireMethod]?.handlerName == entry.handlerName)
        }
    }

    @Test func servedOnProtocolLevelReturnsOnlyCancelRequest() {
        let served = RoleRouting.served(on: .protocolLevel)
        #expect(served.count == 1)
        #expect(served.values.first?.handlerName == "cancelRequest")
    }

    @Test func wireResolvesEveryAgentHandlerToItsRoutingTableWireMethod() {
        for entry in ACPMethodTable.methods where entry.side == .agent {
            #expect(RoleRouting.wireMethod(for: entry.handlerName, on: .agent) == entry.wireMethod)
        }
    }

    @Test func wireResolvesEveryClientHandlerToItsRoutingTableWireMethod() {
        for entry in ACPMethodTable.methods where entry.side == .client {
            #expect(RoleRouting.wireMethod(for: entry.handlerName, on: .client) == entry.wireMethod)
        }
    }

    @Test func methodNotFoundNamesTheResolvedWireMethodNotTheHandlerName() {
        let error = RoleRouting.methodNotFound(handler: "prompt", on: .agent)
        #expect(error.code == .methodNotFound)
        #expect(error.data == .object(["method": .string("session/prompt")]))
    }
}

// MARK: - JSONValue typed coding helpers

@Suite struct JSONValueRoleCodingTests {
    private struct Params: Codable, Equatable {
        var text: String
    }

    @Test func decodeParamsTreatsNilAsAnEmptyObject() throws {
        // Swift's synthesized `Decodable` requires every non-optional member's
        // key to be present, default value or not — an all-defaulted model is
        // therefore one whose members are optional, decoding an absent key to
        // `nil` rather than to a default.
        struct AllDefaulted: Codable, Equatable {
            var flag: Bool?
        }
        let decoded = try JSONValue.decodeParams(AllDefaulted.self, from: nil)
        #expect(decoded == AllDefaulted())
    }

    @Test func decodeParamsDecodesAMatchingObject() throws {
        let decoded = try JSONValue.decodeParams(Params.self, from: .object(["text": .string("hi")]))
        #expect(decoded == Params(text: "hi"))
    }

    @Test func decodeParamsThrowsInvalidParamsOnAMismatchedShape() {
        #expect(throws: RequestError.self) {
            _ = try JSONValue.decodeParams(Params.self, from: .object(["text": .number(1)]))
        }
        do {
            _ = try JSONValue.decodeParams(Params.self, from: .object(["text": .number(1)]))
            Issue.record("expected invalidParams")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
        } catch {
            Issue.record("expected a RequestError, got \(error)")
        }
    }

    @Test func encodeResultThenDecodedRoundTrips() throws {
        let value = Params(text: "round trip")
        let encoded = try JSONValue.encode(result: value)
        #expect(encoded == .object(["text": .string("round trip")]))
        let decoded = try encoded.decoded(as: Params.self)
        #expect(decoded == value)
    }

    @Test func decodedThrowsOnAMismatchedShape() {
        let value = JSONValue.object(["text": .number(1)])
        #expect(throws: (any Error).self) {
            _ = try value.decoded(as: Params.self)
        }
    }
}
