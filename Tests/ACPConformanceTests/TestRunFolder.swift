import Darwin
import Foundation

/// The folder of the test folders and test files of this process.
///
/// Each test folder and each test file goes into the folder of this process,
/// `<temporary directory>/fmacp-tests/<pid>`, and not into the top of the
/// temporary directory. A folder at the top stays there when a test does not
/// remove it.
///
/// - The process removes its folder when it exits (`atexit`).
/// - A process that was stopped before its exit leaves its folder. The first
///   use in the next process removes each folder whose process does not run
///   now.
enum TestRunFolder {
    /// The name of the parent of the folders of each process.
    static let parentName = "fmacp-tests"

    /// The parent of the folders of each process in the temporary directory.
    static let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(parentName, isDirectory: true)

    /// The folder of this process in the temporary directory:
    /// `<temporary directory>/fmacp-tests/<pid>`. Use it in place of
    /// `FileManager.default.temporaryDirectory` in a test.
    static let temporary: URL = makeFolder()

    /// Makes the folder of this process, removes the folders of the processes
    /// that do not run now, and registers the removal at the exit.
    ///
    /// - Returns: The folder.
    private static func makeFolder() -> URL {
        let folder = parent.appendingPathComponent(String(getpid()), isDirectory: true)
        removeFoldersOfEndedProcesses(in: parent)
        try? FileManager.default.removeItem(at: folder)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit {
            try? FileManager.default.removeItem(at: TestRunFolder.temporary)
        }
        return folder
    }

    /// Removes the folder of each process that does not run now.
    ///
    /// - Parameter parent: The parent of the folders of each process.
    static func removeFoldersOfEndedProcesses(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names {
            guard let pid = pid_t(name), pid > 0, pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
            }
        }
    }
}
