import Foundation
import Testing
@testable import BarbackCore

struct CronExpressionTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func strictlyFutureAndMinutePrecision() throws {
        let cron = try CronExpression("* * * * *")
        let start = date("2030-01-01T00:00:00Z")
        #expect(cron.nextDate(after: start, timeZone: utc) == start.addingTimeInterval(60))
        #expect(cron.nextDate(after: start.addingTimeInterval(59.5), timeZone: utc) == start.addingTimeInterval(60))
    }

    @Test func listsRangesAndSteps() throws {
        let cron = try CronExpression("5,20-50/15 9-17/2 * * 1-5")
        #expect(cron.nextDate(after: date("2030-01-04T17:50:01Z"), timeZone: utc) == date("2030-01-07T09:05:00Z"))
        #expect(cron.nextDate(after: date("2030-01-07T09:20:00Z"), timeZone: utc) == date("2030-01-07T09:35:00Z"))
        let offset = try CronExpression("10/20 * * * *")
        #expect(offset.nextDate(after: date("2030-01-07T09:10:00Z"), timeZone: utc) == date("2030-01-07T09:30:00Z"))
    }

    @Test func dayFieldsUseCronOrSemanticsAndSundayAliases() throws {
        let cron = try CronExpression("0 9 1 * 1")
        #expect(cron.nextDate(after: date("2030-01-01T09:00:00Z"), timeZone: utc) == date("2030-01-07T09:00:00Z"))
        let zero = try CronExpression("0 0 * * 0")
        let seven = try CronExpression("0 0 * * 7")
        let start = date("2030-01-01T00:00:00Z")
        #expect(zero.nextDate(after: start, timeZone: utc) == date("2030-01-06T00:00:00Z"))
        #expect(seven.nextDate(after: start, timeZone: utc) == zero.nextDate(after: start, timeZone: utc))
        let wildcardStep = try CronExpression("0 0 */2 * 1")
        #expect(wildcardStep.nextDate(after: start, timeZone: utc) == date("2030-01-07T00:00:00Z"))
        let impossibleDomButValidDow = try CronExpression("0 0 31 2 1")
        #expect(impossibleDomButValidDow.nextDate(after: start, timeZone: utc) == date("2030-02-04T00:00:00Z"))
    }

    @Test func leapDayAndNonLeapCentury() throws {
        let cron = try CronExpression("0 0 29 2 *")
        #expect(cron.nextDate(after: date("2030-03-01T00:00:00Z"), timeZone: utc) == date("2032-02-29T00:00:00Z"))
        #expect(cron.nextDate(after: date("2096-02-29T00:00:00Z"), timeZone: utc) == date("2104-02-29T00:00:00Z"))
        let month = try CronExpression("0 0 31 * *")
        #expect(month.nextDate(after: date("2030-04-01T00:00:00Z"), timeZone: utc) == date("2030-05-31T00:00:00Z"))
    }

    @Test func localTimeZone() throws {
        let cron = try CronExpression("0 9 * * *")
        #expect(cron.nextDate(after: date("2030-01-01T00:00:00Z"), timeZone: TimeZone(identifier: "Asia/Shanghai")!) == date("2030-01-01T01:00:00Z"))
    }

    @Test func dstSkipsMissingAndDoesNotRepeatLocalTime() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = try CronExpression("30 2 * * *")
        #expect(spring.nextDate(after: date("2026-03-08T08:00:00Z"), timeZone: zone) == date("2026-03-09T09:30:00Z"))
        let autumn = try CronExpression("30 1 * * *")
        #expect(autumn.nextDate(after: date("2026-11-01T07:00:00Z"), timeZone: zone) == date("2026-11-01T08:30:00Z"))
        #expect(autumn.nextDate(after: date("2026-11-01T08:30:00Z"), timeZone: zone) == date("2026-11-02T09:30:00Z"))
        #expect(autumn.nextDate(after: date("2026-11-01T09:10:00Z"), timeZone: zone) == date("2026-11-02T09:30:00Z"))
    }

    @Test(arguments: ["", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *",
                      "* * * 13 *", "* * * * 8", "*/0 * * * *", "1,,2 * * * *", "10-5 * * * *",
                      "1/ * * * *", "1/2/3 * * * *", "-1 * * * *", "+1 * * * *", "@daily",
                      "0 0 30 2 *", "0 0 31 4 *", "0 0 * * MON", "999999999999999999999 * * * *"])
    func rejectsInvalidExpressions(_ expression: String) {
        #expect(throws: CronExpression.ParseError.self) { _ = try CronExpression(expression) }
    }
}
