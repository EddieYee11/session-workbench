import SwiftUI
import Charts
import ComCore

// 聊天回复互动组件：后端回复 JSON 的 `widgets` 数组原生渲染。
// 列表内不用任何 Material / 玻璃；卡片自身无定时器、无常驻动画。

struct ReplyWidgetStack: View {
    let messageID: String
    let widgets: [JSON]
    var send: (String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(Array(widgets.enumerated()), id: \.offset) { index, widget in
                let key = "widget:\(messageID):\(index)"
                let widgetKind = (widget["kind"].string.isEmpty ? widget["type"].string : widget["kind"].string).lowercased()
                switch widgetKind {
                case "confirm", "picker", "staging_review":
                    WidgetBubbleView(messageID: messageID, spec: widget, stateKey: key)
                case "checklist":
                    ChecklistWidget(spec: widget, stateKey: key, send: send)
                case "choices":
                    ChoicesWidget(spec: widget, stateKey: key, send: send)
                case "table":
                    TableWidget(spec: widget)
                case "chart":
                    ChartWidget(spec: widget)
                case "steps":
                    StepsWidget(spec: widget)
                case "form":
                    FormWidget(spec: widget, stateKey: key, send: send)
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 共用

private struct WidgetCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !title.isEmpty { Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary) }
            content
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
    }
}

private struct WidgetPrimaryButton: View {
    let title: String
    var enabled = true
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if busy { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                Text(title).font(TypeScale.link)
            }
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Palette.accent.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .disabled(!enabled || busy)
    }
}

/// 状态读写：key 对应 /personal/artifact-state/<key>。格子被复用重建后靠它还原。
@MainActor
private struct WidgetPersist {
    let model: AppModel
    let key: String
    private var path: String { "/personal/artifact-state/" + key.pathEncoded }
    func load() async -> JSON {
        let result = await model.load(path)
        return result?["state"] ?? .null
    }
    /// 返回 nil 表示写成功，否则是给用户看的提示。
    func save(_ state: JSON) async -> String? {
        do { _ = try await model.mutate(path, fields: ["state": state]); return nil }
        catch { return "这一步没存上：" + error.localizedDescription + "——重开后可能还原。" }
    }
}

private func motion(_ reduce: Bool) -> Animation { ComMotion.reduced(reduce, ComMotion.settle) }

// MARK: - checklist

private struct ChecklistWidget: View {
    let spec: JSON
    let stateKey: String
    var send: (String) async -> Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var checked: [String: Bool] = [:]
    @State private var sent = false
    @State private var sending = false
    @State private var loaded = false
    @State private var notice = ""

    private var items: [JSON] { spec["items"].array }
    private func isOn(_ item: JSON) -> Bool { checked[item.id] ?? item["checked"].bool }
    private var submit: String { spec["submit"].string }

    private func itemText(_ item: JSON) -> String {
        let t = item["text"].string
        return t.isEmpty ? item["label"].string : t
    }

    var body: some View {
        WidgetCard(title: spec["title"].string) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let on = isOn(item)
                    Button {
                        guard !sent else { return }
                        Haptics.selection()
                        withAnimation(motion(reduce)) { checked[item.id] = !on }
                        persist()
                    } label: {
                        HStack(spacing: Space.md) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(on ? Palette.accentText : Palette.textTertiary)
                            Text(itemText(item)).font(TypeScale.body)
                                .foregroundStyle(on ? Palette.textTertiary : Palette.textPrimary)
                                .strikethrough(on, color: Palette.textTertiary.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle(scale: 0.99))
                    .accessibilityIdentifier("widget-checklist-item-" + item.id)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if !submit.isEmpty {
                if sent {
                    Label("已发给 Com", systemImage: "checkmark").font(TypeScale.footnote).foregroundStyle(Palette.success)
                } else {
                    WidgetPrimaryButton(title: submit, busy: sending) { Task { await submitTapped() } }
                }
            }
            if !notice.isEmpty { InlineNotice(text: notice) }
        }
        .task { await restore() }
    }

