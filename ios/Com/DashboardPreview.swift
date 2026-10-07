#if DEBUG
import Foundation
import ComCore
extension AppModel {
    func seedDashboardPreview() {
        let raw = #"""
        {"finance":{"available":true,"month":"2026-10","coverage":"界面验收数据，不是真实账目","currencies":[{"id":"CNY","today_minor":3650,"month_minor":248650,"categories":[{"id":"food","name":"餐饮","color_index":0,"group":"日常生活","amount_minor":98650,"count":2},{"id":"travel","name":"交通","color_index":1,"group":"出行","amount_minor":90000,"count":1},{"id":"tools","name":"数码工具","color_index":2,"group":"工作","amount_minor":60000,"count":1}]}],"items":[{"id":"t1","currency":"CNY","category_id":"food","category":"餐饮","comment":"午饭 · 一碗面","amount_minor":3650,"date":"2026-10-07","time":"2026-10-07T12:30:00+08:00","account":"日常账户"},{"id":"t2","currency":"CNY","category_id":"food","category":"餐饮","comment":"周末聚餐","amount_minor":95000,"date":"2026-10-04","time":"2026-10-04T19:00:00+08:00","account":"日常账户"},{"id":"t3","currency":"CNY","category_id":"travel","category":"交通","comment":"出差交通","amount_minor":90000,"date":"2026-10-03","time":"2026-10-03T09:00:00+08:00","account":"日常账户"},{"id":"t4","currency":"CNY","category_id":"tools","category":"数码工具","comment":"创作工具","amount_minor":60000,"date":"2026-10-02","time":"2026-10-02T14:00:00+08:00","account":"日常账户"}]},"board":{"counts":{"active":0,"pending":1,"completed":1,"uncertain":0},"hosts":[{"host":"macbook","stale":false},{"host":"mini","stale":false}],"note":"界面验收数据 · 进展保留来源","projects":[{"id":"preview-project","title":"Com · 个人 Agent","counts":{"active":0,"pending":1,"completed":1},"items":[{"id":"preview-board-item","agent":"codex","host":"macbook","title":"验证手机上的语音小窗","status":"pending","summary":"光效和系统入口已完成，还需要实际录音验收。","next_step":"试一次操作按钮录音，检查发送结果。","evidence_quote":"光效和系统入口已完成，还需要实际录音验收。"},{"id":"preview-board-item2","agent":"hermes","host":"mini","title":"晨晚报生成链路","status":"completed","summary":"独立生成与回执测试已通过。","next_step":"","evidence_quote":"独立生成与回执测试已通过。"}]}]}}
        """#
        let fixture = try! JSON.decode(Data(raw.utf8))
        datasets["/personal/finance"] = fixture["finance"]
        datasets["/personal/projects"] = fixture["board"]
        datasets["/personal/projects/sources/" + "preview-board-item".pathEncoded] = .object(["messages": .array([.object(["id": .string("m1"), "role": .string("assistant"), "text": .string("光效和系统入口已完成，还需要实际录音验收。")])])])
    }
}
#endif
