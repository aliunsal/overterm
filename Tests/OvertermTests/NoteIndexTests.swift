import XCTest

@testable import Overterm

/// The index over a temporary vault; iCloud played by SimulatedCloudFiles.
@MainActor
final class NoteIndexTests: XCTestCase {
    private var vault: URL!
    private var cloud: SimulatedCloudFiles!

    override func setUp() async throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        cloud = SimulatedCloudFiles(latency: 0.05)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func write(_ path: String, _ text: String) throws {
        try cloud.writeText(text, to: vault.appendingPathComponent(path))
    }

    private func index() async -> NoteIndex {
        let index = NoteIndex(root: vault, files: cloud)
        await index.refreshed()
        return index
    }

    func testNotesLinksBacklinksAndTags() async throws {
        try write("Inbox.md", "Read [[Overterm]] and [[Plan#Steps]]. #todo")
        try write("Projects/Overterm.md", "---\ntags: [project]\n---\nSee [[Plan]] #project/overterm")
        try write("Projects/Plan.md", "# Steps\n[[Inbox]]")
        try write("attachments/shot.png", "png")
        try write(".overterm/notes.json", "{}")
        try write("Projects/Plan.md.sb-0542b826-qcqGyn", "half")

        let index = await index()
        XCTAssertTrue(index.isReady)
        XCTAssertEqual(index.notes.map(\.path), ["Inbox.md", "Projects/Overterm.md", "Projects/Plan.md"])
        XCTAssertEqual(index.entries.keys.sorted(), ["Inbox.md", "Projects/Overterm.md", "Projects/Plan.md", "attachments/shot.png"])
        XCTAssertNil(index.entries["attachments/shot.png"]?.syntax, "only notes are read")

        XCTAssertEqual(index.backlinks(to: "Projects/Plan.md").map(\.source), ["Inbox.md", "Projects/Overterm.md"])
        XCTAssertEqual(index.backlinks(to: "Projects/Plan.md").first?.links.first?.heading, "Steps")
        XCTAssertEqual(index.backlinks(to: "Inbox.md").map(\.source), ["Projects/Plan.md"])
        XCTAssertTrue(index.backlinks(to: "attachments/shot.png").isEmpty)

        XCTAssertEqual(index.tags.map(\.name), ["project", "project/overterm", "todo"])
        XCTAssertEqual(index.notes(tagged: "project"), ["Projects/Overterm.md"], "a tag finds the ones under it, each note once")
    }

    func testOnlyWhatChangedIsReadAgain() async throws {
        try write("A.md", "[[B]]")
        try write("B.md", "b")
        let index = await index()
        XCTAssertEqual(Set(cloud.reads.map { URL(fileURLWithPath: $0).lastPathComponent }), ["A.md", "B.md"])

        let before = cloud.reads.count
        await index.refreshed()
        XCTAssertEqual(cloud.reads.count, before, "nothing changed: nothing read")

        // A different size, so the change shows even within the same second.
        try write("A.md", "[[B]] and [[C]] now")
        try write("C.md", "new")
        await index.refreshed()
        XCTAssertEqual(cloud.reads.dropFirst(before).map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(), ["A.md", "C.md"])
        XCTAssertEqual(index.backlinks(to: "C.md").map(\.source), ["A.md"])

        try FileManager.default.removeItem(at: vault.appendingPathComponent("C.md"))
        await index.refreshed()
        XCTAssertNil(index.entries["C.md"])
        XCTAssertTrue(index.backlinks(to: "C.md").isEmpty)
    }

    func testANoteSentToICloudIsNotFetchedBack() async throws {
        try write("A.md", "#kept")
        let index = await index()
        let before = cloud.reads.count
        cloud.putInCloud(vault.appendingPathComponent("A.md"))
        await index.refreshed()
        XCTAssertEqual(cloud.reads.count, before, "the same size and date: what was read stays")
        XCTAssertEqual(index.entries["A.md"]?.cloud.download, .cloud)
        XCTAssertEqual(index.tags.map(\.name), ["kept"])
    }

    func testNotesInICloudAreAllAskedForAndReadAsTheyArrive() async throws {
        for name in ["A", "B", "C"] {
            try write("\(name).md", "[[Hub]] #\(name.lowercased())")
            cloud.putInCloud(vault.appendingPathComponent("\(name).md"))
        }
        try write("Hub.md", "hub")
        let index = await index()
        XCTAssertEqual(
            Set(["A", "B", "C"].map { cloud.state(of: vault.appendingPathComponent("\($0).md")).download }), [.downloading],
            "asked for at once")
        XCTAssertTrue(index.backlinks(to: "Hub.md").isEmpty, "not read yet")

        let arrived = expectation(description: "read once down")
        func check() {
            if index.backlinks(to: "Hub.md").count == 3 { return arrived.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        check()
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(index.tags.map(\.name), ["a", "b", "c"])
    }

    func testASavedNoteIsIndexedAtOnceAndRenamesPlanTheirEdits() async throws {
        try write("A.md", "[[B]]")
        try write("B.md", "b")
        let index = await index()
        index.noteSaved("B.md", text: "now [[A]]")
        XCTAssertEqual(index.backlinks(to: "A.md").map(\.source), ["B.md"], "without waiting for a read")

        let edits = index.renameEdits(old: "B.md", new: "Folder/Bee.md")
        XCTAssertEqual(NoteLinks.apply(edits["A.md"] ?? [], to: "[[B]]"), "[[Bee]]")
        XCTAssertEqual(index.path(for: vault.appendingPathComponent("Folder/Bee.md")), "Folder/Bee.md")
        XCTAssertNil(index.path(for: URL(fileURLWithPath: "/etc/hosts")))
    }
}
