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
            .onAppear { withAnimation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88)) { revealed = true } }
            .animation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88), value: categories)
    }
}

struct FinanceHome: View {
    @Environment(AppModel.self) private var model
    @State private var currency = ""
    @State private var detail: String?
    private var data: JSON { model.datasets["/personal/finance"] ?? .null }
    private var money: JSON { data["currencies"].array.first { $0.id == currency } ?? data["currencies"].array.first ?? .null }
    var body: some View {
        GroupSection("记账") {
            Card {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if data["available"].bool {
                        if data["currencies"].array.count > 1 {
                            Picker("币种", selection: $currency) { ForEach(data["currencies"].array.map(RemoteRow.init)) { Text($0.id).tag($0.id) } }.pickerStyle(.segmented)
                        }
                        HStack(spacing: Space.lg) {
                            Button { detail = "本月" } label: { ExpenseRing(categories: money["categories"].array) }.buttonStyle(.plain).accessibilityLabel("查看支出分类")
                            VStack(alignment: .leading, spacing: Space.lg) {
                                total("今日花销", amount: money["today_minor"], period: "今天")
                                total("本月花销", amount: money["month_minor"], period: "本月")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let top = money["categories"].array.prefix(3)
                        if !top.isEmpty {
                            HStack(spacing: Space.md) { ForEach(top.map(RemoteRow.init)) { row in
                                HStack(spacing: 5) { Circle().fill(expenseColor(row.value)).frame(width: 7, height: 7); Text(row.value["name"].string).lineLimit(1) }.font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                            } }
                        }
                        if data["stale"].bool { Text("暂未更新 · 上次账本快照").font(TypeScale.caption).foregroundStyle(Palette.textSecondary) }
                    } else {
                        HStack { IconBadge(symbol: "chart.pie", tone: .accent); Text(data.isNull ? "正在读取账本…" : data["note"].string).font(TypeScale.callout) }
                        Button("重试读取") { Task { _ = await model.load("/personal/finance") } }.buttonStyle(.quiet)
                    }
                }
            }
        } trailing: { Button("明细", systemImage: "arrow.up.right") { detail = "本月" }.buttonStyle(.quiet) }
        .sheet(item: Binding(get: { detail.map { FinanceDestination(period: $0) } }, set: { detail = $0?.period })) { FinanceDetail(initialPeriod: $0.period, initialCurrency: money.id) }
    }
    private func total(_ title: String, amount: JSON, period: String) -> some View {
        Button { detail = period } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack { Text(title).font(TypeScale.footnote); Image(systemName: "chevron.right").font(.system(size: 10)) }.foregroundStyle(Palette.textSecondary)
                Text(expenseMoney(amount.isNull ? .number(0) : amount, money.id)).font(TypeScale.title).monospacedDigit().contentTransition(.numericText()).minimumScaleFactor(0.65).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel(title)
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
    private var month: String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.timeZone = cal.timeZone
        return f.string(from: cal.date(byAdding: .month, value: monthOffset, to: Date())!)
    }
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
    var body: some View {
        DetailPage(title: "支出明细") {
            HStack {
                Button { period = "本月"; monthOffset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                Spacer(); Text(month).font(TypeScale.headline).monospacedDigit(); Spacer()
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(monthOffset >= 0).accessibilityLabel("下个月")
            }
            if monthOffset == 0 { Picker("时间范围", selection: $period) { Text("今天").tag("今天"); Text("本月").tag("本月") }.pickerStyle(.segmented) }
            if data["currencies"].array.count > 1 { Picker("币种", selection: $currency) { ForEach(data["currencies"].array.map(RemoteRow.init)) { Text($0.id).tag($0.id) } }.pickerStyle(.segmented) }
            if loading { ProgressView("读取真实账目…").frame(maxWidth: .infinity) }
            else if !data["available"].bool { EmptyState(title: "暂时未读到账本", description: data["note"].string, symbol: "wifi.exclamationmark") }
            else {
                Card {
                    HStack(spacing: Space.lg) {
                        ExpenseRing(categories: categories, size: 132)
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(period == "今天" ? "今日花销" : "本月花销").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            Text(expenseMoney(.number(rows.reduce(0) { $0 + $1["amount_minor"].double }), currencyData.id)).font(TypeScale.title).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                            Text("\(rows.count) 笔支出").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                GroupSection("分类排行") {
                    if categories.isEmpty { EmptyState(title: "这段时间还没有支出", description: "在聊天中记一笔，账本会自动更新到这里。", symbol: "tray") }
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
                                    }.frame(height: 7)
                                    Text("\(category["count"].int) 笔 · " + category["group"].string).font(TypeScale.caption).foregroundStyle(Palette.textSecondary)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("expense-category-" + category.id)
                    }
                }
                Text(data["stale"].bool ? "当前是上次读取的账本，暂未更新。" : data["coverage"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .animation(reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88), value: period)
        .task(id: month) {
            loading = true
            let path = monthOffset == 0 ? "/personal/finance" : "/personal/finance?month=" + month
            data = await model.load(path) ?? .null; loading = false
        }
        .onAppear { period = initialPeriod; currency = initialCurrency }
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
