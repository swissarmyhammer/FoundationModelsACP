import Foundation
import Testing

@testable import FoundationModelsACP

/// Runtime decode/encode of the generated tagged unions.
///
/// Two complementary halves. The first is exhaustive over *tags*: it reads
/// every discriminator value the vendored schema declares and checks that each
/// one selects a modeled case rather than falling through to the fallback —
/// the failure a single mistyped tag in the emitter's `switch` would cause,
/// which no hand-written fixture set is likely to catch because it would need
/// a fixture for that exact variant. The second half is hand-written fixtures
/// that pin the whole round trip for one variant of each shape, including a
/// nested one, where the exhaustive half only sees a tag.
@Suite struct TaggedUnionRoundTripTests {
    // MARK: - Every declared tag selects a modeled case

    /// A generated tagged union, bound to the schema definition it came from.
    ///
    /// The tags are read from the schema, so this table carries only what
    /// cannot be derived: which Swift type a definition name became. It must
    /// list every union with a payload-carrying fallback;
    /// `VendoredSchemaTests.everyTaggedUnionCarriesAPayloadBearingFallback`
    /// pins that inventory, so a union added upstream fails there and sends
    /// the next reader here.
    private struct UnionUnderTest: Sendable {
        /// The schema definition name.
        let definition: String

        /// Decodes and re-encodes the union's Swift type.
        let roundTrip: @Sendable (Data) throws -> Data
    }

    /// Builds a decode-then-encode closure for a generated type.
    ///
    /// - Parameter type: The generated union type.
    /// - Returns: A closure mapping wire bytes to re-encoded wire bytes.
    private static func roundTrip<T: Codable & Sendable>(_ type: T.Type) -> @Sendable (Data) throws -> Data {
        { data in try JSONEncoder().encode(try JSONDecoder().decode(T.self, from: data)) }
    }

    /// Every generated union whose fallback carries a payload: the eleven
    /// stand-alone tagged unions, plus the two nested in a base object.
    private static let unionsUnderTest: [UnionUnderTest] = [
        UnionUnderTest(definition: "AuthMethod", roundTrip: roundTrip(AuthMethod.self)),
        UnionUnderTest(definition: "AvailableCommandInput", roundTrip: roundTrip(AvailableCommandInput.self)),
        UnionUnderTest(definition: "ContentBlock", roundTrip: roundTrip(ContentBlock.self)),
        UnionUnderTest(definition: "McpServer", roundTrip: roundTrip(McpServer.self)),
        UnionUnderTest(definition: "PlanUpdateContent", roundTrip: roundTrip(PlanUpdateContent.self)),
        UnionUnderTest(definition: "ReplayFrom", roundTrip: roundTrip(ReplayFrom.self)),
        UnionUnderTest(definition: "RequestPermissionOutcome", roundTrip: roundTrip(RequestPermissionOutcome.self)),
        UnionUnderTest(definition: "RequestPermissionSubject", roundTrip: roundTrip(RequestPermissionSubject.self)),
        UnionUnderTest(definition: "SessionUpdate", roundTrip: roundTrip(SessionUpdate.self)),
        UnionUnderTest(definition: "StateUpdate", roundTrip: roundTrip(StateUpdate.self)),
        UnionUnderTest(definition: "ToolCallContent", roundTrip: roundTrip(ToolCallContent.self)),
        UnionUnderTest(definition: "DiffChange", roundTrip: roundTrip(DiffChange.Payload.self)),
        UnionUnderTest(definition: "SessionConfigOption", roundTrip: roundTrip(SessionConfigOption.Payload.self)),
    ]

    /// A member name no schema variant declares, used to tell a modeled case
    /// from the fallback without knowing either one's payload.
    private static let probeMember = "zzUnmodeledProbe"

    /// A discriminator value no variant declares, used to prove a union reads
    /// the member it claims to.
    private static let unmatchedTag = "zzUnmatchedTagProbe"

