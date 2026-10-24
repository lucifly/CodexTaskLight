import AppKit
import CoreServices
import Darwin
import SQLite3
import SwiftUI

enum TaskState: String, Sendable {
    case running, waiting, completed, failed, unknown
    var title: String {
        switch self {
        case .waiting: return "等待确认 / 审批"
        case .running: return "执行中"
        case .completed: return "已完成"
        case .failed: return "异常 / 已中断"
        case .unknown: return "状态未知"
        }
    }
    var color: NSColor {
        switch self {
        case .running: return .systemYellow
        case .completed: return .systemGreen
        case .failed, .waiting: return .systemRed
        case .unknown: return .systemGray
        }
    }
}
struct Chat: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String
}
struct Reading: Equatable, Sendable {
    var state: TaskState = .unknown
    var lastEvent: Date?
    var pendingQuestionIDs = Set<String>()
    var detail = "等待任务记录"
}
struct EventParser {
    static func read(_ lines: String, initial: Reading = Reading(), expire: Bool = true) -> Reading {
        var result = initial
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = record["payload"] as? [String: Any],
                let type = payload["type"] as? String
            else { continue }
            let date = (record["timestamp"] as? String).flatMap {
                formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            if record["type"] as? String == "response_item" {
                if ["function_call", "custom_tool_call"].contains(type),
                    ["request_user_input_async", "functions.request_user_input_async"].contains(
                        payload["name"] as? String ?? ""),
                    let call = payload["call_id"] as? String
                {
                    let text = payload["arguments"] as? String ?? payload["input"] as? String ?? "{}"
                    let args = text.data(using: .utf8).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    }
                    let count = (args?["questions"] as? [Any])?.count ?? 1
                    for i in 0..<max(1, count) { result.pendingQuestionIDs.insert(call + ":" + String(i)) }
                    if let date { result.lastEvent = date }
                } else if ["function_call_output", "custom_tool_call_output"].contains(type),
                    let call = payload["call_id"] as? String,
                    result.pendingQuestionIDs.contains(where: { $0.hasPrefix(call + ":") }),
                    questionWasRejected(payload["output"])
                {
                    result.pendingQuestionIDs = result.pendingQuestionIDs.filter { !$0.hasPrefix(call + ":") }
                    if let date { result.lastEvent = date }
                } else if type == "message", payload["role"] as? String == "user" {
                    for part in payload["content"] as? [[String: Any]] ?? [] {
                        guard let text = part["text"] as? String,
                            let start = text.range(of: "<send_user_message_question_reply>"),
                            let end = text.range(of: "</send_user_message_question_reply>"),
                            start.upperBound <= end.lowerBound,
                            let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                            let replies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                        else { continue }
                        for reply in replies {
                            guard let encoded = reply["questionItemId"] as? String,
                                let bytes = encoded.data(using: .utf8),
                                let key = try? JSONSerialization.jsonObject(with: bytes) as? [Any], key.count == 3,
                                key[0] as? String == "request_user_input_async", let call = key[1] as? String,
                                let index = key[2] as? Int
                            else { continue }
                            result.pendingQuestionIDs.remove(call + ":" + String(index))
                        }
                        if let date { result.lastEvent = date }
                    }
                }
                continue
            }
            guard record["type"] as? String == "event_msg" else { continue }
            switch type {
            case "task_started", "turn_started":
                result.pendingQuestionIDs.removeAll()
                result.state = .running
                result.detail = "已记录任务开始"
            case "task_complete", "turn_complete":
                result.state = .completed
                result.detail = "已记录本轮任务完成"
            case "turn_aborted", "task_aborted", "task_failed", "turn_failed":
                result.pendingQuestionIDs.removeAll()
                result.state = .failed
                result.detail = "任务异常或被中断，请在 Codex 查看"
            default: break
            }
            if let date { result.lastEvent = date }
        }
        return expire ? result.expiring() : result
    }

    // Only explicit tool failure/cancellation clears a request. A normal turn end
    // must retain accepted asynchronous questions until their individual replies.
    static func questionWasRejected(_ output: Any?) -> Bool {
        if let text = output as? String {
            if let bytes = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes) {
                return questionWasRejected(value)
            }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return message.hasPrefix("error:") || message.hasPrefix("error parsing function call:")
                || message.hasPrefix("tool error:")
        }
        guard let value = output as? [String: Any] else { return false }
        if value["accepted"] as? Bool == false || value["isError"] as? Bool == true { return true }
        if let error = value["error"], !(error is NSNull), (error as? Bool) != false { return true }
        if ["failed", "rejected", "cancelled", "canceled"].contains(value["status"] as? String ?? "") { return true }
        if let result = value["result"], questionWasRejected(result) { return true }
        return (value["content"] as? [[String: Any]] ?? []).contains { questionWasRejected($0["text"]) }
    }
}
extension Reading {
    func expiring(at now: Date = Date()) -> Reading {
        if !pendingQuestionIDs.isEmpty {
            var result = self
            result.state = .waiting
            result.detail = "等待你回答确认问题，回复后自动恢复"
            return result
        }
        if state == .running, let date = lastEvent, now.timeIntervalSince(date) >= 180 {
            return Reading(state: .unknown, lastEvent: date, detail: "超过 3 分钟没有新记录，请在 Codex 确认")
        }
        return self
    }

}