    private func restore() async {
        guard !loaded else { return }
        let state = await WidgetPersist(model: model, key: stateKey).load()
        loaded = true
        if case .object(let o) = state["checked"] { checked = o.mapValues { $0.bool } }
        sent = state["sent"].bool
    }
    private func snapshot() -> JSON {
        var all: [String: JSON] = [:]
        for item in items { all[item.id] = .bool(isOn(item)) }
        return .object(["checked": .object(all), "sent": .bool(sent)])
    }
    private func persist() {
        let state = snapshot()
        Task { if let n = await WidgetPersist(model: model, key: stateKey).save(state) { notice = n } else { notice = "" } }
    }
    private func submitTapped() async {
        let lines = items.filter(isOn).map { "✓ " + $0["text"].string }
        let text = ([submit] + lines).joined(separator: "\n")
        sending = true; notice = ""
        let ok = await send(text)
        sending = false
        if ok { withAnimation(motion(reduce)) { sent = true }; Haptics.success(); persist() }
        else { notice = "没发出去，再点一次试试。" }
    }
}

// MARK: - choices

private struct ChoicesWidget: View {
    let spec: JSON
    let stateKey: String
    var send: (String) async -> Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var selected: [String] = []
    @State private var locked = false
    @State private var sending = false
    @State private var loaded = false
    @State private var notice = ""

    private var options: [String] { spec["options"].array.map(\.string) }
    private var multi: Bool { spec["multi"].bool }

    var body: some View {
        WidgetCard(title: spec["title"].string) {
            VStack(spacing: Space.sm) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    let on = selected.contains(option)
                    Button { tap(option) } label: {
                        HStack(spacing: Space.md) {
                            if multi || on {
                                Image(systemName: on ? (multi ? "checkmark.square.fill" : "checkmark.circle.fill") : "square")
                                    .foregroundStyle(on ? Palette.accentText : Palette.textTertiary)
                            }
                            Text(option).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: 44)
                        .background(on ? Palette.accent.opacity(0.35) : Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .opacity(locked && !on ? 0.5 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                    .disabled(locked || sending)
                    .accessibilityIdentifier("widget-choice-\(i)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if multi && !locked {
                WidgetPrimaryButton(title: "确定", enabled: !selected.isEmpty, busy: sending) { Task { await commit(selected) } }
                    .accessibilityIdentifier("widget-choices-confirm")
            }
            if locked { Label("已选，发给 Com 了", systemImage: "checkmark").font(TypeScale.footnote).foregroundStyle(Palette.success) }
            if !notice.isEmpty { InlineNotice(text: notice) }
        }
        .task { await restore() }
    }

    private func tap(_ option: String) {
        Haptics.selection()
        if multi {
            withAnimation(motion(reduce)) {
                if let i = selected.firstIndex(of: option) { selected.remove(at: i) } else { selected.append(option) }
            }
        } else {
            Task { await commit([option]) }
        }
    }
    private func commit(_ values: [String]) async {
        let previous = selected
        withAnimation(motion(reduce)) { selected = values }
        sending = true; notice = ""
        let ok = await send(values.joined(separator: "、"))
        sending = false
        if ok {
            withAnimation(motion(reduce)) { locked = true }
            Haptics.success()
            let state = JSON.object(["selected": .array(values.map { .string($0) }), "locked": .bool(true)])
            if let n = await WidgetPersist(model: model, key: stateKey).save(state) { notice = n }
        } else {
            withAnimation(motion(reduce)) { selected = multi ? values : previous }
            notice = "没发出去，再点一次试试。"
        }
    }
    private func restore() async {
        guard !loaded else { return }
        let state = await WidgetPersist(model: model, key: stateKey).load()
        loaded = true
        if state["locked"].bool { selected = state["selected"].array.map(\.string); locked = true }
    }
}

// MARK: - table

private struct TableWidget: View {
    let spec: JSON
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var sortColumn: Int?
    @State private var ascending = true
    @State private var expanded = false

    private var columns: [String] { spec["columns"].array.map(\.string) }
    private var rows: [[String]] { spec["rows"].array.map { $0.array.map(\.string) } }
    private let foldAt = 6

    private static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(t)
    }
    private func cell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }
    private var sortedRows: [[String]] {
        guard let c = sortColumn else { return rows }
        let numeric = !rows.isEmpty && rows.allSatisfy { Self.number(cell($0, c)) != nil }
        let sorted = rows.sorted { a, b in
            if numeric { return (Self.number(cell(a, c)) ?? 0) < (Self.number(cell(b, c)) ?? 0) }
            return cell(a, c).localizedStandardCompare(cell(b, c)) == .orderedAscending
        }
        return ascending ? sorted : sorted.reversed()
    }

    var body: some View {
        let all = sortedRows
        let shown = expanded || all.count <= foldAt ? all : Array(all.prefix(foldAt))
        WidgetCard(title: spec["title"].string) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { i, name in
                            Button {
                                Haptics.selection()
                                withAnimation(motion(reduce)) {
                                    if sortColumn == i { ascending.toggle() } else { sortColumn = i; ascending = true }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(name).font(TypeScale.stamp)
                                    if sortColumn == i { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)) }
                                }
                                .foregroundStyle(sortColumn == i ? Palette.accentText : Palette.textSecondary)
                                .frame(width: 104, height: 36, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("widget-table-header-\(i)")
                        }
                    }
                    Divider().overlay(Palette.separator)
                    ForEach(Array(shown.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: 0) {
                            ForEach(0..<columns.count, id: \.self) { i in
                                Text(cell(row, i)).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                                    .lineLimit(2).frame(width: 104, alignment: .leading)
                            }
                        }
                        .frame(minHeight: 36)
                        if r < shown.count - 1 { Divider().overlay(Palette.separator) }
                    }
                }
            }
            if all.count > foldAt {
                Button {
                    withAnimation(motion(reduce)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "展开全部 \(all.count) 行").font(TypeScale.link).foregroundStyle(Palette.accentText)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityIdentifier("widget-table-expand")
            }
        }
    }
}

