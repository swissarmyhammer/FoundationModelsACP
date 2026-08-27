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

/// The `///` doc comment lines that sit directly above a declaration.
///
/// Lets a suite assert on what a doc comment promises, the same way
/// `sourceOfAgentProtocolFile` lets one assert on what a file declares.
///
/// - Parameters:
///   - declaration: The text that opens the declaration line, such as
///     `func loginAuth(`. Leading spaces on the line are ignored.
///   - source: The Swift source to read.
/// - Returns: The doc comment lines, in source order, or `nil` when `source`
///   holds no line that opens with `declaration`.
func docComment(above declaration: String, in source: String) -> String? {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let isDocLine = { (line: Substring) in line.drop(while: { $0 == " " }).hasPrefix("///") }
    guard let declarationIndex = lines.firstIndex(where: {
        $0.drop(while: { $0 == " " }).hasPrefix(declaration)
    }) else {
        return nil
    }

    var firstDocIndex = declarationIndex
    while firstDocIndex > lines.startIndex, isDocLine(lines[firstDocIndex - 1]) {
        firstDocIndex -= 1
    }
    return lines[firstDocIndex..<declarationIndex].joined(separator: "\n")
}
