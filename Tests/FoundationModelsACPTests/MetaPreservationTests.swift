import Foundation
import Testing

import FoundationModelsACP

// MARK: - _meta preservation (spec §2: _meta round-trips untouched)

/// A representative `_meta` payload exercising every JSON shape, including a
/// null nested inside the object — nulls *within* `_meta` are data and must be
/// preserved, unlike an absent top-level optional which is omitted.
private let metaFixture = """
{ "vendor": { "trace": "abc-123", "attempt": 2, "flags": [true, false], "note": null } }
"""

/// Asserts a message type carries `_meta` unchanged across decode → encode.
///
/// Works uniformly for requests, responses, and notifications by comparing the
/// re-encoded `_meta` field structurally, so it never depends on a type's
/// concrete meta accessor.
///
/// - Parameters:
///   - type: The message type under test.
///   - fixture: The full message JSON, including its `_meta` field.
///   - expectedMeta: The structural `_meta` value the fixture should preserve.
///   - sourceLocation: The caller location, for failure reporting.
/// - Throws: Rethrows any decode or encode failure.
private func expectMetaPreserved<T: Codable>(
    _ type: T.Type,
    fixture: String,
    expectedMeta: JSONValue,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let model = try decoded(T.self, fixture: fixture)
    let encoded = try encodedValue(model)
    #expect(field("_meta", of: encoded) == expectedMeta, sourceLocation: sourceLocation)
}

@Test func metaRoundTripsUntouchedOnRequest() throws {
    let fixture = """
    { "cwd": "/home/user/project", "mcpServers": [], "_meta": \(metaFixture) }
    """
    try expectMetaPreserved(
        NewSessionRequest.self,
        fixture: fixture,
        expectedMeta: try jsonValue(fixture: metaFixture)
    )
}

@Test func metaRoundTripsUntouchedOnResponse() throws {
    let fixture = """
    { "sessionId": "sess_abc123", "_meta": \(metaFixture) }
    """
    try expectMetaPreserved(
        NewSessionResponse.self,
        fixture: fixture,
        expectedMeta: try jsonValue(fixture: metaFixture)
    )
}

@Test func metaRoundTripsUntouchedOnNotification() throws {
    let fixture = """
    {
      "sessionId": "sess_abc123",
      "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "hi" } },
      "_meta": \(metaFixture)
    }
    """
    try expectMetaPreserved(
        SessionNotification.self,
        fixture: fixture,
        expectedMeta: try jsonValue(fixture: metaFixture)
    )
}

@Test func absentMetaIsOmittedOnNotification() throws {
    // A notification with no _meta must encode without the field, never as null.
    let fixture = """
    {
      "sessionId": "sess_abc123",
      "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "hi" } }
    }
    """
    let model = try decoded(SessionNotification.self, fixture: fixture)
    let encoded = try encodedValue(model)
    #expect(field("_meta", of: encoded) == nil)
    #expect(!containsNull(encoded))
}
