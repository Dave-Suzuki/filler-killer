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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tiles
                    trendChart
                    topFillers
                    itemList
                }
                .padding(20)
            }
            .navigationTitle("Filler Killer — Trends")
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

    private var tiles: some View {
        HStack(spacing: 12) {
            tile(String(format: "%.2f", model.periodRate), "fillers / 100 words")
            tile(
                model.delta.map { String(format: "%+.2f", $0) } ?? "—",
                "vs previous period",
                color: (model.delta ?? 0) <= 0 ? .green : .orange
            )
            tile("\(model.totalFillers)", "fillers caught")
            tile("\(model.items.count)", "meetings & sessions")
        }
    }

    private func tile(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var trendChart: some View {
        GroupBox("Filler rate over time (daily average)") {
            if model.daily.isEmpty {
                Text("No data in this range yet — start a session or sync Granola.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(model.daily) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Rate", point.rate)
                        )
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Day", point.day),
                            y: .value("Rate", point.rate)
                        )
                        .symbolSize(20)
                    }
                    RuleMark(y: .value("Target", targetRate))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6))
                }
                .frame(minHeight: 180)
            }
        }
    }

    private var topFillers: some View {
        GroupBox("Top fillers") {
            if model.topTerms.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                Chart(model.topTerms) { term in
                    BarMark(
                        x: .value("Count", term.count),
                        y: .value("Term", term.term)
                    )
                }
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
                        HStack {
                            Text(item.source == .live ? "🎙" : "G")
                                .frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                Text(item.day).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.fillers) · " + String(format: "%.2f", item.rate) + "/100w")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(item.rate <= targetRate ? .green : .secondary)
                        }
                        .padding(.vertical, 6)
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
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(line.speaker == "Me" ? Color.accentColor : .secondary)
                        Text(highlighted(line.text, hits: line.hits))
                            .textSelection(.enabled)
                    }
                }
                if lines.isEmpty {
                    Text("No transcript stored for this item.")
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
