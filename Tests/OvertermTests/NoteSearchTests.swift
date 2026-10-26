import XCTest

@testable import Overterm

final class NoteSearchTests: XCTestCase {
    private let notes: [(path: String, text: String, tags: [String])] = [
        ("Inbox.md", "# Inbox\n\nBuy milk.\nCall Şükrü about the çağrı.\n", ["todo"]),
        ("Projects/Milk Run.md", "Plan the run.\n", ["project/milk"]),
        ("Archive/Old.md", "milk milk\nmore milk\n", []),
    ]

    func testTermsQuotesAndTags() {
        XCTAssertEqual(NoteSearch.parse(#"buy "the run" #todo"#), .init(words: ["buy", "the run"], tags: ["todo"]))
        XCTAssertEqual(NoteSearch.parse("#"), .init(words: ["#"], tags: []), "a lone # is a word")
        XCTAssertTrue(NoteSearch.parse("   ").isEmpty)
    }

    func testEveryTermInTheTextOrTheName() {
        XCTAssertEqual(
            NoteSearch.search("milk", notes: notes).map(\.path), ["Projects/Milk Run.md", "Archive/Old.md", "Inbox.md"],
            "the name first, then the most hits")
        XCTAssertEqual(NoteSearch.search("milk run", notes: notes).map(\.path), ["Projects/Milk Run.md"])
        XCTAssertEqual(NoteSearch.search(#""buy milk""#, notes: notes).map(\.path), ["Inbox.md"])
        XCTAssertEqual(NoteSearch.search("sukru cagri", notes: notes).map(\.path), ["Inbox.md"], "accents and case aside")
    }

    func testTagsAndTheTagsUnderThem() {
        XCTAssertEqual(NoteSearch.search("#todo", notes: notes).map(\.path), ["Inbox.md"])
        XCTAssertEqual(NoteSearch.search("#project", notes: notes).map(\.path), ["Projects/Milk Run.md"])
        XCTAssertEqual(NoteSearch.search("#project plan", notes: notes).map(\.path), ["Projects/Milk Run.md"])
        XCTAssertTrue(NoteSearch.search("#project milkshake", notes: notes).isEmpty)
    }

    func testHitsAreLinesOnceWithWhereTheMatchIs() {
        let old = NoteSearch.search("milk", notes: notes).first { $0.path == "Archive/Old.md" }
        XCTAssertEqual(old?.hits.map(\.line), [1, 2])
        XCTAssertEqual(old?.hits.map(\.context), ["milk milk", "more milk"])
        let inbox = NoteSearch.search("çağrı", notes: notes).first
        XCTAssertEqual(inbox?.hits.first.map { ("# Inbox\n\nBuy milk.\nCall Şükrü about the çağrı.\n" as NSString).substring(with: $0.range) }, "çağrı")
    }
}

/// Daily notes and attachments, on a temporary vault.
@MainActor
final class NotesWorkspaceTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func workspace() throws -> NotesWorkspace {
        let workspace = NotesWorkspace(vaults: NoteVaults(url: dir.appendingPathComponent("vaults.json")), files: SimulatedCloudFiles())
        try workspace.addVault(at: dir.appendingPathComponent("Vault"))
        return workspace
    }

    func testTheDailyNoteIsMadeOnceFromTheTemplateIfAny() throws {
        let workspace = try workspace()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 5))!
        let plain = try workspace.dailyNote(for: date)
        XCTAssertEqual(workspace.path(for: plain), "Daily/2026-10-27.md")
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "# 2026-10-27\n\n")
        try "kept".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(try workspace.dailyNote(for: date), plain)
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "kept", "made once, never over what is there")

        let templates = dir.appendingPathComponent("Vault/Templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try "# {{title}}\nStarted {{date}} at {{time}}\n".write(to: templates.appendingPathComponent("Daily.md"), atomically: true, encoding: .utf8)
        let next = try workspace.dailyNote(for: date.addingTimeInterval(86_400))
        XCTAssertEqual(try String(contentsOf: next, encoding: .utf8), "# 2026-10-28\nStarted 2026-10-28 at 09:05\n")
    }

    func testAnAttachmentGetsAFreeNameInTheAttachmentsFolder() throws {
        let workspace = try workspace()
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let first = try workspace.saveAttachment(Data([1, 2, 3]), ext: "png", date: date)
        let second = try workspace.saveAttachment(Data([4]), ext: "png", date: date)
        XCTAssertTrue(first.hasPrefix("attachments/Pasted image 2026"), first)
        XCTAssertNotEqual(first, second, "the same second: another name")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Vault").appendingPathComponent(first)), Data([1, 2, 3]))
        XCTAssertEqual(try workspace.saveAttachment(Data([5]), ext: "jpg", named: "Photo"), "attachments/Photo.jpg")
    }
}