    @Test func everyUnionReadsTheDiscriminatorItsVariantsPin() throws {
        // Establishes, once per union, the premise the per-tag test below
        // rests on. A tag no variant declares must reach the fallback: it
        // decodes without error, and re-encodes with both the tag and the
        // probe member intact.
        //
        // A union reading some *other* member instead throws `keyNotFound` for
        // that member — and cannot be told apart from a variant payload
        // missing a required field, because flattened payloads decode from the
        // same container at the same coding path. This probe separates them,
        // because a correct union has nothing to throw on here at all.
        for union in Self.unionsUnderTest {
            let discriminator = try #require(
                Self.declaredTags(of: union.definition).first?.0,
                "\(union.definition) declares no tags; the table names the wrong definition"
            )
            let probe = JSONValue.object([
                discriminator: .string(Self.unmatchedTag),
                Self.probeMember: .number(1),
            ])
            let encoded = try union.roundTrip(JSONEncoder().encode(probe))
            let reencoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
            #expect(
                reencoded[discriminator] == .string(Self.unmatchedTag),
                "\(union.definition) did not re-encode an unrecognized \"\(discriminator)\""
            )
            #expect(
                reencoded[Self.probeMember] == .number(1),
                "\(union.definition) dropped an unrecognized variant's payload"
            )
        }
    }

    @Test func everyDeclaredTagSelectsAModeledCase() throws {
        // How this tells a modeled case from the fallback without building a
        // valid payload for each variant: the fallback captures whatever it
        // does not recognize and writes it back, while a modeled variant's
        // payload struct decodes only its own members and drops the rest. So
        // an object carrying an undeclared probe member comes back *with* the
        // probe if the tag fell through, and without it if the tag matched.
        //
        // A variant whose payload has required members throws before it can be
        // re-encoded, which also proves the tag matched — but only because
        // `everyUnionReadsTheDiscriminatorItsVariantsPin` has already ruled out
        // the other way a union can throw here. That matters: 37 of these 44
        // tags reach the probe by way of a thrown payload error, so on its own
        // this test would leave 9 of the 13 unions asserting nothing.
        for union in Self.unionsUnderTest {
            for (discriminator, tag) in try Self.declaredTags(of: union.definition) {
                let probe = JSONValue.object([
                    discriminator: .string(tag),
                    Self.probeMember: .number(1),
                ])
                let encoded: Data
                do {
                    encoded = try union.roundTrip(JSONEncoder().encode(probe))
                } catch is DecodingError {
                    continue
                }
                let reencoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
                #expect(
                    reencoded[Self.probeMember] == nil,
                    "\(union.definition) tag \"\(tag)\" fell through to the unknown fallback"
                )
            }
        }
    }

    // MARK: - Whole-payload round trips

    @Test func flattenedPayloadRoundTripsBesideItsDiscriminator() throws {
        // The internally-tagged representation: the payload's members sit in
        // the same object as the discriminator, not nested under it.
        let block = try WireRoundTrip.expectLossless(ContentBlock.self, """
            {"type":"text","text":"hello","_meta":{"trace":"abc"}}
            """)
        guard case .text(let text) = block else {
            Issue.record("expected .text, got \(block)")
            return
        }
        #expect(text.text == "hello")
        #expect(text.meta == .object(["trace": .string("abc")]))
    }

    @Test func siblingVariantsOfOneUnionStayDistinct() throws {
        let image = try WireRoundTrip.expectLossless(ContentBlock.self, """
            {"type":"image","data":"AAAA","mimeType":"image/png"}
            """)
        guard case .image = image else {
            Issue.record("expected .image, got \(image)")
            return
        }
        let link = try WireRoundTrip.expectLossless(ContentBlock.self, """
            {"type":"resource_link","name":"readme","uri":"file:///readme.md"}
            """)
        guard case .resourceLink = link else {
            Issue.record("expected .resourceLink, got \(link)")
            return
        }
    }

    @Test func aUnionNestedInsideAnotherUnionRoundTrips() throws {
        // `ToolCallContent.diff` wraps a `Diff`, whose `changes` are
        // `DiffChange`s — a base object carrying its own nested tagged union.
        // Three flattening layers in one document.
        let content = try WireRoundTrip.expectLossless(ToolCallContent.self, """
            {"type":"diff","changes":[\
            {"operation":"move","oldPath":"/old.txt","path":"/new.txt"},\
            {"operation":"add","path":"/added.txt","fileType":"text"}],\
            "patch":{"format":"git_patch","text":"diff --git a b"}}
            """)
        guard case .diff(let diff) = content else {
            Issue.record("expected .diff, got \(content)")
            return
        }
        #expect(diff.changes.count == 2)
        guard case .move(let moved) = diff.changes[0].operation else {
            Issue.record("expected .move, got \(diff.changes[0].operation)")
            return
        }
        #expect(moved.oldPath == AbsolutePath(rawValue: "/old.txt"))
        #expect(moved.path == AbsolutePath(rawValue: "/new.txt"))
        // The base members of the second change travel beside its payload.
        #expect(diff.changes[1].fileType == .text)
        guard case .add(let added) = diff.changes[1].operation else {
            Issue.record("expected .add, got \(diff.changes[1].operation)")
            return
        }
        #expect(added.path == AbsolutePath(rawValue: "/added.txt"))
    }

    @Test func anUnrecognizedNestedVariantKeepsOnlyItsOwnMembers() throws {
        // The base members are the struct's, so the payload must not also
        // capture them. Two keyed containers over one encoder share an object
        // and the last write wins, so a captured copy would beat the struct's
        // own — and mutating `fileType` would then have no effect on the wire.
        let change = try WireRoundTrip.expectLossless(DiffChange.self, """
            {"operation":"_vendor_symlink","fileType":"text","target":"/elsewhere"}
            """)
        #expect(change.fileType == .text)
        #expect(change.operation == .unknown("_vendor_symlink", .object(["target": .string("/elsewhere")])))

        var mutated = change
        mutated.fileType = .binary
        #expect(try WireRoundTrip.encode(mutated)["fileType"] == .string("binary"))
    }

    @Test func aPayloadClaimingAnOwnedMemberIsRejectedNotSilentlyPreferred() throws {
        // Decoding never builds such a payload — the excluded names are dropped
        // on the way in — but the fallback cases are public and take two
        // associated values, so Swift code can. Left unchecked, the flattened
        // copy would win: `.unknown("_vendor_sso", ["type": "agent"])` would
        // encode `{"type":"agent"}` and re-decode as a *different* variant,
        // and the nested case would let a payload silently replace a base
        // property. Both are encoding errors instead.
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(AuthMethod.unknown("_vendor_sso", .object(["type": .string("agent")])))
        }
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(
                DiffChange(
                    fileType: .text,
                    operation: .unknown("_vendor_symlink", .object(["fileType": .string("binary")]))
                )
            )
        }
        // A payload claiming nothing owned still encodes.
        #expect(throws: Never.self) {
            try JSONEncoder().encode(AuthMethod.unknown("_vendor_sso", .object(["methodId": .string("sso")])))
        }
    }

    @Test func theUnionsWithoutAFixtureAboveStillDecodeTheirOwnDiscriminator() throws {
        // Four unions reach the exhaustive probe only through thrown payload
        // errors, so nothing else here decodes one end to end. A whole valid
        // payload for each is what proves the discriminator key, the tag, and
        // the flattening all line up — the probe alone proves only the first.
        let update = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed"}
            """)
        guard case .toolCallUpdate(let toolCall) = update else {
            Issue.record("expected .toolCallUpdate, got \(update)")
            return
        }
        #expect(toolCall.toolCallId == ToolCallId(rawValue: "call-1"))
        #expect(toolCall.status == .completed)

        let server = try WireRoundTrip.expectLossless(McpServer.self, """
            {"type":"stdio","name":"local","command":"/usr/bin/server","args":["--flag"]}
            """)
        guard case .stdio(let stdio) = server else {
            Issue.record("expected .stdio, got \(server)")
            return
        }
        #expect(stdio.command == AbsolutePath(rawValue: "/usr/bin/server"))

        let input = try WireRoundTrip.expectLossless(AvailableCommandInput.self, """
            {"type":"text","hint":"a file path"}
            """)
        guard case .text = input else {
            Issue.record("expected .text, got \(input)")
            return
        }

        let subject = try WireRoundTrip.expectLossless(RequestPermissionSubject.self, """
            {"type":"tool_call","toolCall":{"toolCallId":"call-1","title":"Read a file"}}
            """)
        guard case .toolCall = subject else {
            Issue.record("expected .toolCall, got \(subject)")
            return
        }
    }

    @Test func aDiscriminatorOnADifferentMemberStillKeys() throws {
        // Not every union keys on `type`: `StateUpdate` keys on `state` and
        // `RequestPermissionOutcome` on `outcome`. The discriminator name is
        // read from the schema per union, so a stage that hardcoded `type`
        // would decode neither.
        let state = try WireRoundTrip.expectLossless(StateUpdate.self, """
            {"state":"idle","stopReason":"end_turn"}
            """)
        guard case .idle = state else {
            Issue.record("expected .idle, got \(state)")
            return
        }
        let outcome = try WireRoundTrip.expectLossless(RequestPermissionOutcome.self, """
            {"outcome":"cancelled"}
            """)
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
    }

    @Test func objectCarryingAUnionRoundTripsBaseAndPayloadTogether() throws {
        let option = try WireRoundTrip.expectLossless(SessionConfigOption.self, """
            {"configId":"model","name":"Model","category":"model","type":"boolean","currentValue":true}
            """)
        #expect(option.configId == SessionConfigId(rawValue: "model"))
        #expect(option.category == .model)
        guard case .boolean(let boolean) = option.type else {
            Issue.record("expected .boolean, got \(option.type)")
            return
        }
        #expect(boolean.currentValue)
    }

    // MARK: - Schema access

    /// The package root, derived from this file's location so the suite does
    /// not depend on the test runner's working directory.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FoundationModelsACPTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    /// The vendored schema document, parsed once.
    private static let schema: JSONValue = {
        let url = packageRoot.appendingPathComponent("Schema/acp-v2.json")
        // A test fixture that cannot be read is a broken test, not a failure
        // to report per assertion.
        return try! JSONDecoder().decode(JSONValue.self, from: try! Data(contentsOf: url))
    }()

    /// Every `const`-pinned discriminator value a definition's union declares.
    ///
    /// - Parameter definition: The schema definition name.
    /// - Returns: The `(discriminator, tag)` pairs in schema order.
    /// - Throws: A test failure when the definition declares no union.
    private static func declaredTags(of definition: String) throws -> [(String, String)] {
        let variants = try #require(schema["$defs"]?[definition]?["anyOf"])
        guard case .array(let entries) = variants else {
            Issue.record("\(definition) has no anyOf array")
            return []
        }
        return entries.flatMap { variant -> [(String, String)] in
            guard case .object(let properties)? = variant["properties"] else { return [] }
            return properties.compactMap { name, fragment in
                guard case .string(let tag)? = fragment["const"] else { return nil }
                return (name, tag)
            }
        }
    }
}
