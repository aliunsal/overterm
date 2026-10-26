import XCTest

@testable import Overterm

final class NoteLinksTests: XCTestCase {
    private let vault = NoteLinks(files: [
        "Inbox.md",
        "Projects/Overterm.md",
        "Projects/Notes/Plan.md",
        "Archive/Plan.md",
        "Archive/2025/Overterm.md",
        "attachments/shot.png",
        "Günlük/2026-10-26.md",
    ])

    private func wiki(_ target: String, from source: String = "Inbox.md") -> String? {
        vault.resolve(target, style: .wiki, from: source)
    }

    func testByNameIgnoringCaseAndExtension() {
        XCTAssertEqual(wiki("inbox"), "Inbox.md")
        XCTAssertEqual(wiki("Inbox.md"), "Inbox.md")
        XCTAssertEqual(wiki("shot.png"), "attachments/shot.png")
        XCTAssertNil(wiki("Not written yet"))
        XCTAssertNil(wiki("shot"), "a file other than a note keeps its extension in its name")
    }

    func testAnAmbiguousNameGoesToTheNearestThenTheShallowest() {
        XCTAssertEqual(wiki("Overterm"), "Projects/Overterm.md", "shallower than Archive/2025")
        XCTAssertEqual(wiki("Overterm", from: "Archive/2025/Log.md"), "Archive/2025/Overterm.md")
        XCTAssertEqual(wiki("Plan", from: "Archive/x.md"), "Archive/Plan.md")
        XCTAssertEqual(wiki("Plan", from: "Projects/x.md"), "Projects/Notes/Plan.md")
        XCTAssertEqual(wiki("Plan"), "Archive/Plan.md", "neither is nearer: the shallower")
    }

    func testAPathOrItsTail() {
        XCTAssertEqual(wiki("Projects/Notes/Plan"), "Projects/Notes/Plan.md")
        XCTAssertEqual(wiki("Notes/Plan"), "Projects/Notes/Plan.md")
        XCTAssertEqual(wiki("2025/Overterm"), "Archive/2025/Overterm.md")
        XCTAssertNil(wiki("Elsewhere/Plan"))
    }

    func testUnicodeNormalizationAndAnEmptyTarget() {
        let decomposed = "Gu\u{0308}nlu\u{0308}k/2026-10-26"
        XCTAssertEqual(wiki(decomposed), "Günlük/2026-10-26.md")
        XCTAssertEqual(wiki("", from: "Projects/Overterm.md"), "Projects/Overterm.md")
    }

    func testMarkdownLinksAreRelativeToTheNote() {
        XCTAssertEqual(vault.resolve("../Inbox.md", style: .markdown, from: "Projects/Overterm.md"), "Inbox.md")
        XCTAssertEqual(vault.resolve("Notes/Plan.md", style: .markdown, from: "Projects/Overterm.md"), "Projects/Notes/Plan.md")
        XCTAssertEqual(vault.resolve("/Archive/Plan.md", style: .markdown, from: "Projects/Overterm.md"), "Archive/Plan.md")
        XCTAssertNil(vault.resolve("../../../etc/passwd", style: .markdown, from: "Projects/Overterm.md"))
    }

    func testTheShortestTargetThatReadsBack() {
        XCTAssertEqual(vault.wikiTarget(to: "Inbox.md", from: "Projects/Overterm.md"), "Inbox")
        XCTAssertEqual(vault.wikiTarget(to: "Archive/2025/Overterm.md", from: "Inbox.md"), "2025/Overterm")
        XCTAssertEqual(vault.wikiTarget(to: "Archive/2025/Overterm.md", from: "Archive/2025/Log.md"), "Overterm")
        XCTAssertEqual(vault.wikiTarget(to: "attachments/shot.png", from: "Inbox.md"), "shot.png")
        XCTAssertEqual(NoteLinks.markdownDestination(to: "Projects/My Plan (v2).md", from: "Archive/2025/Log.md"), "../../Projects/My%20Plan%20%28v2%29.md")
    }

    func testRenameRewritesLinksToTheNoteAndNothingElse() {
        let files = ["Inbox.md", "Projects/Overterm.md", "Notes.md"]
        let inbox = "[[Overterm]] and [[Overterm#Plan|the plan]], [x](Projects/Overterm.md), [[Notes]] [[Missing]]"
        let links = ["Inbox.md": NoteSyntax.parse(inbox).links]
        let edits = NoteLinks.renameEdits(old: "Projects/Overterm.md", new: "Projects/Terminal.md", files: files, links: links)
        XCTAssertEqual(edits.keys.sorted(), ["Inbox.md"])
        XCTAssertEqual(
            NoteLinks.apply(edits["Inbox.md"] ?? [], to: inbox),
            "[[Terminal]] and [[Terminal#Plan|the plan]], [x](Projects/Terminal.md), [[Notes]] [[Missing]]")
    }

    func testANewNameThatWouldStealLinksKeepsThemWhereTheyPointed() {
        // Renaming Drafts/Old.md to Drafts/Plan.md: [[Plan]] in Drafts/x.md
        // meant Archive/Plan.md; the nearer new Plan would take it.
        let files = ["Archive/Plan.md", "Drafts/Old.md", "Drafts/x.md"]
        let x = "[[Plan]] [[Old]]"
        let edits = NoteLinks.renameEdits(old: "Drafts/Old.md", new: "Drafts/Plan.md", files: files, links: ["Drafts/x.md": NoteSyntax.parse(x).links])
        XCTAssertEqual(NoteLinks.apply(edits["Drafts/x.md"] ?? [], to: x), "[[Archive/Plan]] [[Plan]]")
    }

    func testAMovedNotesOwnRelativeLinksFollowIt() {
        let files = ["Inbox.md", "a/Note.md"]
        let note = "[up](../Inbox.md) [[Inbox]]"
        let edits = NoteLinks.renameEdits(old: "a/Note.md", new: "a/b/c/Note.md", files: files, links: ["a/Note.md": NoteSyntax.parse(note).links])
        XCTAssertEqual(edits.keys.sorted(), ["a/b/c/Note.md"], "keyed where the note will be")
        XCTAssertEqual(NoteLinks.apply(edits["a/b/c/Note.md"] ?? [], to: note), "[up](../../../Inbox.md) [[Inbox]]")
    }
}
