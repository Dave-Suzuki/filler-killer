// Port of the dashboard's daily() aggregation (src/fillerkiller/dashboard/
// app.py): one point per day, rate weighted by words spoken that day.
// Pure functions — unit-tested on Linux CI.

import Foundation

public struct RateRow: Sendable {
    public let day: String // "YYYY-MM-DD"
    public let fillers: Int
    public let words: Int

    public init(day: String, fillers: Int, words: Int) {
        self.day = day
        self.fillers = fillers
        self.words = words
    }
}

public struct DailyPoint: Equatable, Identifiable, Sendable {
    public let day: String
    public let rate: Double
    public let count: Int // items that day

    public var id: String { day }

    public init(day: String, rate: Double, count: Int) {
        self.day = day
        self.rate = rate
        self.count = count
    }
}

/// Matches Python round(x, 2): round-half-to-even.
public func weightedRate(fillers: Int, words: Int) -> Double {
    guard words > 0 else { return 0.0 }
    let raw = 100.0 * Double(fillers) / Double(words)
    return (raw * 100).rounded(.toNearestOrEven) / 100
}

public func dailyAverage(_ rows: [RateRow]) -> [DailyPoint] {
    var fillers: [String: Int] = [:]
    var words: [String: Int] = [:]
    var counts: [String: Int] = [:]
    for row in rows {
        fillers[row.day, default: 0] += row.fillers
        words[row.day, default: 0] += row.words
        counts[row.day, default: 0] += 1
    }
    return fillers.keys.sorted().compactMap { day in
        guard let w = words[day], w > 0 else { return nil }
        return DailyPoint(
            day: day,
            rate: weightedRate(fillers: fillers[day] ?? 0, words: w),
            count: counts[day] ?? 0
        )
    }
}

public enum RetroRange: String, CaseIterable, Sendable {
    case day = "Day"
    case threeDays = "3 Days"
    case week = "Week"
    case month = "Month"
    case threeMonths = "3 Months"
    case all = "All"

    public var days: Int? {
        switch self {
        case .day: return 1
        case .threeDays: return 3
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        case .all: return nil
        }
    }

    /// Bare "YYYY-MM-DDTHH:MM:SS" prefix — compares lexicographically against
    /// both Granola's "...Z" stamps and the recorder's fractional-second
    /// stamps (the prototype dashboard's proven trick).
    public func cutoff(now: Date = Date()) -> String? {
        guard let days else { return nil }
        return Self.stamp(now.addingTimeInterval(-Double(days) * 86400))
    }

    /// Start of the equal-length period before this one (for deltas).
    public func previousCutoff(now: Date = Date()) -> String? {
        guard let days else { return nil }
        return Self.stamp(now.addingTimeInterval(-Double(days) * 2 * 86400))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
