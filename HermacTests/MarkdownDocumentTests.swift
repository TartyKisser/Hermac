import XCTest
@testable import Hermac

final class MarkdownDocumentTests: XCTestCase {
    func testComparisonTableKeepsHeadingsRowsAndColumnAlignment() throws {
        let document = MarkdownDocument("""
        ## 联系（真的有交集的部分）

        | 交集 | Hermes | dsh |
        | :--- | :---: | ---: |
        | 模型无关 | 35+ provider 插件 | OpenAI 兼容端点 |
        | 会话持久化 | SQLite `state.db` | **SessionEvent** |
        """)
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].kind, .header(level: 2))
        XCTAssertEqual(String(document.blocks[0].text.characters), "联系（真的有交集的部分）")
        let table = document.blocks[1]
        guard case .table(let columns) = table.kind else { return XCTFail("Expected a table") }
        XCTAssertEqual(columns.map(\.alignment), [.left, .center, .right])
        XCTAssertEqual(table.children.map(\.kind), [.tableHeaderRow, .tableRow(rowIndex: 1), .tableRow(rowIndex: 2)])
        XCTAssertEqual(table.children[0].children.map { String($0.text.characters) }, ["交集", "Hermes", "dsh"])
        XCTAssertEqual(table.children[2].children.map { String($0.text.characters) }, ["会话持久化", "SQLite state.db", "SessionEvent"])
        XCTAssertTrue(table.children[2].children[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testInlineStylesAndLinksRemainAttributedWithoutBlockIntents() throws {
        let text = try XCTUnwrap(MarkdownDocument("**粗体** *斜体* ~~删除~~ `hermes` [Apple](https://developer.apple.com)").blocks.first).text
        XCTAssertEqual(String(text.characters), "粗体 斜体 删除 hermes Apple")
        for style in [InlinePresentationIntent.stronglyEmphasized, .emphasized, .strikethrough, .code] {
            XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(style) == true })
        }
        XCTAssertTrue(text.runs.contains { $0.link == URL(string: "https://developer.apple.com") })
        XCTAssertTrue(text.runs.allSatisfy { $0.presentationIntent == nil })
    }

    func testNestedListsQuotesAndOrderedStartKeepTheirHierarchy() throws {
        let document = MarkdownDocument("""
        3. 第三项
        4. 第四项
           - 子项目

        > 第一段
        >
        > 第二段
        """)
        let list = try XCTUnwrap(document.blocks.first)
        XCTAssertEqual(list.kind, .orderedList)
        XCTAssertEqual(list.children.map(\.kind), [.listItem(ordinal: 3), .listItem(ordinal: 4)])
        XCTAssertEqual(String(list.children[0].children[0].text.characters), "第三项")
        let nested = try XCTUnwrap(list.children[1].children.last)
        XCTAssertEqual(nested.kind, .unorderedList)
        XCTAssertEqual(String(nested.children[0].children[0].text.characters), "子项目")
        let quote = document.blocks[1]
        XCTAssertEqual(quote.kind, .blockQuote)
        XCTAssertEqual(quote.children.map { String($0.text.characters) }, ["第一段", "第二段"])
    }

    func testFencedCodeKeepsLanguageWhitespaceAndLiteralMarkdown() throws {
        let document = MarkdownDocument("""
        ```swift
        let heading = "## literal"
          print(heading)
        ```
        """)
        let code = try XCTUnwrap(document.blocks.first)
        XCTAssertEqual(code.kind, .codeBlock(languageHint: "swift"))
        XCTAssertEqual(String(code.text.characters), "let heading = \"## literal\"\n  print(heading)\n")
        XCTAssertTrue(code.children.isEmpty)
    }

    func testUnclosedBacktickAndTildeFencesStayCodeDuringStreaming() throws {
        for fence in ["```", "~~~~"] {
            let document = MarkdownDocument("\(fence)python\nprint('still streaming')\n")
            let code = try XCTUnwrap(document.blocks.first)
            XCTAssertEqual(code.kind, .codeBlock(languageHint: "python"))
            XCTAssertEqual(String(code.text.characters), "print('still streaming')\n")
        }
    }

    func testEmptyTableCellsKeepTheirColumnIndexes() throws {
        let table = try XCTUnwrap(MarkdownDocument("""
        | A | B | C |
        | --- | --- | --- |
        | x | | z |
        | | y | |
        """).blocks.first)
        XCTAssertEqual(table.children[1].children.map(\.kind), [.tableCell(columnIndex: 0), .tableCell(columnIndex: 2)])
        XCTAssertEqual(table.children[2].children.map(\.kind), [.tableCell(columnIndex: 1)])
        XCTAssertEqual(String(table.children[1].children[1].text.characters), "z")
    }

    func testThematicBreakAndHardLineBreakRemainSeparateBlocks() {
        let document = MarkdownDocument("第一行  \n第二行\n\n---\n\n末段")
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .thematicBreak, .paragraph])
        XCTAssertEqual(String(document.blocks[0].text.characters), "第一行\n第二行")
        XCTAssertEqual(MarkdownDocument("***").blocks.map(\.kind), [.thematicBreak])
        XCTAssertTrue(MarkdownDocument("").blocks.isEmpty)
    }
}
