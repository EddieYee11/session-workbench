import SwiftUI
import ComCore

/// 气泡下的回执：这一轮替他动过哪些数据，一眼能看到，不用去动态页翻。
struct ReceiptStrip: View {
    @Environment(AppModel.self) private var model
    let receipts: [JSON]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(receipts.map(RemoteRow.init)) { row in
                ReceiptRow(receipt: row.value) {
                    // 回滚要真去做，发一条真实指令；这里不假装能一键撤销。
                    model.draft = "把刚才这步撤销：" + row.value["summary"].string
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityIdentifier("chat-receipts")
    }
}

private struct ReceiptRow: View {
    let receipt: JSON
    let undo: () -> Void
    private var symbol: String {
        switch receipt["type"].string {
        case "ledger": "yensign.circle"
        case "schedule": receipt["tool"].string == "remind" ? "bell" : "calendar"
        default: "paperplane"
        }
    }
    private var status: (String, Color) {
        switch receipt["state"].string {
        case "uncertain": ("结果待核对", Palette.warning)
        case "disputed": ("你标记过有问题", Palette.warning)
        case "failed": ("没做成", Palette.danger)
        default: ("已写入", Palette.textTertiary)
        }
    }
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary).frame(width: 18)
            Text(receipt["summary"].string).font(TypeScale.footnote).foregroundStyle(Palette.textPrimary).lineLimit(2)
            Spacer(minLength: Space.xs)
            Text(status.0).font(TypeScale.caption).foregroundStyle(status.1).lineLimit(1)
            Menu {
                Button("让它撤销这一步", systemImage: "arrow.uturn.backward", action: undo)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
            .accessibilityIdentifier("receipt-more-" + receipt["key"].string)
        }
        .frame(minHeight: 28)
        .accessibilityIdentifier("receipt-" + receipt["key"].string)
    }
}
