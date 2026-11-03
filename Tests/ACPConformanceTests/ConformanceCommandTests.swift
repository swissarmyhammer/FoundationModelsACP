import Foundation
import Testing

@testable import ACPConformance

@Suite struct ConformanceCommandTests {
    @Test func theCommandAfterTheSeparatorBecomesTheAgentCommand() throws {
        let options = try ConformanceCommand.parse(["--", "/bin/agent", "--flag", "x"])
        #expect(options.configuration.executable.path == "/bin/agent")
        #expect(options.configuration.arguments == ["--flag", "x"])
    }

    @Test func theJSONFlagSelectsJSONOutput() throws {
        #expect(try ConformanceCommand.parse(["--json", "--", "/bin/agent"]).json)
    }

    @Test func theEnvFlagAddsToTheEnvironment() throws {
        let options = try ConformanceCommand.parse(["--env", "A=1", "--env", "B=2=3", "--", "/bin/agent"])
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString).json")
        try Data(#"{"resumes":[{"sessionId":"root","replayFrom":true,"untilToolCall":"c1"}]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = try ConformanceCommand.parse(["--script", url.path, "--", "/bin/agent"])
        #expect(options.configuration.script?.resumes.first?.untilToolCall == "c1")
    }

    @Test func aBareCommandNameIsFoundOnThePath() throws {
        let options = try ConformanceCommand.parse(["--", "true"])
        #expect(options.configuration.executable.path.hasSuffix("/true"))
    }

    @Test func withoutCwdTheRunnerUsesAnExistingEmptyTemporaryFolder() throws {
        let cwd = try ConformanceCommand.parse(["--", "/bin/agent"]).configuration.cwd
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cwd).isEmpty)
        #expect(cwd != "/")
        try? FileManager.default.removeItem(atPath: cwd)
    }

    @Test func theCwdFlagIsKept() throws {
        #expect(try ConformanceCommand.parse(["--cwd", "/work", "--", "/bin/agent"]).configuration.cwd == "/work")
    }
}
