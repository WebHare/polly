import Foundation

/// The notations of Nagios' `date_format` (cgi/cmd.c `string_to_time`). Command forms are prefilled and read in
/// the server's notation and time zone, neither of which the server reports. Times are handled as wall-clock
/// values (a `Date` in UTC that stands for the server's local time), so no time zone is ever applied.
enum NagiosDateNotation: CaseIterable, Sendable {
    case us, euro, iso8601, strictISO8601

    private var format: String {
        switch self {
        case .us: "MM-dd-yyyy HH:mm:ss"
        case .euro: "dd-MM-yyyy HH:mm:ss"
        case .iso8601: "yyyy-MM-dd HH:mm:ss"
        case .strictISO8601: "yyyy-MM-dd'T'HH:mm:ss"
        }
    }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    /// The wall-clock time, or nil when `text` isn't exactly in this notation.
    func parse(_ text: String) -> Date? {
        let formatter = formatter
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    func format(_ date: Date) -> String { formatter.string(from: date) }

    /// The notations the server may be using, judged from the start and end a downtime form was prefilled with:
    /// both must parse, the end is 2 hours after the start (cmd.c), and the start is the server's "now", so it lies
    /// within 14 hours of this device's clock (the largest UTC offsets) plus a few minutes for clock skew.
    static func candidates(prefilledStart: String, prefilledEnd: String, now: Date = Date()) -> [NagiosDateNotation] {
        allCases.filter { notation in
            guard let start = notation.parse(prefilledStart), let end = notation.parse(prefilledEnd) else { return false }
            return abs(end.timeIntervalSince(start) - 7200) < 1 && abs(start.timeIntervalSince(now)) <= 14 * 3600 + 600
        }
    }

    /// The end of `preset` counted from `start`, in each candidate notation. Returns a value only when every candidate
    /// can read `start` and gives the same text: on 03-04-2026 "us" and "euro" agree on the date of "+30 min" but
    /// not on that of "tomorrow".
    static func end(for preset: DowntimePreset, from start: String, candidates: [NagiosDateNotation]) -> String? {
        let ends = candidates.compactMap { notation in
            notation.parse(start).map { notation.format(preset.end(after: $0)) }
        }
        // Editing the start cannot rule out a notation inferred from the server's form.
        guard ends.count == candidates.count else { return nil }
        let results = Set(ends)
        return results.count == 1 ? results.first : nil
    }
}

extension DowntimePreset {
    /// Wall-clock arithmetic: on a day the server's clock changes for DST, the result can be an hour off.
    func end(after start: Date) -> Date {
        switch self {
        case .thirtyMinutes: return start.addingTimeInterval(30 * 60)
        case .oneHour: return start.addingTimeInterval(3600)
        case .twoHours: return start.addingTimeInterval(2 * 3600)
        case .untilTomorrowMorning:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            return calendar.date(byAdding: .hour, value: 9, to: tomorrow)!
        }
    }
}
