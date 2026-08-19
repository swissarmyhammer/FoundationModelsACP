import Testing

@testable import ACPGenerateCore

/// The stale-file computation the `acp-generate` writer runs after a
/// regeneration: which `.generated.swift` names in the output directory does
/// the set no longer emit. Sharding made this necessary — a shard the shrunk
/// output no longer produces would stay on disk and declare duplicate symbols.
@Suite struct StaleGeneratedFileTests {
    /// Builds an emitted file list from names alone; the contents play no
    /// part in the stale computation.
    ///
    /// - Parameter names: The emitted file names.
    /// - Returns: One `GeneratedFile` per name, with empty contents.
    private func emitted(_ names: [String]) -> [GeneratedFile] {
        names.map { GeneratedFile(name: $0, contents: "") }
    }

    @Test func aShardTheRunNoLongerEmitsIsStale() {
        let stale = SchemaGenerator.staleGeneratedFileNames(
            existing: ["Models.generated.swift", "Models2.generated.swift", "Unions.generated.swift"],
            emitted: emitted(["Models.generated.swift", "Unions.generated.swift"]),
            namespace: nil
        )
        #expect(stale == ["Models2.generated.swift"])
    }

    @Test func theTopLevelSetNeverTouchesANamespacedSetsFiles() {
        let stale = SchemaGenerator.staleGeneratedFileNames(
            existing: ["ToyV2.Models.generated.swift", "Models.generated.swift"],
            emitted: emitted(["Models.generated.swift"]),
            namespace: nil
        )
        #expect(stale.isEmpty)
    }

    @Test func aNamespacedSetOwnsOnlyItsOwnPrefix() {
        let stale = SchemaGenerator.staleGeneratedFileNames(
            existing: [
                "ToyV2.Models.generated.swift",
                "ToyV2.Models2.generated.swift",
                "Models2.generated.swift",
            ],
            emitted: emitted(["ToyV2.Models.generated.swift"]),
            namespace: "ToyV2"
        )
        #expect(stale == ["ToyV2.Models2.generated.swift"])
    }

    @Test func handWrittenFilesAndStampsAreNeverStale() {
        let stale = SchemaGenerator.staleGeneratedFileNames(
            existing: [".schema-hash", ".gitkeep", "Handwritten.swift"],
            emitted: emitted(["Models.generated.swift"]),
            namespace: nil
        )
        #expect(stale.isEmpty)
    }

    @Test func staleNamesComeBackSorted() {
        let stale = SchemaGenerator.staleGeneratedFileNames(
            existing: ["Unions2.generated.swift", "Models9.generated.swift", "Models2.generated.swift"],
            emitted: emitted(["Models.generated.swift", "Unions.generated.swift"]),
            namespace: nil
        )
        #expect(stale == ["Models2.generated.swift", "Models9.generated.swift", "Unions2.generated.swift"])
    }
}
