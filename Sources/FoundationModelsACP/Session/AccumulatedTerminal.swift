import Foundation

/// One agent-owned terminal's accumulated state, folded from `terminal_update`
/// and `terminal_output_chunk` notifications.
///
/// `output` is tracked separately from the other fields: `terminal_update`'s
/// own `output` field carries a `TerminalOutput` snapshot that *replaces* the
/// accumulated bytes outright (an authoritative resync), while
/// `terminal_output_chunk` appends to them — two different operations on the
/// same buffer, not a patch-semantics field to fold like the rest.
public struct AccumulatedTerminal: Hashable, Sendable {
    /// The command being run.
    public var command: PatchField<String> = .unchanged

    /// The absolute working directory of the command.
    public var cwd: PatchField<AbsolutePath> = .unchanged

    /// Exit information. A concrete value marks the terminal as exited.
    public var exitStatus: PatchField<TerminalExitStatus> = .unchanged

    /// The `_meta` extension field.
    public var meta: PatchField<JSONValue> = .unchanged

    /// The terminal's accumulated output bytes, decoded from base64 as they
    /// arrive.
    public var output = Data()

    /// Creates a terminal with every field unknown — the state a
    /// never-before-seen `terminalId` starts in.
    public init() {}
}

extension AccumulatedTerminal {
    /// Folds a `terminal_update` onto this terminal.
    ///
    /// Each patch-semantics field folds with `PatchField.folded(onto:)`. A
    /// concrete `output` snapshot replaces the output bytes, because the
    /// wire states that a `TerminalOutput` is "an authoritative replacement
    /// snapshot", not a patch.
    ///
    /// - Parameter update: The received terminal update.
    internal mutating func apply(_ update: TerminalUpdate) {
        command = update.command.folded(onto: command)
        cwd = update.cwd.folded(onto: cwd)
        exitStatus = update.exitStatus.folded(onto: exitStatus)
        meta = update.meta.folded(onto: meta)
        switch update.output {
        case .unchanged:
            break
        case .cleared:
            output = Data()
        case .value(let snapshot):
            // A snapshot that does not decode as base64 is dropped. It does
            // not replace good bytes with bad ones. The generated types
            // use the same forgiving decode for bad peer data.
            if let bytes = Data(base64Encoded: snapshot.data) {
                output = bytes
            }
        }
    }

    /// Appends the decoded bytes of one output chunk. A chunk that does not
    /// decode as base64 is dropped, so it does not put bad bytes into the
    /// output.
    ///
    /// - Parameter base64: The base64 text of the chunk.
    internal mutating func appendOutput(base64: String) {
        guard let bytes = Data(base64Encoded: base64) else { return }
        output.append(bytes)
    }

    /// Makes the one `terminal_update` that gives this terminal state to an
    /// empty terminal.
    ///
    /// The update carries the output as a snapshot only when there are
    /// output bytes. An empty terminal also has no output bytes, so the
    /// update can omit the field.
    ///
    /// - Parameter terminalId: The identifier of the terminal.
    /// - Returns: The terminal update.
    internal func replayUpdate(terminalId: TerminalId) -> TerminalUpdate {
        TerminalUpdate(
            terminalId: terminalId,
            command: command,
            cwd: cwd,
            exitStatus: exitStatus,
            output: output.isEmpty ? .unchanged : .value(TerminalOutput(data: output.base64EncodedString())),
            meta: meta
        )
    }
}