// Accessed only on the monitor serial queue (or synchronously by command-line checks).
final class LocalReader: @unchecked Sendable {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.home = home.resolvingSymlinksInPath()
    }
    struct Cursor {
        var inode: UInt64
        var device: Int32
        var offset: UInt64 = 0
        var pending = Data()
        var reading = Reading()
        var modified: Int64 = 0
    }
    var cache: [String: Cursor] = [:]
    var bytesRead: UInt64 = 0
    func list() throws -> [Chat] {
        // Read-only: never modifies Codex databases or session files.
        let files = try FileManager.default.contentsOfDirectory(atPath: home.path)
        let dbName =
            files.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }.first ?? "state_5.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent(dbName).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "CodexTaskLight", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 Codex 本地任务列表"])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let sql =
            "SELECT id, title, rollout_path FROM threads WHERE archived = 0 AND (agent_path IS NULL OR agent_path = '') ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "CodexTaskLight", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex 数据格式已变化，请更新工具"])
        }
        defer { sqlite3_finalize(statement) }
        var chats: [Chat] = []
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            chats.append(Chat(id: text(0), title: text(1), path: text(2)))
            resultCode = sqlite3_step(statement)
        }
        guard resultCode == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return chats
    }
    func read(_ chat: Chat) throws -> Reading { try readRaw(chat).expiring() }
    func readRaw(_ chat: Chat) throws -> Reading {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: chat.path))
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let size = UInt64(max(0, info.st_size))
        let modified = Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
        var cursor = cache[chat.path] ?? Cursor(inode: info.st_ino, device: info.st_dev)
        if cursor.inode != info.st_ino || cursor.device != info.st_dev || size < cursor.offset
            || (size == cursor.offset && modified != cursor.modified)
        {
            cursor = Cursor(inode: info.st_ino, device: info.st_dev)
        }
        if cursor.offset == size { return cursor.reading }
        if cursor.offset == 0 && size > 4_194_304 {
            // Bootstrap near EOF; walk backwards if the latest lifecycle marker lies earlier.
            var offset = size > 4_194_304 ? size - 4_194_304 : 0
            var initial = Data()
            while true {
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: Int(size - offset)) ?? Data()
                bytesRead += UInt64(chunk.count)
                initial = chunk
                if offset > 0, let newline = initial.firstIndex(of: 10) {
                    initial = Data(initial[initial.index(after: newline)...])
                }
                let complete = Self.completeLines(initial).0
                let parsed = EventParser.read(String(decoding: complete, as: UTF8.self), expire: false)
                if parsed.state != .unknown || offset == 0 || size - offset >= 67_108_864 { break }
                offset = offset > 4_194_304 ? offset - 4_194_304 : 0
            }
            cursor.pending = initial
        } else {
            try handle.seek(toOffset: cursor.offset)
            let added = try handle.readToEnd() ?? Data()
            bytesRead += UInt64(added.count)
            cursor.pending.append(added)
        }
        // seekToEnd can race a writer; the actual position is the committed read cursor.
        cursor.offset = try handle.offset()
        let (complete, partial) = Self.completeLines(cursor.pending)
        cursor.pending = partial
        cursor.reading = EventParser.read(
            String(decoding: complete, as: UTF8.self), initial: cursor.reading, expire: false)
        cursor.modified = modified
        cache[chat.path] = cursor
        return cursor.reading
    }
    static func completeLines(_ data: Data) -> (Data, Data) {
        guard let newline = data.lastIndex(of: 10) else { return (Data(), data) }
        let after = data.index(after: newline)
        return (Data(data[..<after]), Data(data[after...]))
    }

}

struct TaskSample: Sendable {
    let chat: Chat
    let reading: Reading
}
struct AutomaticSelection: Sendable {
    let sample: TaskSample?
    let runningCount: Int
    static func select(_ samples: [TaskSample]) -> AutomaticSelection {
        let waiting = samples.filter { $0.reading.state == .waiting }
        let running = samples.filter { $0.reading.state == .running }
        let candidates = !waiting.isEmpty ? waiting : (running.isEmpty ? samples : running)
        let newest = candidates.enumerated().max { lhs, rhs in
            let left = lhs.element.reading.lastEvent ?? .distantPast
            let right = rhs.element.reading.lastEvent ?? .distantPast
            return left == right ? lhs.offset > rhs.offset : left < right
        }?.element
        return AutomaticSelection(sample: newest, runningCount: running.count)
    }
}

enum TrackingMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
}

struct TrackingPreference: Codable, Equatable, Sendable {
    var mode: TrackingMode = .automatic
    var manualTaskID: String?
    static let defaultsKey = "trackingPreference"

    static func restore(_ data: Data?) -> TrackingPreference {
        guard let data, let preference = try? PropertyListDecoder().decode(Self.self, from: data) else {
            return TrackingPreference()
        }
        return preference
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? PropertyListEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func select(_ samples: [TaskSample]) -> AutomaticSelection {
        if mode == .automatic { return AutomaticSelection.select(samples) }
        let sample = samples.first { $0.chat.id == manualTaskID }
        return AutomaticSelection(sample: sample, runningCount: sample?.reading.state == .running ? 1 : 0)
    }

    var emptyTitle: String {
        if mode == .automatic { return "尚未发现任务" }
        return manualTaskID == nil ? "请选择要跟踪的任务" : "所选任务不可用"
    }

    var emptyDetail: String {
        if mode == .automatic { return "没有找到本机任务记录" }
        return manualTaskID == nil ? "在下方搜索并选择一个本机任务" : "所选任务已归档或不在本机列表中，请重新选择"
    }
}

struct TaskOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let state: TaskState
    var displayTitle: String { title.isEmpty ? "未命名任务" : title }
}

struct TrackingSnapshot: Sendable {
    let preference: TrackingPreference
    let preferenceRevision: Int
    let selection: AutomaticSelection
    let tasks: [TaskOption]
}

