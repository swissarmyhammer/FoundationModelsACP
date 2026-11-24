import Foundation
import Testing

@testable import ACPConformance

@Suite struct ConformanceCommandTests {
    /// The working directory that each test gives with `--cwd`, when the test
    /// does not check the working directory. Without `--cwd`, the command
    /// makes a new folder at the top of the temporary directory, and the
    /// command does not remove it.
    static let cwdArguments = ["--cwd", TestRunFolder.temporary.path]

    @Test func theCommandAfterTheSeparatorBecomesTheAgentCommand() throws {
        let options = try ConformanceCommand.parse(Self.cwdArguments + ["--", "/bin/agent", "--flag", "x"])
        #expect(options.configuration.executable.path == "/bin/agent")
        #expect(options.configuration.arguments == ["--flag", "x"])
    }

    @Test func theJSONFlagSelectsJSONOutput() throws {
        #expect(try ConformanceCommand.parse(Self.cwdArguments + ["--json", "--", "/bin/agent"]).json)
    }

    @Test func theEnvFlagAddsToTheEnvironment() throws {
        let options = try ConformanceCommand.parse(Self.cwdArguments + ["--env", "A=1", "--env", "B=2=3", "--", "/bin/agent"])
        #expect(options.configuration.environment?["A"] == "1")
        #expect(options.configuration.environment?["B"] == "2=3")
    }

    @Test func aMissingAgentCommandIsAUsageError() {
        #expect(throws: ConformanceCommand.UsageError.self) { try ConformanceCommand.parse(["--json"]) }
    }

    @Test func anUnknownFlagIsAUsageError() {
        #expect(throws: ConformanceCommand.UsageError.self) { try ConformanceCommand.parse(["--bogus", "--", "/bin/a"]) }
    }

    @Test func aScriptFileIsDecoded() throws {
        let url = TestRunFolder.temporary.appendingPathComponent("script-\(UUID().uuidString).json")
        try Data(#"{"resumes":[{"sessionId":"root","replayFrom":true,"untilToolCall":"c1"}]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = try ConformanceCommand.parse(Self.cwdArguments + ["--script", url.path, "--", "/bin/agent"])
        #expect(options.configuration.script?.resumes.first?.untilToolCall == "c1")
    }

    @Test func aBareCommandNameIsFoundOnThePath() throws {
        let options = try ConformanceCommand.parse(Self.cwdArguments + ["--", "true"])
        #expect(options.configuration.executable.path.hasSuffix("/true"))
    }

    @Test func withoutCwdTheRunnerUsesAnExistingEmptyTemporaryFolder() throws {
        let cwd = try ConformanceCommand.parse(["--", "/bin/agent"]).configuration.cwd
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cwd).isEmpty)
        #expect(cwd != "/")
    }

    @Test func theCwdFlagIsKept() throws {
        #expect(try ConformanceCommand.parse(["--cwd", "/work", "--", "/bin/agent"]).configuration.cwd == "/work")
    }
}