// MARK: - chart

private struct ChartWidget: View {
    let spec: JSON
    @State private var selectedLabel: String?
    @State private var selectedAngle: Double?

    private struct Point: Identifiable { let id: Int; let series: String; let label: String; let value: Double }

    private var labels: [String] { spec["labels"].array.map(\.string) }
    private var unit: String { spec["unit"].string }
    private var kind: String { spec["kind"].string }
    private var points: [Point] {
        var out: [Point] = []
        for (si, s) in spec["series"].array.enumerated() {
            let name = s["name"].string.isEmpty ? "系列\(si + 1)" : s["name"].string
            for (i, v) in s["values"].array.enumerated() where i < labels.count {
                out.append(Point(id: out.count, series: name, label: labels[i], value: v.double))
            }
        }
        return out
    }
    private func fmt(_ v: Double) -> String {
        (v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.2f", v)) + unit
    }
    private var pieLabel: String? {
        guard let angle = selectedAngle else { return nil }
        var acc = 0.0
        for p in points where p.series == points.first?.series {
            acc += max(p.value, 0)
            if angle <= acc { return p.label }
        }
        return nil
    }
    private var activeLabel: String? { kind == "pie" ? pieLabel : selectedLabel }

    var body: some View {
        let pts = points
        WidgetCard(title: spec["title"].string) {
            if pts.isEmpty || labels.isEmpty {
                Text("暂无数据").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            } else {
                Text(readout(pts)).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                    .frame(minHeight: 18, alignment: .leading)
                chart(pts)
                    .frame(height: 200)
                    .accessibilityIdentifier("widget-chart")
            }
        }
    }

    private func readout(_ pts: [Point]) -> String {
        guard let l = activeLabel else { return "点一下看具体数值" }
        let hit = pts.filter { $0.label == l }
        return l + "　" + hit.map { (spec["series"].array.count > 1 ? $0.series + " " : "") + fmt($0.value) }.joined(separator: "　")
    }

    @ViewBuilder private func chart(_ pts: [Point]) -> some View {
        let multi = spec["series"].array.count > 1
        switch kind {
        case "line":
            Chart {
                ForEach(pts) { p in
                    LineMark(x: .value("类目", p.label), y: .value("数值", p.value), series: .value("系列", p.series))
                        .foregroundStyle(by: .value("系列", p.series)).interpolationMethod(.monotone)
                    PointMark(x: .value("类目", p.label), y: .value("数值", p.value))
                        .foregroundStyle(by: .value("系列", p.series)).symbolSize(p.label == selectedLabel ? 90 : 30)
                }
                if let l = selectedLabel { RuleMark(x: .value("类目", l)).foregroundStyle(Palette.separator) }
            }
            .chartXScale(domain: labels)
            .chartXSelection(value: $selectedLabel)
            .chartLegend(multi ? .visible : .hidden)
        case "pie":
            let first = pts.first?.series
            Chart(pts.filter { $0.series == first }) { p in
                SectorMark(angle: .value("数值", max(p.value, 0)), innerRadius: .ratio(0.5), angularInset: 1)
                    .foregroundStyle(by: .value("类目", p.label))
                    .opacity(selectedLabel == nil || p.label == pieLabel ? 1 : 0.5)
            }
            .chartAngleSelection(value: $selectedAngle)
        default:
            Chart(pts) { p in
                BarMark(x: .value("类目", p.label), y: .value("数值", p.value))
                    .foregroundStyle(by: .value("系列", p.series))
                    .position(by: .value("系列", p.series))
                    .opacity(selectedLabel == nil || p.label == selectedLabel ? 1 : 0.5)
            }
            .chartXScale(domain: labels)
            .chartXSelection(value: $selectedLabel)
            .chartLegend(multi ? .visible : .hidden)
        }
    }
}

// MARK: - steps

private struct StepsWidget: View {
    let spec: JSON
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var open: Set<Int> = []

