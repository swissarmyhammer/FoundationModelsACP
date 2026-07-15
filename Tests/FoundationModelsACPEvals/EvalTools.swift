import Foundation
import FoundationModels

@testable import FoundationModelsACP

/// Arguments for the ``WeatherEvalTool``.
@Generable
struct WeatherToolArguments {
    /// The city to report the weather for.
    @Guide(description: "The city name")
    var city: String
}

/// A self-contained weather tool the eval registers so the model can select it.
///
/// It returns a fixed string rather than reaching the client, so the case
/// scores tool selection and call well-formedness without depending on any
/// client capability.
struct WeatherEvalTool: Tool {
    /// The tool's wire name, matched against a `tool_call` update's title.
    let name = "getWeather"

    /// The tool's natural-language description the model selects against.
    let description = "Get the current weather for a city."

    /// The tool's structured argument type.
    typealias Arguments = WeatherToolArguments

    /// Returns a fixed weather report for the requested city.
    ///
    /// - Parameter arguments: The decoded city argument.
    /// - Returns: A fixed weather report.
    func call(arguments: WeatherToolArguments) async throws -> String {
        "It is 20C and sunny in \(arguments.city)."
    }
}

/// Arguments for the ``ReaderEvalTool``.
@Generable
struct ReaderToolArguments {
    /// The absolute path of the file to read.
    @Guide(description: "The absolute path to the file to read")
    var path: String
}

/// A file-reading tool the eval registers so the model can select it.
///
/// Its work runs through ``ClientEnvironment/current`` — the ambient handle the
/// bridge binds for the turn — so a selected read is served by the client over
/// the reverse `fs/read_text_file` path, exercising the full bridge. When no
/// environment is bound (the tool ran outside a bridged turn), it returns a
/// sentinel so the turn still completes; the eval scores the emitted
/// `tool_call`, which precedes the tool's execution regardless.
struct ReaderEvalTool: Tool {
    /// The tool's wire name, matched against a `tool_call` update's title.
    let name = "reader"

    /// The tool's natural-language description the model selects against.
    let description = "Read the contents of a text file at an absolute path."

    /// The tool's structured argument type.
    typealias Arguments = ReaderToolArguments

    /// Reads the requested file through the bound client environment.
    ///
    /// - Parameter arguments: The decoded path argument.
    /// - Returns: The file's contents, or a sentinel when no environment is
    ///   bound or the path is not absolute.
    func call(arguments: ReaderToolArguments) async throws -> String {
        guard let environment = ClientEnvironment.current,
            let path = AbsolutePath(rawValue: arguments.path)
        else {
            return "no client environment bound for \(arguments.path)"
        }
        return try await environment.readTextFile(path: path)
    }
}

/// The tools the eval harness makes available to every case, keyed by wire
/// name.
///
/// Every case registers the full set, so a case scores whether the model
/// selects the *right* tool among several — a stronger tool-selection signal
/// than offering a single candidate.
enum EvalToolRegistry {
    /// The full tool set registered on every eval session.
    static let all: [any Tool] = [WeatherEvalTool(), ReaderEvalTool()]

    /// The wire names of every registered tool.
    static let knownToolNames: Set<String> = ["getWeather", "reader"]
}
