import SwiftUI
import ComCore

struct DeviceReceiptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var records: [JSON] = []
    @State private var working = false
    @State private var note = ""
    @State private var noteFailed = false
    @State private var land = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    var body: some View {
        ScrollPage(spacing: Space.md) {
            Text("在这台手机上动过设备的事都留底；能撤销的会给你按钮，不确定的先查回执，别连点两次。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                .modifier(EnterRise(on: land, delay: 0, y: 10, blur: 4, animation: ComMotion.rise))
            if loading || !loadedOnce {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐设备回执…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐设备回执")
                .accessibilityIdentifier("device-receipts-pulling")
            }
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading ? "重试中…" : "再试一次") {
                    guard !loading else { return }
                    reloadReceipts()
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading)
                .accessibilityIdentifier("device-receipts-retry")
            }
            if records.isEmpty && loadedOnce && !loading {
                EmptyState(title: failNote.isEmpty ? "还没有设备操作回执" : "回执还没读上",
                           description: failNote.isEmpty
                            ? "用语音或聊天让我操作本机时，结果会记在这里——方便你核对，也能撤销。"
                            : "先重试拉齐本机回执；撤销前请先确认列表能读到。",
                           symbol: "checkmark.seal")
                    .modifier(EnterRise(on: land, delay: 0.04, y: 12, blur: 5, animation: ComMotion.pop))
            }
            if !note.isEmpty { InlineNotice(text: note, tone: noteFailed ? .danger : .neutral) }
            ForEach(Array(records.map(RemoteRow.init).enumerated()), id: \.element.id) { index, row in
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack {
                            Text(row.value["tool"].string).font(TypeScale.headline)
                            Spacer()
                            StatusPill(text: displayStatus(row.value["status"].string), tone: row.value["status"].string == "succeeded" ? .success : statusTone(row.value["status"].string))
                        }
                        RawDetails(title: "回读与操作证据", value: row.value["result"])
                        if row.value["status"].string == "succeeded" && row.value["result"]["verified"].bool && !row.value["result"]["undo"].isNull {
                            Button(role: .destructive) { Task { await undo(row.value) } } label: {
                                Text(working ? "撤销中…" : (row.value["undo_requested"].bool ? "已申请撤销，请核对回执" : "撤销此操作"))
                            }
                            .buttonStyle(.quiet)
                            .disabled(working || row.value["undo_requested"].bool)
                            .opacity(working || row.value["undo_requested"].bool ? 0.5 : 1)
                            .accessibilityIdentifier("device-undo-" + row.id)
                        }
                    }
                }
                .modifier(EnterRise(on: land, delay: 0.06 + Double(min(index, 6)) * ComMotion.stagger, y: 10, blur: 4, animation: ComMotion.pop))
            }
        }
        .navigationTitle("设备回执").navigationBarTitleDisplayMode(.inline)
        .refreshable { reloadReceipts() }
        .onAppear {
            reloadReceipts()
            if reduce { land = true }
            else { withAnimation(ComMotion.lift) { land = true } }
        }
    }
    private func reloadReceipts() {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        let batch = SecureVault.loadRecords(prefix: "invocation-")
        if let err = batch.directoryError, !err.isEmpty {
            failNote = "本机回执目录没读上：" + err + "——可再试"
            // 保留已有列表，别因目录瞬断清空成假空。
            if !records.isEmpty { return }
            records = []
            return
        }
        records = batch.items.sorted { $0["finished_at"].double > $1["finished_at"].double }
        if batch.decodeFailures > 0 {
            failNote = "有 \(batch.decodeFailures) 条回执解不开——下面是能读的；可再试或稍后重开"
        }
    }
    private func undo(_ record: JSON) async {
        guard !working, !record["undo_requested"].bool else { return }
        working = true
        note = ""
        noteFailed = false
        defer { working = false }
        let key = "invocation-" + record.id.pathEncoded
        // 先占坑防连点叠撤销；未验证 / 没送出都回滚，别假锁成「已申请撤销」。
        var claimed = record
        claimed["undo_requested"] = .bool(true)
        do {
            try SecureVault.save(claimed, name: key)
            reloadReceipts()
            guard model.client != nil else {
                _ = clearUndoClaim(record, key: key)
                noteFailed = true
                note = "还没连上 mini——撤销没发出去，可配对后再试。不会假装已撤销。"
                return
            }
            let undo = record["result"]["undo"]
            guard !undo.isNull, !undo["tool"].string.isEmpty else {
                _ = clearUndoClaim(record, key: key)
                noteFailed = true
                note = "这条回执没有可执行的撤销步骤——不能撤销。不会假装已撤销。"
                return
            }
            let result = try await model.mutate(
                "/personal/devices/" + model.devices.nodeID.pathEncoded + "/invoke",
                fields: ["tool": undo["tool"], "args": undo["args"], "timeout": .number(60)]
            )
            let status = result["status"].string
            let verified = result["result"]["verified"].bool
            let ok = status == "succeeded" && verified
            if ok {
                noteFailed = false
                note = "撤销已回读验证"
                reloadReceipts()
                return
            }
            // 服务有回但未验证：回滚占坑，允许再点；勿保持「已申请」假成功。
            let unlocked = clearUndoClaim(record, key: key)
            noteFailed = true
            let detail = result["result"]["error"].string.isEmpty ? status : result["result"]["error"].string
            note = unlocked
                ? "撤销尚未验证：" + (detail.isEmpty ? "结果不清" : detail) + "——还可以再试。不会假装已撤销。"
                : "撤销尚未验证，且本地解锁失败——下拉刷新后再看。不会假装已撤销。"
            reloadReceipts()
        } catch {
            let unlocked = clearUndoClaim(record, key: key)
            noteFailed = true
            note = unlocked
                ? "撤销没送出去：" + error.localizedDescription + "——还可以再试。不会假装已撤销。"
                : "撤销没送出去，且本地解锁失败——下拉刷新后再试。不会假装已撤销。"
            reloadReceipts()
        }
    }
    /// 清掉 undo_requested 占坑。true = 已写回可再点。
    @discardableResult
    private func clearUndoClaim(_ record: JSON, key: String) -> Bool {
        var restored = record
        restored["undo_requested"] = .bool(false)
        do {
            try SecureVault.save(restored, name: key)
            return true
        } catch {
            return false
        }
    }
}