    private func state(_ s: String) -> StepState {
        switch s { case "done": .done; case "current": .current; default: .pending }
    }
    var body: some View {
        let items = spec["items"].array
        WidgetCard(title: spec["title"].string) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let detail = item["detail"].string
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Button {
                            guard !detail.isEmpty else { return }
                            Haptics.selection()
                            withAnimation(motion(reduce)) { if open.contains(i) { open.remove(i) } else { open.insert(i) } }
                        } label: {
                            HStack {
                                StepRow(text: item["title"].string, state: state(item["state"].string))
                                if !detail.isEmpty {
                                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.textTertiary).rotationEffect(.degrees(open.contains(i) ? 180 : 0))
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("widget-step-\(i)")
                        if open.contains(i), !detail.isEmpty {
                            Text(detail).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                .padding(.leading, 28).padding(.bottom, Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - form

private struct FormWidget: View {
    let spec: JSON
    let stateKey: String
    var send: (String) async -> Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var values: [String: String] = [:]
    @State private var sent = false
    @State private var sending = false
    @State private var loaded = false
    @State private var notice = ""

    private var fields: [JSON] { spec["fields"].array }
    private func initial(_ f: JSON) -> String {
        if !f["value"].isNull { return f["value"].string }
        switch f["kind"].string {
        case "slider": return f["min"].isNull ? "0" : f["min"].string
        case "select": return f["options"].array.first?.string ?? ""
        default: return ""
        }
    }
    private func value(_ f: JSON) -> String { values[f.id] ?? initial(f) }
    private func binding(_ f: JSON) -> Binding<String> {
        Binding(get: { value(f) }, set: { values[f.id] = $0 })
    }

    var body: some View {
        WidgetCard(title: spec["title"].string) {
            ForEach(Array(fields.enumerated()), id: \.offset) { i, f in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text(f["label"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        if f["kind"].string == "slider" { Spacer(); Text(value(f)).font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Palette.textPrimary) }
                    }
                    field(f, index: i)
                }
                .disabled(sent)
                .opacity(sent ? 0.6 : 1)
            }
            if sent {
                Label("已提交", systemImage: "checkmark").font(TypeScale.footnote).foregroundStyle(Palette.success)
            } else {
                WidgetPrimaryButton(title: spec["submit"].string.isEmpty ? "提交" : spec["submit"].string, busy: sending) { Task { await submit() } }
                    .accessibilityIdentifier("widget-form-submit")
            }
            if !notice.isEmpty { InlineNotice(text: notice) }
        }
        .task { await restore() }
    }

    @ViewBuilder private func field(_ f: JSON, index: Int) -> some View {
        switch f["kind"].string {
        case "slider":
            let lo = f["min"].isNull ? 0 : f["min"].double
            let hi = f["max"].isNull ? 100 : max(f["max"].double, lo + 1)
            Slider(value: Binding(get: { Double(value(f)) ?? lo }, set: { values[f.id] = JSON.number($0.rounded()).string }), in: lo...hi, step: 1)
                .tint(Palette.accent)
                .accessibilityIdentifier("widget-form-field-\(index)")
        case "select":
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(Array(f["options"].array.map(\.string).enumerated()), id: \.offset) { _, option in
                        let on = value(f) == option
                        Button { Haptics.selection(); values[f.id] = option } label: {
                            Text(option).font(TypeScale.subheadline).foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, Space.md).frame(minHeight: 36)
                                .background(on ? Palette.accent.opacity(0.5) : Palette.fill, in: Capsule())
                        }.buttonStyle(SoftPressStyle())
                    }
                }
            }
        case "number":
            TextField(f["label"].string, text: binding(f)).keyboardType(.decimalPad).textFieldStyle(.plain)
                .padding(.horizontal, Space.md).frame(minHeight: 44)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .accessibilityIdentifier("widget-form-field-\(index)")
        default:
            TextField(f["label"].string, text: binding(f)).textFieldStyle(.plain)
                .padding(.horizontal, Space.md).frame(minHeight: 44)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .accessibilityIdentifier("widget-form-field-\(index)")
        }
    }

    private func submit() async {
        let lines = fields.map { $0["label"].string + ": " + value($0) }
        let text = ([spec["submit"].string.isEmpty ? "提交" : spec["submit"].string] + lines).joined(separator: "\n")
        sending = true; notice = ""
        let ok = await send(text)
        sending = false
        if ok {
            withAnimation(motion(reduce)) { sent = true }
            Haptics.success()
            let state = JSON.object(["values": .object(values.mapValues { .string($0) }), "sent": .bool(true)])
            if let n = await WidgetPersist(model: model, key: stateKey).save(state) { notice = n }
        } else { notice = "没发出去，再点一次试试。" }
    }
    private func restore() async {
        guard !loaded else { return }
        let state = await WidgetPersist(model: model, key: stateKey).load()
        loaded = true
        if state["sent"].bool {
            if case .object(let o) = state["values"] { values = o.mapValues(\.string) }
            sent = true
        }
    }
}

#if DEBUG
enum ReplyWidgetFixture {
    static let widgets: [JSON] = [
        .object(["type": .string("checklist"), "title": .string("出门前确认"), "submit": .string("这些都带了"),
                 "items": .array([
                    .object(["id": .string("a"), "text": .string("充电宝"), "checked": .bool(true)]),
                    .object(["id": .string("b"), "text": .string("身份证"), "checked": .bool(false)]),
                    .object(["id": .string("c"), "text": .string("雨伞"), "checked": .bool(false)])])]),
        .object(["type": .string("choices"), "title": .string("晚饭吃什么"), "options": .array([.string("火锅"), .string("面条"), .string("沙拉")])]),
        .object(["type": .string("choices"), "title": .string("想看哪些"), "multi": .bool(true), "options": .array([.string("科幻"), .string("悬疑"), .string("喜剧")])]),
        .object(["type": .string("table"), "title": .string("本月支出"), "columns": .array([.string("项目"), .string("金额"), .string("占比")]),
                 "rows": .array((1...8).map { i in .array([.string("项目\(i)"), .string("¥\(i * 120 % 700),00"), .string("\(i * 3)%")]) })]),
        .object(["type": .string("chart"), "title": .string("每周步数"), "kind": .string("bar"), "unit": .string("步"),
                 "labels": .array([.string("周一"), .string("周二"), .string("周三"), .string("周四")]),
                 "series": .array([.object(["name": .string("步数"), "values": .array([.number(5200), .number(8100), .number(6400), .number(9300)])])])]),
        .object(["type": .string("steps"), "title": .string("发布流程"), "items": .array([
            .object(["title": .string("写脚本"), "detail": .string("口播稿已定稿"), "state": .string("done")]),
            .object(["title": .string("剪辑"), "detail": .string("正在做字幕"), "state": .string("current")]),
            .object(["title": .string("发布"), "state": .string("pending")])])]),
        .object(["type": .string("form"), "title": .string("预约"), "submit": .string("提交预约"), "fields": .array([
            .object(["id": .string("name"), "label": .string("称呼"), "kind": .string("text")]),
            .object(["id": .string("n"), "label": .string("人数"), "kind": .string("slider"), "min": .number(1), "max": .number(10), "value": .number(2)]),
            .object(["id": .string("t"), "label": .string("时段"), "kind": .string("select"), "options": .array([.string("上午"), .string("下午")])])])])
    ]
}

#Preview("ReplyWidgets") {
    ScrollView { ReplyWidgetStack(messageID: "preview", widgets: ReplyWidgetFixture.widgets, send: { _ in true }).padding() }
        .background(Palette.background)
        .environment(AppModel())
}
#endif
