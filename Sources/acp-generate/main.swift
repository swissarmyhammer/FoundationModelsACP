import ACPGenerateCore
import Foundation

/// The prefix identifying this tool in every diagnostic message.
let toolPrefix = "acp-generate: "

/// The directory generated sources are written into by default.
let defaultOutputPath = "Sources/FoundationModelsACP/Generated"

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

/// Loads an optional tree-relative artifact.
///
/// - Parameters:
///   - path: The tree-relative artifact path, or `nil` when the set has none.
///   - role: What the path is for, for messages.
/// - Returns: The artifact bytes, or `nil` when `path` is `nil`.
/// - Throws: An error when the file cannot be read.
func loadArtifact(_ path: String?, role: String) throws -> Data? {
    guard let path else { return nil }
    requireTreeRelative(path, role: role)
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

// Usage: acp-generate [output-dir]
// The generator's inputs are the vendored `SchemaSet` descriptors, not
// positional arguments; only the output directory can be overridden. Defaults
// assume execution from the package root (`swift run acp-generate`), which the
// command plugin guarantees by setting the working directory to the package.
let arguments = CommandLine.arguments
guard arguments.count <= 2 else {
    die(message: "usage: acp-generate [output-dir]")
}
let outputPath = arguments.count > 1 ? arguments[1] : defaultOutputPath
requireTreeRelative(outputPath, role: "output-dir")
let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)

/// Reads the artifact hash recorded by the previous run, if any.
///
/// - Parameter stampName: The stamp file name to read from the output dir.
/// - Returns: The recorded hash, or `nil` when no readable stamp exists.
func recordedHash(stampName: String) -> String? {
    let url = outputDirectory.appendingPathComponent(stampName)
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Writes a generated file into the output directory, refusing path-like names.
///
/// - Parameter file: The file to write.
/// - Throws: An error when the write fails.
func write(file: GeneratedFile) throws {
    guard !file.name.contains("/"), !file.name.contains("..") else {
        die(message: "\(toolPrefix)refusing path-like generated file name \"\(file.name)\"")
    }
    let destination = outputDirectory.appendingPathComponent(file.name)
    try Data(file.contents.utf8).write(to: destination)
    print("wrote \(destination.path)")
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for schemaSet in SchemaSet.all {
        requireTreeRelative(schemaSet.schemaPath, role: "schema-path")
        let schemaJSON = try Data(contentsOf: URL(fileURLWithPath: schemaSet.schemaPath))
        let metaJSON = try loadArtifact(schemaSet.metaPath, role: "meta-path")
        let unstableMetaJSON = try loadArtifact(schemaSet.unstableMetaPath, role: "unstable-meta-path")
        let stampName = SchemaGenerator.stampFileName(namespace: schemaSet.outputNamespace)
        let outcome = try SchemaGenerator(config: schemaSet.config).generateIfChanged(
            schemaJSON: schemaJSON,
            metaJSON: metaJSON,
            unstableMetaJSON: unstableMetaJSON,
            namespace: schemaSet.outputNamespace,
            previousHash: recordedHash(stampName: stampName)
        )
        switch outcome {
        case .unchanged(let hash):
            print("\(schemaSet.versionLabel): up to date (schema hash \(hash)); nothing regenerated")
        case .regenerated(let files, let hash):
            for file in files {
                try write(file: file)
            }
            print("\(schemaSet.versionLabel): regenerated \(files.count) files (schema hash \(hash))")
        }
    }
} catch let error as GeneratorError {
    printError(message: "\(toolPrefix)\(error.description)")
    exit(1)
} catch {
    printError(message: "\(toolPrefix)\(error)")
    exit(1)
}