// One recursive stream covers every task without opening a descriptor per log.
// Access and lifetime are confined to EventMonitor.queue.
final class DirectoryEvents {
    var stream: FSEventStreamRef?
    var onEvents: (([(String, FSEventStreamEventFlags)]) -> Void)?
    func start(root: String, queue: DispatchQueue) throws {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                nil,
                { _, context, count, paths, flags, _ in
                    guard let context else { return }
                    let owner = Unmanaged<DirectoryEvents>.fromOpaque(context).takeUnretainedValue()
                    let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    owner.onEvents?((0..<count).map { (String(cString: names[$0]), flags[$0]) })
                }, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        else {
            throw Self.unavailable
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw Self.unavailable
        }
        stream = created
    }
    static var unavailable: NSError {
        NSError(domain: "CodexTaskLight", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法启动任务文件监听，正在重试；可打开详情刷新"])
    }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}

// SQLite WAL appends can be coalesced by FSEvents. Keep at most three vnode
// watches (home, newest database, its WAL) for prompt task-list changes.
final class IndexEvents {
    final class Watch {
        let source: any DispatchSourceFileSystemObject
        let inode: UInt64
        let device: Int32

        init(source: any DispatchSourceFileSystemObject, inode: UInt64, device: Int32) {
            self.source = source
            self.inode = inode
            self.device = device
        }
    }

    private var watches: [String: Watch] = [:]

    func sync(root: URL, queue: DispatchQueue, onChange: @escaping () -> Void) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let database = names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }.first
        var desired = [root.path]
        if let database {
            desired.append(root.appendingPathComponent(database).path)
            desired.append(root.appendingPathComponent(database + "-wal").path)
        }
        for path in Array(watches.keys) {
            var info = stat()
            if !desired.contains(path) || stat(path, &info) != 0
                || watches[path]?.inode != info.st_ino || watches[path]?.device != info.st_dev
            {
                watches.removeValue(forKey: path)?.source.cancel()
            }
        }
        for path in desired where watches[path] == nil {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { continue }
                throw Self.unavailable
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                close(fd)
                throw Self.unavailable
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue
            )
            let watch = Watch(source: source, inode: info.st_ino, device: info.st_dev)
            watches[path] = watch
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak watch] in
                guard let watch else { return }
                if !watch.source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self?.watches.removeValue(forKey: path)?.source.cancel()
                }
                onChange()
            }
            source.activate()
        }
    }

    static var unavailable: NSError {
        NSError(domain: "CodexTaskLight", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法启动任务索引监听，正在重试"])
    }

    func stop() {
        for watch in watches.values { watch.source.cancel() }
        watches.removeAll()
    }
}

// All filesystem callbacks, cursor mutations and coalesced reads use one serial queue.
final class EventMonitor: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.codextasklight.events", qos: .utility)
    let reader: LocalReader
    let directoryEvents = DirectoryEvents()
    let indexEvents = IndexEvents()
    var restartEvents = false
    var watchRetry: DispatchWorkItem?
    var watchBackoff: Double = 1
    var known: [Chat] = []
    var samples: [String: TaskSample] = [:]
    var paths = Set<String>()
    var reloadIndex = false
    var readAll = false
    var pending: DispatchWorkItem?
    var expiry: DispatchWorkItem?
    var onUpdate: (@Sendable (TrackingSnapshot, String?) -> Void)?
    var preference: TrackingPreference
    var preferenceRevision = 0
    var useLive: Bool
    lazy var live = LiveStatusClient(queue: queue)
    init(
        reader: LocalReader = LocalReader(), useLive: Bool = true, preference: TrackingPreference = TrackingPreference()
    ) {
        self.reader = reader
        self.useLive = useLive
        self.preference = preference
    }
    func start() {
        queue.async { [self] in
            if useLive {
                live.onChange = { [weak self] in self?.publish() }
                live.start()
            }
            schedule(index: true, all: true)
        }
    }
    func refresh() { queue.async { [self] in schedule(index: true, all: true) } }
    func setPreference(_ preference: TrackingPreference, revision: Int = 0) {
        queue.async { [self] in
            self.preference = preference
            self.preferenceRevision = revision
            publish()
        }
    }
    func syncWatches() throws {
        if restartEvents {
            directoryEvents.stop()
            restartEvents = false
        }
        directoryEvents.onEvents = { [weak self] events in self?.filesChanged(events) }
        try directoryEvents.start(root: reader.home.path, queue: queue)
        try indexEvents.sync(root: reader.home, queue: queue) { [weak self] in self?.schedule(index: true) }
        watchRetry?.cancel()
        watchRetry = nil
        watchBackoff = 1
    }
    func filesChanged(_ events: [(String, FSEventStreamEventFlags)]) {
        let root = reader.home.path
        let recovery = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for (path, flags) in events {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                restartEvents = true
                schedule(index: true, all: true)
            } else if flags & recovery != 0 {
                // Coalesced/dropped events require an event-driven reconciliation.
                schedule(index: true, all: true)
            } else if path == root
                || (path.hasPrefix(root + "/state_") && !path.dropFirst(root.count + 1).contains("/")
                    && (path.hasSuffix(".sqlite") || path.hasSuffix(".sqlite-wal")))
            {
                schedule(index: true)
            } else if path.hasPrefix(root + "/sessions/") || path == root + "/sessions" {
                paths.insert(path)
                let directory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                schedule(index: directory || !known.contains(where: { $0.path == path }), all: directory)
            } else if known.contains(where: { $0.path == path }) {
                paths.insert(path)
                schedule()
            }
        }
    }
    func retryWatching() {
        guard watchRetry == nil else { return }
        let job = DispatchWorkItem { [weak self] in
            self?.watchRetry = nil
            self?.schedule(index: true, all: true)
        }
        watchRetry = job
        queue.asyncAfter(deadline: .now() + watchBackoff, execute: job)
        watchBackoff = min(30, watchBackoff * 2)
    }
    func schedule(index: Bool = false, all: Bool = false) {
        reloadIndex = reloadIndex || index
        readAll = readAll || all
        guard pending == nil else { return }
        // A fixed coalescing window never starves under continuous writes.
        let job = DispatchWorkItem { [weak self] in self?.process() }
        pending = job
        queue.asyncAfter(deadline: .now() + 0.15, execute: job)
    }
    func process() {
        pending = nil
        let index = reloadIndex
        let all = readAll
        let changed = paths
        reloadIndex = false
        readAll = false
        paths.removeAll()
        do {
            // Start before taking the snapshot, so writes during loading are queued.
            try syncWatches()
            if index {
                known = try reader.list()
                if useLive { live.follow(Set(known.map(\.id))) }
                let liveIDs = Set(known.map(\.id))
                let livePaths = Set(known.map(\.path))
                samples = samples.filter { liveIDs.contains($0.key) }
                reader.cache = reader.cache.filter { livePaths.contains($0.key) }
            }
            for chat in known
            where all || changed.contains(chat.path) || samples[chat.id] == nil
                || samples[chat.id]?.chat.path != chat.path
            {
                do { samples[chat.id] = TaskSample(chat: chat, reading: try reader.readRaw(chat)) } catch {
                    samples[chat.id] = TaskSample(chat: chat, reading: Reading(detail: "无法读取这条任务的记录"))
                }
            }
            publish()
        } catch {
            publish(error: error.localizedDescription)
            let problem = error as NSError
            if directoryEvents.stream == nil || (problem.domain == "CodexTaskLight" && problem.code == 4) {
                retryWatching()
            }
        }
    }
    func publish(error: String? = nil) {
        let current = known.map { chat in
            let fallback = (samples[chat.id]?.reading ?? Reading()).expiring()
            return TaskSample(chat: chat, reading: useLive ? live.reading(for: chat.id, fallback: fallback) : fallback)
        }
        let snapshot = TrackingSnapshot(
            preference: preference,
            preferenceRevision: preferenceRevision,
            selection: preference.select(current),
            tasks: current.map { TaskOption(id: $0.chat.id, title: $0.chat.title, state: $0.reading.state) }
        )
        onUpdate?(snapshot, error)
        expiry?.cancel()
        expiry = nil
        // A one-shot deadline marks silence as unknown, without polling any files.
        if let deadline = samples.values.compactMap({ sample -> Date? in
            guard sample.reading.state == .running, let time = sample.reading.lastEvent else { return nil }
            let expiry = time.addingTimeInterval(180)
            return expiry > Date() ? expiry : nil
        }).min() {
            let job = DispatchWorkItem { [weak self] in self?.publish() }
            expiry = job
            queue.asyncAfter(deadline: .now() + max(0.01, deadline.timeIntervalSinceNow), execute: job)
        }
    }
    func stop() {
        queue.sync {
            if useLive {
                live.onChange = nil
                live.stop()
            }
            pending?.cancel()
            pending = nil
            expiry?.cancel()
            expiry = nil
            watchRetry?.cancel()
            watchRetry = nil
            directoryEvents.stop()
            indexEvents.stop()
        }
    }
}

