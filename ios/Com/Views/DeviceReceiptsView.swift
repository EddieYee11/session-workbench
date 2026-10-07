import SwiftUI
import ComCore

struct DeviceReceiptsView: View {
    @Environment(AppModel.self) private var model
    @State private var records = SecureVault.records(prefix: "invocation-").sorted { $0["finished_at"].double > $1["finished_at"].double }
    @State private var working = false
    @State private var note = ""
    var body: some View {
        ScrollPage(spacing: Space.md) {
            if records.isEmpty { EmptyState(title: "暂无本机设备操作回执", description: "", symbol: "checkmark.seal") }
            if !note.isEmpty { InlineNotice(text: note) }
            ForEach(records.map(RemoteRow.init)) { row in
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
                                Text(row.value["undo_requested"].bool ? "已申请撤销，请核对回执" : "撤销此操作")
                            }
                            .buttonStyle(.quiet)
                            .disabled(working || row.value["undo_requested"].bool)
                            .opacity(working || row.value["undo_requested"].bool ? 0.5 : 1)
                        }
                    }
                }
            }
        }.navigationTitle("设备回执").navigationBarTitleDisplayMode(.inline)
    }
    private func undo(_ record: JSON) async {
        var saved = record; saved["undo_requested"] = .bool(true)
        working = true; defer { working = false }
        do {
            // Persist before sending; an uncertain undo must not become a second write.
            try SecureVault.save(saved, name: "invocation-" + record.id.pathEncoded)
            records = SecureVault.records(prefix: "invocation-")
            let undo = record["result"]["undo"]
            let result = try await model.mutate("/personal/devices/" + model.devices.nodeID.pathEncoded + "/invoke", fields: ["tool": undo["tool"], "args": undo["args"], "timeout": .number(60)])
            note = result["status"].string == "succeeded" && result["result"]["verified"].bool ? "撤销已回读验证" : "撤销尚未验证：" + result["status"].string
            records = SecureVault.records(prefix: "invocation-")
        } catch { note = "撤销送达待核实，请查询原请求，不要重复撤销。" }
    }
}
