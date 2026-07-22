import Foundation
import Synchronization

// MARK: - Typed coding helpers

extension JSONValue {
    /// Decodes call parameters into a handler's typed model.
    ///
    /// A `nil` params value is treated as an empty object so paramless calls
    /// decode into all-defaulted models.
    ///
    /// - Parameters:
    ///   - modelType: The model type to decode.
    ///   - params: The raw parameters, or `nil` for a paramless call.
    /// - Returns: The decoded model.
    /// - Throws: `RequestError.invalidParams` when the parameters do not
    ///   satisfy the model.
    static func decodeParams<Model: Decodable>(
        _ modelType: Model.Type,
        from params: JSONValue?
    ) throws -> Model {
        do {
            let data = try JSONEncoder().encode(params ?? .object([:]))
            return try JSONDecoder().decode(Model.self, from: data)
        } catch {
            throw RequestError.invalidParams
        }
    }

    /// Encodes a handler's typed result into a structural value for the wire.
    ///
    /// - Parameter result: The model to encode.
    /// - Returns: The encoded structural value.
    /// - Throws: Rethrows any encoding or re-parse failure.
    static func encode<Model: Encodable>(result: Model) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    }

    /// Decodes this structural value into a caller's expected response model.
    ///
    /// - Parameter modelType: The model type to decode.
    /// - Returns: The decoded model.
    /// - Throws: Rethrows any decode failure from a malformed peer response.
    func decoded<Model: Decodable>(as modelType: Model.Type) throws -> Model {
        try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(self))
    }
}

// MARK: - Routing-table lookups

/// Wire-name lookups derived from the generated `ACPMethodTable`.
///
/// The role layer resolves every wire method through this type so that wire
/// method strings live only in the generated routing table and never as
/// literals in hand-written dispatch code.
enum RoleRouting {
    /// The methods served by one side, keyed by their wire method name.
    ///
    /// - Parameter side: The serving participant.
    /// - Returns: A wire-name-to-entry map of that side's methods.
    static func served(on side: MethodSide) -> [String: MethodInfo] {
        Dictionary(
            uniqueKeysWithValues: ACPMethodTable.methods
                .filter { $0.side == side }
                .map { ($0.wireMethod, $0) }
        )
    }

    /// The wire method name for a handler served by one side.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name from the routing table.
    ///   - side: The serving participant.
    /// - Returns: The wire method name.
    static func wire(handler: String, on side: MethodSide) -> String {
        guard
            let match = ACPMethodTable.methods.first(where: {
                $0.side == side && $0.handlerName == handler
            })
        else {
            preconditionFailure("no routing-table entry for handler \"\(handler)\" on side \(side)")
        }
        return match.wireMethod
    }

    /// A method-not-found error naming a handler's wire method.
    ///
    /// Shared by the `Agent` and `Client` default implementations so the
    /// error-construction logic lives in one place.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the unsupported method.
    ///   - side: The side that serves the method.
    /// - Returns: The `-32601` error carrying the method's wire name.
    static func methodNotFound(handler: String, on side: MethodSide) -> RequestError {
        .methodNotFound(wire(handler: handler, on: side))
    }
}

// MARK: - Inbound / outbound dispatch helpers

/// Decode-call-encode helpers shared by both connection roles.
///
/// Inbound helpers decode parameters, invoke a role handler, and encode the
/// result; outbound helpers encode parameters, issue the wire call, and decode
/// the response — all keyed through `RoleRouting` so no wire strings appear.
enum RoleDispatch {
    /// The wire result of a request whose handler returns no value.
    static let emptyResult: JSONValue = .object([:])

    /// Serves a request whose handler returns a typed response.
    ///
    /// - Parameters:
    ///   - params: The raw request parameters.
    ///   - requestType: The parameters' model type.
    ///   - body: The role handler to invoke with the decoded parameters.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.invalidParams` on a decode failure, or any
    ///   error the handler throws.
    static func serveResult<Request: Decodable, Response: Encodable>(
        _ params: JSONValue?,
        as requestType: Request.Type,
        _ body: (Request) async throws -> Response
    ) async throws -> JSONValue {
        try await serve(params, as: requestType) { request in
            let response = try await body(request)
            return try JSONValue.encode(result: response)
        }
    }

    /// Serves a request whose handler returns no value, answering `{}`.
    ///
    /// - Parameters:
    ///   - params: The raw request parameters.
    ///   - requestType: The parameters' model type.
    ///   - body: The role handler to invoke with the decoded parameters.
    /// - Returns: The empty result object.
    /// - Throws: `RequestError.invalidParams` on a decode failure, or any
    ///   error the handler throws.
    static func serveEmpty<Request: Decodable>(
        _ params: JSONValue?,
        as requestType: Request.Type,
        _ body: (Request) async throws -> Void
    ) async throws -> JSONValue {
        try await serve(params, as: requestType) { request in
            try await body(request)
            return emptyResult
        }
    }

