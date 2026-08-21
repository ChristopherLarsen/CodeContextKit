import XCTest
import CodeContextKitCore

final class OutlineAssemblerTests: XCTestCase {
    private func sym(
        kind: SymbolRecord.Kind,
        name: String,
        qn: String,
        start: Int,
        end: Int,
        enclosing: String? = nil,
        docs: String? = nil
    ) -> SymbolRecord {
        SymbolRecord(
            kind: kind,
            name: name,
            qualifiedName: qn,
            signature: "\(kind.rawValue) \(name)",
            filePath: "Huge.swift",
            startLine: start,
            endLine: end,
            enclosingType: enclosing,
            docComment: docs
        )
    }

    func testDefaultOmitsDocs() {
        let symbols = [
            sym(kind: .class, name: "Host", qn: "Host", start: 1, end: 10, docs: "A host type"),
            sym(kind: .method, name: "run", qn: "Host.run", start: 3, end: 5, enclosing: "Host", docs: "Runs it"),
        ]
        let outline = OutlineAssembler.render(symbols: symbols)
        XCTAssertFalse(outline.contains("///"))
        XCTAssertTrue(outline.contains("class Host"))
        XCTAssertTrue(outline.contains("method run"))
    }

    func testIncludeDocsOptIn() {
        let symbols = [
            sym(kind: .class, name: "Host", qn: "Host", start: 1, end: 10, docs: "A host type"),
        ]
        let outline = OutlineAssembler.render(
            symbols: symbols,
            options: OutlineOptions(includeDocs: true)
        )
        XCTAssertTrue(outline.contains("/// A host type"))
    }

    func testCollapsesHugeNestedTypeMembers() {
        var symbols = [
            sym(kind: .class, name: "MarkupView", qn: "MarkupView", start: 1, end: 500),
            sym(
                kind: .class,
                name: "Coordinator",
                qn: "MarkupView.Coordinator",
                start: 10,
                end: 490,
                enclosing: "MarkupView"
            ),
        ]
        for i in 1...45 {
            symbols.append(
                sym(
                    kind: .method,
                    name: "m\(i)",
                    qn: "MarkupView.Coordinator.m\(i)",
                    start: 10 + i,
                    end: 10 + i,
                    enclosing: "Coordinator"
                )
            )
        }
        let outline = OutlineAssembler.render(symbols: symbols)
        XCTAssertTrue(outline.contains("class MarkupView"))
        XCTAssertTrue(outline.contains("class Coordinator"))
        XCTAssertTrue(outline.contains("members omitted"))
        XCTAssertFalse(outline.contains("method m1"), outline)
        XCTAssertFalse(outline.contains("method m45"), outline)
    }

    func testSmallTypeKeepsMembers() {
        let symbols = [
            sym(kind: .struct, name: "Tiny", qn: "Tiny", start: 1, end: 20),
            sym(kind: .method, name: "run", qn: "Tiny.run", start: 5, end: 8, enclosing: "Tiny"),
        ]
        let outline = OutlineAssembler.render(symbols: symbols)
        XCTAssertTrue(outline.contains("method run"))
        XCTAssertFalse(outline.contains("omitted"))
    }

    func testMaxCharsTruncates() {
        var symbols: [SymbolRecord] = []
        for i in 1...30 {
            symbols.append(sym(kind: .function, name: "f\(i)", qn: "f\(i)", start: i, end: i))
        }
        let outline = OutlineAssembler.render(
            symbols: symbols,
            options: OutlineOptions(maxChars: 80, collapseMemberThreshold: Int.max)
        )
        XCTAssertTrue(outline.contains("outline truncated"))
        XCTAssertLessThan(outline.count, 200)
    }
}
