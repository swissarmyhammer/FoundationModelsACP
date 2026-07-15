import Foundation
import PackagePlugin

/// A failure raised while running the `acp-generate` tool.
struct GenerateACPError: Error, CustomStringConvertible {
    /// The human-readable failure description.
    let description: String
}

/// The `swift package generate-acp` command plugin.
///
/// A command plugin — not a build-tool plugin — because regeneration must
/// write into the package's `Sources/FoundationModelsACP/Generated/`
/// directory. Build-tool plugins run in a sandbox that forbids writing into
/// the package; command plugins may, with the `writeToPackageDirectory`
/// permission declared in `Package.swift` and granted at invocation.
@main
struct GenerateACPPlugin: CommandPlugin {
    /// Runs the vendored `acp-generate` tool from the package root.
    ///
    /// - Parameters:
    ///   - context: The plugin context, providing the built tool and package
    ///     directory.
    ///   - arguments: Extra arguments forwarded verbatim to `acp-generate`.
    /// - Throws: `GenerateACPError` when the tool cannot be launched or exits
    ///   with a non-zero status, so a failed regeneration fails the command
    ///   (and the CI diff gate that runs it).
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "acp-generate")
        let process = Process()
        process.executableURL = tool.url
        process.currentDirectoryURL = context.package.directoryURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GenerateACPError(
                description: "acp-generate exited with status \(process.terminationStatus)"
            )
        }
    }
}
