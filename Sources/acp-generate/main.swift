import ACPGenerateCore
import Foundation

/// The prefix identifying this tool in every diagnostic message.
let toolPrefix = "acp-generate: "

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

/// Rejects paths that could escape the working tree — absolute paths and
/// `..` traversal segments.
///
/// - Parameters:
///   - path: The candidate path.
///   - role: What the path is for (`schema-path`/`output-dir`), for messages.
func requireTreeRelative(_ path: String, role: String) {
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
        die(message: "\(toolPrefix)\(role) must be a relative path without '..' segments; got \"\(path)\"")
    }
}

// Usage: acp-generate [schema-path] [output-dir]
// Defaults assume execution from the package root (`swift run acp-generate`).
// The routing manifests are derived from the schema path by the vendoring
// convention: `<base>.json` → `<base>.meta.json` + `<base>.meta.unstable.json`.
let arguments = CommandLine.arguments
guard arguments.count <= 3 else {
    die(message: "usage: acp-generate [schema-path] [output-dir]")
}
let schemaPath = arguments.count > 1 ? arguments[1] : "Schema/acp-v1.json"
let outputPath = arguments.count > 2 ? arguments[2] : "Sources/FoundationModelsACP/Generated"

// Both paths must stay inside the working tree so stray arguments can
// neither read nor write elsewhere.
requireTreeRelative(schemaPath, role: "schema-path")
requireTreeRelative(outputPath, role: "output-dir")

guard schemaPath.hasSuffix(".json") else {
    die(message: "\(toolPrefix)schema-path must end in .json to locate its routing manifests; got \"\(schemaPath)\"")
}
let manifestBasePath = String(schemaPath.dropLast(".json".count))

do {
    let schemaJSON = try Data(contentsOf: URL(fileURLWithPath: schemaPath))
    let metaJSON = try Data(contentsOf: URL(fileURLWithPath: manifestBasePath + ".meta.json"))
    let unstableMetaJSON = try Data(contentsOf: URL(fileURLWithPath: manifestBasePath + ".meta.unstable.json"))
    let files = try SchemaGenerator().generate(
        schemaJSON: schemaJSON,
        metaJSON: metaJSON,
        unstableMetaJSON: unstableMetaJSON
    )
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for file in files {
        // Generated names are plain file names; refuse anything path-like.
        guard !file.name.contains("/"), !file.name.contains("..") else {
            die(message: "\(toolPrefix)refusing path-like generated file name \"\(file.name)\"")
        }
        let destination = outputDirectory.appendingPathComponent(file.name)
        try Data(file.contents.utf8).write(to: destination)
        print("wrote \(destination.path)")
    }
} catch let error as GeneratorError {
    printError(message: "\(toolPrefix)\(error.description)")
    exit(1)
} catch {
    printError(message: "\(toolPrefix)\(error)")
    exit(1)
}