@MainActor
final class Monitor: ObservableObject {
    @Published var reading = Reading()
    @Published var selected = ""
    @Published var currentTitle = "尚未发现任务"
    @Published var runningCount = 0
    @Published private(set) var trackingPreference: TrackingPreference
    @Published private(set) var tasks: [TaskOption] = []
    @Published var taskSearchText = ""
    var onChange: (() -> Void)?
    let events: EventMonitor
    private let defaults: UserDefaults
    private var preferenceRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let preference = TrackingPreference.restore(defaults.data(forKey: TrackingPreference.defaultsKey))
        trackingPreference = preference
        events = EventMonitor(preference: preference)
        currentTitle = preference.emptyTitle
    }

    func start() {
        events.onUpdate = { [weak self] snapshot, error in
            Task { @MainActor [weak self] in
                // Discard queued updates from before a mode/target change.
                guard let self, snapshot.preference == self.trackingPreference,
                    snapshot.preferenceRevision == self.preferenceRevision
                else { return }
                let selection = snapshot.selection
                let reading =
                    error.map { Reading(detail: $0) } ?? selection.sample?.reading
                    ?? Reading(detail: snapshot.preference.emptyDetail)
                if self.reading != reading { self.reading = reading }
                let selected = selection.sample?.chat.id ?? ""
                if self.selected != selected { self.selected = selected }
                let title = selection.sample?.chat.title ?? snapshot.preference.emptyTitle
                if self.currentTitle != title { self.currentTitle = title }
                if self.runningCount != selection.runningCount { self.runningCount = selection.runningCount }
                if self.tasks != snapshot.tasks { self.tasks = snapshot.tasks }
                self.onChange?()
            }
        }
        events.start()
    }
    func refresh() { events.refresh() }

    func setMode(_ mode: TrackingMode) {
        updatePreference(TrackingPreference(mode: mode, manualTaskID: trackingPreference.manualTaskID))
    }

    func followTask(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        updatePreference(TrackingPreference(mode: .manual, manualTaskID: id))
    }

    private func updatePreference(_ preference: TrackingPreference) {
        guard preference != trackingPreference else { return }
        preferenceRevision += 1
        trackingPreference = preference
        preference.save(to: defaults)
        selected = ""
        reading = Reading(detail: "正在切换跟踪任务")
        currentTitle =
            preference.mode == .manual
            ? tasks.first(where: { $0.id == preference.manualTaskID })?.displayTitle ?? preference.emptyTitle
            : "正在自动选择任务"
        runningCount = 0
        onChange?()
        events.setPreference(preference, revision: preferenceRevision)
    }
}

