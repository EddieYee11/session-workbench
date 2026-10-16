import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: StatusWidgetSnapshot?
}
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) { completion(StatusEntry(date: .now, snapshot: StatusWidgetSnapshot.read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [StatusEntry(date: now, snapshot: StatusWidgetSnapshot.read())], policy: .after(now.addingTimeInterval(900))))
    }
}
struct ComStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StatusWidgetSnapshot.kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Com 今天与待确认")
        .description("显示最近一次同步的简报与待确认数量，点开继续处理。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .systemSmall])
    }
}
private struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family
    private var fresh: Bool { entry.snapshot.map { entry.date.timeIntervalSince($0.updatedAt) < 3600 } ?? false }
    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: "hand.raised")
                    Text(fresh ? "\(entry.snapshot!.reviewCount)" : "—").font(.headline)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Com · 今天", systemImage: "sparkles").font(.headline)
                    if fresh, let snapshot = entry.snapshot {
                        Text("\(snapshot.reviewCount) 项待确认 · \(snapshot.briefingCount) 条简报").font(.caption)
                        Text("更新于 \(snapshot.updatedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
                    } else { Text("打开 Com 更新进展").font(.caption) }
                }
            }
        }.widgetURL(URL(string: fresh && (entry.snapshot?.reviewCount ?? 0) > 0 ? "com-eddie://tasks" : "com-eddie://today"))
    }
}
