import Foundation

@testable import FoundationModelsACP

/// Builds the HTTP requests of a client for the HTTP transport tests.
enum HTTPTestSupport {
    /// The bearer token that the connections of the tests send.
    static let clientToken = "device-token"

    /// Makes one HTTP request of the client.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - target: The request target.
    ///   - connectionId: The `Acp-Connection-Id` header, or `nil` for none.
    ///   - token: The bearer token of the `Authorization` header, or `nil` for
    ///     none.
    ///   - headers: More header fields, written as given; one of them replaces
    ///     a field of the same name above.
    ///   - body: The body of the request.
    /// - Returns: The request.
    static func request(
        _ method: String,
        target: String = "/acp",
        connectionId: String? = nil,
        token: String? = clientToken,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> HTTPRequest {
        var fields: [String: String] = [:]
        if let connectionId {
            fields[HTTPServerTransport.connectionIdHeader] = connectionId
        }
        if let token {
            fields["Authorization"] = "Bearer \(token)"
        }
        fields.merge(headers) { _, given in given }
        return HTTPRequest(method: method, target: target, headers: fields, body: body)
    }
}
