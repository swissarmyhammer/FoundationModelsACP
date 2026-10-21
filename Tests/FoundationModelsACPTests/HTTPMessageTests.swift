import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Helpers

/// The bytes of a text, as a client sends them.
///
/// - Parameter text: The text of the request.
/// - Returns: The UTF-8 bytes of `text`.
private func wire(_ text: String) -> Data {
    Data(text.utf8)
}

/// A complete `POST` request with a body of two bytes.
private let postRequest = "POST /acp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}"

// MARK: - Parsing requests

@Test func aCompleteRequestParsesToItsMethodTargetHeadersAndBody() throws {
    var parser = HTTPRequestParser()

    let requests = try parser.append(wire(postRequest))

    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.method == "POST")
    #expect(request.target == "/acp")
    #expect(request.header(named: "host") == "localhost")
    #expect(request.body == wire("{}"))
}

@Test func aRequestSplitAcrossChunksParsesWhenItsLastByteArrives() throws {
    var parser = HTTPRequestParser()
    let bytes = wire(postRequest)

    let early = try parser.append(bytes.prefix(bytes.count - 1))
    let late = try parser.append(bytes.suffix(1))

    #expect(early.isEmpty)
    #expect(late.first?.body == wire("{}"))
}

@Test func twoPipelinedRequestsParseInOrder() throws {
    var parser = HTTPRequestParser()

    let requests = try parser.append(wire(postRequest + "GET /acp HTTP/1.1\r\n\r\n"))

    #expect(requests.map(\.method) == ["POST", "GET"])
}

@Test func aHeaderNameMatchesInAnyCase() throws {
    var parser = HTTPRequestParser()

    let request = try #require(try parser.append(wire("GET / HTTP/1.1\r\nACP-CONNECTION-ID: abc\r\n\r\n")).first)

    #expect(request.header(named: HTTPServerTransport.connectionIdHeader) == "abc")
}

@Test func aRequestWithNoContentLengthHasAnEmptyBody() throws {
    var parser = HTTPRequestParser()

    let request = try #require(try parser.append(wire("DELETE /acp HTTP/1.1\r\n\r\n")).first)

    #expect(request.body.isEmpty)
}

@Test func aChunkedRequestBodyIsRefused() {
    var parser = HTTPRequestParser()

    #expect(throws: HTTPParseError.unsupportedTransferEncoding) {
        try parser.append(wire("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
    }
}

@Test func aMalformedRequestLineIsRefused() {
    var parser = HTTPRequestParser()

    #expect(throws: HTTPParseError.malformed) {
        try parser.append(wire("NOT-HTTP\r\n\r\n"))
    }
}

@Test func anInvalidContentLengthIsRefused() {
    var parser = HTTPRequestParser()

    #expect(throws: HTTPParseError.malformed) {
        try parser.append(wire("POST / HTTP/1.1\r\nContent-Length: -2\r\n\r\n"))
    }
}

@Test func aHeaderSectionPastTheLimitIsRefused() {
    var parser = HTTPRequestParser()
    let oversized = Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maximumHeaderBytes + 1)

    #expect(throws: HTTPParseError.headerTooLarge) {
        try parser.append(oversized)
    }
}

@Test func aBodyPastTheLimitIsRefused() {
    var parser = HTTPRequestParser()
    let length = HTTPRequestParser.maximumBodyBytes + 1

    #expect(throws: HTTPParseError.bodyTooLarge) {
        try parser.append(wire("POST / HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"))
    }
}

// MARK: - The bearer token

@Test func theBearerTokenIsTheCredentialOfTheAuthorizationHeader() {
    let request = HTTPRequest(method: "POST", target: "/", headers: ["Authorization": "Bearer abc"], body: Data())

    #expect(request.bearerToken == "abc")
}

@Test func theBearerSchemeMatchesInAnyCase() {
    let request = HTTPRequest(method: "POST", target: "/", headers: ["authorization": "BEARER abc"], body: Data())

    #expect(request.bearerToken == "abc")
}

@Test func anotherAuthorizationSchemeGivesNoBearerToken() {
    let request = HTTPRequest(method: "POST", target: "/", headers: ["Authorization": "Basic abc"], body: Data())

    #expect(request.bearerToken == nil)
}

@Test func anEmptyBearerCredentialGivesNoBearerToken() {
    let request = HTTPRequest(method: "POST", target: "/", headers: ["Authorization": "Bearer "], body: Data())

    #expect(request.bearerToken == nil)
}

// MARK: - Writing responses

@Test func aResponseWritesItsStatusLineHeadersAndBody() {
    let response = HTTPResponse(status: .notFound, headers: ["X-Test": "1"], body: wire("gone"))

    let text = String(decoding: response.serialized(), as: UTF8.self)

    #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    #expect(text.contains("\r\nContent-Length: 4\r\n"))
    #expect(text.contains("\r\nX-Test: 1\r\n"))
    #expect(text.hasSuffix("\r\n\r\ngone"))
}

@Test func aWrittenResponseParsesBackWithTheSameHeaders() throws {
    let response = HTTPResponse(
        status: .accepted,
        headers: [HTTPServerTransport.connectionIdHeader: "abc"],
        body: Data()
    )
    // A response has the same header section as a request; a request line
    // in place of the status line lets the request parser read it back.
    let written = response.serialized()
    let headerSection = try #require(String(data: written, encoding: .utf8)?.split(separator: "\r\n", maxSplits: 1).last)
    var parser = HTTPRequestParser()

    let parsed = try #require(try parser.append(wire("POST / HTTP/1.1\r\n" + headerSection)).first)

    #expect(parsed.header(named: HTTPServerTransport.connectionIdHeader) == "abc")
    #expect(parsed.header(named: "content-length") == "0")
}

@Test func aStreamChunkIsFramedWithItsHexadecimalLength() {
    let chunk = HTTPResponse.chunk(Data(repeating: UInt8(ascii: "x"), count: 26))

    let text = String(decoding: chunk, as: UTF8.self)

    #expect(text == "1a\r\n" + String(repeating: "x", count: 26) + "\r\n")
}
