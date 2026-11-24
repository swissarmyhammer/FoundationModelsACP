import Darwin
import Foundation
import Testing

/// Tests of ``TestRunFolder``: the folder of this process holds the test
/// folders, and the first use removes the folders of the processes that do
/// not run.
@Suite
struct TestRunFolderTests {
    /// The process that the tests start and wait for, so that its pid names a
    /// process that does not run.
    static let endedCommand = "/usr/bin/true"

    /// The folder of this process is `<temporary directory>/fmacp-tests/<pid>`.
    @Test func theFolderOfThisProcessIsNamedByItsPid() {
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent(TestRunFolder.parentName, isDirectory: true)
            .appendingPathComponent(String(getpid()), isDirectory: true)

        #expect(TestRunFolder.temporary.standardizedFileURL == expected.standardizedFileURL)
    }

    /// The first use makes the folder of this process.
    @Test func theFolderOfThisProcessExists() {
        var isDirectory: ObjCBool = false

        let exists = FileManager.default.fileExists(atPath: TestRunFolder.temporary.path, isDirectory: &isDirectory)

        #expect(exists && isDirectory.boolValue)
    }

    /// The removal removes the folder of a process that does not run.
    @Test func theRemovalRemovesTheFolderOfAnEndedProcess() throws {
        let parent = try Self.makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = try Self.makeFolder(named: try Self.endedPid(), in: parent)

        TestRunFolder.removeFoldersOfEndedProcesses(in: parent)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// The removal keeps the folder of a process that runs.
    @Test func theRemovalKeepsTheFolderOfARunningProcess() throws {
        let parent = try Self.makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = try Self.makeFolder(named: getppid(), in: parent)

        TestRunFolder.removeFoldersOfEndedProcesses(in: parent)

        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Makes a new parent folder in the folder of this process.
    ///
    /// - Returns: The parent folder.
    /// - Throws: The error of the folder creation.
    private static func makeParent() throws -> URL {
        let parent = TestRunFolder.temporary
            .appendingPathComponent("test-run-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    /// Makes the folder of a process in a parent folder.
    ///
    /// - Parameters:
    ///   - pid: The pid that names the folder.
    ///   - parent: The parent folder.
    /// - Returns: The folder.
    /// - Throws: The error of the folder creation.
    private static func makeFolder(named pid: pid_t, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(String(pid), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Starts a process, waits for its end, and gives its pid.
    ///
    /// - Returns: The pid of a process that does not run.
    /// - Throws: The error of the start of the process.
    private static func endedPid() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: endedCommand)
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
