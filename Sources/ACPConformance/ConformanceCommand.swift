import Foundation

/// The command line of `acp-conformance`.
///
///     acp-conformance [--json] [--trace] [--script FILE] [--env KEY=VALUE]... [--cwd PATH]
///                     [--quiet SECONDS] [--timeout SECONDS] -- AGENT [ARGUMENT]...
///
/// The exit code is 0 when no check failed, 1 when a check failed, and 2 for a usage error.
public enum ConformanceCommand {
    /// The exit code for a usage error or an unwritable report.
    static let usageExitCode: Int32 = 2

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    struct Options {
        var configuration: ConformanceConfiguration
        var json: Bool
        var trace = false
    }

    static let usage = """
        usage: acp-conformance [--json] [--trace] [--script FILE] [--env KEY=VALUE]... [--cwd PATH] \
        [--quiet SECONDS] [--timeout SECONDS] -- AGENT [ARGUMENT]...
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var json = false
        var trace = false
        var scriptPath: String?
        var overrides: [String: String] = [:]
        var cwd: String?
        var quiet: Double?
        var timeout: Double?
        var index = 0
        var command: [String] = []
        func value(after flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(description: "\(flag) needs a value") }
            return arguments[index]
        }
        func seconds(_ flag: String) throws -> Double {
            guard let number = Double(try value(after: flag)), number > 0 else {
                throw UsageError(description: "\(flag) needs a number of seconds above 0")
            }
            return number
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--":
                command = Array(arguments[(index + 1)...])
                index = arguments.count
                continue
            case "--json": json = true
            case "--trace": trace = true
            case "--script": scriptPath = try value(after: "--script")
            case "--cwd": cwd = try value(after: "--cwd")
            case "--quiet": quiet = try seconds("--quiet")
            case "--timeout": timeout = try seconds("--timeout")
            case "--env":
                let pair = try value(after: "--env")
                guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                    throw UsageError(description: "--env needs KEY=VALUE")
                }
                overrides[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
            default:
                throw UsageError(description: "unknown option \(arguments[index])")
            }
            index += 1
        }
        guard let program = command.first else { throw UsageError(description: "no agent command after --") }
        var configuration = ConformanceConfiguration(
            executable: try resolve(program), arguments: Array(command.dropFirst()))
        if !overrides.isEmpty { configuration.environment = ProcessInfo.processInfo.environment.merging(overrides) { $1 } }
        configuration.cwd = try cwd ?? makeEmptyFolder()
        if let quiet { configuration.quiet = .seconds(quiet) }
        if let timeout { configuration.timeout = .seconds(timeout) }
        if let scriptPath {
            do {
                configuration.script = try JSONDecoder().decode(
                    ConformanceScript.self, from: Data(contentsOf: URL(fileURLWithPath: scriptPath)))
            } catch {
                throw UsageError(description: "cannot read the script \(scriptPath): \(error)")
            }
        }
        return Options(configuration: configuration, json: json, trace: trace)
    }

    /// A new empty folder for the working directory of the sessions. A cwd such as
    /// `/` makes some agents index the whole disk.
    private static func makeEmptyFolder() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-conformance-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UsageError(description: "cannot make a working folder: \(error)")
        }
        return folder.path
    }

    /// A name with a slash is a path. A bare name is searched in `PATH`.
    private static func resolve(_ program: String) throws -> URL {
        if program.contains("/") { return URL(fileURLWithPath: program) }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw UsageError(description: "\(program) is not in PATH")
    }

    /// Runs the conformance checks and prints the report.
    ///
    /// - Parameter arguments: The command-line arguments without the program name.
    /// - Returns: The exit code.
    public static func main(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("acp-conformance: \(error)\n\(usage)\n".utf8))
            return usageExitCode
        }
        let report = await ConformanceRunner.run(options.configuration)
        if options.trace { FileHandle.standardError.write(Data((report.traceText + "\n").utf8)) }
        do {
            let output = options.json ? try report.json() : report.text
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        } catch {
            FileHandle.standardError.write(Data("acp-conformance: cannot write the report: \(error)\n".utf8))
            return usageExitCode
        }
        return report.exitCode
    }
}
