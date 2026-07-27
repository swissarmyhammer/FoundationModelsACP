import Foundation

/// The package root, derived from this file's location so the suites that
/// use it do not depend on the test runner's working directory.
private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // FoundationModelsACPTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root

/// The tree-relative directory holding the hand-written role protocols.
private let connectionDirectory = "Sources/FoundationModelsACP/Connection"

/// Reads a tree-relative file from the package as UTF-8 text.
///
/// - Parameter treeRelativePath: The path relative to the package root.
/// - Returns: The file's contents.
/// - Throws: An error when the file cannot be read.
private func packageSource(_ treeRelativePath: String) throws -> String {
    String(decoding: try Data(contentsOf: packageRoot.appendingPathComponent(treeRelativePath)), as: UTF8.self)
}

/// The source of the hand-written `Agent` role protocol.
///
/// - Returns: `Agent.swift`'s contents.
/// - Throws: An error when the file cannot be read.
func sourceOfAgentProtocolFile() throws -> String {
    try packageSource("\(connectionDirectory)/Agent.swift")
}

/// The source of the hand-written `Client` role protocol.
///
/// - Returns: `Client.swift`'s contents.
/// - Throws: An error when the file cannot be read.
func sourceOfClientProtocolFile() throws -> String {
    try packageSource("\(connectionDirectory)/Client.swift")
}