struct StatusPanel: View {
    @ObservedObject var monitor: Monitor
    private var matchingTasks: [TaskOption] {
        let query = monitor.taskSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? monitor.tasks : monitor.tasks.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    private var trackingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("跟踪方式", selection: Binding(get: { monitor.trackingPreference.mode }, set: monitor.setMode)) {
                Text("自动识别").tag(TrackingMode.automatic)
                Text("手动指定").tag(TrackingMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if monitor.trackingPreference.mode == .manual {
                TextField("搜索任务名称", text: $monitor.taskSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索本机任务")
                if monitor.tasks.isEmpty {
                    Text("尚未发现可选择的本机任务").font(.caption).foregroundStyle(.secondary)
                } else if matchingTasks.isEmpty {
                    Text("没有匹配的任务").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(matchingTasks) { task in
                                Button {
                                    monitor.followTask(task.id)
                                } label: {
                                    HStack(spacing: 7) {
                                        Circle().fill(Color(nsColor: task.state.color)).frame(width: 6, height: 6)
                                        Text(task.displayTitle).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if task.id == monitor.trackingPreference.manualTaskID {
                                            Image(systemName: "checkmark").font(.caption)
                                        }
                                    }
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        task.id == monitor.trackingPreference.manualTaskID
                                            ? Color.accentColor.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(task.displayTitle + " · " + task.state.title)
                                .accessibilityLabel(task.displayTitle + "，" + task.state.title)
                            }
                        }
                    }.frame(height: 132)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("CodexTaskLight").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).help("刷新状态")
            }
            HStack(spacing: 12) {
                ForEach([TaskState.failed, .running, .completed], id: \.rawValue) { state in
                    Circle().fill(
                        Color(
                            nsColor: (monitor.reading.state == state
                                || (state == .failed && monitor.reading.state == .waiting))
                                ? state.color : .quaternaryLabelColor)
                    )
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
                Spacer()
                Text(monitor.reading.state.title).font(.system(size: 13, weight: .medium))
            }.padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            trackingControls
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(monitor.trackingPreference.mode == .automatic ? "自动跟踪任务" : "手动跟踪任务")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if monitor.trackingPreference.mode == .automatic && monitor.runningCount > 1 {
                        Text("\(monitor.runningCount) 个执行中").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(monitor.currentTitle).font(.system(size: 13, weight: .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(monitor.reading.detail).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                if let event = monitor.reading.lastEvent {
                    Text("最近记录：" + event.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(
                        .tertiary)
                }
            }
            Divider()
            Text("黄：执行中  ·  绿：完成  ·  红：异常或中断\n红灯也表示等待确认或审批；处理后恢复黄灯。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(5)
            HStack {
                Text(monitor.trackingPreference.mode == .automatic ? "实时状态 · 自动识别" : "实时状态 · 手动指定")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("打开 Codex") {
                    NSWorkspace.shared.open(URL(string: "codex://threads/" + monitor.selected)!)
                }.buttonStyle(.plain).font(.caption).disabled(monitor.selected.isEmpty)
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 338)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let popover = NSPopover()
    var floating: FloatingLightController?
    func applicationWillTerminate(_ notification: Notification) { monitor.events.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floating?.setVisible(true)
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusPanel(monitor: monitor))
        floating = FloatingLightController(onClick: { [weak self] in
            guard let self, let view = self.floating?.light else { return }
            self.showDetails(from: view)
        })
        monitor.onChange = { [weak self] in self?.update() }
        update()
        monitor.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let view = self.floating?.light else { return }
                self.showDetails(from: view)
            }
        }
    }
    func update() {
        floating?.update(state: monitor.reading.state, title: monitor.currentTitle)
    }
    func showDetails(from view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

enum FileEventTests {
    static func run(stress: Bool = false) {
        var originalLimit = rlimit()
        precondition(getrlimit(RLIMIT_NOFILE, &originalLimit) == 0)
        if stress {
            var limited = rlimit(rlim_cur: min(64, originalLimit.rlim_cur), rlim_max: originalLimit.rlim_max)
            precondition(setrlimit(RLIMIT_NOFILE, &limited) == 0)
        }
        defer { if stress { precondition(setrlimit(RLIMIT_NOFILE, &originalLimit) == 0) } }
        // macOS can exclude temporary/cache trees from FSEvents delivery.
        // Use a disposable fixture under the working directory instead.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".codextasklight-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("sessions/one.jsonl")
        try! Data().write(to: first)
        var db: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        sql(
            "PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, archived INTEGER, agent_path TEXT, updated_at INTEGER);"
        )
        func add(_ id: String, _ path: URL, _ time: Int) {
            sql("INSERT INTO threads VALUES ('\(id)', '\(id)', '\(path.path)', 0, NULL, \(time));")
        }
        add("one", first, 1)
        let reader = LocalReader(home: root)
        let monitor = EventMonitor(reader: reader, useLive: false)
        let semaphore = DispatchSemaphore(value: 0)
        final class Inbox: @unchecked Sendable {
            let lock = NSLock()
            var latest: AutomaticSelection?
            var error: String?
        }
        let inbox = Inbox()
        func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        monitor.onUpdate = { snapshot, problem in
            let selection = snapshot.selection
            inbox.lock.lock()
            inbox.latest = selection
            inbox.error = problem
            inbox.lock.unlock()
            FileHandle.standardOutput.write(
                Data(
                    ("EVENT " + (selection.sample?.chat.id ?? "none") + " "
                        + (selection.sample?.reading.state.rawValue ?? "none") + " error=" + (problem ?? "none") + "\n")
                        .utf8))
            semaphore.signal()
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = DispatchTime.now() + 8
            while true {
                if condition() { return }
                while semaphore.wait(timeout: .now()) != .success {
                    precondition(DispatchTime.now() < deadline, "Timed out waiting for filesystem event")
                    CFRunLoopRunInMode(.defaultMode, 0.05, true)
                }
                inbox.lock.lock()
                let problem = inbox.error
                inbox.lock.unlock()
                precondition(problem == nil, "File watcher failed: " + (problem ?? ""))
            }
        }
        func wait(_ id: String, _ state: TaskState) {
            report("WAIT " + id + " " + state.rawValue)
            waitUntil {
                inbox.lock.lock()
                defer { inbox.lock.unlock() }
                return inbox.latest?.sample?.chat.id == id && inbox.latest?.sample?.reading.state == state
            }
        }
        func line(_ type: String, timestamp: String? = nil) -> Data {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = timestamp ?? formatter.string(from: Date())
            let value: [String: Any] = ["type": "event_msg", "timestamp": date, "payload": ["type": type]]
            var result = try! JSONSerialization.data(withJSONObject: value)
            result.append(10)
            return result
        }
        func append(_ data: Data, to path: URL) {
            let handle = try! FileHandle(forWritingTo: path)
            try! handle.seekToEnd()
            try! handle.write(contentsOf: data)
            try! handle.synchronize()
            try! handle.close()
        }
        monitor.start()
        defer { monitor.stop() }
        wait("one", .unknown)
        append(line("task_started"), to: first)
        wait("one", .running)
        let finished = line("task_complete")
        append(Data(finished.prefix(finished.count / 2)), to: first)
        // Exercise partial-line cursors directly, without relying on delivery timing.
        monitor.queue.sync {
            let raw = try! reader.readRaw(Chat(id: "one", title: "one", path: first.path))
            precondition(raw.state == .running)
        }
        append(Data(finished.suffix(finished.count - finished.count / 2)), to: first)
        wait("one", .completed)
        monitor.queue.sync {
            let before = reader.bytesRead
            _ = try! reader.readRaw(Chat(id: "one", title: "one", path: first.path))
            precondition(reader.bytesRead == before, "Unchanged log was reread")
        }
        let folder = root.appendingPathComponent("sessions/new-date")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let second = folder.appendingPathComponent("two.jsonl")
        try! line("task_started").write(to: second)
        add("two", second, 2)
        wait("two", .running)
        // Atomic replacement uses a new inode; stale cursors must be discarded.
        try! line("turn_aborted").write(to: second, options: .atomic)
        wait("two", .failed)
        // Truncation in place must reset the cursor as well.
        try! line("task_started").write(to: second)
        wait("two", .running)
        // Pin a completed task while another task is running, then verify that
        // incoming events continue to update the pin without switching targets.
        monitor.setPreference(TrackingPreference(mode: .manual, manualTaskID: "one"))
        wait("one", .completed)
        append(line("turn_aborted"), to: second)
        waitUntil { monitor.queue.sync { monitor.samples["two"]?.reading.state == .failed } }
        inbox.lock.lock()
        precondition(inbox.latest?.sample?.chat.id == "one")
        inbox.lock.unlock()
        append(line("task_started"), to: first)
        wait("one", .running)
        append(line("task_complete"), to: first)
        wait("one", .completed)
        sql("UPDATE threads SET archived = 1 WHERE id = 'one';")
        waitUntil {
            inbox.lock.lock()
            defer { inbox.lock.unlock() }
            return inbox.latest?.sample == nil
        }
        precondition(monitor.queue.sync { monitor.preference.mode == .manual })
        sql("UPDATE threads SET archived = 0 WHERE id = 'one';")
        wait("one", .completed)
        monitor.setPreference(TrackingPreference())
        append(line("task_started"), to: second)
        wait("two", .running)
        report("PASS: manual pin, incoming updates, unavailable/returned target and switching back to automatic")
        if stress {
            func descriptors() -> Int { (0..<64).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
            let baseline = descriptors()
            let historyFolder = root.appendingPathComponent("sessions/history")
            try! FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
            let old = line("task_complete", timestamp: "2020-01-01T00:00:00Z")
            for i in 0..<128 {
                let path = historyFolder.appendingPathComponent("old-\(i).jsonl")
                try! old.write(to: path)
                add("old-\(i)", path, -i)
            }
            waitUntil {
                monitor.queue.sync {
                    monitor.known.count == 130
                        && (0..<128).allSatisfy { monitor.samples["old-\($0)"]?.reading.state == .completed }
                }
            }
            let loaded = descriptors()
            precondition(loaded <= baseline + 4, "Watcher descriptor usage grew with historical tasks")
            // Complete the current task, then reactivate the oldest historical log
            // without touching SQLite: every log must remain covered by the stream.
            append(line("task_complete"), to: second)
            wait("two", .completed)
            let oldest = historyFolder.appendingPathComponent("old-127.jsonl")
            append(line("task_started"), to: oldest)
            wait("old-127", .running)
            append(line("task_complete"), to: oldest)
            wait("old-127", .completed)
            let latest = root.appendingPathComponent("sessions/newest/new.jsonl")
            try! FileManager.default.createDirectory(
                at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! line("task_started").write(to: latest)
            add("new", latest, 200)
            wait("new", .running)
            // Exercise recovery from coalesced/dropped notifications explicitly.
            monitor.queue.sync {
                monitor.samples.removeAll()
                monitor.filesChanged([
                    (
                        root.path,
                        FSEventStreamEventFlags(
                            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
                    )
                ])
            }
            waitUntil { monitor.queue.sync { monitor.samples.count == 131 } }
            // Restart the stream and prove later writes still reach the monitor.
            monitor.queue.sync {
                monitor.restartEvents = true
                monitor.schedule(index: true, all: true)
            }
            waitUntil { monitor.queue.sync { !monitor.restartEvents } }
            append(line("turn_aborted"), to: latest)
            wait("new", .failed)
            report(
                "PASS: 64-descriptor limit, 131 tasks, descriptors \(baseline) -> \(loaded), oldest-log append without index changes, new-task admission, dropped-event reconciliation and stream restart"
            )
        }
        // Silence expiry is computed from cached state, with no filesystem scanning.
        let stale = Reading(state: .running, lastEvent: Date().addingTimeInterval(-181))
        precondition(stale.expiring().state == .unknown)
        print(
            "PASS: real filesystem notifications, incremental/partial append, unchanged-file cache, new directory/task discovery, atomic replacement, truncation and silence expiry"
        )
    }
}

@main
struct CodexTaskLightApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--file-test") {
            FileEventTests.run()
            return
        }
        if CommandLine.arguments.contains("--resource-test") {
            FileEventTests.run(stress: true)
            return
        }
        if CommandLine.arguments.contains("--test") {
            let now = ISO8601DateFormatter().string(from: Date())
            func event(_ type: String) -> String {
                let data = try! JSONSerialization.data(withJSONObject: [
                    "type": "event_msg", "timestamp": now, "payload": ["type": type],
                ])
                return String(decoding: data, as: UTF8.self) + "\n"
            }
            precondition(EventParser.read(event("task_started")).state == .running)
            precondition(EventParser.read(event("task_started") + event("task_complete")).state == .completed)
            precondition(EventParser.read(event("task_started") + event("turn_aborted")).state == .failed)
            precondition(EventParser.read(event("task_complete") + event("task_started")).state == .running)
            precondition(EventParser.read("bad json\n").state == .unknown)
            let stale = event("task_started").replacingOccurrences(of: now, with: "2020-01-01T00:00:00Z")
            precondition(EventParser.read(stale).state == .unknown)
            precondition(EventParser.read(event("task_started")).lastEvent != nil)
            func response(_ payload: [String: Any]) -> String {
                let data = try! JSONSerialization.data(withJSONObject: [
                    "type": "response_item", "timestamp": now, "payload": payload,
                ])
                return String(decoding: data, as: UTF8.self) + "\n"
            }
            let ask = response([
                "type": "function_call", "name": "request_user_input_async", "call_id": "question",
                "arguments": "{\"questions\":[{},{}]}",
            ])
            let requestState = EventParser.read(event("task_started") + ask, expire: false)
            precondition(requestState.expiring().state == .waiting && requestState.pendingQuestionIDs.count == 2)
            func reply(_ index: Int) -> String {
                let key = String(
                    decoding: try! JSONSerialization.data(withJSONObject: [
                        "request_user_input_async", "question", index,
                    ]), as: UTF8.self)
                let body = String(
                    decoding: try! JSONSerialization.data(withJSONObject: [["questionItemId": key, "answer": "ok"]]),
                    as: UTF8.self)
                return response([
                    "type": "message", "role": "user",
                    "content": [
                        ["text": "<send_user_message_question_reply>" + body + "</send_user_message_question_reply>"]
                    ],
                ])
            }
            let partlyAnswered = EventParser.read(reply(0), initial: requestState, expire: false)
            precondition(partlyAnswered.expiring().state == .waiting && partlyAnswered.pendingQuestionIDs.count == 1)
            let answeredQuestion = EventParser.read(reply(1), initial: partlyAnswered, expire: false)
            precondition(answeredQuestion.expiring().state == .running && answeredQuestion.pendingQuestionIDs.isEmpty)
            precondition(EventParser.read(event("task_started"), initial: requestState).pendingQuestionIDs.isEmpty)
            let accepted = response([
                "type": "function_call_output", "call_id": "question", "output": "{\"accepted\":true}",
            ])
            let acceptedEnd = EventParser.read(accepted + event("task_complete"), initial: requestState, expire: false)
            precondition(acceptedEnd.expiring().state == .waiting && acceptedEnd.pendingQuestionIDs.count == 2)
            precondition(EventParser.read(reply(0) + reply(1), initial: acceptedEnd).state == .completed)
            for output in [
                "{\"accepted\":false,\"error\":\"validation failed\"}",
                "{\"isError\":true}", "{\"status\":\"cancelled\"}",
                "{\"result\":{\"accepted\":false}}",
                "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"accepted\\\":false}\"}]}",
                "Error: question could not be shown",
            ] {
                for type in ["function_call_output", "custom_tool_call_output"] {
                    let rejected = response(["type": type, "call_id": "question", "output": output])
                    let resumed = EventParser.read(rejected, initial: requestState, expire: false)
                    precondition(resumed.pendingQuestionIDs.isEmpty && resumed.expiring().state == .running)
                    precondition(EventParser.read(event("task_complete"), initial: resumed).state == .completed)
                }
            }
            let anotherAsk = response([
                "type": "custom_tool_call", "name": "functions.request_user_input_async", "call_id": "another",
                "input": "{\"questions\":[{}]}",
            ])
            let rejectFirst = response([
                "type": "function_call_output", "call_id": "question", "output": "{\"accepted\":false}",
            ])
            let independent = EventParser.read(anotherAsk + rejectFirst, initial: requestState, expire: false)
            precondition(independent.pendingQuestionIDs == ["another:0"] && independent.expiring().state == .waiting)
            let unrelatedError = response([
                "type": "function_call_output", "call_id": "unrelated", "output": "{\"isError\":true}",
            ])
            precondition(
                EventParser.read(unrelatedError, initial: requestState, expire: false).pendingQuestionIDs
                    == requestState.pendingQuestionIDs)
            let liveActive: [String: Any] = ["threadRuntimeStatus": ["type": "active", "activeFlags": []]]
            let liveWait: [String: Any] = [
                "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]]
            ]
            let fallback = Reading(state: .running)
            let liveIdle: [String: Any] = ["threadRuntimeStatus": ["type": "idle"]]
            for type in ["turn_aborted", "task_aborted", "task_failed", "turn_failed"] {
                let failed = EventParser.read(event("task_started") + event(type), expire: false)
                precondition(LiveStatusClient.derive(liveIdle, fallback: failed) == failed)
                let resumed = EventParser.read(event("task_started"), initial: failed, expire: false)
                precondition(LiveStatusClient.derive(liveActive, fallback: resumed).state == .running)
                let finished = EventParser.read(event("task_complete"), initial: resumed, expire: false)
                precondition(LiveStatusClient.derive(liveIdle, fallback: finished).state == .completed)
            }
            precondition(LiveStatusClient.derive(liveIdle, fallback: Reading()).state == .completed)
            precondition(LiveStatusClient.derive(liveWait, fallback: fallback).state == .waiting)
            precondition(LiveStatusClient.derive(liveActive, fallback: fallback).state == .running)
            let inputWait: [String: Any] = ["requests": [["method": "item/tool/requestUserInput"]]]
            precondition(LiveStatusClient.derive(inputWait, fallback: fallback).state == .waiting)
            let answered: [String: Any] = [
                "requests": [["method": "item/tool/requestUserInput", "completed": true]],
                "threadRuntimeStatus": ["type": "active", "activeFlags": []],
            ]
            precondition(LiveStatusClient.derive(answered, fallback: fallback).state == .running)
            var patchState = liveActive
            patchState = try! StatePatch.apply(
                patchState, path: ["threadRuntimeStatus", "activeFlags"], operation: "replace",
                value: ["waitingOnApproval"])
            precondition(LiveStatusClient.derive(patchState, fallback: fallback).state == .waiting)
            patchState = try! StatePatch.apply(
                patchState, path: ["threadRuntimeStatus", "activeFlags"], operation: "replace", value: [String]())
            precondition(LiveStatusClient.derive(patchState, fallback: fallback).state == .running)
            let gapClient = LiveStatusClient(queue: DispatchQueue(label: "revision-test"))
            gapClient.clientID = "observer"
            gapClient.followed = ["thread"]
            gapClient.receive([
                "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                "sourceClientId": "owner",
                "params": [
                    "conversationId": "thread", "hostId": "local",
                    "change": ["type": "snapshot", "revision": 3, "conversationState": liveWait],
                ],
            ])
            precondition(gapClient.reading(for: "thread", fallback: fallback).state == .waiting)
            gapClient.receive([
                "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                "sourceClientId": "owner",
                "params": [
                    "conversationId": "thread", "hostId": "local",
                    "change": ["type": "patches", "baseRevision": 1, "revision": 2, "patches": []],
                ],
            ])
            precondition(gapClient.reading(for: "thread", fallback: fallback).state == .unknown)
            gapClient.clientID = nil
            precondition(gapClient.reading(for: "thread", fallback: fallback).state == .unknown)
            let older = Date().addingTimeInterval(-20)
            let newer = Date()
            let a = Chat(id: "a", title: "A", path: "")
            let b = Chat(id: "b", title: "B", path: "")
            let activeA = TaskSample(chat: a, reading: Reading(state: .running, lastEvent: older))
            let activeB = TaskSample(chat: b, reading: Reading(state: .running, lastEvent: newer))
            let doneA = TaskSample(chat: a, reading: Reading(state: .completed, lastEvent: newer))
            let doneB = TaskSample(chat: b, reading: Reading(state: .completed, lastEvent: older))
            precondition(AutomaticSelection.select([activeA, doneB]).sample?.chat.id == "a")
            let waitingB = TaskSample(chat: b, reading: Reading(state: .waiting, lastEvent: older))
            precondition(AutomaticSelection.select([activeA, waitingB]).sample?.chat.id == "b")
            let two = AutomaticSelection.select([activeA, activeB])
            precondition(two.sample?.chat.id == "b" && two.runningCount == 2)
            precondition(AutomaticSelection.select([doneA, activeB]).sample?.chat.id == "b")
            precondition(AutomaticSelection.select([doneB, doneA]).sample?.chat.id == "a")
            precondition(AutomaticSelection.select([]).sample == nil)
            let unreadable = TaskSample(chat: b, reading: Reading())
            precondition(AutomaticSelection.select([unreadable, activeA]).sample?.chat.id == "a")
            let manualA = TrackingPreference(mode: .manual, manualTaskID: "a")
            precondition(manualA.select([doneA, activeB]).sample?.chat.id == "a")
            precondition(manualA.select([doneA, waitingB]).sample?.reading.state == .completed)
            precondition(manualA.select([activeA, waitingB]).sample?.reading.state == .running)
            let failedA = TaskSample(chat: a, reading: Reading(state: .failed, lastEvent: newer))
            precondition(manualA.select([failedA, activeB]).sample?.reading.state == .failed)
            precondition(manualA.select([activeB]).sample == nil)
            precondition(manualA.select([]).sample == nil)
            precondition(TrackingPreference(mode: .manual).select([activeA, activeB]).sample == nil)
            let autoAgain = TrackingPreference(mode: .automatic, manualTaskID: "a")
            precondition(autoAgain.select([activeA, waitingB]).sample?.chat.id == "b")
            for preference in [TrackingPreference(), manualA, autoAgain] {
                let data = try! PropertyListEncoder().encode(preference)
                precondition(TrackingPreference.restore(data) == preference)
            }
            precondition(TrackingPreference.restore(nil) == TrackingPreference())
            precondition(TrackingPreference.restore(Data("invalid".utf8)) == TrackingPreference())
            print(
                "PASS: manual target selection, no fallback for missing target, automatic handoff and saved preference restoration"
            )
            print(
                "PASS: lifecycle parsing, automatic running selection, concurrent tasks, completion handoff, empty and unreadable records"
            )
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
