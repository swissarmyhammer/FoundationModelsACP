import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

/// The rules of the renderer that hold for each input: the same input gives
/// the same text, a replay gives the same text, the two entry points agree,
/// and the labels change only the fixed words.
@Suite struct SessionMarkdownPropertyTests {
    /// The name of each golden input.
    static let inputs = SessionMarkdownGoldenTests.cases.map(\.name).filter { $0 != "empty-with-title" }

    @Test(arguments: inputs)
    func twoRendersOfTheSameUpdatesAreTheSame(_ name: String) throws {
        let updates = try GoldenFiles.updates(named: name)
        let options = SessionMarkdown.Options(includeThoughts: true)
        #expect(SessionMarkdown.render(updates: updates, options: options)
            == SessionMarkdown.render(updates: updates, options: options))
    }

    @Test(arguments: inputs)
    func theRenderOfTheReplayIsTheSame(_ name: String) throws {
        let updates = try GoldenFiles.updates(named: name)
        let engine = SessionMergeEngine(replaying: updates)
        let options = SessionMarkdown.Options(includeThoughts: true)
        let first = SessionMarkdown.render(updates: updates, options: options)
        let replay = SessionMarkdown.render(updates: engine.stateUpdates + engine.transcriptUpdates, options: options)
        #expect(replay == first)
    }

    @Test func theRenderOfTheFullSessionReplayIsTheSame() throws {
        let updates = try GoldenFiles.fullSessionUpdates()
        let engine = SessionMergeEngine(replaying: updates)
        #expect(SessionMarkdown.render(updates: engine.transcriptUpdates) == SessionMarkdown.render(updates: updates))
    }

    @Test(arguments: inputs)
    func theTwoEntryPointsGiveTheSameText(_ name: String) throws {
        let updates = try GoldenFiles.updates(named: name)
        let engine = SessionMergeEngine(replaying: updates)
        #expect(SessionMarkdown.render(entries: engine.entries, sessionInfo: engine.sessionInfo)
            == SessionMarkdown.render(updates: updates))
    }

    @Test func theTitleOptionReplacesTheTitleOfTheSession() throws {
        let updates = try GoldenFiles.updates(named: "title-and-agent-name")
        let document = SessionMarkdown.render(updates: updates, options: .init(title: "Mine"))
        #expect(document.hasPrefix("# Mine\n\n"))
        #expect(!document.contains("Fix the build"))
    }

    @Test func anEmptyTranscriptWithNoTitleIsAnEmptyString() {
        #expect(SessionMarkdown.render(updates: [SessionUpdate]()) == "")
    }

    /// Labels that are not English change only the fixed words. The test
    /// renders each input with French labels, then changes each French word
    /// back to the English word. The result is the English document.
    @Test(arguments: inputs)
    func labelsChangeOnlyTheFixedWords(_ name: String) throws {
        let updates = try GoldenFiles.updates(named: name)
        let pairs = Self.frenchPairs
        var french = SessionMarkdown.Labels()
        for pair in pairs {
            french[keyPath: pair.keyPath] = pair.french
        }
        let options = SessionMarkdown.Options(includeThoughts: true, labels: french)
        var document = SessionMarkdown.render(updates: updates, options: options)
        // The longest words first, so that a short word does not change a
        // part of a long one.
        for pair in pairs.sorted(by: { $0.french.count > $1.french.count }) {
            document = document.replacing(pair.french, with: SessionMarkdown.Labels.english[keyPath: pair.keyPath])
        }
        #expect(document == SessionMarkdown.render(updates: updates, options: .init(includeThoughts: true)))
    }

    /// One fixed word and a French word that no input has.
    struct Pair {
        let keyPath: WritableKeyPath<SessionMarkdown.Labels, String>
        let french: String
    }

    /// Each fixed word, with a French word that is unique in each document.
    static var frenchPairs: [Pair] { [
        Pair(keyPath: \.user, french: "Utilisateur⁰"),
        Pair(keyPath: \.agent, french: "Agent⁰"),
        Pair(keyPath: \.thought, french: "Pensée⁰"),
        Pair(keyPath: \.from, french: "De⁰"),
        Pair(keyPath: \.fromUserIn, french: "De l’utilisateur, dans⁰"),
        Pair(keyPath: \.to, french: "À⁰"),
        Pair(keyPath: \.unknownSession, french: "une session inconnue⁰"),
        Pair(keyPath: \.plan, french: "Plan⁰"),
        Pair(keyPath: \.exitStatus, french: "Code de sortie⁰"),
        Pair(keyPath: \.compacted, french: "Le contexte a été compacté.⁰"),
        Pair(keyPath: \.toolCall, french: "Appel d’outil⁰"),
        Pair(keyPath: \.terminal, french: "Terminal⁰"),
        Pair(keyPath: \.image, french: "Image⁰"),
        Pair(keyPath: \.audio, french: "Audio⁰"),
        Pair(keyPath: \.resource, french: "Ressource⁰"),
        Pair(keyPath: \.toolCallStatus.pending, french: "en attente⁰"),
        Pair(keyPath: \.toolCallStatus.inProgress, french: "en cours⁰"),
        Pair(keyPath: \.toolCallStatus.paused, french: "en pause⁰"),
        Pair(keyPath: \.toolCallStatus.completed, french: "terminé⁰"),
        Pair(keyPath: \.toolCallStatus.failed, french: "échoué⁰"),
        Pair(keyPath: \.toolCallStatus.cancelled, french: "annulé⁰"),
        Pair(keyPath: \.toolKind.read, french: "lecture⁰"),
        Pair(keyPath: \.toolKind.edit, french: "modification⁰"),
        Pair(keyPath: \.toolKind.delete, french: "suppression⁰"),
        Pair(keyPath: \.toolKind.move, french: "déplacement⁰"),
        Pair(keyPath: \.toolKind.search, french: "recherche⁰"),
        Pair(keyPath: \.toolKind.execute, french: "exécution⁰"),
        Pair(keyPath: \.toolKind.think, french: "réflexion⁰"),
        Pair(keyPath: \.toolKind.fetch, french: "récupération⁰"),
        Pair(keyPath: \.toolKind.switchMode, french: "changement de mode⁰"),
        Pair(keyPath: \.toolKind.other, french: "autre⁰"),
        Pair(keyPath: \.planItemStatus.inProgress, french: "en cours (plan)⁰"),
        Pair(keyPath: \.planItemStatus.cancelled, french: "annulé (plan)⁰"),
        Pair(keyPath: \.diffOperation.add, french: "Ajouté⁰"),
        Pair(keyPath: \.diffOperation.delete, french: "Supprimé⁰"),
        Pair(keyPath: \.diffOperation.modify, french: "Modifié⁰"),
        Pair(keyPath: \.diffOperation.move, french: "Déplacé⁰"),
        Pair(keyPath: \.diffOperation.copy, french: "Copié⁰"),
    ] }
}
