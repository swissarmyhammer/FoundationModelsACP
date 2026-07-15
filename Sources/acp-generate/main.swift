import ACPGenerateCore
import Foundation

/// Prints a message to standard error.
///
/// - Parameter message: The line to print, newline appended.
func printError(message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Exits with a usage/validation error.
///
/// - Parameter message: The reason the invocation was rejected.
func die(message: String) -> Never {
    printError(message: message)
    exit(2)
}

// Usage: acp-generate [schema-path] [output-dir]
// Defaults assume execution from the package root (`swift run acp-generate`).
let arguments = CommandLine.arguments
guard arguments.count <= 3 else {
    die(message: "usage: acp-generate [schema-path] [output-dir]")
}
let schemaPath = arguments.count > 1 ? arguments[1] : "Schema/acp-v1.json"
let outputPath = arguments.count > 2 ? arguments[2] : "Sources/FoundationModelsACP/Generated"

// The output directory must stay inside the working tree: reject traversal
// segments and absolute paths so a stray argument cannot write elsewhere.
guard !outputPath.hasPrefix("/"), !outputPath.split(separator: "/").contains("..") else {
    die(message: "acp-generate: output-dir must be a relative path without '..' segments; got \"\(outputPath)\"")
}

do {
    let schemaJSON = try Data(contentsOf: URL(fileURLWithPath: schemaPath))
    let files = try SchemaGenerator().generate(schemaJSON: schemaJSON)
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for file in files {
        // Generated names are plain file names; refuse anything path-like.
        guard !file.name.contains("/"), !file.name.contains("..") else {
            die(message: "acp-generate: refusing path-like generated file name \"\(file.name)\"")
        }
        let destination = outputDirectory.appendingPathComponent(file.name)
        try Data(file.contents.utf8).write(to: destination)
        print("wrote \(destination.path)")
    }
} catch let error as GeneratorError {
    printError(message: "acp-generate: \(error.description)")
    exit(1)
} catch {
    printError(message: "acp-generate: \(error)")
    exit(1)
}