    /// The single decode-then-invoke path behind `serveResult` and
    /// `serveEmpty`, which differ only in how they turn the handler's outcome
    /// into a wire response.
    ///
    /// - Parameters:
    ///   - params: The raw request parameters.
    ///   - requestType: The parameters' model type.
    ///   - respond: Invokes the role handler with the decoded parameters and
    ///     produces the encoded response value.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.invalidParams` on a decode failure, or any
    ///   error the handler throws.
    private static func serve<Request: Decodable>(
        _ params: JSONValue?,
        as requestType: Request.Type,
        _ respond: (Request) async throws -> JSONValue
    ) async throws -> JSONValue {
        try await respond(JSONValue.decodeParams(Request.self, from: params))
    }

    /// Issues an outbound request and decodes its typed response.
    ///
    /// - Parameters:
    ///   - connection: The underlying full-duplex connection.
    ///   - handler: The Swift handler name to resolve to a wire method.
    ///   - side: The serving side of the target method.
    ///   - params: The typed request parameters.
    ///   - responseType: The expected response model type.
    /// - Returns: The decoded response.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on
    ///   disconnect, or a decode failure on a malformed response.
    static func callResult<Request: Encodable, Response: Decodable>(
        _ connection: Connection,
        handler: String,
        on side: MethodSide,
        _ params: Request,
        returning responseType: Response.Type
    ) async throws -> Response {
        try await call(connection, handler: handler, on: side, params).decoded(as: Response.self)
    }

    /// Issues an outbound request whose response carries no value of interest.
    ///
    /// - Parameters:
    ///   - connection: The underlying full-duplex connection.
    ///   - handler: The Swift handler name to resolve to a wire method.
    ///   - side: The serving side of the target method.
    ///   - params: The typed request parameters.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    static func callEmpty<Request: Encodable>(
        _ connection: Connection,
        handler: String,
        on side: MethodSide,
        _ params: Request
    ) async throws {
        _ = try await call(connection, handler: handler, on: side, params)
    }

    /// The single encode-resolve-request path behind `callResult` and
    /// `callEmpty`, which differ only in whether they decode the raw result.
    ///
    /// - Parameters:
    ///   - connection: The underlying full-duplex connection.
    ///   - handler: The Swift handler name to resolve to a wire method.
    ///   - side: The serving side of the target method.
    ///   - params: The typed request parameters.
    /// - Returns: The response's raw `result` value.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    private static func call<Request: Encodable>(
        _ connection: Connection,
        handler: String,
        on side: MethodSide,
        _ params: Request
    ) async throws -> JSONValue {
        try await connection.request(
            method: RoleRouting.wire(handler: handler, on: side),
            params: JSONValue.encode(result: params)
        )
    }

    /// Sends an outbound notification; no response is expected.
    ///
    /// - Parameters:
    ///   - connection: The underlying full-duplex connection.
    ///   - handler: The Swift handler name to resolve to a wire method.
    ///   - side: The serving side of the target notification.
    ///   - params: The typed notification parameters.
    /// - Throws: `ConnectionError.closed` after disconnect, or a transport
    ///   write failure.
    static func notify<Params: Encodable>(
        _ connection: Connection,
        handler: String,
        on side: MethodSide,
        _ params: Params
    ) async throws {
        try await connection.notify(
            method: RoleRouting.wire(handler: handler, on: side),
            params: JSONValue.encode(result: params)
        )
    }
}

// MARK: - Role holder

/// A write-once, thread-safe cell holding the role object a connection serves.
///
/// The connection's inbound handlers capture this holder rather than the
/// connection itself, which breaks the initialization cycle between a
/// connection and the role its own factory builds from it.
final class RoleHolder<Role: Sendable>: Sendable {
    /// The stored role, guarded for the read loop and inbound handler tasks.
    private let storage = Mutex<Role?>(nil)

    /// Stores the role, called once before the read loop can dispatch.
    ///
    /// - Parameter role: The role object to serve inbound calls.
    func set(_ role: Role) {
        storage.withLock { $0 = role }
    }

    /// The stored role, or `nil` before wiring completes.
    var role: Role? {
        storage.withLock { $0 }
    }
}

// MARK: - Deprecated method routing

/// Routing for the deprecated `session/set_mode` method.
///
/// The requirement is intentionally not deprecated so the connection can call
/// it without a warning, while its witness is deprecated so the witness body
/// forms a deprecated context permitted to invoke `Agent.setSessionMode`. This
/// is the one construction that keeps the library's build warning-free while
/// still deprecating the method for external callers.
protocol DeprecatedRouting {
    /// Routes an inbound `session/set_mode` request to the agent.
    ///
    /// - Parameters:
    ///   - agent: The agent serving the request.
    ///   - params: The raw request parameters.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.invalidParams` on a decode failure, or any
    ///   error the agent throws.
    func routeSetSessionMode(_ agent: any Agent, params: JSONValue?) async throws -> JSONValue
}

/// The default `DeprecatedRouting` implementation.
struct DeprecatedRouter: DeprecatedRouting {
    @available(*, deprecated)
    func routeSetSessionMode(_ agent: any Agent, params: JSONValue?) async throws -> JSONValue {
        try await RoleDispatch.serveResult(params, as: SetSessionModeRequest.self, agent.setSessionMode)
    }
}
