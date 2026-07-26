import Foundation
import Testing

@testable import ACPGenerateCore

/// A synthetic schema-and-manifest artifact set.
///
/// The hash-stamp tests care only that the generator hashes *some* stable
/// artifact bytes and regenerates when they change — not what protocol those
/// bytes describe. A synthetic set keeps that coverage independent of whichever
/// schema revision happens to be vendored under `Schema/`.
enum SyntheticArtifacts {
    /// A minimal schema with one object definition and one method-bearing pair.
    static let schema = Data(
        #"""
        {
          "$defs": {
            "PingRequest": {
              "type": "object",
              "properties": {"label": {"type": "string"}},
              "required": ["label"],
              "x-side": "agent",
              "x-method": "session/ping"
            },
            "PingResponse": {
              "type": "object",
              "properties": {},
              "required": [],
              "x-side": "agent",
              "x-method": "session/ping"
            }
          }
        }
        """#.utf8
    )

    /// A stable routing manifest naming the one method the schema defines.
    static let meta = Data(
        #"""
        {
          "version": 1,
          "agentMethods": {"ping": "session/ping"},
          "clientMethods": {},
          "protocolMethods": {}
        }
        """#.utf8
    )

    /// An unstable routing manifest adding one method beyond the stable set.
    static let unstableMeta = Data(
        #"""
        {
          "version": 1,
          "agentMethods": {"ping": "session/ping", "experiment": "session/experiment"},
          "clientMethods": {},
          "protocolMethods": {}
        }
        """#.utf8
    )

    /// The synthetic schema, stable-manifest, and unstable-manifest bytes.
    static var all: (schema: Data, meta: Data, unstableMeta: Data) {
        (schema, meta, unstableMeta)
    }
}
