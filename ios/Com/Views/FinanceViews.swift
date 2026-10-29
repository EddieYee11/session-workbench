import SwiftUI
import Charts
import ComCore

private func expenseColor(_ category: JSON) -> Color {
    let colors: [Color] = [Color(red: 0.51, green: 0.64, blue: 0.17), Color(red: 0.39, green: 0.58, blue: 0.85), Color(red: 0.86, green: 0.55, blue: 0.37), Color(red: 0.63, green: 0.47, blue: 0.76), Color(red: 0.31, green: 0.67, blue: 0.62), Color(red: 0.80, green: 0.64, blue: 0.29), Color(red: 0.76, green: 0.42, blue: 0.56)]
    let index = category["color_index"].int
    return index < colors.count ? colors[max(0, index)] : Color(hue: (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.48, brightness: 0.73)
}
private func expenseMoney(_ minor: JSON, _ currency: String) -> String {
    let amount = (minor.double / 100).formatted(.number.precision(.fractionLength(2)))
    return (currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency == "UNKNOWN" ? "" : currency + " ") + amount
}
private struct ExpenseRing: View {
    let categories: [JSON]
    var size: CGFloat = 148
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var revealed = false
    var body: some View {
        let positives = categories.filter { $0["amount_minor"].double > 0 }
        ZStack {
            if positives.isEmpty { Circle().stroke(Palette.fill, lineWidth: size * 0.18) .padding(size * 0.09) }
            else {
                Chart(positives.map(RemoteRow.init)) { row in
                    SectorMark(angle: .value("支出", row.value["amount_minor"].double), innerRadius: .ratio(0.65), angularInset: 2)
                        .cornerRadius(4).foregroundStyle(expenseColor(row.value))
                        .accessibilityLabel(row.value["name"].string).accessibilityValue(String(row.value["amount_minor"].double / 100))
                }.chartLegend(.hidden)
            }
            VStack(spacing: Space.xxs) {
                Text(positives.isEmpty ? "还未记账" : "花在哪里").font(TypeScale.footnote.weight(.medium))
                Text("\(categories.count) 个分类").font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
            }
        }.frame(width: size, height: size)
            .scaleEffect(reduce || revealed ? 1 : 0.96).opacity(revealed ? 1 : 0)
            .onAppear { withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { revealed = true } }
            .animation(ComMotion.reduced(reduce, ComMotion.settle), value: categories)
    }
}

private struct FinanceDestination: Identifiable { var period: String; var id: String { period } }

struct FinanceDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let initialPeriod: String
    let initialCurrency: String
    @State private var period = "本月"
    @State private var currency = ""
    @State private var monthOffset = 0
    @State private var data: JSON = .null
    @State private var selected: JSON?
    @State private var loading = false
    @State private var land = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private var month: String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.timeZone = cal.timeZone
        return f.string(from: cal.date(byAdding: .month, value: monthOffset, to: Date())!)
    }
    private var financePath: String { monthOffset == 0 ? "/personal/finance" : "/personal/finance?month=" + month }
    private var currencyData: JSON { data["currencies"].array.first { $0.id == currency } ?? data["currencies"].array.first ?? .null }
    private var rows: [JSON] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return data["items"].array.filter { $0["currency"].string == currencyData.id && (period != "今天" || $0["date"].string == f.string(from: Date())) }
    }
    private var categories: [JSON] {
        currencyData["categories"].array.compactMap { category in
            let items = rows.filter { $0["category_id"].string == category.id }
            guard !items.isEmpty else { return nil }
            var value = category; value["amount_minor"] = .number(items.reduce(0) { $0 + $1["amount_minor"].double }); value["count"] = .number(Double(items.count)); return value
        }.sorted { $0["amount_minor"].double > $1["amount_minor"].double }
    }
    private func reload(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        let path = financePath
        // 与 openFinance 同路：入口已在拉则等它结束，避免叠刷清空当前月。
        if monthOffset == 0, model.financeOpening, !force {
            while model.financeOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if let snap = model.datasets["/personal/finance"] {
                data = snap
                failNote = ""
                if currency.isEmpty || !snap["currencies"].array.contains(where: { $0.id == currency }) {
                    currency = snap["currencies"].array.first?.id ?? currency
                }
                if model.errors["/personal/finance"] == nil { return }
            }
            let err = model.errors["/personal/finance"] ?? ""
            failNote = err.isEmpty
                ? (data.isNull ? "账本没拉齐——检查配对或网络后再试" : "账本没刷新上——下面仍是上一版，可再试")
                : (data.isNull ? "账本没拉齐：" + err + "——可再试" : "账本没刷新上：" + err + "——下面仍是上一版")
            return
        }
        if let fresh = await model.load(path) {
            data = fresh
            failNote = ""
            if monthOffset == 0 { model.financeOpenNote = "" }
            if currency.isEmpty || !fresh["currencies"].array.contains(where: { $0.id == currency }) {
                currency = fresh["currencies"].array.first?.id ?? currency
            }
            return
        }
        let err = model.errors[path] ?? model.errors["/personal/finance"] ?? ""
        failNote = err.isEmpty
            ? (data.isNull ? "账本没拉齐——检查配对或网络后再试" : "账本没刷新上——下面仍是上一版，可再试")
            : (data.isNull ? "账本没拉齐：" + err + "——可再试" : "账本没刷新上：" + err + "——下面仍是上一版")
    }
    var body: some View {
        DetailPage(title: "支出明细") {
            HStack {
                Button { period = "本月"; monthOffset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .buttonStyle(SoftPressStyle(scale: 0.92)).accessibilityLabel("上个月")
                Spacer(); Text(month).font(TypeScale.headline).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: month)
                Spacer()
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .buttonStyle(SoftPressStyle(scale: 0.92)).disabled(monthOffset >= 0).accessibilityLabel("下个月")
            }
            if monthOffset == 0 { Picker("时间范围", selection: $period) { Text("今天").tag("今天"); Text("本月").tag("本月") }.pickerStyle(.segmented) }
            if data["currencies"].array.count > 1 { Picker("币种", selection: $currency) { ForEach(data["currencies"].array.map(RemoteRow.init)) { Text($0.id).tag($0.id) } }.pickerStyle(.segmented) }
            // 菜单/账本卡 openFinance 的拉齐 + 页内 reload：有缓存仍可看，顶上标 busy。
            let pulling = loading || (monthOffset == 0 && model.financeOpening) || !loadedOnce
            if pulling {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(model.financeOpening ? "正在拉齐账本…" : "读取真实账目…")
                        .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("正在拉齐账本")
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading || model.financeOpening ? "重试中…" : "再试一次") {
                    guard !loading, !(monthOffset == 0 && model.financeOpening) else { return }
                    Task { await reload(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading || (monthOffset == 0 && model.financeOpening))
                .accessibilityIdentifier("finance-retry")
            }
            if !pulling && !failNote.isEmpty && (data.isNull || !data["available"].bool) {
                EmptyState(title: "暂时读不到账本",
                           description: data["note"].string.isEmpty ? "先重试拉齐；通了再看花销。我这边不会凭空编账。" : data["note"].string,
                           symbol: "wifi.exclamationmark")
            }
            else if !pulling && failNote.isEmpty && !data["available"].bool && !data.isNull {
                EmptyState(title: "暂时读不到账本",
                           description: data["note"].string.isEmpty ? "连上 mini 后再打开这里；我这边不会凭空编花销。" : data["note"].string,
                           symbol: "wifi.exclamationmark")
            }
            else if pulling && data.isNull {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, Space.xl)
            }
            else if data["available"].bool {
                Card {
                    HStack(spacing: Space.lg) {
                        ExpenseRing(categories: categories, size: 132)
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(period == "今天" ? "今日花销" : "本月花销").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            Text(expenseMoney(.number(rows.reduce(0) { $0 + $1["amount_minor"].double }), currencyData.id)).font(TypeScale.title).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                                .contentTransition(.numericText())
                            Text("\(rows.count) 笔支出").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
                .modifier(EnterRise(on: land, delay: 0.02, y: 12, blur: 5, animation: ComMotion.lift))
                GroupSection("分类排行") {
                    if categories.isEmpty {
                        EmptyState(title: "这段还没花销",
                                   description: "跟我说「记一下咖啡18」或「午饭花了 28」，账本会自动更新到这里。",
                                   symbol: "tray")
                    }
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        Button { selected = category } label: {
                            Card {
                                VStack(alignment: .leading, spacing: Space.md) {
                                    HStack {
                                        Text(String(format: "%02d", index + 1)).font(TypeScale.footnote).monospacedDigit().foregroundStyle(Palette.textTertiary)
                                        Circle().fill(expenseColor(category)).frame(width: 9, height: 9)
                                        Text(category["name"].string).font(TypeScale.headline); Spacer()
                                        Text(expenseMoney(category["amount_minor"], currencyData.id)).font(TypeScale.callout.weight(.semibold)).monospacedDigit(); Chevron()
                                    }
                                    GeometryReader { geometry in
                                        Capsule().fill(Palette.fill)
                                        Capsule().fill(expenseColor(category)).frame(width: geometry.size.width * max(0, category["amount_minor"].double) / max(1, categories.first?["amount_minor"].double ?? 1))
                                            .animation(ComMotion.reduced(reduce, ComMotion.settle), value: category["amount_minor"].double)
                                    }.frame(height: 7)
                                    Text("\(category["count"].int) 笔 · " + category["group"].string).font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(SoftPressStyle(scale: 0.985))
                        .modifier(EnterRise(on: land, delay: 0.06 + Double(min(index, 8)) * ComMotion.stagger, y: 10, blur: 4, animation: ComMotion.pop))
                        .accessibilityIdentifier("expense-category-" + category.id)
                    }
                }
                Text(data["stale"].bool ? "当前是上次读取的账本，暂未更新。" : data["coverage"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: period)
        .task(id: month) {
            // 换月别沿用上月画面；本月可保留 openFinance / 已记缓存。
            if monthOffset != 0 {
                data = .null
                currency = ""
                failNote = ""
                loadedOnce = false
            }
            await reload(force: false)
        }
        // 主聊「已记」会立刻刷 /personal/finance；账本 sheet 已开时直接吃进缓存，不卡旧快照、也不重复请求。
        .onChange(of: model.fetchedAt["/personal/finance"] ?? .distantPast) { _, _ in
            guard monthOffset == 0, let snap = model.datasets["/personal/finance"] else { return }
            data = snap
            failNote = ""
            if currency.isEmpty || !snap["currencies"].array.contains(where: { $0.id == currency }) {
                currency = snap["currencies"].array.first?.id ?? currency
            }
        }
        .onAppear {
            period = initialPeriod; currency = initialCurrency
            if monthOffset == 0, let snap = model.datasets["/personal/finance"] {
                data = snap
                if currency.isEmpty { currency = snap["currencies"].array.first?.id ?? "" }
            }
            if reduce { land = true }
            else { withAnimation(ComMotion.lift) { land = true } }
        }
        .sheet(item: Binding(get: { selected.map(RemoteRow.init) }, set: { selected = $0?.value })) { selection in
            ExpenseTransactions(category: selection.value, currency: currencyData.id, items: rows.filter { $0["category_id"].string == selection.id })
        }
    }
}

private struct ExpenseTransactions: View {
    let category: JSON
    let currency: String
    let items: [JSON]
    var body: some View {
        DetailPage(title: category["name"].string) {
            HStack { Circle().fill(expenseColor(category)).frame(width: 10, height: 10); Text("\(items.count) 笔支出").font(TypeScale.callout); Spacer(); Text(expenseMoney(category["amount_minor"], currency)).font(TypeScale.title).monospacedDigit() }
            let groups = Dictionary(grouping: items) { $0["date"].string }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                GroupSection(day) {
                    GroupedCard {
                        ForEach((groups[day] ?? []).map(RemoteRow.init)) { row in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.value["comment"].string.isEmpty ? row.value["category"].string : row.value["comment"].string).font(TypeScale.rowTitle).fixedSize(horizontal: false, vertical: true)
                                    Spacer(); Text(expenseMoney(row.value["amount_minor"], currency)).font(TypeScale.headline).monospacedDigit()
                                }
                                Text(String(row.value["time"].string.dropFirst(11).prefix(5)) + " · " + row.value["account"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            }.rowPadding()
                        }
                    }
                }
            }
        }
    }
}
