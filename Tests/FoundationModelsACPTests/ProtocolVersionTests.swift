import Foundation
import Testing

import FoundationModelsACP

@Test func protocolVersionEncodesAsBareInteger() throws {
    let data = try JSONEncoder().encode(ProtocolVersion.v1)
    #expect(String(decoding: data, as: UTF8.self) == "1")
}

@Test func protocolVersionDecodesFromBareInteger() throws {
    let decoded = try JSONDecoder().decode(ProtocolVersion.self, from: Data("1".utf8))
    #expect(decoded == ProtocolVersion.v1)
    #expect(decoded.rawValue == 1)
}

@Test func protocolVersionRejectsStringForms() {
    // The wire value is the integer 1 — "v1" and "1.0.0" are labelling, not protocol.
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProtocolVersion.self, from: Data("\"v1\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProtocolVersion.self, from: Data("\"1.0.0\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProtocolVersion.self, from: Data("\"1\"".utf8))
    }
}

@Test func protocolVersionLatestIsV1() {
    #expect(ProtocolVersion.latest == ProtocolVersion.v1)
    #expect(ProtocolVersion.v1 == ProtocolVersion(rawValue: 1))
}
