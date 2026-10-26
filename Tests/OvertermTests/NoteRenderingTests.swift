import AppKit
import XCTest

@testable import Overterm

final class NoteRenderingTests: XCTestCase {
    func testWikilinksAndTagsBecomeLinksTheHostTakes() {
        let markdown = NoteRendering.markdown("See [[Plan]], [[Projects/Plan#Steps|the steps]], [[#Here]] and #todo.")
        XCTAssertEqual(
            markdown,
            "See [Plan](overterm-note:Plan), [the steps](overterm-note:Projects/Plan#Steps), [Here](overterm-note:#Here) and [#todo](overterm-tag:todo).")
        let back = NoteRendering.target(of: URL(string: "overterm-note:My%20Note#A%20Heading")!)
        XCTAssertEqual(back?.target, "My Note")
        XCTAssertEqual(back?.heading, "A Heading")
        XCTAssertEqual(NoteRendering.tag(of: URL(string: "overterm-tag:project/overterm")!), "project/overterm")
        XCTAssertNil(NoteRendering.target(of: URL(string: "https://example.com")!))
    }

    func testCommentsAndFrontmatterGoCodeStays() {
        let markdown = NoteRendering.markdown("---\ntags: [a]\n---\nVisible %%hidden%% text\n\n```\n[[not]] #not\n```\n")
        XCTAssertEqual(markdown, "Visible  text\n\n```\n[[not]] #not\n```\n")
    }

    func testASingleLineBreakIsALineBreak() {
        let text = "First line\nsecond line\n\n- item\n- item two\n# Heading\nafter\n| a | b |\n| - | - |\n"
        let markdown = NoteRendering.markdown(text)
        XCTAssertTrue(markdown.hasPrefix("First line  \nsecond line\n\n"), markdown)
        XCTAssertTrue(markdown.contains("- item\n- item two\n"), "a list's items stay items")
        XCTAssertTrue(markdown.contains("# Heading\nafter\n"), "a heading is its own line already")
        XCTAssertTrue(markdown.contains("| a | b |\n| - | - |"), "a table is untouched")
        // And the renderer draws it on two lines.
        let rendered = MarkdownRenderer.render("First line  \nsecond line", theme: EditorTheme(background: .black)).string
        XCTAssertTrue(rendered.contains("First line\u{2028}second line") || rendered.contains("First line\nsecond line"), rendered.debugDescription)
    }

    func testAnAliasWithBracketsIsEscaped() {
        XCTAssertEqual(NoteRendering.markdown("[[Plan|a [draft]]]"), "[a \\[draft](overterm-note:Plan)]")
    }
}

final class NoteCompletionTests: XCTestCase {
    private func context(_ text: String) -> NoteCompletion.Context? {
        let caret = (text as NSString).range(of: "|").location
        let without = text.replacingOccurrences(of: "|", with: "")
        return NoteCompletion.context(in: without as NSString, caret: caret)
    }

    func testTheCaretInsideAnOpenWikilink() {
        XCTAssertEqual(context("See [[Pla|]] now"), .init(anchor: 6, query: "Pla", isClosed: true, isEmbed: false))
        XCTAssertEqual(context("See [[My No|"), .init(anchor: 6, query: "My No", isClosed: false, isEmbed: false))
        XCTAssertEqual(context("![[sh|]]")?.isEmbed, true)
        XCTAssertNil(context("See [[Plan]] and |"), "after a closed link")
        XCTAssertNil(context("[[Plan#Ste|]]"), "a heading is no name")
        XCTAssertNil(context("[[\nPla|"), "not across lines")
        XCTAssertNil(context("[Pla|"))
    }

    func testSuggestionsByNameAndAliasWritingTheShortestTarget() {
        let files = ["Inbox.md", "Projects/Plan.md", "Archive/Plan.md", "attachments/shot.png"]
        let links = NoteLinks(files: files)
        let open = NoteCompletion.Context(anchor: 2, query: "pla", isClosed: true, isEmbed: false)
        let suggestions = NoteCompletion.suggestions(
            for: open, files: files, aliases: ["Inbox.md": ["Gelen kutusu"]], links: links, from: "Projects/x.md")
        XCTAssertEqual(suggestions.map(\.title), ["Plan", "Plan"])
        XCTAssertEqual(Set(suggestions.map(\.insert)), ["Plan]]", "Archive/Plan]]"], "the nearer by name, the other by the path that reaches it")
        XCTAssertFalse(suggestions.contains { $0.title.contains("shot") }, "a link offers notes")

        let alias = NoteCompletion.suggestions(
            for: .init(anchor: 2, query: "gelen", isClosed: false, isEmbed: false), files: files, aliases: ["Inbox.md": ["Gelen kutusu"]],
            links: links, from: "Projects/x.md")
        XCTAssertEqual(alias.first?.insert, "Inbox|Gelen kutusu]]")

        let embed = NoteCompletion.suggestions(
            for: .init(anchor: 3, query: "shot", isClosed: false, isEmbed: true), files: files, aliases: [:], links: links, from: "Inbox.md")
        XCTAssertEqual(embed.first?.insert, "shot.png]]")
    }

    func testAFoldersNotesMoveTogether() {
        let files = ["Inbox.md", "Old/A.md", "Old/B.md"]
        let inbox = "[[Old/A]] [[B]] [x](Old/B.md)"
        let edits = NoteLinks.renameEdits(
            moves: ["Old/A.md": "New/A.md", "Old/B.md": "New/B.md"], files: files, links: ["Inbox.md": NoteSyntax.parse(inbox).links])
        XCTAssertEqual(NoteLinks.apply(edits["Inbox.md"] ?? [], to: inbox), "[[A]] [[B]] [x](New/B.md)")
    }
}
