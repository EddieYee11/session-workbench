import Foundation
import UIKit
import AVFoundation
@preconcurrency import EventKit
@preconcurrency import Contacts
@preconcurrency import CoreLocation
import Observation
import ComCore

@MainActor @Observable final class DeviceBridge {
    weak var model: AppModel?
    let health = HealthReader()
    private let events = EKEventStore()
    private let contacts = CNContactStore()
    private let location = LocationReader()
    var connected = false
    var note = "仅在 App 使用期间连接手机能力"
    var readingHealth = false
    var healthNote = ""
    var healthSync = UserDefaults.standard.bool(forKey: "healthSync")
    var contactsSync = UserDefaults.standard.bool(forKey: "contactsSync")
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var running: Set<String> = []
    private var generation = 0
    var nodeID: String {
        if let id = UserDefaults.standard.string(forKey: "nodeID") { return id }
        let id = "node_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: "nodeID"); return id
    }
    init(model: AppModel) {
        self.model = model
        location.onAuthorizationChange = { [weak self] in Task { await self?.connect() } }
    }

    var capabilities: [JSON] {
        func cap(_ tool: String, _ permission: Bool, _ available: Bool = true, _ reason: String = "") -> JSON {
            .object(["tool": .string(tool), "permission": .bool(permission), "available": .bool(available), "reason": .string(reason.isEmpty && !permission ? (available ? "尚未授予系统权限，可在设置中申请" : "当前设备没有此能力") : reason)])
        }
        let calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let contactStatus = CNContactStore.authorizationStatus(for: .contacts)
        let contact = (contactStatus == .authorized || contactStatus == .limited) && contactsSync
        let healthy = health.available && UserDefaults.standard.bool(forKey: "healthRequested") && healthSync
        return [cap("device.status", true), cap("device.vibrate", true), cap("device.torch", true, AVCaptureDevice.default(for: .video)?.hasTorch == true),
                cap("location.last", location.permitted), cap("health.summary", healthy, health.available, "健康结果同步须在设置开启；空结果不代表授权被拒绝"),
                cap("calendar.list", calendar), cap("calendar.create", calendar), cap("calendar.update", calendar), cap("calendar.delete", calendar),
                cap("reminders.list", reminders), cap("reminders.create", reminders), cap("reminders.update", reminders), cap("reminders.delete", reminders),
                cap("contacts.search", contact, true, "仅访问系统允许的联系人；结果同步须在设置开启"),
                cap("contacts.create", contact), cap("contacts.update", contact), cap("contacts.delete", contact),
                cap("notifications.list", false, false, "iOS 不提供读取其他 App 通知的接口"),
                cap("notifications.dismiss", false, false, "iOS 不提供关闭其他 App 通知的接口"),
                cap("apps.list", false, false, "iOS 不提供应用清单接口"), cap("apps.usage", false, false, "未接入 Screen Time 授权"),
                cap("apps.launch", false, false, "通过用户操作的系统链接打开"), cap("device.volume", false, false, "使用系统音量控件"),
                cap("media.list", false, false, "使用系统照片选择器，不扫描照片库"), cap("alarm.set", false, false, "首版使用提醒事项"),
                cap("alarm.show", false, false, "未接入系统闹钟")]
    }
    func authorize(_ domain: String) async {
        do {
            switch domain {
            case "health": try await health.requestPermission(); model?.localHealth = try await health.summary(days: 1)
            case "calendar": guard try await events.requestFullAccessToEvents() else { throw denied() }
            case "reminders": guard try await events.requestFullAccessToReminders() else { throw denied() }
            case "contacts": guard try await contacts.requestAccess(for: .contacts) else { throw denied() }
            case "location": location.requestPermission()
            default: break
            }
            note = "授权已请求；系统允许的数据才会返回"
            await connect()
        } catch { note = error.localizedDescription }
    }
    func updateSync() async {
        UserDefaults.standard.set(healthSync, forKey: "healthSync")
        UserDefaults.standard.set(contactsSync, forKey: "contactsSync")
        await connect()
    }
    func readHealth() async {
        guard !readingHealth else { return }
        readingHealth = true; healthNote = ""
        defer { readingHealth = false }
        do {
            if !UserDefaults.standard.bool(forKey: "healthRequested") { try await health.requestPermission() }
            model?.localHealth = try await health.summary(days: 1)
            healthNote = model?.localHealth["missing_reason"].string ?? ""
            if healthNote.isEmpty { healthNote = "最近 24 小时的摘要已更新" }
            await connect()
        } catch { healthNote = "读取未完成：" + error.localizedDescription }
    }
    func connect() async {
        stop()
        guard let model, model.active, let api = model.client else { return }
        let current = generation
        do {
            _ = try await api.request("/personal/devices/register", body: .object([
                "id": .string(nodeID), "name": .string(UIDevice.current.name), "platform": .string("ios"),
                "capabilities": .array(capabilities), "os_version": .string(UIDevice.current.systemVersion)
            ]))
            guard current == generation, model.active else { return }
            let ws = try api.socket("/personal/devices/" + nodeID.pathEncoded + "/ws")
            socket = ws; ws.resume()
            receiveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard current == self.generation else { return }
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let value = try JSON.decode(data)
                        self.connected = true; self.note = "iPhone 能力已连接"
                        if value["type"].string == "invocation" { await self.handle(value, socket: ws) }
                        if value["type"].string == "snapshot" { await self.recover(value["invocations"].array, socket: ws) }
                    }
                } catch {
                    guard current == self.generation else { return }
                    self.connected = false; self.note = "手机能力已离线：" + error.localizedDescription
                    self.scheduleReconnect()
                }
            }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled, current == self.generation else { return }
                    do { try await self.send(.object(["type": .string("heartbeat")]), socket: ws) }
                    catch { return }
                }
            }
        } catch {
            guard current == generation else { return }
            connected = false; note = error.localizedDescription; scheduleReconnect()
        }
    }
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.model?.active == true else { return }
            await self.connect()
        }
    }
    func stop() {
        generation += 1; receiveTask?.cancel(); heartbeat?.cancel(); reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false
    }
    private func send(_ value: JSON, socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(String(decoding: JSONEncoder().encode(value), as: UTF8.self)))
    }
    private func recover(_ rows: [JSON], socket: URLSessionWebSocketTask) async {
        for row in rows where ["unknown", "executing", "pending"].contains(row["status"].string) {
            let id = row.id
            if let cached = try? SecureVault.load(JSON.self, name: "invocation-" + id.pathEncoded) {
                if cached["type"].string == "result" { try? await send(cached, socket: socket) }
                else if !running.contains(id) {
                    try? await send(.object(["type": .string("result"), "id": .string(id), "status": .string("unknown"),
                                            "result": .object(["reason": .string("上次设备操作结果未知，不会重新执行")])]), socket: socket)
                }
            }
        }
    }
    private func handle(_ row: JSON, socket: URLSessionWebSocketTask) async {
        let id = row.id
        guard !id.isEmpty, !running.contains(id) else { return }
        if let cached = try? SecureVault.load(JSON.self, name: "invocation-" + id.pathEncoded) {
            if cached["type"].string == "result" { try? await send(cached, socket: socket) }
            else { try? await send(.object(["type": .string("result"), "id": .string(id), "status": .string("unknown")]), socket: socket) }
            return
        }
        running.insert(id); defer { running.remove(id) }
        var result: JSON
        do {
            guard let capability = capabilities.first(where: { $0["tool"] == row["tool"] }), capability["available"].bool else {
                throw APIError(status: 422, detail: "此 iPhone 能力不可用")
            }
            guard capability["permission"].bool else { throw denied() }
            // Journal before ACK and any local side effect. Never replay after a crash.
            try SecureVault.save(JSON.object(["type": .string("executing"), "id": .string(id), "tool": row["tool"]]), name: "invocation-" + id.pathEncoded)
            try await send(.object(["type": .string("ack"), "id": .string(id)]), socket: socket)
            let value = try await execute(row["tool"].string, args: row["args"])
            result = .object(["type": .string("result"), "id": .string(id), "status": .string("succeeded"), "result": value])
        } catch {
            result = .object(["type": .string("result"), "id": .string(id),
                              "status": .string((error as? APIError)?.status == 403 ? "permission_denied" : (error as? APIError)?.status == 0 ? "unknown" : "failed"),
                              "result": .object(["reason": .string(error.localizedDescription)])])
        }
        result["tool"] = row["tool"]; result["finished_at"] = .number(Date().timeIntervalSince1970)
        do { try SecureVault.save(result, name: "invocation-" + id.pathEncoded); try await send(result, socket: socket) }
        catch { note = "操作回执待补传；不会再次执行" }
    }
    private func denied() -> APIError { APIError(status: 403, detail: "权限未允许或设备结果同步未开启") }
    private func date(_ value: JSON, fallback: Date? = nil) throws -> Date {
        if case .number(let ms) = value { return Date(timeIntervalSince1970: ms / 1000) }
        if let d = ISO8601DateFormatter().date(from: value.string) { return d }
        if let fallback { return fallback }
        throw APIError(status: 400, detail: "时间应为毫秒时间戳或 ISO 8601")
    }
    private func execute(_ tool: String, args: JSON) async throws -> JSON {
        switch tool {
        case "device.status":
            UIDevice.current.isBatteryMonitoringEnabled = true
            return .object(["platform": .string("ios"), "name": .string(UIDevice.current.name), "os": .string(UIDevice.current.systemVersion),
                            "battery": UIDevice.current.batteryLevel < 0 ? .null : .number(Double(UIDevice.current.batteryLevel * 100)),
                            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled), "foreground": .bool(model?.active == true)])
        case "device.vibrate": Haptics.sent(); return .object(["requested": .bool(true)])
        case "device.torch":
            guard let camera = AVCaptureDevice.default(for: .video), camera.hasTorch else { throw APIError(status: 422, detail: "无手电筒") }
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            camera.torchMode = args["enabled"].bool ? .on : .off
            return .object(["enabled": .bool(camera.torchMode == .on)])
        case "location.last": return try await location.read()
        case "health.summary": return try await health.summary(days: args["days"].int == 0 ? 1 : args["days"].int)
        case "calendar.list": return try calendarList(args)
        case "calendar.create", "calendar.update", "calendar.delete": return try calendarWrite(tool, args)
        case "reminders.list": return try await reminderList(args)
        case "reminders.create", "reminders.update", "reminders.delete": return try reminderWrite(tool, args)
        case "contacts.search": return try contactsSearch(args)
        case "contacts.create", "contacts.update", "contacts.delete": return try contactsWrite(tool, args)
        default: throw APIError(status: 422, detail: "iOS 不支持此操作")
        }
    }
    private func eventJSON(_ e: EKEvent) -> JSON {
        .object(["id": .string(e.eventIdentifier ?? ""), "event_id": .string(e.eventIdentifier ?? ""), "title": .string(e.title ?? ""),
                 "begin": .number(e.startDate.timeIntervalSince1970 * 1000), "end": .number(e.endDate.timeIntervalSince1970 * 1000),
                 "calendar_id": .string(e.calendar.calendarIdentifier), "calendar_displayName": .string(e.calendar.title),
                 "description": .string(e.notes ?? ""), "all_day": .bool(e.isAllDay), "source": .string("iPhone EventKit"),
                 "external_id": .string(e.calendarItemExternalIdentifier ?? ""), "modified_at": .number(e.lastModifiedDate?.timeIntervalSince1970 ?? 0)])
    }
    private func calendarList(_ args: JSON) throws -> JSON {
        let start = try date(args["start"], fallback: Date())
        let end = try date(args["end"], fallback: start.addingTimeInterval(Double(max(1, min(90, args["days"].int == 0 ? 30 : args["days"].int))) * 86400))
        guard end > start else { throw APIError(status: 400, detail: "结束时间必须晚于开始") }
        let rows = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
        return .object(["items": .array(rows.sorted { $0.startDate < $1.startDate }.prefix(250).map(eventJSON)),
                        "calendars": .array(events.calendars(for: .event).map { .object(["id": .string($0.calendarIdentifier), "name": .string($0.title), "writable": .bool($0.allowsContentModifications)]) }),
                        "source": .string("iPhone EventKit"), "start": .number(start.timeIntervalSince1970 * 1000), "end": .number(end.timeIntervalSince1970 * 1000)])
    }
    private func calendarWrite(_ tool: String, _ args: JSON) throws -> JSON {
        let creating = tool == "calendar.create"
        let event: EKEvent
        if creating { event = EKEvent(eventStore: events); event.calendar = events.calendar(withIdentifier: args["calendar_id"].string) ?? events.defaultCalendarForNewEvents }
        else { guard let old = events.event(withIdentifier: args["id"].string) else { throw APIError(status: 404, detail: "日历事件不存在或已改变") }; event = old }
        guard event.calendar?.allowsContentModifications == true else { throw APIError(status: 403, detail: "此日历不可编辑") }
        let before = creating ? JSON.null : eventJSON(event)
        if !creating {
            guard !args["expected_start"].isNull, abs(event.startDate.timeIntervalSince1970 * 1000 - args["expected_start"].double) < 1 else {
                throw APIError(status: 409, detail: "事件已改变，请刷新后再调整")
            }
            if event.hasRecurrenceRules { throw APIError(status: 422, detail: "重复日程请在系统日历选择本次或整个系列") }
            if event.hasAttendees && !args["explicit_shared_event"].bool { throw APIError(status: 403, detail: "共享日程需要具体交办") }
            if (event.notes ?? "").contains("固定") { throw APIError(status: 403, detail: "固定安排不可自动调整") }
        }
        if tool == "calendar.delete" {
            let id = event.eventIdentifier ?? ""; try events.remove(event, span: .thisEvent, commit: true)
            return .object(["id": .string(id), "verified": .bool(events.event(withIdentifier: id) == nil), "undo": .object(["tool": .string("calendar.create"), "args": .object(before.object.merging(["start": before["begin"]]) { _, b in b })])])
        }
        let start = try date(args["start"], fallback: creating ? nil : event.startDate)
        let end = try date(args["end"], fallback: creating ? nil : event.endDate)
        guard end > start else { throw APIError(status: 400, detail: "结束时间必须晚于开始") }
        let overlaps = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: [event.calendar])).filter { $0.eventIdentifier != event.eventIdentifier && !$0.isAllDay }
        guard overlaps.isEmpty || args["explicit_allow_conflict"].bool else { throw APIError(status: 409, detail: "时间与已有日程冲突，请确认后再安排") }
        event.startDate = start; event.endDate = end
        if !args["title"].string.isEmpty { event.title = args["title"].string }
        if !args["description"].isNull { event.notes = args["description"].string }
        if !args["all_day"].isNull { event.isAllDay = args["all_day"].bool }
        event.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard !(event.title ?? "").isEmpty else { throw APIError(status: 400, detail: "日程标题不能为空") }
        try events.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier, let read = events.event(withIdentifier: id) else { throw APIError(status: 0, detail: "日程已写入但回读失败，请核对，不能重复创建") }
        return .object(["id": .string(id), "verified": .bool(abs(read.startDate.timeIntervalSince(start)) < 1 && abs(read.endDate.timeIntervalSince(end)) < 1 && read.title == event.title && read.notes == event.notes && read.isAllDay == event.isAllDay), "readback": eventJSON(read),
                        "undo": creating ? .object(["tool": .string("calendar.delete"), "args": .object(["id": .string(id), "expected_start": .number(start.timeIntervalSince1970 * 1000)])]) : .object(["tool": .string("calendar.update"), "args": .object(before.object.merging(["start": before["begin"], "expected_start": .number(start.timeIntervalSince1970 * 1000)]) { _, b in b })])])
    }
    nonisolated private static func reminderJSON(_ r: EKReminder) -> JSON {
        .object(["id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""), "completed": .bool(r.isCompleted),
                 "notes": .string(r.notes ?? ""), "calendar_id": .string(r.calendar.calendarIdentifier),
                 "due": r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { .string($0.ISO8601Format()) } ?? .null,
                 "modified_at": .number(r.lastModifiedDate?.timeIntervalSince1970 ?? 0)])
    }
    private func reminderList(_ args: JSON) async throws -> JSON {
        let rows: [JSON] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: events.predicateForReminders(in: nil)) { reminders in
                let rows = (reminders ?? []).filter { args["include_completed"].bool || !$0.isCompleted }.prefix(250).map(Self.reminderJSON)
                continuation.resume(returning: rows)
            }
        }
        return .object(["items": .array(rows), "source": .string("iPhone EventKit")])
    }

    private func reminderWrite(_ tool: String, _ args: JSON) throws -> JSON {
        let creating = tool == "reminders.create"
        let reminder: EKReminder
        if creating { reminder = EKReminder(eventStore: events); reminder.calendar = events.calendar(withIdentifier: args["calendar_id"].string) ?? events.defaultCalendarForNewReminders() }
        else { guard let old = events.calendarItem(withIdentifier: args["id"].string) as? EKReminder else { throw APIError(status: 404, detail: "提醒事项不存在") }; reminder = old }
        guard reminder.calendar?.allowsContentModifications == true else { throw denied() }
        let before = creating ? JSON.null : Self.reminderJSON(reminder)
        if !creating, args["expected_modified"].isNull || abs(before["modified_at"].double - args["expected_modified"].double) > 0.001 { throw APIError(status: 409, detail: "请先读取提醒事项的最新版本") }
        if tool == "reminders.delete" {
            let id = reminder.calendarItemIdentifier; try events.remove(reminder, commit: true)
            return .object(["verified": .bool(events.calendarItem(withIdentifier: id) == nil), "undo": .object(["tool": .string("reminders.create"), "args": before])])
        }
        if !args["title"].string.isEmpty { reminder.title = args["title"].string }
        if !args["notes"].isNull { reminder.notes = args["notes"].string }
        if !args["completed"].isNull { reminder.isCompleted = args["completed"].bool }
        if args["clear_due"].bool { reminder.dueDateComponents = nil }
        if !args["due"].isNull { reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try date(args["due"])) }
        guard !(reminder.title ?? "").isEmpty else { throw APIError(status: 400, detail: "提醒标题不能为空") }
        try events.save(reminder, commit: true)
        let id = reminder.calendarItemIdentifier
        guard let read = events.calendarItem(withIdentifier: id) as? EKReminder else { throw APIError(status: 0, detail: "提醒已写入但回读失败") }
        let undo = creating ? JSON.object(["tool": .string("reminders.delete"), "args": .object(["id": .string(id), "expected_modified": .number(read.lastModifiedDate?.timeIntervalSince1970 ?? 0)])]) : .object(["tool": .string("reminders.update"), "args": .object(before.object.merging(["clear_due": .bool(before["due"].isNull), "expected_modified": .number(read.lastModifiedDate?.timeIntervalSince1970 ?? 0)]) { _, b in b })])
        return .object(["id": .string(id), "verified": .bool(read.title == reminder.title && read.notes == reminder.notes && read.isCompleted == reminder.isCompleted && read.dueDateComponents == reminder.dueDateComponents), "readback": Self.reminderJSON(read), "undo": undo])
    }
    private var contactKeys: [CNKeyDescriptor] { [CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
                                                  CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor] }
    private func contactJSON(_ c: CNContact) -> JSON {
        .object(["id": .string(c.identifier), "given_name": .string(c.givenName), "family_name": .string(c.familyName),
                 "name": .string([c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")),
                 "phones": .array(c.phoneNumbers.map { .string($0.value.stringValue) }), "emails": .array(c.emailAddresses.map { .string($0.value as String) })])
    }
    private func contactsSearch(_ args: JSON) throws -> JSON {
        let query = args["query"].string.isEmpty ? args["name"].string : args["query"].string
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError(status: 400, detail: "请提供联系人搜索词") }
        let rows = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: contactKeys)
        return .object(["items": .array(rows.prefix(50).map(contactJSON)), "source": .string("iPhone Contacts"), "limited_access": .bool(CNContactStore.authorizationStatus(for: .contacts) == .limited)])
    }
    private func contactsWrite(_ tool: String, _ args: JSON) throws -> JSON {
        let creating = tool == "contacts.create"
        let contact: CNMutableContact
        if creating { contact = CNMutableContact() }
        else {
            let old = try contacts.unifiedContact(withIdentifier: args["id"].string, keysToFetch: contactKeys)
            guard args["expected"] == contactJSON(old) else { throw APIError(status: 409, detail: "联系人已改变，请先查询最新内容") }
            contact = old.mutableCopy() as! CNMutableContact
        }
        let before = creating ? JSON.null : contactJSON(contact)
        let request = CNSaveRequest()
        if tool == "contacts.delete" {
            request.delete(contact); try contacts.execute(request)
            var removed = false
            do { _ = try contacts.unifiedContact(withIdentifier: contact.identifier, keysToFetch: contactKeys) }
            catch { let error = error as NSError; if error.domain == CNErrorDomain && error.code == CNError.Code.recordDoesNotExist.rawValue { removed = true } else { throw APIError(status: 0, detail: "联系人删除后回读失败，请核对") } }
            return .object(["verified": .bool(removed), "undo": .object(["tool": .string("contacts.create"), "args": before])])
        }
        if !args["given_name"].isNull { contact.givenName = args["given_name"].string }
        else if creating { contact.givenName = args["name"].string }
        if !args["family_name"].isNull { contact.familyName = args["family_name"].string }
        if !args["phones"].isNull { contact.phoneNumbers = args["phones"].array.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0.string)) } }
        if !args["emails"].isNull { contact.emailAddresses = args["emails"].array.map { CNLabeledValue(label: CNLabelHome, value: $0.string as NSString) } }
        guard !contact.givenName.isEmpty || !contact.familyName.isEmpty else { throw APIError(status: 400, detail: "联系人姓名不能为空") }
        if creating { request.add(contact, toContainerWithIdentifier: nil) } else { request.update(contact) }
        try contacts.execute(request)
        let read: CNContact
        do { read = try contacts.unifiedContact(withIdentifier: contact.identifier, keysToFetch: contactKeys) }
        catch { throw APIError(status: 0, detail: "联系人已写入但回读失败，请核对，不能重复创建") }
        let result = contactJSON(read)
        return .object(["id": .string(read.identifier), "verified": .bool(result == contactJSON(contact)), "readback": result,
                        "undo": creating ? .object(["tool": .string("contacts.delete"), "args": .object(["id": .string(read.identifier), "expected": result])]) : .object(["tool": .string("contacts.update"), "args": .object(before.object.merging(["expected": result]) { _, b in b })])])
    }
}

@MainActor final class LocationReader: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onAuthorizationChange: (() -> Void)?
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<JSON, Error>?
    private var timeout: Task<Void, Never>?
    var permitted: Bool { manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways }
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func read() async throws -> JSON {
        guard permitted else { throw APIError(status: 403, detail: "位置权限未允许") }
        guard continuation == nil else { throw APIError(status: 409, detail: "正在获取位置") }
        return try await withCheckedThrowingContinuation { c in
            continuation = c; manager.requestLocation()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(APIError(status: 0, detail: "位置获取超时")))
            }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorizationChange?() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success(.object(["latitude": .number(location.coordinate.latitude), "longitude": .number(location.coordinate.longitude),
                                 "accuracy_meters": .number(location.horizontalAccuracy), "measured_at": .number(location.timestamp.timeIntervalSince1970 * 1000),
                                 "source": .string("iPhone CoreLocation"), "is_live": .bool(abs(location.timestamp.timeIntervalSinceNow) < 30)])))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<JSON, Error>) {
        timeout?.cancel(); timeout = nil; continuation?.resume(with: result); continuation = nil
    }
}
