// Native retrospective: one Overview window (range picker, stat tiles, daily
// word-weighted trend + target line, top-8 fillers, unified list) with
// drill-down to category-highlighted transcripts — the simplification of the
// proven web dashboard, per the product spec.

import Charts
import DetectorKit
import SessionKit
import SessionStore
import SwiftUI

@MainActor
final class RetroModel: ObservableObject {
    @Published var range: RetroRange = .month {
        didSet { reload() }
    }

    @Published var items: [RetroItem] = []
    @Published var daily: [DailyPoint] = []
    @Published var topTerms: [TermCount] = []
    @Published var periodRate = 0.0
    @Published var delta: Double?
    @Published var totalFillers = 0
    @Published var loadError = ""

    private let store: SessionStore?

    init(store: SessionStore?) {
        self.store = store
        reload()
    }

    func reload() {
        guard let store else {
            loadError = "Storage unavailable."
            return
        }
        do {
            let cutoff = range.cutoff()
            let current = try store.retroItems(since: cutoff)
            items = current
            daily = dailyAverage(current.map {
                RateRow(day: $0.day, fillers: $0.fillers, words: $0.words)
            })
            topTerms = try store.topTerms(since: cutoff)
            let words = current.reduce(0) { $0 + $1.words }
            totalFillers = current.reduce(0) { $0 + $1.fillers }
            periodRate = weightedRate(fillers: totalFillers, words: words)
            if let previousCutoff = range.previousCutoff(), let cutoff {
                let previous = try store.retroItems(since: previousCutoff)
                    .filter { $0.startedAt < cutoff }
                let previousWords = previous.reduce(0) { $0 + $1.words }
                if previousWords > 0 {
                    let previousRate = weightedRate(
                        fillers: previous.reduce(0) { $0 + $1.fillers },
                        words: previousWords
                    )
                    delta = periodRate - previousRate
                } else {
                    delta = nil
                }
            } else {
                delta = nil
            }
            loadError = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    func transcript(for item: RetroItem) -> [TranscriptLine] {
        guard let store else { return [] }
        switch item.source {
        case .meeting:
            return (try? store.meetingTranscript(meetingId: item.sourceId)) ?? []
        case .live:
            return (try? store.liveTranscript(sessionId: Int64(item.sourceId) ?? -1)) ?? []
        }
    }
}

struct RetroView: View {
    @ObservedObject var model: RetroModel
    @AppStorage("targetRate") private var targetRate = 3.0

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty, model.range == .all {
                    wholeWindowEmpty
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            headerBlock
                            trendChart
                            topFillers
                            itemList
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Trends")
            .toolbar {
                Picker("Range", selection: $model.range) {
                    ForEach(RetroRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.reload()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var wholeWindowEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Nothing to see yet — literally.")
                .font(.system(size: 15, weight: .semibold))
            Text("Start a session from the menu bar, or connect Granola to "
                + "analyze past meetings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.2f", model.periodRate))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(judgment(rate: model.periodRate, target: targetRate))
                Text("fillers per 100 words")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                if let delta = model.delta {
                    HStack(spacing: 3) {
                        Image(systemName: delta <= 0 ? "arrow.down.right" : "arrow.up.right")
                        Text(String(format: "%.2f vs previous period", abs(delta)))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(delta <= 0 ? .green : .orange)
                }
            }
            Text("\(model.totalFillers) fillers caught · \(model.items.count) meetings & sessions")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var trendChart: some View {
        GroupBox("Daily rate") {
            if model.daily.isEmpty {
                Text("Quiet week. The chart fills in as you talk.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let maxRate = model.daily.map { $0.rate }.max() ?? targetRate
                Chart {
                    ForEach(model.daily) { point in
                        AreaMark(
                            x: .value("Day", point.day),
                            y: .value("Rate", point.rate)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Rate", point.rate)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)
                    }
                    if let last = model.daily.last {
                        PointMark(
                            x: .value("Day", last.day),
                            y: .value("Rate", last.rate)
                        )
                        .symbolSize(30)
                        .foregroundStyle(Color.accentColor)
                    }
                    RuleMark(y: .value("Target", targetRate))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(String(format: "goal %.1f", targetRate))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0 ... max(maxRate, targetRate) * 1.15)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisValueLabel()
                    }
                }
                .frame(minHeight: 180)
            }
        }
    }

    private var topFillers: some View {
        GroupBox("Your favorite words") {
            if model.topTerms.isEmpty {
                Text("No favorites yet — that's the goal, actually.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(model.topTerms) { term in
                    BarMark(
                        x: .value("Count", term.count),
                        y: .value("Term", term.term)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(term.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(minHeight: CGFloat(model.topTerms.count) * 26 + 30)
            }
        }
    }

    private var itemList: some View {
        GroupBox("Meetings & sessions") {
            if !model.loadError.isEmpty {
                Text(model.loadError).foregroundStyle(.red)
            }
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    NavigationLink(value: item.id) {
                        HStack(spacing: 10) {
                            Image(systemName: item.source == .live
                                ? "waveform.circle.fill" : "calendar.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(item.source == .live
                                    ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text(item.day).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(item.fillers) fillers")
                                    .font(.system(size: 13))
                                    .monospacedDigit()
                                Text(String(format: "%.1f / 100w", item.rate))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(judgment(rate: item.rate, target: targetRate))
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .navigationDestination(for: String.self) { itemId in
                if let item = model.items.first(where: { $0.id == itemId }) {
                    TranscriptView(item: item, lines: model.transcript(for: item))
                }
            }
        }
    }
}

struct TranscriptView: View {
    let item: RetroItem
    let lines: [TranscriptLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if item.source == .meeting, item.selfSpeaker != "Me" {
                    Text("Someone else captured this note, so “Me” is their mic — "
                        + "your counted words are the “\(item.selfSpeaker)” lines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                line.speaker == item.selfSpeaker
                                    ? Color.accentColor : .secondary
                            )
                        Text(highlighted(line.text, hits: line.hits))
                            .textSelection(.enabled)
                    }
                }
                if lines.isEmpty {
                    Text("No transcript was stored for this one.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.title)
    }
}

/// Builds an AttributedString with category-colored backgrounds from scalar-
/// offset hit spans (skipping overlaps, like the web dashboard's highlight()).
func highlighted(_ text: String, hits: [FillerHit]) -> AttributedString {
    let scalars = Array(text.unicodeScalars)

    func slice(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        for scalar in scalars[range] { view.append(scalar) }
        return String(view)
    }

    func color(_ category: String) -> Color {
        switch category {
        case "vocalized": return .yellow.opacity(0.4)
        case "phrase": return .orange.opacity(0.35)
        case "discourse": return .blue.opacity(0.3)
        case "repetition": return .purple.opacity(0.3)
        default: return .gray.opacity(0.3)
        }
    }

    var out = AttributedString()
    var pos = 0
    for hit in hits.sorted(by: { $0.start < $1.start }) {
        guard hit.start >= pos, hit.end <= scalars.count, hit.end > hit.start else { continue }
        out += AttributedString(slice(pos ..< hit.start))
        var mark = AttributedString(slice(hit.start ..< hit.end))
        mark.backgroundColor = color(hit.category)
        out += mark
        pos = hit.end
    }
    if pos < scalars.count {
        out += AttributedString(slice(pos ..< scalars.count))
    }
    return out
}
