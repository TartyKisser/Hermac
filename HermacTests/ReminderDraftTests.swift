import XCTest
@testable import Hermac

final class ReminderDraftTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!

    func testMissingDateStaysUnscheduledAndLocationIsPreserved() throws {
        let draft = try ReminderDraft.parse(#"{"title":"讨论方案","notes":"带上资料","location":"会议室A","date":null,"time":null,"priority":0}"#, timeZone: zone)
        XCTAssertNil(draft.dueDate)
        XCTAssertFalse(draft.includesTime)
        XCTAssertNil(draft.dueComponents(timeZone: zone))
        XCTAssertEqual(draft.reminderNotes, "带上资料\n\n地点：会议室A")
    }

    func testTimedAndAllDayDatesKeepLocalCalendarComponents() throws {
        let timed = try ReminderDraft.parse(#"{"title":"评审","date":"2026-11-10","time":"15:30","priority":1}"#, timeZone: zone)
        let components = try XCTUnwrap(timed.dueComponents(timeZone: zone))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 10)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 30)
        XCTAssertTrue(timed.includesTime)
        let allDay = try ReminderDraft.parse(#"{"title":"交报告","date":"2026-11-12","time":null}"#, timeZone: zone)
        XCTAssertFalse(allDay.includesTime)
        XCTAssertNil(allDay.dueComponents(timeZone: zone)?.hour)
        XCTAssertNil(allDay.dueComponents(timeZone: zone)?.minute)
    }

    func testInvalidDateAndEmptyTitleCannotBecomeDrafts() {
        XCTAssertThrowsError(try ReminderDraft.parse(#"{"title":"会议","date":"2026-02-30","time":"15:00"}"#, timeZone: zone))
        XCTAssertThrowsError(try ReminderDraft.parse(#"{"title":"  "}"#, timeZone: zone))
        XCTAssertThrowsError(try ReminderDraft.parse("not JSON", timeZone: zone))
    }

    func testFencedJSONAndTimeWithoutDateRetainUncertainty() throws {
        let draft = try ReminderDraft.parse("```json\n" + #"{"title":"交材料","date":null,"time":"15:00","notes":"带上签字版","priority":8}"# + "\n```", timeZone: zone)
        XCTAssertNil(draft.dueDate)
        XCTAssertTrue(draft.notes.contains("日期待定"))
        XCTAssertTrue(draft.notes.contains("15:00"))
        XCTAssertEqual(draft.priority, 0)
    }
}
