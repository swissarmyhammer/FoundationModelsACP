import ACPGenerateCore
import Foundation

/// Prints a message to standard error.
///
/// - Parameter message: The line to print, newline appended.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Usage: acp-generate [schema-path] [output-dir]
// Defaults assume execution from the package root (`swift run acp-generate`).
let arguments = CommandLine.arguments
guard arguments.count <= 3 else {
    printError("usage: acp-generate [schema-path] [output-dir]")
    exit(2)
}
let schemaPath = arguments.count > 1 ? arguments[1] : "Schema/acp-v1.json"
let outputPath = arguments.count > 2 ? arguments[2] : "Sources/FoundationModelsACP/Generated"

do {
    let schemaJSON = try Data(contentsOf: URL(fileURLWithPath: schemaPath))
    let files = try SchemaGenerator().generate(schemaJSON: schemaJSON)
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for file in files {
        let destination = outputDirectory.appendingPathComponent(file.name)
        try Data(file.contents.utf8).write(to: destination)
        print("wrote \(destination.path)")
    }
} catch let error as GeneratorError {
    printError("acp-generate: \(error.description)")
    exit(1)
} catch {
    printError("acp-generate: \(error)")
    exit(1)
}
