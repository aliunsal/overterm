import XCTest

@testable import Overterm

final class NoteSyntaxTests: XCTestCase {
    private func text(_ source: String, _ range: NSRange) -> String { (source as NSString).substring(with: range) }

    func testWikilinksWithHeadingsBlocksAliasesAndEmbeds() {
        let source = "See [[Overterm]], [[Projects/Notes#Plan|the plan]], [[Log#^abc12]] and ![[shot.png]]. [[#Here]]"
        let links = NoteSyntax.parse(source).links
        XCTAssertEqual(links.map(\.target), ["Overterm", "Projects/Notes", "Log", "shot.png", ""])
        XCTAssertEqual(links.map(\.heading), [nil, "Plan", nil, nil, "Here"])
        XCTAssertEqual(links.map(\.block), [nil, nil, "abc12", nil, nil])
        XCTAssertEqual(links.map(\.alias), [nil, "the plan", nil, nil, nil])
        XCTAssertEqual(links.map(\.isEmbed), [false, false, false, true, false])
        XCTAssertEqual(links.map { text(source, $0.range) }, ["[[Overterm]]", "[[Projects/Notes#Plan|the plan]]", "[[Log#^abc12]]", "![[shot.png]]", "[[#Here]]"])
        XCTAssertEqual(links.map { text(source, $0.targetRange) }, ["Overterm", "Projects/Notes", "Log", "shot.png", ""])
        XCTAssertTrue(links.allSatisfy { $0.style == .wiki })
    }

    func testATablesEscapedPipeStillSplitsTheAlias() {
        let link = NoteSyntax.parse("| [[Overterm\\|app]] | x |").links.first
        XCTAssertEqual(link?.target, "Overterm")
        XCTAssertEqual(link?.alias, "app")
    }

    func testMarkdownLinksToNotesButNotToURLs() {
        let source = "[the plan](../Projects/My%20Plan.md#Steps) [site](https://example.com/#top) ![s](img/a.png)"
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.links.map(\.target), ["../Projects/My Plan.md", "img/a.png"])
        XCTAssertEqual(syntax.links.first?.heading, "Steps")
        XCTAssertEqual(syntax.links.first?.alias, "the plan")
        XCTAssertEqual(syntax.links.first.map { text(source, $0.targetRange) }, "../Projects/My%20Plan.md")
        XCTAssertEqual(syntax.links.map(\.isEmbed), [false, true])
        XCTAssertTrue(syntax.tags.isEmpty, "a URL's fragment is no tag")
    }

    func testTagsNeedALetterAndASpaceBefore() {
        let source = "#inbox and #project/overterm, issue #42, a#b, #ünlü_etiket.\n# Heading"
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.tags.map(\.name), ["inbox", "project/overterm", "ünlü_etiket"])
        XCTAssertEqual(syntax.tags.map { text(source, $0.range) }, ["#inbox", "#project/overterm", "#ünlü_etiket"])
        XCTAssertEqual(syntax.headings.map(\.text), ["Heading"])
    }

    func testNothingCountsInsideCode() {
        let source = """
            `[[not a link]] #nottag` [[real]]
            ```swift
            let x = "[[nope]] #nope"
            ```
            ~~~~
            #nope
            ~~~~
            after #yes
            """
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.links.map(\.target), ["real"])
        XCTAssertEqual(syntax.tags.map(\.name), ["yes"])
        XCTAssertEqual(syntax.code.count, 3)
        XCTAssertEqual(text(source, syntax.code[0]), "`[[not a link]] #nottag`")
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        let syntax = NoteSyntax.parse("before #a\n```\n#b [[c]]\n")
        XCTAssertEqual(syntax.tags.map(\.name), ["a"])
        XCTAssertTrue(syntax.links.isEmpty)
    }

    func testCommentsHideWhatIsInThemAcrossLines() {
        let source = "a %%hidden [[x]]%% b [[y]]\n%%\n#secret\n[[z]]\n%% #shown"
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.links.map(\.target), ["y"])
        XCTAssertEqual(syntax.tags.map(\.name), ["shown"])
        XCTAssertEqual(syntax.comments.map { text(source, $0) }, ["%%hidden [[x]]%%", "%%\n#secret\n[[z]]\n%%"])
    }

    func testFrontmatterTagsAliasesAndFields() {
        let source = """
            ---
            title: "Plan"
            tags: [notes, "icloud"]
            aliases:
              - The Plan
              - Notes plan
            created: 2026-10-26
            ---
            # Body #inbody
            """
        let syntax = NoteSyntax.parse(source)
        let frontmatter = syntax.frontmatter
        XCTAssertEqual(frontmatter?.tags, ["notes", "icloud"])
        XCTAssertEqual(frontmatter?.aliases, ["The Plan", "Notes plan"])
        XCTAssertEqual(frontmatter?.fields.map(\.key), ["title", "tags", "aliases", "created"])
        XCTAssertEqual(frontmatter?.fields.first?.value, "Plan")
        XCTAssertEqual(frontmatter.map { text(source, $0.range) }?.hasSuffix("---\n"), true)
        XCTAssertEqual(syntax.headings.map(\.text), ["Body #inbody"])
        XCTAssertEqual(syntax.allTags, ["notes", "icloud", "inbody"])
    }

    func testOldFrontmatterFormsAndNoFrontmatter() {
        XCTAssertEqual(NoteSyntax.parse("---\ntags: a, #b c\n---\n").frontmatter?.tags, ["a", "b", "c"])
        XCTAssertEqual(NoteSyntax.parse("---\naliases: One, Two\n---\n").frontmatter?.aliases, ["One", "Two"])
        XCTAssertNil(NoteSyntax.parse("text\n---\ntags: a\n---\n").frontmatter, "only at the very top")
        XCTAssertNil(NoteSyntax.parse("---\ntags: a\nnever closed").frontmatter)
    }

    func testTasksHighlightsAndCallouts() {
        let source = """
            - [ ] write the plan
            - [x] spike ==iCloud== first
            1. [ ] numbered
            - [link](x.md) is no task
            > [!warning]- Careful
            > text
            """
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.tasks.map(\.isDone), [false, true, false])
        XCTAssertEqual(syntax.tasks.map { text(source, $0.range) }, ["[ ]", "[x]", "[ ]"])
        XCTAssertEqual(syntax.highlights.map { text(source, $0) }, ["==iCloud=="])
        XCTAssertEqual(syntax.callouts.map(\.type), ["warning"])
        XCTAssertEqual(syntax.callouts.first?.title, "Careful")
    }

    func testRangesAreUTF16() {
        let source = "🙂 çağ [[Şükrü]] #ğ"
        let syntax = NoteSyntax.parse(source)
        XCTAssertEqual(syntax.links.first.map { text(source, $0.range) }, "[[Şükrü]]")
        XCTAssertEqual(syntax.tags.first.map { text(source, $0.range) }, "#ğ")
    }

    func testHeadingsAndCRLF() {
        let syntax = NoteSyntax.parse("# One #\r\n## Two\r\n####### seven\r\n#nospace\r\n")
        XCTAssertEqual(syntax.headings.map(\.text), ["One", "Two"])
        XCTAssertEqual(syntax.headings.map(\.level), [1, 2])
        XCTAssertEqual(syntax.tags.map(\.name), ["nospace"])
    }
}
