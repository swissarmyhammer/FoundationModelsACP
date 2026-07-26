import Foundation
import Testing

@testable import FoundationModelsACP

/// The forgiving-decode helpers behind the schema's two extension keywords.
///
/// `x-deserialize-default-on-error` degrades a malformed field to a default
/// instead of failing the whole message; `x-deserialize-skip-invalid-items`
/// drops malformed array elements instead of failing the array. Together they
/// are why an unknown capability field cannot fail the `initialize` handshake.
///
/// These test the helpers directly, on a hand-written container, so a failure
/// names the helper rather than whichever generated type happened to use it.
@Suite struct ForgivingDecodingTests {
    /// A container-shaped probe: every field decodes through one of the
    /// forgiving helpers, so a test can hand it any JSON object.
    private struct Probe: Decodable {
        var optionalScalar: Int?
        var defaultedScalar: Int
        var requiredArray: [Int]
        var optionalArray: [Int]?

        private enum CodingKeys: String, CodingKey {
            case optionalScalar, defaultedScalar, requiredArray, optionalArray
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            optionalScalar = container.forgivingDecodeIfPresent(Int.self, forKey: .optionalScalar)
            defaultedScalar = container.forgivingDecode(Int.self, forKey: .defaultedScalar, default: 7)
            requiredArray = container.forgivingDecodeArray(of: Int.self, forKey: .requiredArray)
            optionalArray = container.forgivingDecodeArrayIfPresent(of: Int.self, forKey: .optionalArray)
        }
    }

    /// Decodes the probe from a JSON object literal.
    ///
    /// - Parameter json: The object text.
    /// - Returns: The decoded probe.
    /// - Throws: `DecodingError` only if the document itself is malformed —
    ///   never for a field's contents, which is the property under test.
    private func probe(_ json: String) throws -> Probe {
        try WireRoundTrip.decode(Probe.self, from: json)
    }

    @Test func wellFormedValuesDecodeNormally() throws {
        let decoded = try probe("""
            {"optionalScalar":1,"defaultedScalar":2,"requiredArray":[3,4],"optionalArray":[5]}
            """)
        #expect(decoded.optionalScalar == 1)
        #expect(decoded.defaultedScalar == 2)
        #expect(decoded.requiredArray == [3, 4])
        #expect(decoded.optionalArray == [5])
    }

    @Test func absentFieldsTakeTheirDefaults() throws {
        let decoded = try probe("{}")
        #expect(decoded.optionalScalar == nil)
        #expect(decoded.defaultedScalar == 7)
        #expect(decoded.requiredArray == [])
        #expect(decoded.optionalArray == nil)
    }

    @Test func explicitNullIsTreatedAsAbsent() throws {
        let decoded = try probe("""
            {"optionalScalar":null,"defaultedScalar":null,"requiredArray":null,"optionalArray":null}
            """)
        #expect(decoded.optionalScalar == nil)
        #expect(decoded.defaultedScalar == 7)
        #expect(decoded.requiredArray == [])
        #expect(decoded.optionalArray == nil)
    }

    @Test func mistypedScalarsDegradeInsteadOfFailingTheMessage() throws {
        let decoded = try probe("""
            {"optionalScalar":"nope","defaultedScalar":{"also":"nope"}}
            """)
        #expect(decoded.optionalScalar == nil)
        #expect(decoded.defaultedScalar == 7)
    }

    @Test func mistypedArraysDegradeToEmptyOrNil() throws {
        // Not an array at all — distinct from an array holding bad elements.
        let decoded = try probe("""
            {"requiredArray":"nope","optionalArray":17}
            """)
        #expect(decoded.requiredArray == [])
        #expect(decoded.optionalArray == nil)
    }

    @Test func invalidArrayElementsAreSkippedNotFatal() throws {
        // The distinguishing behaviour of `skip-invalid-items`: the valid
        // elements survive. Degrading the whole array to empty would pass an
        // "it did not throw" test while losing every good element.
        let decoded = try probe("""
            {"requiredArray":[1,"two",3,null,{"four":4},5],"optionalArray":["x",6]}
            """)
        #expect(decoded.requiredArray == [1, 3, 5])
        #expect(decoded.optionalArray == [6])
    }

    @Test func anArrayOfEntirelyInvalidElementsBecomesEmptyRatherThanNil() throws {
        // Present-but-all-invalid is not the same as absent: the optional
        // array is `[]`, which says "the peer sent one and none of it parsed".
        let decoded = try probe("""
            {"optionalArray":["x","y"]}
            """)
        #expect(decoded.optionalArray == [])
    }
}
