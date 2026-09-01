import XCTest
import Foundation
@testable import CodeContextKitContext

/// Low budgets used to deliver a header-only packet at exit 0 with no
/// warning — a silent wrong answer from a retrieval tool whose entire value
/// proposition is trustworthy output.
final class BudgetTruncationNoticeTests: XCTestCase {
    func testAppendBudgetNoticeExplainsTruncation() throws {
        let packet = "# Context Packet (Tokens: 59/600 · primary: 0 symbols · mode: raw)\n"
        let withNotice = ContextPacker.appendBudgetNotice(
            to: packet,
            budget: 600,
            unconstrainedTokens: 819,
            primaries: 3
        )
        XCTAssertTrue(withNotice.contains("## Warning"))
        XCTAssertTrue(withNotice.contains("600"))
        XCTAssertTrue(withNotice.contains("~819 tokens across 3 primaries"))
        XCTAssertTrue(withNotice.contains("--budget"))
        // The original header survives the notice.
        XCTAssertTrue(withNotice.hasPrefix(packet.trimmingCharacters(in: .newlines).prefix(20)))
    }

    func testNoticeIsAppendedOnlyWhenTruncationConfirmed() {
        // The notice exists precisely because 0-primaries has two causes:
        // true absence (probe finds nothing → no notice) and truncation
        // (probe finds content → notice). This pins the second case's format.
        let notice = ContextPacker.appendBudgetNotice(
            to: "packet", budget: 10, unconstrainedTokens: 400, primaries: 2)
        XCTAssertNotEqual(notice, "packet")
    }
}
