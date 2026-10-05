import Foundation

/// Numeric, five-field cron. No seconds, aliases, names or external dependency.
public struct CronExpression: Sendable {
    public enum ParseError: Error, LocalizedError {
        case invalid
        public var errorDescription: String? {
            "CRON 必须是五段：分 时 日 月 星期；支持数字、*、逗号、范围和 /步长，且必须存在有效日期"
        }
    }

    private struct Field: Sendable {
        let values: [Int]
        let wildcard: Bool

        init(_ text: Substring, range: ClosedRange<Int>, sunday: Bool = false) throws {
            wildcard = text.hasPrefix("*")
            var result = Set<Int>()
            func number(_ text: Substring) throws -> Int {
                guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let value = Int(text) else { throw ParseError.invalid }
                return value
            }
            for item in text.split(separator: ",", omittingEmptySubsequences: false) {
                let parts = item.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count) else { throw ParseError.invalid }
                let step = try parts.count == 2 ? number(parts[1]) : 1
                guard step > 0 else { throw ParseError.invalid }
                let lower: Int
                let upper: Int
                if parts[0] == "*" {
                    lower = range.lowerBound
                    upper = range.upperBound
                } else {
                    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(bounds.count) else { throw ParseError.invalid }
                    lower = try number(bounds[0])
                    upper = try bounds.count == 2 ? number(bounds[1]) : (parts.count == 2 ? range.upperBound : lower)
                }
                guard range.contains(lower), range.contains(upper), lower <= upper else { throw ParseError.invalid }
                for value in lower...upper where (value - lower) % step == 0 {
                    result.insert(sunday && value == 7 ? 0 : value)
                }
            }
            guard !result.isEmpty else { throw ParseError.invalid }
            values = result.sorted()
        }
    }

    private let minutes: Field
    private let hours: Field
    private let days: Field
    private let months: Field
    private let weekdays: Field

    public init(_ expression: String) throws {
        guard expression.utf8.count <= 256 else { throw ParseError.invalid }
        let fields = expression.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 5 else { throw ParseError.invalid }
        minutes = try Field(fields[0], range: 0...59)
        hours = try Field(fields[1], range: 0...23)
        days = try Field(fields[2], range: 1...31)
        months = try Field(fields[3], range: 1...12)
        weekdays = try Field(fields[4], range: 0...7, sunday: true)
        // With two restricted day fields cron uses OR; otherwise both must match.
        // Reject impossible dates such as February 30 without searching year after year.
        let maxDays = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        if days.wildcard || weekdays.wildcard {
            guard months.values.contains(where: { month in days.values.contains { $0 <= maxDays[month - 1] } })
            else { throw ParseError.invalid }
        }
    }

    /// Strictly after `date`, using the system's local time zone by default. Search days,
    /// then jump directly to an allowed hour/minute; never scan intervening minutes.
    /// Missing DST times are skipped; repeated local times use their first occurrence.
    public func nextDate(after date: Date, timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var day = calendar.startOfDay(for: date)
        let firstDay = day
        // February 29 can be eight years apart across a non-leap century (2100).
        guard let limit = calendar.date(byAdding: .year, value: 8, to: day) else { return nil }
        let current = calendar.dateComponents([.hour, .minute], from: date)
        while day <= limit {
            guard let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
            let components = calendar.dateComponents([.month, .day, .weekday], from: day)
            let dom = days.values.contains(components.day!)
            let dow = weekdays.values.contains(components.weekday! - 1)
            let dayMatches = days.wildcard || weekdays.wildcard ? dom && dow : dom || dow
            if months.values.contains(components.month!), dayMatches {
                for hour in hours.values {
                    if day == firstDay, hour < current.hour! { continue }
                    for minute in minutes.values {
                        if day == firstDay,
                           hour * 60 + minute < current.hour! * 60 + current.minute! { continue }
                        guard let candidate = calendar.date(
                            bySettingHour: hour, minute: minute, second: 0, of: day,
                            matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward
                        ), candidate >= interval.start, candidate < interval.end, candidate > date else { continue }
                        return candidate
                    }
                }
            }
            day = interval.end
        }
        return nil
    }
}
