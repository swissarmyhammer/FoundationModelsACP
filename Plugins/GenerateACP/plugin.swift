import Foundation
import PackagePlugin

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
    /// - Throws: An error when the tool cannot be located or launched.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "acp-generate")
        let process = Process()
        process.executableURL = tool.url
        process.currentDirectoryURL = context.package.directoryURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Diagnostics.error("acp-generate exited with status \(process.terminationStatus)")
            return
        }
    }
}
